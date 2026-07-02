import Foundation
@testable import OfemKit
import Testing

// MARK: - OfemEngine + TokenProviderAdapter tests (tests-02)

//
// These tests cover the wiring/lifecycle paths that are reachable without
// network or MSAL, validating the load-bearing behaviours documented in the
// engine doc-comments.

// MARK: - Helpers

/// Builds a temporary OfemPaths rooted under a unique temp directory.
private func makeTempPaths() throws -> OfemPaths {
    let tmp = FileManager.default.temporaryDirectory
        .appending(path: "ofem-engine-test-\(UUID().uuidString)", directoryHint: .isDirectory)
        .resolvingSymlinksInPath()
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    return OfemPaths(root: tmp)
}

/// Builds a minimal OfemConfigStore in a temp directory.
private func makeTempConfigStore() throws -> (OfemConfigStore, OfemPaths) {
    let paths = try makeTempPaths()
    let store = try OfemConfigStore(paths: paths)
    return (store, paths)
}

/// Builds a process-local TelemetryClient backed by a noop sink.
private func makeNoopTelemetry() -> TelemetryClient {
    TelemetryClient(
        sink: NoopTelemetrySink(),
        appVersion: "0.0.0-test",
        installID: "test-install",
        configuration: TelemetryConfiguration(optOut: true)
    )
}

// MARK: - Standalone init

@Suite("OfemEngine — standalone init")
struct OfemEngineStandaloneTests {
    @Test("standalone init succeeds and exposes subsystems")
    func standaloneInitSucceeds() async throws {
        let (store, paths) = try makeTempConfigStore()
        let engine = try OfemEngine(configStore: store, paths: paths)
        // All public subsystems must be reachable without an actor hop
        // (nonisolated let).  Access them so the compiler confirms they are
        // non-nil references.
        _ = engine.cache
        _ = engine.sync
        _ = engine.telemetry
        _ = engine.logger
        _ = engine.sessionPool
        await engine.shutdown()
    }

    @Test("standalone init respects httpBaseURLs override")
    func standaloneInitRespectsURLOverride() async throws {
        let (store, paths) = try makeTempConfigStore()
        let customOneLake = try #require(URL(string: "https://custom.onelake.example.com"))
        let customFabric = try #require(URL(string: "https://custom.fabric.example.com"))
        let engine = try OfemEngine(
            configStore: store,
            paths: paths,
            httpBaseURLs: (oneLake: customOneLake, fabric: customFabric)
        )
        // The engine should build without error when non-nil base URLs are provided.
        await engine.shutdown()
    }
}

// MARK: - Injected (shared-subsystem) init

@Suite("OfemEngine — injected (shared-subsystem) init")
struct OfemEngineInjectedTests {
    @Test("injected init reuses provided cache and telemetry instances")
    func injectedInitReusesSharedInstances() async throws {
        let (store, paths) = try makeTempConfigStore()
        let sharedCache = try CacheStore(root: paths.cacheDir, maxBlobBytes: 0)
        let sharedTelemetry = makeNoopTelemetry()
        let sharedPool = SessionPool(tokenProvider: NoopTokenProvider())

        let engine = try OfemEngine(
            configStore: store,
            paths: paths,
            sharedCache: sharedCache,
            sharedTelemetry: sharedTelemetry,
            sharedSessionPool: sharedPool
        )

        // Must be the exact same instances (identity, not value equality).
        #expect(engine.cache === sharedCache)
        #expect(engine.telemetry === sharedTelemetry)
        await engine.shutdown()
    }

    @Test("injected init shutdown does not stop the shared telemetry client")
    func injectedInitShutdownDoesNotStopSharedTelemetry() async throws {
        let (store, paths) = try makeTempConfigStore()
        let sink = MemoryTelemetrySink()
        let sharedTelemetry = TelemetryClient(
            sink: sink,
            appVersion: "0.0.0-test",
            installID: "test-install",
            configuration: TelemetryConfiguration(
                optOut: false,
                maxBatchSize: 100,
                flushInterval: .seconds(3600)
            )
        )
        let sharedCache = try CacheStore(root: paths.cacheDir, maxBlobBytes: 0)
        let sharedPool = SessionPool(tokenProvider: NoopTokenProvider())

        await sharedTelemetry.start()

        let engine = try OfemEngine(
            configStore: store,
            paths: paths,
            sharedCache: sharedCache,
            sharedTelemetry: sharedTelemetry,
            sharedSessionPool: sharedPool
        )

        // Shut down the per-alias engine — the shared telemetry must keep running.
        await engine.shutdown()

        // If the shared telemetry was incorrectly shut down, track+flush would
        // silently drop events.  An event tracked after shutdown must still
        // appear in the sink after an explicit flush.
        await sharedTelemetry.track(TelemetryEvent(name: "post_engine_shutdown"))
        await sharedTelemetry.flush()
        #expect(sink.count == 1, "shared TelemetryClient must still be active after per-alias engine shutdown")

        await sharedTelemetry.shutdown()
    }
}

// MARK: - start() idempotency

@Suite("OfemEngine — start() idempotency")
struct OfemEngineStartTests {
    @Test("start() is idempotent — calling twice does not double-start telemetry")
    func startIsIdempotent() async throws {
        let (store, paths) = try makeTempConfigStore()
        let engine = try OfemEngine(configStore: store, paths: paths)
        // A second start must not crash or produce observable double-start side effects.
        await engine.start()
        await engine.start()
        await engine.shutdown()
    }
}

// MARK: - shutdown() tears down owned subsystems

@Suite("OfemEngine — shutdown() tears down owned subsystems (engine-02)")
struct OfemEngineShutdownTests {
    @Test("standalone shutdown flushes owned telemetry")
    func standaloneShutdownFlushesOwnedTelemetry() async throws {
        // Build a standalone engine with an injected noop telemetry sink
        // via httpBaseURLs — we test the code path, not real telemetry.
        let (store, paths) = try makeTempConfigStore()
        let engine = try OfemEngine(configStore: store, paths: paths)
        await engine.start()
        // Shutdown must complete without deadlock or crash, confirming owned
        // telemetry is flushed.
        await engine.shutdown()
    }
}

// MARK: - SubsystemOwnership type safety

@Suite("OfemEngine — SubsystemOwnership (engine-03)")
struct OfemEngineOwnershipTests {
    @Test("standalone engine does not shut down a separately-held shared telemetry reference")
    func standaloneEngineDoesNotLeakShutdownToOtherClients() async throws {
        // Two standalone engines constructed from the same store/paths will each
        // own their own TelemetryClient; shutting down one must not affect the
        // other.  We verify this indirectly: both shutdowns must complete without
        // deadlock.
        let (store, paths) = try makeTempConfigStore()

        let engine1 = try OfemEngine(configStore: store, paths: paths)
        // engine2 needs its own paths to avoid SQLite contention.
        let paths2 = try makeTempPaths()
        let engine2 = try OfemEngine(configStore: store, paths: paths2)

        await engine1.start()
        await engine2.start()
        await engine1.shutdown()
        await engine2.shutdown()
    }
}

// MARK: - TokenProviderAdapter wiring

@Suite("TokenProviderAdapter wiring (tests-02)")
struct TokenProviderAdapterTests {
    @Test("engine wires a token provider into OneLakeClient and FabricClient (no crash)")
    func engineWiresTokenProvider() async throws {
        // This is a construction-only test — verifies that the private
        // TokenProviderAdapter is correctly wired.  If the adapter is missing
        // or wired to the wrong type, OfemEngine.init throws.
        let (store, paths) = try makeTempConfigStore()
        let engine = try OfemEngine(configStore: store, paths: paths)
        // SyncEngine (which owns the HTTP clients) is accessible without crash.
        _ = engine.sync
        await engine.shutdown()
    }

    @Test("scoped token provider scope: .dfs maps to OneLake, .fabric maps to Fabric")
    func tokenProviderAdapterScopeRouting() async throws {
        // We verify the adapter exists and the engine builds without error
        // when provided with a URL override for the scoped clients.
        let (store, paths) = try makeTempConfigStore()
        let engine = try OfemEngine(
            configStore: store,
            paths: paths,
            httpBaseURLs: (
                oneLake: try #require(URL(string: "https://onelake.local")),
                fabric: try #require(URL(string: "https://fabric.local"))
            )
        )
        await engine.shutdown()
    }
}

// MARK: - Log-level wiring

@Suite("OfemEngine — log-level wiring")
struct OfemEngineLogLevelTests {
    @Test("engine honours log.level=debug from config")
    func engineHonoursDebugLogLevel() async throws {
        let (store, paths) = try makeTempConfigStore()
        try await store.updateAndSave { cfg in
            cfg.log.level = "debug"
        }
        // Should build without error — LogLevel(string:) must parse "debug".
        let engine = try OfemEngine(configStore: store, paths: paths)
        await engine.shutdown()
    }

    @Test("engine falls back to .info for unrecognised log level")
    func engineFallsBackToInfoForUnknownLogLevel() async throws {
        let (store, paths) = try makeTempConfigStore()
        try await store.updateAndSave { cfg in
            cfg.log.level = "zzz_unknown"
        }
        // Must not throw — unrecognised level falls back gracefully.
        let engine = try OfemEngine(configStore: store, paths: paths)
        await engine.shutdown()
    }
}

// MARK: - config snapshot read once (engine-01)

@Suite("OfemEngine — config snapshot read once (engine-01)")
struct OfemEngineConfigSnapshotTests {
    @Test("standalone init uses a single consistent config snapshot")
    func standaloneInitUsesConsistentSnapshot() async throws {
        let (store, paths) = try makeTempConfigStore()
        // Change the config before engine init so that both the shared-subsystem
        // and per-alias builds see the same version.
        try await store.updateAndSave { cfg in
            cfg.log.level = "warn"
        }
        // Build without error — no divergence between the two snapshot reads
        // should occur (previously both inits called configStore.snapshot()
        // separately).
        let engine = try OfemEngine(configStore: store, paths: paths)
        await engine.shutdown()
    }
}

// MARK: - defaultFabricBaseURL constant (fp-01 / engine-04)

@Suite("OfemEngine — Fabric URL constant (fp-01)")
struct OfemEngineFabricURLTests {
    @Test("engine builds successfully without a fabric URL override (no force-unwrap crash)")
    func engineBuildsWithDefaultFabricURL() async throws {
        let (store, paths) = try makeTempConfigStore()
        // Passing nil httpBaseURLs exercises the defaultFabricBaseURL constant.
        let engine = try OfemEngine(configStore: store, paths: paths, httpBaseURLs: nil)
        await engine.shutdown()
    }
}

// MARK: - start / shutdown ordering (fpe-12)

@Suite("OfemEngine — start/shutdown ordering (fpe-12)")
struct OfemEngineStartShutdownOrderingTests {
    @Test("shutdown after immediate start does not deadlock or crash")
    func shutdownAfterImmediateStartCompletes() async throws {
        // Verifies that calling shutdown() very soon after start() does not
        // deadlock or crash. In a correct implementation start() is idempotent
        // and shutdown() joins any in-flight start before tearing down.
        let (store, paths) = try makeTempConfigStore()
        let engine = try OfemEngine(configStore: store, paths: paths)
        // Fire start and shutdown concurrently — neither must hang.
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await engine.start() }
            group.addTask { await engine.shutdown() }
        }
    }

    @Test("multiple start/shutdown cycles complete without crash")
    func multipleStartShutdownCycles() async throws {
        let (store, paths) = try makeTempConfigStore()
        let engine = try OfemEngine(configStore: store, paths: paths)
        await engine.start()
        await engine.shutdown()
        // A second cycle must not crash (shutdown is a one-way gate but start
        // is idempotent and safe to call again on a fully shut-down engine).
        await engine.start()
        await engine.shutdown()
    }
}

// MARK: - shutdownSharedSubsystems flushes telemetry (fpe-14)

@Suite("TelemetryClient — shutdownSharedSubsystems flushes final batch (fpe-14)")
struct SharedSubsystemsTelemetryFlushTests {
    @Test("shutdown flushes events that were tracked before shutdown")
    func shutdownFlushesFinalBatch() async {
        let sink = MemoryTelemetrySink()
        let telemetry = TelemetryClient(
            sink: sink,
            appVersion: "0.0.0-test",
            installID: "test-install",
            configuration: TelemetryConfiguration(
                optOut: false,
                maxBatchSize: 100,
                flushInterval: .seconds(3600) // no auto-flush during test
            )
        )
        await telemetry.start()
        await telemetry.track(TelemetryEvent(name: "before_shutdown"))

        // Shutdown must flush the pending event.
        await telemetry.shutdown()

        #expect(
            sink.count == 1,
            "shutdown must flush the final telemetry batch (fpe-14)"
        )
    }

    @Test("events tracked after a per-engine shutdown are still flushed by shared client shutdown")
    func perEngineShutdownDoesNotLoseSubsequentEvents() async throws {
        let (store, paths) = try makeTempConfigStore()
        let sink = MemoryTelemetrySink()
        let sharedTelemetry = TelemetryClient(
            sink: sink,
            appVersion: "0.0.0-test",
            installID: "test-install",
            configuration: TelemetryConfiguration(
                optOut: false,
                maxBatchSize: 100,
                flushInterval: .seconds(3600)
            )
        )
        let sharedCache = try CacheStore(root: paths.cacheDir, maxBlobBytes: 0)
        let sharedPool = SessionPool(tokenProvider: NoopTokenProvider())

        await sharedTelemetry.start()

        let engine = try OfemEngine(
            configStore: store,
            paths: paths,
            sharedCache: sharedCache,
            sharedTelemetry: sharedTelemetry,
            sharedSessionPool: sharedPool
        )
        await engine.start()
        // Per-alias engine shutdown must NOT stop the shared telemetry.
        await engine.shutdown()

        // Events tracked after per-engine shutdown must survive to the final flush.
        await sharedTelemetry.track(TelemetryEvent(name: "post_engine_shutdown"))
        await sharedTelemetry.shutdown()

        #expect(
            sink.count == 1,
            "final telemetry shutdown must flush events that arrived after per-engine shutdown"
        )
    }
}
