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
// to `_engine` and `_buildError`. `buildEngine()` is a nonisolated throwing
// function; `OfemEngine.init` no longer requires @MainActor now that `OfemAuth`
// is a Swift actor rather than a @MainActor class.
//
// Process-wide config store: all FPEEngineHost instances in the same
// FPE process share ONE OfemConfigStore via `FPEEngineHost.sharedConfigStore`.
// This guarantees that concurrent XPC handlers for different domains
// (different aliases) read and write the same in-memory snapshot, so
// an updateAndSave from one domain does not clobber fields that another
// domain's handler just wrote. OfemClientControlService accesses the
// store via `engineHost.configStore()` which returns this shared instance.
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
// fpe-10 fix: a transient build failure is not cached permanently.
//   A failed build stores `_buildError` plus the timestamp of the
//   failure. `engine()` retries after a short back-off window
//   (`buildErrorBackoff`, default 5 s) instead of throwing the cached
//   error forever.
//
// fpe-11 fix: `invalidate()` sets `_invalidated = true` before spawning
//   the shutdown task. Any concurrent or later `engine()` call that races
//   with shutdown sees the flag and throws `.cannotSynchronize` immediately
//   rather than silently rebuilding a fresh engine inside an already-torn-
//   down extension instance.

import FileProvider
import Foundation
import OfemKit
import os.log

/// Per-domain engine container.
///
/// Constructed once per `FileProviderExtension` instance (one per alias).
/// The `OfemEngine` inside is built lazily on the first call that needs it.
final class FPEEngineHost: Sendable {
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
    /// - Throws: `CacheError` if the SQLite file cannot be opened or migrated.
    static func sharedCache() throws -> CacheStore {
        try sharedSubsystemsLock.withLock {
            if let c = _sharedCache { return c }
            let cfg = try sharedConfigStore().snapshot()
            let paths = OfemPaths()
            let c = try CacheStore(root: paths.cacheDir, maxBlobBytes: cfg.cache.maxBytes)
            _sharedCache = c
            return c
        }
    }

    /// Returns (or lazily creates) the process-wide TelemetryClient.
    ///
    /// - Throws: `OfemConfigError` if the shared config store cannot be loaded.
    static func sharedTelemetry() throws -> TelemetryClient {
        try sharedSubsystemsLock.withLock {
            if let t = _sharedTelemetry { return t }
            let cfg = try sharedConfigStore().snapshot()
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
            let t = TelemetryClient(
                sink: telSink,
                appVersion: BuildInfo.version,
                installID: cfg.installID,
                configuration: TelemetryConfiguration(optOut: !cfg.telemetry)
            )
            _sharedTelemetry = t
            return t
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

    /// Invalidates all process-wide shared subsystem singletons.
    ///
    /// Called when the FPE process is torn down (all domains have been
    /// invalidated) so that the next process launch starts clean.  Not
    /// needed in the normal flow — the OS kills the FPE process after the
    /// last domain shuts down — but useful for testing.
    static func resetSharedSubsystems() {
        sharedSubsystemsLock.withLock {
            _sharedCache = nil
            _sharedTelemetry = nil
            _sharedGateRegistry = nil
        }
        sharedStoreLock.withLock {
            _sharedConfigStore = nil
        }
    }

    // MARK: - Mutable state (guarded by lock)

    private let lock = NSLock()
    private nonisolated(unsafe) var _engine: OfemEngine?
    /// Most-recent build error.  Cleared after `buildErrorBackoff` seconds so
    /// the next `engine()` call retries (fpe-10).
    private nonisolated(unsafe) var _buildError: Error?
    /// Wall-clock time of the last failed build attempt (nanoseconds).
    private nonisolated(unsafe) var _buildErrorTimestampNs: UInt64 = 0
    /// Set to `true` by `shutdown()` / `invalidate()` once teardown begins.
    /// After this point `engine()` always throws rather than rebuilding (fpe-11).
    private nonisolated(unsafe) var _invalidated: Bool = false

    /// Back-off window (in nanoseconds) before retrying after a build failure.
    /// 5 seconds covers the most common transient causes (Keychain momentarily
    /// locked, TOML file mid-write) while allowing recovery in a single macOS
    /// re-enumeration cycle.
    private static let buildErrorBackoffNs: UInt64 = 5_000_000_000

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
    /// HTTPGateRegistry are obtained from process-wide singletons. Construction
    /// is serialised by a lock so concurrent callers do not race to create
    /// multiple engines.
    ///
    /// - Throws:
    ///   - `NSFileProviderError(.cannotSynchronize)` once ``shutdown()`` or
    ///     ``invalidate()`` has been called (fpe-11): the extension instance is
    ///     shutting down and must not resurrect the engine.
    ///   - The last build error when within the back-off window (fpe-10). The
    ///     error is cleared after the window expires so the next call retries.
    func engine() async throws -> OfemEngine {
        // Fast path — engine already built.
        if let e = lock.withLock({ _engine }) {
            return e
        }

        // fpe-11: refuse to build / rebuild after invalidation.
        if lock.withLock({ _invalidated }) {
            throw NSFileProviderError(.cannotSynchronize)
        }

        // fpe-10: honour a cached build error only within the back-off window.
        // After the window expires, clear the cached error and try again.
        // C2: capture both _buildError and _buildErrorTimestampNs inside one
        // lock.withLock closure to avoid reading _buildErrorTimestampNs outside
        // the critical section.
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

        return try await buildEngine()
    }

    /// Shuts down the current engine and clears the cached instance so the
    /// next ``engine()`` call rebuilds from the freshly loaded config snapshot.
    ///
    /// This is the engine reload mechanism: ``OfemEngine`` reads the config
    /// once at init, so applying a new config requires shutting down the
    /// current engine and letting it be lazily rebuilt on the next use.
    /// `OfemClientControlService` calls this after a successful `setConfig`
    /// write so the new settings (log level, telemetry, cache limit, etc.)
    /// take effect without waiting for the FPE process to terminate.
    ///
    /// Note: reloading an engine does NOT recreate the shared CacheStore,
    /// TelemetryClient, or HTTPGateRegistry — those are process-wide singletons
    /// that persist for the lifetime of the FPE process.
    func reloadEngine() async {
        let existing: OfemEngine? = lock.withLock {
            let e = _engine
            _engine = nil
            _buildError = nil
            _buildErrorTimestampNs = 0
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
        let e: OfemEngine? = lock.withLock {
            _invalidated = true
            return _engine
        }
        guard let e else { return }
        await e.shutdown()
        lock.withLock { _engine = nil }
        Self.log.info("FPEEngineHost[\(self.alias, privacy: .public)]: engine shut down")
    }

    // MARK: - Private

    private func buildEngine() throws -> OfemEngine {
        // Re-check after the actor hop (another Task may have built it or shut
        // it down while we were waiting for the main actor).
        if lock.withLock({ _invalidated }) {
            throw NSFileProviderError(.cannotSynchronize)
        }
        if let e = lock.withLock({ _engine }) { return e }
        // C2: capture both fields inside one lock.withLock to avoid reading
        // _buildErrorTimestampNs outside the critical section.
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
            // Fire-and-forget start (telemetry flush timer start is idempotent).
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
