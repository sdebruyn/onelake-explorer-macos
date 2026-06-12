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

    // MARK: - Private state

    private var started = false

    /// `true` when this engine constructed its own `TelemetryClient`,
    /// `CacheStore`, and `HTTPGateRegistry` (standalone init path).
    /// `false` when those were injected from the process-wide container
    /// (FPE shared-subsystem path) — in that case `shutdown()` must NOT
    /// tear down the shared client or the flush timer will be cancelled for
    /// all still-live engines in the process.
    private let ownsSharedSubsystems: Bool

    private static let log = Logger(subsystem: "dev.debruyn.ofem", category: "OfemEngine")

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
        let perAlias = try OfemEngine.buildPerAliasSubsystems(
            configStore: configStore,
            paths: paths,
            cache: sharedCache,
            telemetry: sharedTelemetry,
            gateRegistry: sharedGateRegistry,
            httpBaseURLs: httpBaseURLs
        )

        self.logger = perAlias.logger
        self.cache = sharedCache
        self.telemetry = sharedTelemetry
        self.auth = perAlias.auth
        self.sync = perAlias.sync
        // Injected init does NOT own the shared subsystems.
        self.ownsSharedSubsystems = false
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

        // Build owned gate registry.
        let ownedGates = HTTPGateRegistry.makeDefault()

        let perAlias = try OfemEngine.buildPerAliasSubsystems(
            configStore: configStore,
            paths: paths,
            cache: ownedCache,
            telemetry: ownedTelemetry,
            gateRegistry: ownedGates,
            httpBaseURLs: httpBaseURLs
        )

        self.logger = perAlias.logger
        self.cache = ownedCache
        self.telemetry = ownedTelemetry
        self.auth = perAlias.auth
        self.sync = perAlias.sync
        // Standalone init owns all subsystems it created.
        self.ownsSharedSubsystems = true
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

    /// Stops per-alias background tasks and, when this engine owns the
    /// `TelemetryClient`, performs a final telemetry flush and cancels the
    /// flush timer.
    ///
    /// When using a **shared** `TelemetryClient` (injected init), this method
    /// does **not** call `telemetry.shutdown()`.  The flush timer keeps running
    /// for all surviving engines in the process.  Call
    /// `FPEEngineHost.shutdownSharedSubsystems()` once all domains have been
    /// torn down to perform the final flush.
    ///
    /// When using a **standalone** `TelemetryClient` (standalone init), this
    /// method shuts down the client as before.
    public func shutdown() async {
        if ownsSharedSubsystems {
            await telemetry.shutdown()
        }
        Self.log.info("OfemEngine: shutdown complete")
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
    /// changes (e.g. WP-G SyncEngine updates) only need to be applied once.
    private static func buildPerAliasSubsystems(
        configStore: OfemConfigStore,
        paths: OfemPaths,
        cache: CacheStore,
        telemetry: TelemetryClient,
        gateRegistry: HTTPGateRegistry,
        httpBaseURLs: (oneLake: URL, fabric: URL)?
    ) throws -> PerAliasSubsystems {
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

        // 2. Auth — OfemAuth is a Swift actor (not @MainActor), so init
        //    no longer forces the engine init onto the main thread.
        let auth = OfemAuth(configStore: configStore)

        // 3. HTTP clients — use the provided gate registry.
        let http = HTTPClient(gateRegistry: gateRegistry)

        let oneLakeURL = httpBaseURLs?.oneLake ?? OneLakeClient.defaultBaseURL
        let fabricURL  = httpBaseURLs?.fabric  ?? URL(string: "https://api.fabric.microsoft.com")!

        let tokenProvider = TokenProviderAdapter(auth: auth)
        let onelake = OneLakeClient(http: http, tokenProvider: tokenProvider, baseURL: oneLakeURL)
        let fabric  = FabricClient(http: http, tokenProvider: tokenProvider, baseURL: fabricURL)

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
