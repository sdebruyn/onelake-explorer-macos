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
// Fase 7.2 scope: the Go-daemon Unix-socket IPC in CoreBridge.swift
// remains active as a fallback for account management commands not yet
// routed through the FPE's NSFileProviderServiceSource. Fase 7.3 will
// remove that path entirely.
//
// Fase 7.3b-1: `configStore` is now a public property so the XPC handler
// (OfemClientControlService.swift) can read and mutate config directly
// for getEngineStatus / setConfig without having to open a second store.

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

    // MARK: - Mutable state (guarded by lock)

    private let lock = NSLock()
    private nonisolated(unsafe) var _engine: OfemEngine?
    private nonisolated(unsafe) var _buildError: Error?
    /// The config store, loaded lazily on first use (by the engine build or
    /// by the XPC handler's getEngineStatus / setConfig calls).
    private nonisolated(unsafe) var _configStore: OfemConfigStore?

    // MARK: - Init

    init(alias: String, domain: NSFileProviderDomain) {
        self.alias = alias
        self.domain = domain
    }

    // MARK: - Config store access

    /// Returns the shared config store, creating it on first call.
    ///
    /// OfemConfigStore is Sendable and uses an NSLock internally, so the
    /// returned reference may be used from any context. The store is shared
    /// between the engine build path and the XPC handler so both read and
    /// write the same in-memory snapshot.
    ///
    /// - Throws: `OfemConfigError` on TOML parse failure (first call only).
    func configStore() throws -> OfemConfigStore {
        if let cs = lock.withLock({ _configStore }) { return cs }
        let cs = try OfemConfigStore()
        lock.withLock { _configStore = cs }
        return cs
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
