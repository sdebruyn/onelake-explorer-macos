import Foundation
import os.log

// MARK: - OfemEngine

/// Façade that assembles all OfemKit subsystems into a single, ready-to-use
/// engine object.
///
/// `OfemEngine` is a **facade / wire-up container** that builds the full
/// dependency graph (auth → HTTP client → Fabric + OneLake clients → cache →
/// sync engine) in the correct order and exposes the subsystems to callers
/// via public properties. The File Provider Extension instantiates one
/// `OfemEngine` and forwards `NSFileProviderEnumerator` / change-observer
/// calls to `SyncEngine`.
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

    /// Metadata + blob cache.
    public nonisolated let cache: CacheStore

    /// Sync coordinator (enumerate / open / put / delete / mkdir).
    public nonisolated let sync: SyncEngine

    /// Telemetry client. Telemetry is opt-out; when the config sets
    /// `telemetry = false` this is a noop-sink-backed client.
    public nonisolated let telemetry: TelemetryClient

    /// Structured logger.
    public nonisolated let logger: OfemLogger

    // MARK: - Private state

    private var started = false
    private static let log = Logger(subsystem: "dev.debruyn.ofem", category: "OfemEngine")

    // MARK: - Initialiser

    /// Builds all subsystems from a loaded ``OfemConfigStore`` and
    /// ``OfemPaths``.
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
    /// - configStore: The loaded TOML config.
    /// - paths: Resolved on-disk paths (cache dir, log dir, etc.).
    /// - httpBaseURLs: Override the default DFS / Fabric base URLs. Pass
    /// `nil` to use the production endpoints.
    @MainActor
    public init(
        configStore: OfemConfigStore,
        paths: OfemPaths,
        httpBaseURLs: (oneLake: URL, fabric: URL)? = nil
    ) throws {
        let cfg = configStore.snapshot()

        // 1. Logger.
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

        // 3. Auth (needs to be on @MainActor because OfemAuth is @MainActor).
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

    /// Starts background tasks (telemetry flush timer, paused workspace sweep).
    public func start() async {
        guard !started else { return }
        started = true
        await telemetry.start()
        Self.log.info("OfemEngine: started")
    }

    /// Stops background tasks and performs a final telemetry flush.
    public func shutdown() async {
        await telemetry.shutdown()
        Self.log.info("OfemEngine: shutdown complete")
    }
}

// MARK: - TokenProviderAdapter

/// Bridges ``OfemAuth`` (a `@MainActor` class) to the ``TokenProvider``
/// protocol expected by ``OneLakeClient`` and ``FabricClient``.
///
/// Token acquisition is always dispatched to the main actor; the adapter
/// re-enters `@MainActor` via `await MainActor.run { … }`.
private final class TokenProviderAdapter: TokenProvider, Sendable {
    private let auth: OfemAuth

    init(auth: OfemAuth) {
        self.auth = auth
    }

    func token(alias: String, scope: TokenScope) async throws -> String {
        // Calling a @MainActor method from a non-isolated async context causes
        // Swift to automatically hop to the main actor for the duration of the
        // call, which is safe here — OfemAuth never blocks the main thread.
        try await auth.tokenForScope(alias: alias, scope: scope)
    }
}

