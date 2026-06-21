import Foundation

// MARK: - OfemEngine

/// Façade that assembles all OfemKit subsystems into a single, ready-to-use
/// engine object.
///
/// `OfemEngine` is a **facade / wire-up container** that builds the per-alias
/// dependency graph (auth → session pool → Fabric + OneLake clients → sync
/// engine) using process-wide shared subsystems (cache, telemetry, session
/// pool) that are injected at initialisation time.
///
/// ## Process-wide shared vs per-alias
///
/// Three subsystems are process-wide singletons, shared across every engine
/// instance in the same FPE process (arch-04):
///
/// - `CacheStore` — one SQLite file + shard dir, already row-keyed by
///   `account_alias`.  One shared actor eliminates the N-pools-over-one-file
///   hazard and ensures the blob byte-budget is enforced once, globally.
/// - `TelemetryClient` — one flush timer.  All per-alias telemetry events
///   flow through the shared client.
/// - `SessionPool` — one Alamofire session per `(alias, scope)` pair; sharing
///   the pool avoids multiplying connection pools by the number of engines.
///
/// Per-alias subsystems that remain private to each `OfemEngine`:
///
/// - `OfemAuth` — per-account `MSALPublicClientApplication` + Keychain slice.
/// - `SyncEngine` — per-account download/upload semaphores + in-flight map.
/// - `OfemLogger` — category tag includes the alias for easy log filtering.
///
/// ## Thread safety
///
/// `OfemEngine` is a Swift `actor`. Public properties (`auth`, `cache`,
/// `sync`, `telemetry`, `logger`) are `nonisolated` so callers can read them
/// from any context without hopping to the engine's executor.
///
/// ## Telemetry ownership
///
/// When the standalone `init(configStore:paths:)` is used, the engine
/// constructs its own `TelemetryClient` and **owns** it — `shutdown()` will
/// call `telemetry.shutdown()` and cancel the flush timer.
///
/// When the injected `init(configStore:paths:sharedCache:sharedTelemetry:
/// sharedGateRegistry:)` is used, the engine receives a process-wide shared
/// `TelemetryClient` and does **not** own it — `shutdown()` skips the
/// telemetry shutdown so the flush timer keeps running for all surviving
/// engines.  The caller (`FPEEngineHost`) is responsible for shutting down
/// the shared `TelemetryClient` (and other shared subsystems) exactly once,
/// after the last per-alias engine has been torn down, via
/// `FPEEngineHost.shutdownSharedSubsystems()`.
public actor OfemEngine {
    // MARK: - Public subsystems

    /// Authentication facade (token acquisition, account management).
    public nonisolated let auth: OfemAuth

    /// Metadata + blob cache (process-wide shared instance, arch-04).
    public nonisolated let cache: CacheStore

    /// Sync coordinator (enumerate / open / put / delete / mkdir).
    public nonisolated let sync: SyncEngine

    /// Telemetry client (process-wide shared instance, arch-04).
    public nonisolated let telemetry: TelemetryClient

    /// Structured logger.
    public nonisolated let logger: OfemLogger

    /// Process-wide session pool (process-wide shared instance, arch-04).
    ///
    /// Exposed so callers can invalidate sessions for a specific alias after an
    /// account is removed, ensuring no stale session reuses a purged token.
    public nonisolated let sessionPool: SessionPool

    // MARK: - Private state

    private var started = false

    /// Describes whether this engine owns the shared subsystems it holds
    /// references to, and if so, bundles the owned instances for teardown
    /// (engine-02, engine-03).
    ///
    /// - `shared`: the shared subsystems were injected by the caller
    ///   (`FPEEngineHost`).  `shutdown()` must **not** tear them down —
    ///   `FPEEngineHost.shutdownSharedSubsystems()` is responsible.
    /// - `owned(telemetry:)`: the standalone init constructed these
    ///   subsystems; `shutdown()` tears down the owned `TelemetryClient`.
    ///   The owned `CacheStore` is already held by `self.cache` (ARC) and
    ///   is released — and closed by GRDB — when the engine is deallocated.
    private enum SubsystemOwnership {
        case shared
        case owned(telemetry: TelemetryClient)
    }

    private let subsystemOwnership: SubsystemOwnership

    /// Default Fabric REST base URL. Named constant eliminates both the
    /// force-unwrap and the magic-string duplication (fp-01, engine-04).
    private static let defaultFabricBaseURL = URL(string: "https://api.fabric.microsoft.com")
        .unsafelyUnwrapped // static literal — always valid

    // MARK: - Initialisers

    /// Builds per-alias subsystems from a loaded ``OfemConfigStore`` and
    /// ``OfemPaths``, reusing process-wide shared subsystems.
    ///
    /// Use this initialiser in the FPE where `FPEEngineHost` has already
    /// constructed the shared singletons.  The engine does **not** own the
    /// injected subsystems; call `FPEEngineHost.shutdownSharedSubsystems()`
    /// to shut them down once all domains have been torn down.
    ///
    /// ## Config reload
    ///
    /// The config snapshot is read once at initialisation time and baked
    /// into the subsystems (log level → `OfemLogger`, telemetry opt-out →
    /// sink choice, `cache.maxBytes` → `CacheStore`). Subsequent config
    /// changes therefore require building a **new** `OfemEngine` from the
    /// updated snapshot.
    ///
    /// The reload mechanism in `FPEEngineHost` is: after a successful
    /// `setConfig` write, call `FPEEngineHost.reloadEngine()`, which shuts
    /// down the current engine, clears `_engine` and `_buildError`, and lets
    /// the next `FPEEngineHost.engine()` call lazily rebuild from the fresh
    /// config snapshot.
    ///
    /// - Parameters:
    ///   - configStore: The loaded TOML config.
    ///   - paths: Resolved on-disk paths (cache dir, log dir, etc.).
    ///   - sharedCache: Process-wide CacheStore to share across engines.
    ///   - sharedTelemetry: Process-wide TelemetryClient to share across engines.
    ///   - sharedSessionPool: Process-wide SessionPool to share across engines.
    ///   - httpBaseURLs: Override the default DFS / Fabric base URLs. Pass
    ///     `nil` to use the production endpoints.
    public init(
        configStore: OfemConfigStore,
        paths: OfemPaths,
        sharedCache: CacheStore,
        sharedTelemetry: TelemetryClient,
        sharedSessionPool: SessionPool,
        httpBaseURLs: (oneLake: URL, fabric: URL)? = nil
    ) throws {
        // Read the config snapshot exactly once so all subsystems see the same
        // generation (engine-01).
        let cfg = configStore.snapshot()

        let perAlias = try OfemEngine.buildPerAliasSubsystems(
            cfg: cfg,
            configStore: configStore,
            auth: nil,
            paths: paths,
            cache: sharedCache,
            telemetry: sharedTelemetry,
            sessionPool: sharedSessionPool,
            httpBaseURLs: httpBaseURLs
        )

        logger = perAlias.logger
        cache = sharedCache
        telemetry = sharedTelemetry
        sessionPool = sharedSessionPool
        auth = perAlias.auth
        sync = perAlias.sync
        // Injected init does NOT own the shared subsystems (engine-03).
        subsystemOwnership = .shared
    }

    /// Builds all subsystems autonomously — constructs its own cache, telemetry,
    /// and gate registry.
    ///
    /// Intended for standalone use (tests, CLI tools, one-engine scenarios) where
    /// a process-wide shared container is not available. Production FPE code should
    /// use the injected-dependency initialiser to share subsystems across engines.
    ///
    /// The engine **owns** its `TelemetryClient`, `CacheStore`, and
    /// `HTTPGateRegistry`; `shutdown()` will shut them all down.
    ///
    /// - Parameters:
    ///   - configStore: The loaded TOML config.
    ///   - paths: Resolved on-disk paths (cache dir, log dir, etc.).
    ///   - httpBaseURLs: Override the default DFS / Fabric base URLs. Pass
    ///     `nil` to use the production endpoints.
    public init(
        configStore: OfemConfigStore,
        paths: OfemPaths,
        httpBaseURLs: (oneLake: URL, fabric: URL)? = nil
    ) throws {
        let cfg = configStore.snapshot()

        // Build owned telemetry.
        // `AppInsightsSink.init` throws only if the connection string is
        // malformed; the constant in `BuildInfo` is always well-formed, so
        // the `try?` here is purely a defensive fallback.
        let telSink: any TelemetrySink = if cfg.telemetry,
                                            let sink = try? AppInsightsSink(
                                                connectionString: BuildInfo.appInsightsConnectionString,
                                                installID: cfg.installID,
                                                appVersion: BuildInfo.version
                                            )
        {
            sink
        } else {
            NoopTelemetrySink()
        }
        let ownedTelemetry = TelemetryClient(
            sink: telSink,
            appVersion: BuildInfo.version,
            installID: cfg.installID,
            configuration: TelemetryConfiguration(optOut: !cfg.telemetry)
        )

        // Build owned cache.
        let ownedCache = try CacheStore(
            root: paths.cacheDir,
            maxBlobBytes: cfg.cache.maxBytes
        )

        // Build auth first so the owned pool uses the same instance.
        let ownedAuth = OfemAuth(configStore: configStore)
        // Build owned session pool backed by the same OfemAuth actor.
        let ownedPool = SessionPool(tokenProvider: ownedAuth)

        let perAlias = try OfemEngine.buildPerAliasSubsystems(
            cfg: cfg,
            configStore: configStore,
            auth: ownedAuth,
            paths: paths,
            cache: ownedCache,
            telemetry: ownedTelemetry,
            sessionPool: ownedPool,
            httpBaseURLs: httpBaseURLs
        )

        logger = perAlias.logger
        cache = ownedCache
        telemetry = ownedTelemetry
        sessionPool = ownedPool
        auth = perAlias.auth
        sync = perAlias.sync
        // Standalone init owns every subsystem it created (engine-03).
        // CacheStore is already held by self.cache (ARC); no need to store
        // it again in the ownership enum — it will be released (and closed
        // by GRDB) when the engine is deallocated after shutdown().
        subsystemOwnership = .owned(telemetry: ownedTelemetry)
    }

    // MARK: - Lifecycle

    /// Starts background tasks (telemetry flush timer).
    ///
    /// When using a shared `TelemetryClient`, `start()` is idempotent — the
    /// client's own guard prevents double-starting.
    public func start() async {
        guard !started else { return }
        started = true
        await telemetry.start()
        // Use self.logger so the "started" line reaches the RotatingFileWriter
        // file sink (and not only os_log).
        logger.info("OfemEngine: started")
    }

    /// Stops per-alias background tasks and, when this engine owns the shared
    /// subsystems, tears them all down (engine-02).
    ///
    /// **Shared-subsystem (injected) init:** this method does **not** shut down
    /// the cache, telemetry, or gate registry — those are owned by
    /// `FPEEngineHost`.  Call `FPEEngineHost.shutdownSharedSubsystems()` once
    /// all domains have been torn down.
    ///
    /// **Standalone init:** closes the owned `TelemetryClient` (final flush +
    /// timer cancel).  The owned `CacheStore` is held by `self.cache` via ARC
    /// and is released — and closed by GRDB on deinit — when the engine is
    /// deallocated after `shutdown()` returns.  The `HTTPGateRegistry` holds
    /// no persistent resources, so no explicit close is needed.
    public func shutdown() async {
        switch subsystemOwnership {
        case .shared:
            // Shared subsystems stay alive for other engines — do not touch them.
            break
        case let .owned(ownedTelemetry):
            // Telemetry: final flush + cancel flush timer.
            await ownedTelemetry.shutdown()
            // CacheStore: held by self.cache (ARC).  GRDB DatabasePool closes
            // its SQLite connection when the engine is deallocated after
            // shutdown() returns.  Actor isolation guarantees no new reads/
            // writes can start after this point.
        }
        // Use self.logger so the "shutdown complete" line reaches the file
        // sink before the writer is torn down (the RotatingFileWriter flushes
        // on every write, so this line lands on disk immediately).
        logger.info("OfemEngine: shutdown complete")
    }

    // MARK: - Private helpers

    /// Per-alias subsystems produced by `buildPerAliasSubsystems`.
    private struct PerAliasSubsystems {
        let logger: OfemLogger
        let auth: OfemAuth
        let sync: SyncEngine
    }

    /// Wires up all per-alias subsystems (logger, auth, HTTP clients, sync
    /// engine) given already-resolved shared subsystems.
    ///
    /// Extracted so both initialisers share identical wiring logic and future
    /// changes only need to be applied once.
    ///
    /// The `cfg` parameter must be the snapshot already read by the caller
    /// so that both inits read the config exactly once (engine-01).
    private static func buildPerAliasSubsystems(
        cfg: OfemConfig,
        configStore: OfemConfigStore,
        auth existingAuth: OfemAuth?,
        paths: OfemPaths,
        cache: CacheStore,
        telemetry: TelemetryClient,
        sessionPool: SessionPool,
        httpBaseURLs: (oneLake: URL, fabric: URL)?
    ) throws -> PerAliasSubsystems {
        // 1. Logger (per-alias).
        // store-14: wire RotatingFileWriter so on-disk logs are produced.
        // Use LogLevel(string:) to honour all four levels; fall back to .info
        // for an unrecognised value (matches LogLevel.init(string:) semantics).
        let logLevel = LogLevel(string: cfg.log.level) ?? .info
        let fileWriter = RotatingFileWriter(logDirectory: paths.logDir)
        let logConfig = LogConfiguration(
            subsystem: OfemPaths.bundleID,
            category: "engine",
            level: logLevel,
            fileWriter: fileWriter
        )
        let logger = OfemLogger(configuration: logConfig)

        // 2. Auth — reuse the provided instance when the caller already built
        //    it (standalone init pre-builds auth so the SessionPool and the
        //    engine use the same actor). Otherwise build a fresh one.
        let auth = existingAuth ?? OfemAuth(configStore: configStore)

        // 3. HTTP clients — use the provided session pool.
        let oneLakeURL = httpBaseURLs?.oneLake ?? OneLakeClient.defaultBaseURL
        let fabricURL = httpBaseURLs?.fabric ?? OfemEngine.defaultFabricBaseURL

        let onelake = OneLakeClient(sessionPool: sessionPool, baseURL: oneLakeURL, logger: logger)
        let fabric = FabricClient(sessionPool: sessionPool, baseURL: fabricURL, logger: logger)

        // 4. Sync engine (per-alias).
        let scratchBase = paths.cacheDir.appendingPathComponent("partials")
        let syncEngine = SyncEngine(
            cache: cache,
            onelake: onelake,
            fabric: fabric,
            logger: logger,
            telemetry: telemetry,
            scratchBase: scratchBase
        )

        return PerAliasSubsystems(logger: logger, auth: auth, sync: syncEngine)
    }
}
