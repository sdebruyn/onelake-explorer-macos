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
// to `_engine` and `_buildError`. `buildEngine()` is @MainActor because
// OfemEngine.init is @MainActor. The Task in `engine()` hops to the
// main actor for the build step, then returns the result.
//
// Process-wide config store: all FPEEngineHost instances in the same
// FPE process share ONE OfemConfigStore via `FPEEngineHost.sharedConfigStore`.
// This guarantees that concurrent XPC handlers for different domains
// (different aliases) read and write the same in-memory snapshot, so
// an updateAndSave from one domain does not clobber fields that another
// domain's handler just wrote. OfemClientControlService accesses the
// store via `engineHost.configStore()` which returns this shared instance.

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

    // MARK: - Mutable state (guarded by lock)

    private let lock = NSLock()
    private nonisolated(unsafe) var _engine: OfemEngine?
    private nonisolated(unsafe) var _buildError: Error?

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
    /// Building the engine involves loading the config, creating the
    /// SQLite cache store, and wiring up the HTTP clients — all safe
    /// to do in the FPE's process. Construction is serialised by a
    /// lock so concurrent callers do not race to create multiple engines.
    ///
    /// - Throws: If the engine could not be constructed. Once an engine
    ///   fails to build, the error is cached and all subsequent calls
    ///   throw the same error without retrying.
    func engine() async throws -> OfemEngine {
        // Fast path — engine already built.
        if let e = lock.withLock({ _engine }) {
            return e
        }
        // Already failed — propagate cached error.
        if let err = lock.withLock({ _buildError }) {
            throw err
        }
        // Build on the main actor (OfemEngine.init is @MainActor).
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
    func reloadEngine() async {
        let existing: OfemEngine? = lock.withLock {
            let e = _engine
            _engine = nil
            _buildError = nil
            return e
        }
        if let e = existing {
            await e.shutdown()
            Self.log.info("FPEEngineHost[\(self.alias, privacy: .public)]: engine reloaded after config change")
        }
    }

    /// Shuts down the engine if it was started.
    func shutdown() async {
        let e: OfemEngine? = lock.withLock { _engine }
        guard let e else { return }
        await e.shutdown()
        lock.withLock { _engine = nil }
        Self.log.info("FPEEngineHost[\(self.alias, privacy: .public)]: engine shut down")
    }

    // MARK: - Private

    @MainActor
    private func buildEngine() throws -> OfemEngine {
        // Re-check after the actor hop (another Task may have built it).
        if let e = lock.withLock({ _engine }) { return e }
        if let err = lock.withLock({ _buildError }) { throw err }

        Self.log.info("FPEEngineHost[\(self.alias, privacy: .public)]: building OfemEngine")

        do {
            // Use the shared configStore so the XPC handler and the engine
            // read from the same in-memory snapshot.
            let cs = try configStore()
            let paths = OfemPaths()
            let engine = try OfemEngine(configStore: cs, paths: paths)
            lock.withLock { _engine = engine }
            Self.log.info("FPEEngineHost[\(self.alias, privacy: .public)]: engine built")
            // Fire-and-forget start (telemetry flush timer, etc.)
            Task { await engine.start() }
            return engine
        } catch {
            lock.withLock { _buildError = error }
            Self.log.error(
                "FPEEngineHost[\(self.alias, privacy: .public)]: engine build failed: \(error.localizedDescription, privacy: .public)"
            )
            throw error
        }
    }
}
