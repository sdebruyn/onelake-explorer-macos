import CryptoKit
import Foundation
import os.log

// MARK: - SyncEngine

/// The top-level sync coordinator.
///
/// `SyncEngine` wires `OfemAuth`, `CacheStore`, `OneLakeClientProtocol`,
/// `FabricClientProtocol`, `TelemetryClient`, and `OfemLogger` into the core
/// OFEM file-system operations: enumerate, open, put, delete, mkdir, and
/// workspace / item discovery.
///
/// ## Design notes
///
/// - `SyncEngine` is a Swift `actor` so all mutable state (the per-account
/// download / upload semaphore tables, in-flight download map) is automatically
/// serialised.
/// - Network-heavy methods (`open`, `put`) release the actor while the network
/// call is in flight so other tasks are not blocked (Swift structured
/// concurrency: `async` automatically suspends the caller).
/// - Blocking filesystem I/O (spill-file create/seek/hash) is dispatched via
/// `Task.detached` to a background executor and never runs on the actor's
/// thread (sync-14).
/// - Concurrency caps are enforced per account alias via `AsyncSemaphore`.
/// - Last-write-wins semantics: `put` and `delete` never use `If-Match` for
/// writes. This matches the agreed conflict policy in `docs/auth.md`.
public actor SyncEngine {
    // MARK: - Configuration

    /// Default per-account cap on concurrent downloads.
    public static let defaultMaxConcurrentDownloads = 8

    /// Default per-account cap on concurrent uploads.
    public static let defaultMaxConcurrentUploads = 4

    /// Default minimum gap between workspace-recovery probes (mirrors
    /// `PauseManager.defaultProbeInterval` so `SyncEngine.init` can expose it
    /// in a public default-argument without leaking the internal `PauseManager`
    /// type into the public API).
    public static let defaultPauseProbeInterval: Duration = .seconds(120)

    /// Default self-heal floor for ``refreshMaterialized`` (#380): force a
    /// non-gated full re-list of each container at least this often as insurance
    /// against the empirical "directory etag advances on any descendant write"
    /// invariant. PR B wires this to a configurable advanced setting
    /// (10–60 min, disableable); PR A uses this default and a `0 ⇒ disabled`
    /// parameter so the behaviour is testable in isolation.
    public static let defaultSelfHealIntervalMinutes = 30

    /// Default freshness window for ``open(key:)``'s cache-hit path: a row
    /// synced within this long ago is served without a `getProperties` HEAD.
    /// Aligned with `ChangeWatcher`'s default `materializedPollInterval`
    /// (60 s): `syncedAtNs` is stamped fresh by the initial download and by
    /// any subsequent `refreshFolder` pass that observes an actual change for
    /// this row (an unchanged row's `syncedAtNs` is deliberately left alone —
    /// see `refreshFolder`'s upsert-batch comment). So the window mainly
    /// covers the common burst case — Quick Look, a re-open shortly after a
    /// download or a poll-observed change — not an indefinitely-refreshed
    /// guarantee; a stable file still re-validates with a real HEAD roughly
    /// once per window. `.zero` disables the fast path (always HEAD, today's
    /// behaviour).
    public static let defaultBlobFreshnessTTL: Duration = .seconds(60)

    // MARK: - Dependencies (internal — callers should still go through SyncEngine API)

    //
    // sync-19: these were `nonisolated let` with default (internal) access,
    // letting any OfemKit code bypass the actor's pause/semaphore/telemetry
    // invariants by calling the clients directly. Made `private` now;
    // `nonisolated` is still required for wiring in init (which runs before
    // the actor is fully initialised).
    //
    // M10a (#466): promoted back to `internal` ahead of splitting this file
    // into `SyncEngine+*.swift` family extensions, which need to reference
    // this state from other files. The sync-19 guidance still holds as a
    // convention — callers outside `SyncEngine`'s own extensions should go
    // through its API, not this state directly.

    nonisolated let cache: CacheStore
    nonisolated let onelake: any OneLakeClientProtocol
    nonisolated let fabric: any FabricClientProtocol

    let logger: OfemLogger
    let telemetry: TelemetryClient?

    // MARK: - Internal state

    let pauseManager: PauseManager
    let offlineTracker: OfflineTracker
    let partials: PartialManager

    /// Per-account semaphores for downloads, uploads, and materialized-set refreshes.
    ///
    /// Entries are allocated lazily on first use per alias. Growth is bounded
    /// by the number of distinct account aliases active in this process
    /// (typically 1-3) so the unbounded-map concern is negligible in practice.
    /// A future `forgetAccount(alias:)` hook can prune entries on sign-out
    /// (sync-16).
    var downloadSlots: [String: AsyncSemaphore] = [:]
    var uploadSlots: [String: AsyncSemaphore] = [:]
    var refreshSlots: [String: AsyncSemaphore] = [:]
    let maxDownloads: Int
    let maxUploads: Int

    /// In-flight download tasks keyed by ``CacheKey/stableKeyString``.
    ///
    /// A second `open()` for the same key awaits the first's task rather than
    /// spawning a duplicate download. The map entry is removed when the task
    /// VALUE is delivered (not when the spawning frame unwinds) so a second
    /// caller that arrives while the task is still running always finds the
    /// entry (sync-24 fix).
    var inFlightDownloads: [String: Task<OpenResult, any Error>] = [:]

    /// Generation counter per key — incremented each time a new download task is
    /// spawned for a key. Used to guard against a stale cleanup (from a previous,
    /// now-cancelled task) removing an entry that belongs to a newer task.
    var downloadGenerations: [String: UInt64] = [:]

    /// Per-container timestamp (Unix nanoseconds) of the last self-heal forced
    /// full re-list in ``refreshMaterialized`` (#380). Keyed by
    /// ``CacheKey/stableKeyString``. Absent ⇒ never self-healed yet ⇒ the first
    /// poll forces a list and records the timestamp, so steady-state self-heals
    /// land roughly one interval apart rather than all firing on poll 1.
    var lastSelfHealNs: [String: Int64] = [:]

    /// Injectable time source (Unix nanoseconds) used by the self-heal floor so
    /// tests can drive elapsed time deterministically instead of sleeping on the
    /// wall clock. Defaults to the real clock.
    nonisolated let nowNsProvider: @Sendable () -> Int64

    /// ``defaultBlobFreshnessTTL`` (or the constructor-supplied override) used
    /// to gate ``open(key:)``'s freshness HEAD. Converted to nanoseconds
    /// inline where compared, mirroring how ``refreshMaterialized`` derives
    /// its self-heal threshold from `selfHealIntervalMinutes`.
    nonisolated let blobFreshnessTTL: Duration

    /// Account aliases with a ``refreshMaterialized`` pass currently in flight
    /// (#380). The production caller `pollMaterialized` spawns an unstructured
    /// `Task` per XPC poll with no cross-pass mutual exclusion, and the
    /// per-alias semaphore only caps concurrency *within* a pass — so two
    /// overlapping same-alias passes could interleave across the `cache.fetch`
    /// suspension points and break the "a parent vouched THIS pass" guarantee.
    /// A second pass for an alias already in flight returns early: the in-flight
    /// pass already covers this poll's freshness.
    var refreshInFlightAliases: Set<String> = []

    /// Minimum gap between Fabric item-listing refreshes for a single
    /// materialized workspace container (F6/C16). A workspace container is
    /// depth-0 with no subtree etag, so the #380 skip-gate can never elide it;
    /// without this throttle ``refreshMaterialized`` would issue one Fabric REST
    /// call per materialized workspace on every poll. 60 s mirrors the host
    /// working-set poll cadence (`OfemWorkingSetEnumerator.workspaceRefreshInterval`).
    static let itemListThrottleNs: Int64 = 60 * 1_000_000_000

    /// Unix-nanosecond timestamp of the last SUCCESSFUL Fabric item-listing
    /// refresh per `(alias, workspaceID)`, gating ``refreshItemListing`` by
    /// ``itemListThrottleNs``. Keyed by ``itemListKey(alias:workspaceID:)``.
    /// Stamped only after a successful list so a thrown attempt stays due.
    var lastItemListNs: [String: Int64] = [:]

    /// `(alias, workspaceID)` pairs with a ``refreshItemListing`` in flight, so
    /// overlapping poll-path refreshes for the same workspace coalesce instead
    /// of each reading pre-upsert discovery state and double-writing. Mirrors
    /// ``refreshInFlightAliases``. Keyed by ``itemListKey(alias:workspaceID:)``.
    var itemListInFlight: Set<String> = []

    /// Minimum gap between tombstone TTL purges for a single account alias.
    /// `refreshMaterialized` is the throttle host (the poll tick already fires
    /// ~every 60 s per alias), so the purge rides that cadence at most once per
    /// day instead of adding its own loop. 24 h is far tighter than the 30-day
    /// tombstone TTL, so the purge horizon never lags materially behind the TTL.
    static let tombstonePurgeThrottleNs: Int64 = 24 * 60 * 60 * 1_000_000_000

    /// Unix-nanosecond timestamp of the last SUCCESSFUL tombstone purge per
    /// account alias, gating ``purgeExpiredTombstonesThrottled(alias:)`` by
    /// ``tombstonePurgeThrottleNs``. Stamped only after a successful purge so a
    /// thrown attempt (e.g. a transient SQLite error) stays due next poll —
    /// mirrors the stamp-after-success policy of ``lastItemListNs`` /
    /// ``lastSelfHealNs``.
    var lastTombstonePurgeNs: [String: Int64] = [:]

    static let log = Logger(subsystem: "dev.debruyn.ofem", category: "SyncEngine")

    // MARK: - Init

    /// Creates a `SyncEngine`.
    ///
    /// - Parameters:
    /// - cache: Metadata + blob cache (required).
    /// - onelake: DFS HTTP client (required).
    /// - fabric: Fabric REST client (required).
    /// - logger: Structured logger.
    /// - telemetry: Optional telemetry sink.
    /// - maxConcurrentDownloads: Per-account download cap.
    /// - maxConcurrentUploads: Per-account upload cap.
    /// - scratchBase: Directory for download spill files. Defaults to
    /// `<tmp>/ofem-download-partials/<pid>`.
    /// - pauseProbeInterval: Minimum gap between workspace-recovery probes.
    /// - blobFreshnessTTL: Minimum row age below which ``open(key:)`` trusts a
    ///   cached blob without a `getProperties` HEAD. `.zero` always
    ///   HEADs (today's behaviour); tests that want to force a HEAD on every
    ///   open pass `.zero` explicitly.
    /// - nowNsProvider: Injectable Unix-nanosecond clock for the #380 self-heal
    ///   floor. Defaults to the real wall clock; tests pass a controllable
    ///   source to drive elapsed time deterministically.
    public init(
        cache: CacheStore,
        onelake: any OneLakeClientProtocol,
        fabric: any FabricClientProtocol,
        logger: OfemLogger = OfemLogger(),
        telemetry: TelemetryClient? = nil,
        maxConcurrentDownloads: Int = SyncEngine.defaultMaxConcurrentDownloads,
        maxConcurrentUploads: Int = SyncEngine.defaultMaxConcurrentUploads,
        scratchBase: URL? = nil,
        pauseProbeInterval: Duration = SyncEngine.defaultPauseProbeInterval,
        blobFreshnessTTL: Duration = SyncEngine.defaultBlobFreshnessTTL,
        nowNsProvider: (@Sendable () -> Int64)? = nil
    ) {
        self.cache = cache
        // Resolve the default inside the init body: the default-argument
        // expression is evaluated in the caller's scope, where the private
        // global `currentNowNs()` is not visible. `nil` ⇒ real wall clock.
        self.nowNsProvider = nowNsProvider ?? { currentNowNs() }
        self.blobFreshnessTTL = blobFreshnessTTL
        self.onelake = onelake
        self.fabric = fabric
        self.logger = logger
        self.telemetry = telemetry
        self.maxDownloads = max(1, maxConcurrentDownloads)
        self.maxUploads = max(1, maxConcurrentUploads)

        // Scratch dir: per-process sub-directory.
        let base: URL = if let sb = scratchBase {
            sb
        } else {
            URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent(PartialManager.partialsDirName)
        }
        let pid = ProcessInfo.processInfo.processIdentifier
        let scratchDir = base.appendingPathComponent("\(pid)")
        self.partials = PartialManager(scratchDir: scratchDir)

        // Defer the stale-partial reap to a background task so SyncEngine.init
        // (called from OfemEngine's @MainActor init) never performs synchronous
        // FileManager traversal or kill(2) probes on the main thread.
        Task.detached(priority: .utility) {
            PartialManager.reapStalePartialDirs(under: base)
        }

        self.pauseManager = PauseManager(cache: cache, onelake: onelake, probeInterval: pauseProbeInterval)
        self.offlineTracker = OfflineTracker()
    }
}
