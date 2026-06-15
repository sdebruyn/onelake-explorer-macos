// FPEEngineHost.swift
// Per-domain OfemEngine container.
//
// Each File Provider domain corresponds to exactly one account alias.
// The FPE spawns one OfemEngine per domain on first use and shuts it
// down when the extension is invalidated. The engine is constructed
// lazily on the first enumerator call so the FPE process does not
// spend resources building the engine for domains that are loaded but
// never opened.
//
// Thread safety: `FPEEngineHost` uses an NSLock to serialise mutations
// to `_engine` and `_buildError`. `buildEngine()` is a throwing
// synchronous function; concurrent callers race to a single-flight Task
// so the engine is built exactly once even under concurrent pressure.
//
// Process-wide config store: all FPEEngineHost instances in the same
// FPE process share ONE OfemConfigStore via `FPEEngineHost.sharedConfigStore`.
// This guarantees that concurrent XPC handlers for different domains
// (different aliases) read and write the same in-memory snapshot.
// OfemClientControlService accesses the store via `engineHost.configStore()`
// which returns this shared instance.
//
// Process-wide shared subsystems (arch-04): all FPEEngineHost instances also
// share one CacheStore, one TelemetryClient, and one HTTPGateRegistry via the
// `shared*` static properties below.  This eliminates:
//   - N DatabasePool writers over the same SQLite file.
//   - N BlobShardCache instances over the same shard directory.
//   - N TelemetryClient flush timers.
//   - N HTTPGateRegistry instances that would multiply per-host budgets.
//   - Blob byte-budget enforcement N times over a shared store (each engine
//     believed it could use the full cap independently).
//
// Telemetry ownership: because the TelemetryClient is shared, individual
// OfemEngine.shutdown() calls do NOT stop the flush timer — only the owning
// container does.  After the last FPEEngineHost.shutdown() returns, call
// FPEEngineHost.shutdownSharedSubsystems() to flush remaining events and
// cancel the flush timer.  In normal FPE operation the OS terminates the
// process immediately after the last domain is invalidated, so this acts as
// a belt-and-suspenders process-exit hook.

import FileProvider
import Foundation
import OfemKit
import os.log

// MARK: - EngineProviding

/// The testability seam between the FPE callbacks and the engine.
///
/// `FileProviderExtension`, `OfemFPEEnumerator`, and `OfemClientControlService`
/// depend on this protocol rather than on the concrete `FPEEngineHost`. Tests
/// inject a `MockEngineHost` that conforms to this protocol, allowing the
/// callback logic to be verified without a live `fileproviderd` or a real
/// `OfemEngine`.
protocol EngineProviding: AnyObject, Sendable {
    /// The account alias this provider serves.
    var alias: String { get }

    /// Returns the engine, building it on first call.
    ///
    /// Throws if the host has been shut down or if the build fails.
    func engine() async throws -> OfemEngine

    /// Returns the engine if it is already built, without triggering a build.
    func existingEngine() -> OfemEngine?

    /// Returns the process-wide config store.
    func configStore() throws -> OfemConfigStore

    /// Shuts down the current engine and rebuilds it on next access.
    func reloadEngine() async

    /// Permanently shuts the engine down. Subsequent `engine()` calls throw.
    func shutdown() async
}

/// Per-domain engine container.
///
/// Constructed once per `FileProviderExtension` instance (one per alias).
/// The `OfemEngine` inside is built lazily on the first call that needs it.
final class FPEEngineHost: EngineProviding {
    private static let log = Logger(
        subsystem: "dev.debruyn.ofem.fileprovider",
        category: "engine-host"
    )

    /// The account alias this host serves.
    let alias: String

    /// The File Provider domain. Retained for diagnostics.
    let domain: NSFileProviderDomain

    // MARK: - Process-wide shared config store

    // All FPEEngineHost instances in this process share one OfemConfigStore.
    // This eliminates the "split-brain" hazard where two hosts each hold their
    // own load-once snapshot and silently revert each other's writes.
    private static let sharedStoreLock = NSLock()
    private static nonisolated(unsafe) var _sharedConfigStore: OfemConfigStore?

    /// Returns the process-wide OfemConfigStore, creating it on first call.
    ///
    /// All FPEEngineHost instances (one per domain) in the same FPE process
    /// share this single store so their XPC handlers all read and write the
    /// same in-memory snapshot. Cross-process safety (host vs FPE) is handled
    /// by `OfemConfigStore.updateAndSave`, which uses `fcntl(2)` record locks
    /// to serialise writes at the file level.
    ///
    /// - Throws: `OfemConfigError` on TOML parse failure (first call only).
    static func sharedConfigStore() throws -> OfemConfigStore {
        try sharedStoreLock.withLock {
            if let cs = _sharedConfigStore { return cs }
            let cs = try OfemConfigStore()
            _sharedConfigStore = cs
            return cs
        }
    }

    // MARK: - Process-wide shared subsystems (arch-04)

    // CacheStore, TelemetryClient, and HTTPGateRegistry are shared across all
    // FPEEngineHost instances in this process.  Building N copies over the same
    // on-disk state causes:
    //   - N DatabasePool writers contending over one SQLite WAL file.
    //   - N BlobShardCache instances over the same shard directory.
    //   - Blob byte-budget multiplied: each engine believed it owned the full cap.
    //   - N TelemetryClient flush timers.
    //   - N HTTPGateRegistry instances multiplying per-endpoint budgets.
    // One shared instance of each fixes all of the above.

    private static let sharedSubsystemsLock = NSLock()
    private static nonisolated(unsafe) var _sharedCache: CacheStore?
    private static nonisolated(unsafe) var _sharedTelemetry: TelemetryClient?
    private static nonisolated(unsafe) var _sharedGateRegistry: HTTPGateRegistry?

    /// Returns (or lazily creates) the process-wide CacheStore.
    ///
    /// The first call constructs the store from the default `OfemPaths.cacheDir`
    /// and the `cfg.cache.maxBytes` limit read from the shared config store.
    ///
    /// `CacheStore.init` performs directory creation, SQLite open, and an
    /// orphan sweep.  To avoid blocking other shared-subsystem callers for the
    /// full duration of that I/O, the construction is done **outside** the
    /// lock using a double-checked pattern: read config under the lock, build
    /// outside, then re-acquire to CAS the result.  If two threads race on the
    /// very first call they may each construct a store; only the first one to
    /// re-acquire the lock wins, and the duplicate is discarded (harmless
    /// because `CacheStore.init` is idempotent for the same directory).
    ///
    /// - Throws: `CacheError` if the SQLite file cannot be opened or migrated.
    static func sharedCache() throws -> CacheStore {
        // Fast path — already created.
        if let c = sharedSubsystemsLock.withLock({ _sharedCache }) { return c }

        // Build outside the lock to avoid blocking other callers during I/O.
        let cfg = try sharedSubsystemsLock.withLock { try sharedConfigStore().snapshot() }
        let paths = OfemPaths()
        let candidate = try CacheStore(root: paths.cacheDir, maxBlobBytes: cfg.cache.maxBytes)

        // CAS: install only if no one else already created it.
        return sharedSubsystemsLock.withLock {
            if let c = _sharedCache { return c }
            _sharedCache = candidate
            return candidate
        }
    }

    /// Returns (or lazily creates) the process-wide TelemetryClient.
    ///
    /// Uses the same double-checked pattern as `sharedCache()` to avoid
    /// running `AppInsightsSink.init` under the broad subsystems lock.
    ///
    /// - Throws: `OfemConfigError` if the shared config store cannot be loaded.
    static func sharedTelemetry() throws -> TelemetryClient {
        // Fast path — already created.
        if let t = sharedSubsystemsLock.withLock({ _sharedTelemetry }) { return t }

        // Build outside the lock.
        let cfg = try sharedSubsystemsLock.withLock { try sharedConfigStore().snapshot() }
        let telSink: any TelemetrySink
        if cfg.telemetry,
           let sink = try? AppInsightsSink(
               connectionString: BuildInfo.appInsightsConnectionString,
               installID: cfg.installID,
               appVersion: BuildInfo.version
           ) {
            telSink = sink
        } else {
            telSink = NoopTelemetrySink()
        }
        let candidate = TelemetryClient(
            sink: telSink,
            appVersion: BuildInfo.version,
            installID: cfg.installID,
            configuration: TelemetryConfiguration(optOut: !cfg.telemetry)
        )

        // CAS: install only if no one else already created it.
        return sharedSubsystemsLock.withLock {
            if let t = _sharedTelemetry { return t }
            _sharedTelemetry = candidate
            return candidate
        }
    }

    /// Returns (or lazily creates) the process-wide HTTPGateRegistry.
    static func sharedGateRegistry() -> HTTPGateRegistry {
        sharedSubsystemsLock.withLock {
            if let g = _sharedGateRegistry { return g }
            let g = HTTPGateRegistry.makeDefault()
            _sharedGateRegistry = g
            return g
        }
    }

    /// Shuts down the process-wide shared subsystems and performs a final
    /// telemetry flush.
    ///
    /// Call this once, after **all** per-alias engines and their
    /// `FPEEngineHost` containers have been shut down (i.e. after the last
    /// `FPEEngineHost.shutdown()` completes).  In normal FPE operation the
    /// OS terminates the extension process after the last domain is
    /// invalidated, so this method acts as a belt-and-suspenders process-exit
    /// hook that guarantees the final telemetry batch is flushed before the
    /// process exits.
    ///
    /// This is distinct from `OfemEngine.shutdown()` for injected-subsystem
    /// engines: individual engine shutdown does **not** stop the shared
    /// `TelemetryClient` so that the flush timer keeps running while other
    /// domains are still active.
    static func shutdownSharedSubsystems() async {
        let telemetry = sharedSubsystemsLock.withLock { _sharedTelemetry }
        if let t = telemetry {
            await t.shutdown()
        }
    }

    /// Invalidates all process-wide shared subsystem singletons.
    ///
    /// **Test-only.** Nils out the shared singletons so the next call to
    /// `sharedCache()`, `sharedTelemetry()`, or `sharedGateRegistry()` starts
    /// fresh.  Only safe to call after all engines have been shut down and no
    /// concurrent `buildEngine()` calls are in flight — calling it while a
    /// background task holds a reference to a shared subsystem will silently
    /// revert to the N-pools bug for any engine rebuilt after the reset.
    #if DEBUG
    static func resetSharedSubsystems() {
        // Acquire both locks in a consistent order (subsystems first, then
        // store) so the reset is atomic with respect to concurrent
        // sharedCache() / sharedTelemetry() calls that also nest
        // sharedSubsystemsLock → sharedStoreLock.
        sharedSubsystemsLock.withLock {
            sharedStoreLock.withLock {
                _sharedConfigStore = nil
            }
            _sharedCache = nil
            _sharedTelemetry = nil
            _sharedGateRegistry = nil
        }
    }
    #endif

    // MARK: - Mutable state (guarded by lock)

    private let lock = NSLock()
    private nonisolated(unsafe) var _engine: OfemEngine?
    /// Most-recent build error.  Cleared after `buildErrorBackoff` nanoseconds so
    /// the next `engine()` call retries.
    private nonisolated(unsafe) var _buildError: Error?
    /// Monotonic uptime nanoseconds of the last failed build attempt.
    private nonisolated(unsafe) var _buildErrorTimestampNs: UInt64 = 0
    /// Set to `true` by `shutdown()` once teardown begins.
    /// After this point `engine()` always throws rather than rebuilding.
    private nonisolated(unsafe) var _invalidated: Bool = false
    /// In-flight build Task. Allows concurrent `engine()` callers to await the
    /// same build rather than racing to construct separate engines. Cleared
    /// (to nil) once the task finishes — successfully or not.
    private nonisolated(unsafe) var _buildTask: Task<OfemEngine, Error>?

    /// Back-off window (in nanoseconds) before retrying after a build failure.
    /// 5 seconds covers the most common transient causes (Keychain momentarily
    /// locked, TOML file mid-write) while allowing recovery in a single macOS
    /// re-enumeration cycle.
    ///
    /// Declared `internal` (rather than `private`) intentionally so that
    /// `FPEEngineHostTests` can assert the constant is positive via
    /// `@testable import`. Do not narrow back to `private` without moving
    /// the test assertion or removing it.
    static let buildErrorBackoffNs: UInt64 = 5_000_000_000

    // MARK: - Init

    init(alias: String, domain: NSFileProviderDomain) {
        self.alias = alias
        self.domain = domain
    }

    // MARK: - Config store access

    /// Returns the process-wide config store.
    ///
    /// Delegates to ``FPEEngineHost/sharedConfigStore()`` so all
    /// FPEEngineHost instances in this process read and write the same
    /// in-memory snapshot. Cross-process safety against the host app is
    /// handled by the `fcntl(2)`-based read-merge-write in
    /// `OfemConfigStore.updateAndSave`.
    ///
    /// - Throws: `OfemConfigError` on TOML parse failure (first call only).
    func configStore() throws -> OfemConfigStore {
        try FPEEngineHost.sharedConfigStore()
    }

    // MARK: - Engine access

    /// Returns the already-built engine without triggering a build.
    ///
    /// Returns `nil` if the engine has never been requested (or if the
    /// build has not completed yet). Used by the XPC status handler to
    /// skip the blob-bytes query when the engine is not yet warm.
    func existingEngine() -> OfemEngine? {
        lock.withLock { _engine }
    }

    /// Returns the engine, building it on first call.
    ///
    /// Building the engine involves loading the config, wiring up the HTTP
    /// clients, and constructing the per-alias subsystems — all safe to do
    /// in the FPE's process. The shared CacheStore, TelemetryClient, and
    /// HTTPGateRegistry are obtained from process-wide singletons.
    ///
    /// Concurrent callers share a single in-flight build Task so the engine
    /// is always constructed at most once, even under concurrent pressure.
    ///
    /// - Throws:
    ///   - `NSFileProviderError(.cannotSynchronize)` once ``shutdown()`` has
    ///     been called: the extension instance is shutting down and must not
    ///     resurrect the engine.
    ///   - The last build error when within the back-off window. The error is
    ///     cleared after the window expires so the next call retries.
    func engine() async throws -> OfemEngine {
        // Fast path — engine already built.
        if let e = lock.withLock({ _engine }) {
            return e
        }

        // Refuse to build / rebuild after invalidation.
        if lock.withLock({ _invalidated }) {
            throw NSFileProviderError(.cannotSynchronize)
        }

        // Honour a cached build error only within the back-off window.
        // Capture both fields in a single lock closure to avoid reading
        // _buildErrorTimestampNs outside the critical section.
        let cachedError: (Error, UInt64)? = lock.withLock {
            guard let err = _buildError else { return nil }
            return (err, _buildErrorTimestampNs)
        }
        if let (err, ts) = cachedError {
            let elapsedNs = DispatchTime.now().uptimeNanoseconds &- ts
            if elapsedNs < FPEEngineHost.buildErrorBackoffNs {
                throw err
            }
            // Window expired — clear and fall through to retry.
            lock.withLock {
                _buildError = nil
                _buildErrorTimestampNs = 0
            }
        }

        // Single-flight: reuse an in-flight build Task if one already exists.
        // This prevents two concurrent callers from each constructing their own
        // engine and then having one silently overwrite the other.
        let task: Task<OfemEngine, Error> = lock.withLock {
            if let existing = _buildTask { return existing }
            let newTask = Task<OfemEngine, Error> { [weak self] in
                guard let self else { throw NSFileProviderError(.cannotSynchronize) }
                return try self.buildEngine()
            }
            _buildTask = newTask
            return newTask
        }
        do {
            let engine = try await task.value
            lock.withLock { _buildTask = nil }
            return engine
        } catch {
            lock.withLock { _buildTask = nil }
            throw error
        }
    }

    /// Shuts down the current engine and clears the cached instance so the
    /// next ``engine()`` call rebuilds from the freshly loaded config snapshot.
    ///
    /// This is the engine reload mechanism: ``OfemEngine`` reads the config
    /// once at init, so applying a new config requires shutting down the
    /// current engine and letting it be lazily rebuilt on the next use.
    /// `OfemClientControlService` calls this after a successful `setConfig`
    /// write so per-alias settings (log level, per-alias auth, etc.) take
    /// effect without waiting for the FPE process to terminate.
    ///
    /// **Process-wide shared subsystems are NOT recreated on reload.**
    /// `CacheStore`, `TelemetryClient`, and `HTTPGateRegistry` are
    /// process-wide singletons captured at first construction.  Config fields
    /// that only affect those subsystems (e.g. `cache.maxBytes`,
    /// `telemetry`) will not take effect until the FPE process restarts.
    /// This is intentional: the shared-subsystem design eliminates N-pools,
    /// and recreating them on every reload would re-introduce that hazard.
    func reloadEngine() async {
        let existing: OfemEngine? = lock.withLock {
            let e = _engine
            _engine = nil
            _buildError = nil
            _buildErrorTimestampNs = 0
            _buildTask?.cancel()
            _buildTask = nil
            return e
        }
        if let e = existing {
            await e.shutdown()
            Self.log.info("FPEEngineHost[\(self.alias, privacy: .public)]: engine reloaded after config change")
        }
    }

    /// Shuts down the engine if it was started.
    ///
    /// After this call, any concurrent or future `engine()` call will throw
    /// ``NSFileProviderError(.cannotSynchronize)`` rather than rebuild the
    /// engine (fpe-11).
    func shutdown() async {
        // Set _invalidated before taking the engine reference so any concurrent
        // engine() call that sees _invalidated=true fast-fails rather than
        // spawning a new build. Also cancel any in-flight build task.
        let e: OfemEngine? = lock.withLock {
            _invalidated = true
            _buildTask?.cancel()
            _buildTask = nil
            return _engine
        }
        guard let e else { return }
        await e.shutdown()
        lock.withLock { _engine = nil }
        Self.log.info("FPEEngineHost[\(self.alias, privacy: .public)]: engine shut down")
    }

    // MARK: - Private

    private func buildEngine() throws -> OfemEngine {
        // Called from a single-flight Task; by the time we run, another Task
        // may have already completed a build (racing tasks that both missed the
        // fast path both land here).  Re-check under the lock before building.
        if lock.withLock({ _invalidated }) {
            throw NSFileProviderError(.cannotSynchronize)
        }
        if let e = lock.withLock({ _engine }) { return e }

        // Honour a still-fresh cached build error.
        let cachedErr: (Error, UInt64)? = lock.withLock {
            guard let e = _buildError else { return nil }
            return (e, _buildErrorTimestampNs)
        }
        if let (err, ts) = cachedErr {
            let elapsedNs = DispatchTime.now().uptimeNanoseconds &- ts
            if elapsedNs < FPEEngineHost.buildErrorBackoffNs { throw err }
            lock.withLock { _buildError = nil; _buildErrorTimestampNs = 0 }
        }

        Self.log.info("FPEEngineHost[\(self.alias, privacy: .public)]: building OfemEngine")

        do {
            // Use the shared configStore so the XPC handler and the engine
            // read from the same in-memory snapshot.
            let cs = try configStore()
            let paths = OfemPaths()

            // Obtain (or lazily create) the process-wide shared subsystems.
            // All engines in this FPE process share the same CacheStore,
            // TelemetryClient, and HTTPGateRegistry (arch-04).
            let cache = try FPEEngineHost.sharedCache()
            let telemetry = try FPEEngineHost.sharedTelemetry()
            let gateRegistry = FPEEngineHost.sharedGateRegistry()

            let engine = try OfemEngine(
                configStore: cs,
                paths: paths,
                sharedCache: cache,
                sharedTelemetry: telemetry,
                sharedGateRegistry: gateRegistry
            )
            lock.withLock { _engine = engine }
            Self.log.info("FPEEngineHost[\(self.alias, privacy: .public)]: engine built")
            // Start background tasks (telemetry flush timer). start() is
            // idempotent so this is safe when called for a shared telemetry client.
            Task { await engine.start() }
            return engine
        } catch {
            lock.withLock {
                _buildError = error
                _buildErrorTimestampNs = DispatchTime.now().uptimeNanoseconds
            }
            Self.log.error(
                "FPEEngineHost[\(self.alias, privacy: .public)]: engine build failed: \(error.localizedDescription, privacy: .public)"
            )
            throw error
        }
    }
}
