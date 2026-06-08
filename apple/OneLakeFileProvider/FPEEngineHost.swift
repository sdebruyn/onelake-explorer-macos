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

    // MARK: - Init

    init(alias: String, domain: NSFileProviderDomain) {
        self.alias = alias
        self.domain = domain
    }

    // MARK: - Engine access

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
            let configStore = try OfemConfigStore()
            let paths = OfemPaths()
            let engine = try OfemEngine(configStore: configStore, paths: paths)
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
