import Foundation
import os.log

// MARK: - OfemEngine

/// Façade that assembles all OfemKit subsystems into a single, ready-to-use
/// engine object.
///
/// `OfemEngine` is a **facade / wire-up container** that builds the per-alias
/// dependency graph (auth → HTTP client → Fabric + OneLake clients → sync
/// engine) using process-wide shared subsystems (cache, telemetry, HTTP gate
/// registry) that are injected at initialisation time.
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
/// - `HTTPGateRegistry` — endpoint-protection budgets are per-host, not
///   per-account; sharing the registry prevents the budgets from being
///   multiplied by the number of accounts.
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

    // MARK: - Private state

    private var started = false
    private static let log = Logger(subsystem: "dev.debruyn.ofem", category: "OfemEngine")

    // MARK: - Initialisers

    /// Builds per-alias subsystems from a loaded ``OfemConfigStore`` and
    /// ``OfemPaths``, reusing process-wide shared subsystems.
    ///
    /// Use this initialiser in the FPE where `FPEEngineHost` has already
    /// constructed the shared singletons.
    ///
    /// ## Config reload
    ///
    /// The config snapshot is read once at initialisation time and baked
    /// into the subsystems (log level → `OfemLogger`, telemetry opt-out →
    /// sink choice, `cache.maxBytes` → `CacheStore`, concurrency limits →
    /// `HTTPGateRegistry`). Subsequent config changes therefore require
    /// building a **new** `OfemEngine` from the updated snapshot.
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
    ///   - sharedGateRegistry: Process-wide HTTPGateRegistry to share across engines.
    ///   - httpBaseURLs: Override the default DFS / Fabric base URLs. Pass
    ///     `nil` to use the production endpoints.
    public init(
        configStore: OfemConfigStore,
        paths: OfemPaths,
        sharedCache: CacheStore,
        sharedTelemetry: TelemetryClient,
        sharedGateRegistry: HTTPGateRegistry,
        httpBaseURLs: (oneLake: URL, fabric: URL)? = nil
    ) throws {
        let cfg = configStore.snapshot()

        // 1. Logger (per-alias).
        // store-14: wire RotatingFileWriter so on-disk logs are produced.
        // Use LogLevel(string:) to honour all four levels; fall back to .info
        // for an unrecognised value (matches LogLevel.init(string:) semantics).
        let logLevel: LogLevel = LogLevel(string: cfg.log.level) ?? .info
        let fileWriter = RotatingFileWriter(logDirectory: paths.logDir)
        let logConfig = LogConfiguration(
            subsystem: "dev.debruyn.ofem",
            category: "engine",
            level: logLevel,
            fileWriter: fileWriter
        )
        let logger = OfemLogger(configuration: logConfig)
        self.logger = logger

        // 2. Shared subsystems — injected from the process-wide container.
        self.cache = sharedCache
        self.telemetry = sharedTelemetry

        // 3. Auth — OfemAuth is a Swift actor (not @MainActor), so init
        //    no longer forces the engine init onto the main thread.
        let auth = OfemAuth(configStore: configStore)
        self.auth = auth

        // 4. HTTP clients — use the shared gate registry.
        let http = HTTPClient(gateRegistry: sharedGateRegistry)

        let oneLakeURL = httpBaseURLs?.oneLake ?? OneLakeClient.defaultBaseURL
        let fabricURL  = httpBaseURLs?.fabric  ?? URL(string: "https://api.fabric.microsoft.com")!

        let tokenProvider = TokenProviderAdapter(auth: auth)
        let onelake = OneLakeClient(http: http, tokenProvider: tokenProvider, baseURL: oneLakeURL)
        let fabric  = FabricClient(http: http, tokenProvider: tokenProvider, baseURL: fabricURL)

        // 5. Sync engine (per-alias).
        let scratchBase = paths.cacheDir.appendingPathComponent("partials")
        let syncEngine = SyncEngine(
            cache: sharedCache,
            onelake: onelake,
            fabric: fabric,
            logger: logger,
            telemetry: sharedTelemetry,
            scratchBase: scratchBase
        )
        self.sync = syncEngine
    }

    /// Builds all subsystems autonomously — constructs its own cache, telemetry,
    /// and gate registry.
    ///
    /// Intended for standalone use (tests, CLI tools, one-engine scenarios) where
    /// a process-wide shared container is not available. Production FPE code should
    /// use the injected-dependency initialiser to share subsystems across engines.
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

        // 1. Logger.
        let logLevel: LogLevel = LogLevel(string: cfg.log.level) ?? .info
        let fileWriter = RotatingFileWriter(logDirectory: paths.logDir)
        let logConfig = LogConfiguration(
            subsystem: "dev.debruyn.ofem",
            category: "engine",
            level: logLevel,
            fileWriter: fileWriter
        )
        let logger = OfemLogger(configuration: logConfig)
        self.logger = logger

        // 2. Telemetry.
        // `AppInsightsSink.init` throws only if the connection string is
        // malformed; the constant in `BuildInfo` is always well-formed, so
        // the `try?` here is purely a defensive fallback.
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
        let telClient = TelemetryClient(
            sink: telSink,
            appVersion: BuildInfo.version,
            installID: cfg.installID,
            configuration: TelemetryConfiguration(optOut: !cfg.telemetry)
        )
        self.telemetry = telClient

        // 3. Auth.
        let auth = OfemAuth(configStore: configStore)
        self.auth = auth

        // 4. HTTP clients.
        let gate = HTTPGateRegistry.makeDefault()
        let http = HTTPClient(gateRegistry: gate)

        let oneLakeURL = httpBaseURLs?.oneLake ?? OneLakeClient.defaultBaseURL
        let fabricURL  = httpBaseURLs?.fabric  ?? URL(string: "https://api.fabric.microsoft.com")!

        let tokenProvider = TokenProviderAdapter(auth: auth)
        let onelake = OneLakeClient(http: http, tokenProvider: tokenProvider, baseURL: oneLakeURL)
        let fabric  = FabricClient(http: http, tokenProvider: tokenProvider, baseURL: fabricURL)

        // 5. Cache.
        let cache = try CacheStore(
            root: paths.cacheDir,
            maxBlobBytes: cfg.cache.maxBytes
        )
        self.cache = cache

        // 6. Sync engine.
        let scratchBase = paths.cacheDir.appendingPathComponent("partials")
        let syncEngine = SyncEngine(
            cache: cache,
            onelake: onelake,
            fabric: fabric,
            logger: logger,
            telemetry: telClient,
            scratchBase: scratchBase
        )
        self.sync = syncEngine
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
        Self.log.info("OfemEngine: started")
    }

    /// Stops background tasks and performs a final telemetry flush.
    ///
    /// When using a shared `TelemetryClient`, the caller (FPEEngineHost) is
    /// responsible for calling `shutdown()` only once, after the last engine
    /// that owns the client has been torn down.
    public func shutdown() async {
        await telemetry.shutdown()
        Self.log.info("OfemEngine: shutdown complete")
    }
}

// MARK: - TokenProviderAdapter

/// Bridges ``OfemAuth`` (a Swift `actor`) to the ``TokenProvider``
/// protocol expected by ``OneLakeClient`` and ``FabricClient``.
///
/// Token acquisition runs on `OfemAuth`'s own executor — not the main actor —
/// so concurrent Finder I/O calls in the FPE do not serialise through the
/// main thread.
private final class TokenProviderAdapter: TokenProvider, Sendable {
    private let auth: OfemAuth

    init(auth: OfemAuth) {
        self.auth = auth
    }

    func token(alias: String, scope: TokenScope) async throws -> String {
        // OfemAuth is a Swift actor; calling its methods suspends here and
        // resumes on the actor's executor. No main-actor hop needed.
        try await auth.tokenForScope(alias: alias, scope: scope)
    }
}
