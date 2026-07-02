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

    // MARK: - Dependencies (private — callers must go through SyncEngine API)

    //
    // sync-19: these were `nonisolated let` with default (internal) access,
    // letting any OfemKit code bypass the actor's pause/semaphore/telemetry
    // invariants by calling the clients directly. Made `private` now;
    // `nonisolated` is still required for wiring in init (which runs before
    // the actor is fully initialised).

    private nonisolated let cache: CacheStore
    private nonisolated let onelake: any OneLakeClientProtocol
    private nonisolated let fabric: any FabricClientProtocol

    private let logger: OfemLogger
    private let telemetry: TelemetryClient?

    // MARK: - Internal state

    private let pauseManager: PauseManager
    private let offlineTracker: OfflineTracker
    private let partials: PartialManager

    /// Per-account semaphores for downloads, uploads, and materialized-set refreshes.
    ///
    /// Entries are allocated lazily on first use per alias. Growth is bounded
    /// by the number of distinct account aliases active in this process
    /// (typically 1-3) so the unbounded-map concern is negligible in practice.
    /// A future `forgetAccount(alias:)` hook can prune entries on sign-out
    /// (sync-16).
    private var downloadSlots: [String: AsyncSemaphore] = [:]
    private var uploadSlots: [String: AsyncSemaphore] = [:]
    private var refreshSlots: [String: AsyncSemaphore] = [:]
    private let maxDownloads: Int
    private let maxUploads: Int

    /// In-flight download tasks keyed by ``CacheKey/stableKeyString``.
    ///
    /// A second `open()` for the same key awaits the first's task rather than
    /// spawning a duplicate download. The map entry is removed when the task
    /// VALUE is delivered (not when the spawning frame unwinds) so a second
    /// caller that arrives while the task is still running always finds the
    /// entry (sync-24 fix).
    private var inFlightDownloads: [String: Task<OpenResult, any Error>] = [:]

    /// Generation counter per key — incremented each time a new download task is
    /// spawned for a key. Used to guard against a stale cleanup (from a previous,
    /// now-cancelled task) removing an entry that belongs to a newer task.
    private var downloadGenerations: [String: UInt64] = [:]

    /// Per-container timestamp (Unix nanoseconds) of the last self-heal forced
    /// full re-list in ``refreshMaterialized`` (#380). Keyed by
    /// ``CacheKey/stableKeyString``. Absent ⇒ never self-healed yet ⇒ the first
    /// poll forces a list and records the timestamp, so steady-state self-heals
    /// land roughly one interval apart rather than all firing on poll 1.
    private var lastSelfHealNs: [String: Int64] = [:]

    /// Injectable time source (Unix nanoseconds) used by the self-heal floor so
    /// tests can drive elapsed time deterministically instead of sleeping on the
    /// wall clock. Defaults to the real clock.
    private nonisolated let nowNsProvider: @Sendable () -> Int64

    /// ``defaultBlobFreshnessTTL`` (or the constructor-supplied override) used
    /// to gate ``open(key:)``'s freshness HEAD. Converted to nanoseconds
    /// inline where compared, mirroring how ``refreshMaterialized`` derives
    /// its self-heal threshold from `selfHealIntervalMinutes`.
    private nonisolated let blobFreshnessTTL: Duration

    /// Account aliases with a ``refreshMaterialized`` pass currently in flight
    /// (#380). The production caller `pollMaterialized` spawns an unstructured
    /// `Task` per XPC poll with no cross-pass mutual exclusion, and the
    /// per-alias semaphore only caps concurrency *within* a pass — so two
    /// overlapping same-alias passes could interleave across the `cache.fetch`
    /// suspension points and break the "a parent vouched THIS pass" guarantee.
    /// A second pass for an alias already in flight returns early: the in-flight
    /// pass already covers this poll's freshness.
    private var refreshInFlightAliases: Set<String> = []

    /// Minimum gap between Fabric item-listing refreshes for a single
    /// materialized workspace container (F6/C16). A workspace container is
    /// depth-0 with no subtree etag, so the #380 skip-gate can never elide it;
    /// without this throttle ``refreshMaterialized`` would issue one Fabric REST
    /// call per materialized workspace on every poll. 60 s mirrors the host
    /// working-set poll cadence (`OfemWorkingSetEnumerator.workspaceRefreshInterval`).
    private static let itemListThrottleNs: Int64 = 60 * 1_000_000_000

    /// Unix-nanosecond timestamp of the last SUCCESSFUL Fabric item-listing
    /// refresh per `(alias, workspaceID)`, gating ``refreshItemListing`` by
    /// ``itemListThrottleNs``. Keyed by ``itemListKey(alias:workspaceID:)``.
    /// Stamped only after a successful list so a thrown attempt stays due.
    private var lastItemListNs: [String: Int64] = [:]

    /// `(alias, workspaceID)` pairs with a ``refreshItemListing`` in flight, so
    /// overlapping poll-path refreshes for the same workspace coalesce instead
    /// of each reading pre-upsert discovery state and double-writing. Mirrors
    /// ``refreshInFlightAliases``. Keyed by ``itemListKey(alias:workspaceID:)``.
    private var itemListInFlight: Set<String> = []

    private static let log = Logger(subsystem: "dev.debruyn.ofem", category: "SyncEngine")

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

    // MARK: - Workspace / item discovery

    /// Returns all workspaces visible to `alias`, reconciling the local cache.
    public func listWorkspaces(alias: String) async throws -> [Workspace] {
        let start = Date()
        let ws: [Workspace]
        do {
            ws = try await fabric.listAllWorkspaces(alias: alias)
        } catch {
            await offlineTracker.observe(error)
            if await pauseManager.markPausedIfNeeded(
                workspaceID: VirtualIDs.workspaceID, alias: alias, error: error
            ) {
                await track(eventName: "workspace_list", alias: alias, start: start, outcome: .paused)
                throw SyncError.workspacePaused
            }
            await track(eventName: "workspace_list", alias: alias, start: start, outcome: .failed("list_failed"))
            throw error
        }
        await offlineTracker.observe(nil)

        let nowNs = currentNowNs()
        let parentKey = CacheKey(
            accountAlias: alias,
            workspaceID: VirtualIDs.workspaceID,
            itemID: VirtualIDs.workspaceID,
            path: ""
        )
        let root = MetadataRecord(
            accountAlias: alias,
            workspaceID: VirtualIDs.workspaceID,
            itemID: VirtualIDs.workspaceID,
            path: "",
            parentPath: "",
            name: alias,
            isDir: true,
            lastAccessedNs: nowNs,
            syncedAtNs: nowNs
        )
        do { try await cache.upsert(root) } catch {
            Self.log.warning("listWorkspaces: upsert root failed err=\(error, privacy: .public)")
        }

        let seen = Set(ws.map(\.id))
        // Fetch the cached children ONCE and reuse the array for both the
        // new-or-changed classification and the expiry reconcile below, instead
        // of querying `cache.children` twice per pass.
        let cachedChildren = (try? await cache.children(of: parentKey)) ?? []
        let cachedByPath = Self.indexByPath(cachedChildren)
        let candidates = ws.map { w in
            MetadataRecord(
                accountAlias: alias,
                workspaceID: VirtualIDs.workspaceID,
                itemID: VirtualIDs.workspaceID,
                path: w.id,
                parentPath: "",
                name: w.displayName,
                isDir: true,
                lastAccessedNs: cachedByPath[w.id]?.lastAccessedNs ?? nowNs,
                syncedAtNs: nowNs
            )
        }
        let rows = Self.classifyUpserts(candidates: candidates, cachedByPath: cachedByPath).batch
        await batchUpsert(rows, context: "listWorkspaces")
        // The parent of the workspaces listing is the domain root — root must
        // never be signalled (a root signal forces `.syncAnchorExpired` →
        // full re-enumeration). Root stays remount-driven via ChangeWatcher.
        // Container freshness for sub-containers is surfaced by the host
        // working-set poll loop rather than any per-container signal.
        await expireDiscoveryRows(children: cachedChildren, seen: seen, alias: alias)

        await track(eventName: "workspace_list", alias: alias, start: start, outcome: .success())
        return ws
    }

    /// Returns all items inside `workspaceID`, reconciling the local cache.
    ///
    /// On-demand entry point (navigation / `item(for:)` cache-miss fallback):
    /// always lists — it is NOT throttled, so a first-mount cache miss still
    /// populates the cache immediately. The periodic poll path uses the
    /// throttled ``refreshItemListing(alias:workspaceID:)`` instead.
    public func listItems(alias: String, workspaceID: String) async throws -> [Item] {
        let start = Date()
        let (items, _) = try await reconcileItemListing(alias: alias, workspaceID: workspaceID)
        await track(eventName: "item_list", alias: alias, start: start, outcome: .success())
        return items
    }

    /// Refreshes a materialized workspace's Fabric item listing on the poll
    /// path, returning the reconcile ``Diff``.
    ///
    /// A workspace container is materialized under the ``VirtualIDs/itemID``
    /// sentinel (see ``CacheReader/materializedContainers(alias:)``); routing it
    /// through ``refreshFolder(key:)`` would call `onelake.listPath` with
    /// `itemGUID == "__items__"` — a guaranteed DFS error — so it is handled
    /// here via the Fabric item listing instead (F6/C16).
    ///
    /// Two guards keep the poll cheap and consistent:
    /// - **Coalesce**: a second call while one is in flight for the same
    ///   workspace returns an empty ``Diff`` — the in-flight pass covers this
    ///   poll and both must not read pre-upsert state and double-write.
    /// - **Throttle**: within ``itemListThrottleNs`` of the last successful
    ///   list, returns an empty ``Diff`` WITHOUT listing. Depth-0 workspace
    ///   containers have no subtree etag, so the #380 skip-gate can never elide
    ///   them; this is their throttle. The clock is only stamped on success, so
    ///   a thrown (offline/paused) attempt stays due next poll.
    func refreshItemListing(alias: String, workspaceID: String) async throws -> Diff {
        let throttleKey = Self.itemListKey(alias: alias, workspaceID: workspaceID)

        // Coalesce overlapping poll-path refreshes for the same workspace.
        guard !itemListInFlight.contains(throttleKey) else { return Diff() }

        // Throttle: serve an empty diff inside the window. A backward clock step
        // (nowNs < last) fails toward refreshing rather than silently freezing.
        let nowNs = nowNsProvider()
        if let last = lastItemListNs[throttleKey], nowNs >= last, nowNs - last < Self.itemListThrottleNs {
            return Diff()
        }

        itemListInFlight.insert(throttleKey)
        defer { itemListInFlight.remove(throttleKey) }

        let (_, diff) = try await reconcileItemListing(alias: alias, workspaceID: workspaceID)

        // Stamp only after a successful list (reconcileItemListing rethrows on
        // offline/paused BEFORE returning), so an offline poll stays due.
        lastItemListNs[throttleKey] = nowNs

        if diff.total > 0 {
            await track(TelemetryEvent(
                name: "sync_pulled",
                accountAliasHash: TelemetryRedaction.hashAlias(alias),
                itemsChanged: diff.total
            ))
        }
        return diff
    }

    /// The shared reconcile-core for a workspace's Fabric item listing, used by
    /// both the on-demand ``listItems(alias:workspaceID:)`` and the poll-path
    /// ``refreshItemListing(alias:workspaceID:)``.
    ///
    /// Fetches the Fabric items (with the pause/offline guards), applies the
    /// storage-type allowlist, upserts the item-listing root marker, writes the
    /// conditional discovery-row batch, expires vanished rows (tombstoning each
    /// removed item's `.item` identifier), and returns both the storage-backed
    /// items and the reconcile ``Diff``. Emits the paused/failed telemetry on a
    /// thrown Fabric call; the SUCCESS telemetry is left to the callers so the
    /// on-demand and poll paths report distinct events.
    private func reconcileItemListing(
        alias: String,
        workspaceID: String
    ) async throws -> (items: [Item], diff: Diff) {
        let start = Date()
        let items: [Item]
        do {
            items = try await fabric.listAllItems(alias: alias, workspaceID: workspaceID)
        } catch {
            await offlineTracker.observe(error)
            if await pauseManager.markPausedIfNeeded(
                workspaceID: workspaceID, alias: alias, error: error
            ) {
                await track(eventName: "item_list", alias: alias, start: start, outcome: .paused)
                throw SyncError.workspacePaused
            }
            await track(eventName: "item_list", alias: alias, start: start, outcome: .failed("list_failed"))
            throw error
        }
        await offlineTracker.observe(nil)

        // Keep only items whose type is in the strict allowlist
        // (Lakehouse, Warehouse, MirroredDatabase, SQLDatabase). All other
        // types — including types that have OneLake storage but are not yet
        // supported (KQLDatabase, Eventhouse, MirroredWarehouse) and types with
        // no DFS path at all (SQLEndpoint, SemanticModel, Notebook, Report, …)
        // — are hidden. Unknown and empty types are also hidden.
        // Allowlist policy: hide by default.
        let storageItems = items.filter(\.hasOneLakeStorage)

        let nowNs = currentNowNs()
        let parentKey = CacheKey(
            accountAlias: alias,
            workspaceID: workspaceID,
            itemID: VirtualIDs.itemID,
            path: ""
        )
        let root = MetadataRecord(
            accountAlias: alias,
            workspaceID: workspaceID,
            itemID: VirtualIDs.itemID,
            path: "",
            parentPath: "",
            name: workspaceID,
            isDir: true,
            lastAccessedNs: nowNs,
            syncedAtNs: nowNs
        )
        do { try await cache.upsert(root) } catch {
            Self.log.warning("reconcileItemListing: upsert root failed err=\(error, privacy: .public)")
        }

        let seen = Set(storageItems.map(\.id))
        // Fetch the cached children ONCE and thread the array into both the
        // classification and the expiry reconcile (avoids a second query).
        let cachedChildren = (try? await cache.children(of: parentKey)) ?? []
        let cachedByPath = Self.indexByPath(cachedChildren)
        let candidates = storageItems.map { it in
            MetadataRecord(
                accountAlias: alias,
                workspaceID: workspaceID,
                itemID: VirtualIDs.itemID,
                path: it.id,
                parentPath: "",
                name: it.displayName,
                isDir: true,
                lastAccessedNs: cachedByPath[it.id]?.lastAccessedNs ?? nowNs,
                syncedAtNs: nowNs,
                itemType: it.type
            )
        }
        let (rows, added, updated) = Self.classifyUpserts(candidates: candidates, cachedByPath: cachedByPath)
        await batchUpsert(rows, context: "listItems")
        let removed = await expireDiscoveryRows(children: cachedChildren, seen: seen, alias: alias)

        var diff = Diff()
        diff.added = added
        diff.updated = updated
        diff.removed = removed
        return (storageItems, diff)
    }

    /// The throttle/coalesce map key for a `(alias, workspaceID)` pair.
    /// A NUL separator keeps the two components unambiguous.
    private static func itemListKey(alias: String, workspaceID: String) -> String {
        "\(alias)\u{0}\(workspaceID)"
    }

    // MARK: - Enumerate

    /// Returns the children of the container identified by `key`.
    ///
    /// Cache-hit path: when the cache already holds children for `key`, they are
    /// returned immediately. The host poll loop drives freshness via
    /// ``refreshMaterialized(alias:keys:concurrencyCap:)`` + `.workingSet` signal.
    /// Only on a cold cache (no cached children) does a blocking refresh run
    /// before returning, so first open still yields live entries.
    ///
    /// Throws ``FPError/wrongItemKind(_:)`` when `key` refers to a file, not a
    /// directory. The error propagates rather than falling through to a remote
    /// refresh.
    public func enumerate(key: CacheKey) async throws -> [MetadataRecord] {
        let start = Date()

        // Fast path: serve from cache whenever children are present.
        // `cachedListingIfPresent` throws `FPError.wrongItemKind` for files —
        // propagate that error directly instead of swallowing it.
        if let present = try await cachedListingIfPresent(key: key) {
            await track(eventName: "folder_list", alias: key.accountAlias, start: start, outcome: .success())
            return present.children
        }

        // Cold cache (first open): blocking refresh, then return live entries.
        do {
            _ = try await refreshFolder(key: key)
        } catch {
            await track(eventName: "folder_list", alias: key.accountAlias, start: start, outcome: .failed("list_failed"))
            throw error
        }
        let entries = try await cache.children(of: key)
        await track(eventName: "folder_list", alias: key.accountAlias, start: start, outcome: .success())
        return entries
    }

    /// Unconditionally fetches folder contents from OneLake and reconciles the
    /// local cache.
    ///
    /// The work runs as six ordered phases whose sequence is load-bearing and
    /// must be preserved:
    ///
    /// 1. ``fetchRemoteChildren(key:)`` — pause/offline-guarded listing plus the
    ///    direct-child / macOS-metadata filter. Any throw here leaves the cache
    ///    untouched, so a paused or offline folder is never torn on a partial
    ///    result.
    /// 2. ``resolveFolderItemType(key:)`` — the Fabric item type stamped on rows.
    /// 3. ``buildUpsertBatch(key:remoteChildren:cachedByPath:folderItemType:nowNs:)``
    ///    — the conditional-upsert core (pure).
    /// 4. ``harvestSubtreeEtags(key:remoteChildren:cachedByPath:upsertBatch:)`` —
    ///    keeps each directory child's #380 skip-gate token current WITHOUT a
    ///    `synced_at_ns` bump.
    /// 5. ``buildDeleteBatch(key:remoteChildren:cachedByPath:)`` (pure) — tombstones
    ///    cached children absent from the FULL remote listing (never from the
    ///    upsert batch, which deliberately omits unchanged-but-present children).
    /// 6. ``stampParentRow(key:diff:folderItemType:nowNs:)`` — the conditional
    ///    parent freshness marker.
    public func refreshFolder(key: CacheKey) async throws -> Diff {
        // Phase 1: pause/offline-guarded listing. Rethrows before any cache
        // mutation, so a paused/offline folder leaves the cache intact.
        let remoteChildren = try await fetchRemoteChildren(key: key)

        // Capture the reconcile timestamps once the (now filtered) listing is in
        // hand. Every row written this pass shares this syncedAtNs, and
        // elapsed_ms is measured from here. (The pre-refactor code captured
        // `now` a few microseconds earlier — before the child filter — so the
        // logged elapsed_ms no longer includes that filter span; immaterial, and
        // it affects the debug log only.)
        let nowNs = currentNowNs()
        let now = Date()

        // Phase 2: resolve the Fabric item type for capability computation.
        let folderItemType = await resolveFolderItemType(key: key)

        // Load existing cached children once (sync-05: surface the error — a
        // failed children read could otherwise lead to deleting all cached rows
        // on the next reconcile, which is worse than throwing here).
        let cachedByPath = Self.indexByPath(try await cache.children(of: key))

        var diff = Diff()

        // Phase 3: build the conditional upsert batch (pure). Only new and
        // actually-changed rows are written back; unchanged rows are left out so
        // their syncedAtNs is not bumped — bumping it on every poll would shift
        // the working-set delta baseline forward and produce phantom deltas.
        let (upsertBatch, added, updated) = Self.buildUpsertBatch(
            key: key,
            remoteChildren: remoteChildren,
            cachedByPath: cachedByPath,
            folderItemType: folderItemType,
            nowNs: nowNs
        )
        diff.added += added
        diff.updated += updated
        await batchUpsert(upsertBatch, context: "refreshFolder upsert")

        // Phase 4: #380 subtree-etag harvest (only updateSubtreeEtag, never a
        // synced_at_ns bump).
        await harvestSubtreeEtags(
            key: key,
            remoteChildren: remoteChildren,
            cachedByPath: cachedByPath,
            upsertBatch: upsertBatch
        )

        // Phase 5: delete cached children that disappeared remotely, in one
        // batch. The reference set is the FULL remote listing (`remoteChildren`),
        // NEVER the upsert batch — a child skipped from the batch because it is
        // unchanged is still present remotely and must not be tombstoned. Each
        // removed row (and any descendants of a vanished directory) is tombstoned
        // so enumerateChanges delivers the removal incrementally.
        let deleteBatch = Self.buildDeleteBatch(
            key: key,
            remoteChildren: remoteChildren,
            cachedByPath: cachedByPath
        )
        diff.removed += deleteBatch.count
        await batchDelete(deleteBatch, recordTombstones: true, context: "refreshFolder delete")

        // Phase 6: stamp the parent freshness-marker row (conditionally).
        await stampParentRow(key: key, diff: diff, folderItemType: folderItemType, nowNs: nowNs)

        if diff.total > 0 {
            await track(TelemetryEvent(
                name: "sync_pulled",
                accountAliasHash: TelemetryRedaction.hashAlias(key.accountAlias),
                itemsChanged: diff.total
            ))
        }
        logger.debug("folder refreshed",
                     metadata: [
                         "account": key.accountAlias,
                         "workspace": key.workspaceID,
                         "item": key.itemID,
                         "path": key.path,
                         "added": "\(diff.added)",
                         "updated": "\(diff.updated)",
                         "removed": "\(diff.removed)",
                         "elapsed_ms": "\(elapsedMs(since: now))",
                     ])
        return diff
    }

    // MARK: - refreshFolder phases

    /// Phase 1 of ``refreshFolder(key:)``: lists the folder's remote children and
    /// returns them keyed by item-relative path, filtered to direct, non-metadata
    /// entries.
    ///
    /// The pause/offline guards are preserved exactly: a paused workspace throws
    /// ``SyncError/workspacePaused`` and an offline `listPath` rethrows the
    /// underlying error. Both happen BEFORE the caller performs any cache
    /// mutation. INVARIANT: any throw from here leaves the cache untouched.
    private func fetchRemoteChildren(key: CacheKey) async throws -> [String: PathEntry] {
        try await pauseManager.guardPaused(workspaceID: key.workspaceID, alias: key.accountAlias)

        let result: ListResult
        do {
            result = try await onelake.listPath(
                alias: key.accountAlias,
                workspaceGUID: key.workspaceID,
                itemGUID: key.itemID,
                directory: key.path,
                recursive: false
            )
        } catch {
            await offlineTracker.observe(error)
            if await pauseManager.markPausedIfNeeded(
                workspaceID: key.workspaceID, alias: key.accountAlias, error: error
            ) {
                throw SyncError.workspacePaused
            }
            throw error
        }
        await offlineTracker.observe(nil)

        // Build the remote children set, filtering macOS metadata artefacts at
        // emit time so that remote .DS_Store / ._* files never appear in listings
        // and cannot resurrect after a local-only delete.
        //
        // onelake-12: listPath() returns PathEntry.name values that are already
        // item-relative (convertRawEntry stripped the "<itemGUID>/" prefix before
        // returning). Do NOT call Enumerator.stripItemPrefix here — that would
        // attempt to strip the itemGUID prefix a second time and return nil for
        // every entry, leaving remoteChildren empty and causing refreshFolder to
        // reconcile zero children against the cache.
        var remoteChildren: [String: PathEntry] = [:]
        for entry in result.entries {
            // Trim any trailing slash that the DFS API may append to directory names.
            let rel = entry.name.hasSuffix("/") ? String(entry.name.dropLast()) : entry.name
            guard !rel.isEmpty,
                  Enumerator.isDirectChild(parent: key.path, child: rel),
                  !isMacOSMetadata(rel)
            else { continue }
            remoteChildren[rel] = entry
        }
        return remoteChildren
    }

    /// Phase 2 of ``refreshFolder(key:)``: resolves the Fabric item type for this
    /// folder so every path row can carry it for capability computation.
    ///
    /// The discovery row written by `listItems` uses ``VirtualIDs/itemID`` as its
    /// itemID and stores the actual item GUID as `path`. An empty string means
    /// "unknown / not yet enumerated" and is treated as read-only by
    /// `computeCapabilities`.
    private func resolveFolderItemType(key: CacheKey) async -> String {
        let itemTypeKey = CacheKey(
            accountAlias: key.accountAlias,
            workspaceID: key.workspaceID,
            itemID: VirtualIDs.itemID,
            path: key.itemID
        )
        return (try? await cache.fetch(key: itemTypeKey))?.itemType ?? ""
    }

    /// Phase 4 of ``refreshFolder(key:)``: keeps each directory child's #380
    /// skip-gate token (`subtree_etag`) current WITHOUT bumping `synced_at_ns`.
    ///
    /// A dir child that exists but was not re-upserted (the common case —
    /// `entryChanged` ignores directory etag per #379) would otherwise freeze its
    /// `subtree_etag` at first-sight, so the skip-gate would never see the token
    /// advance. Rows already in `upsertBatch` carry the fresh value, so they are
    /// skipped; only rows whose harvested etag actually differs from the cached
    /// value are stamped via the targeted
    /// ``CacheStore/updateSubtreeEtag(key:etag:)``, which never touches
    /// `synced_at_ns` (pinned by the "writing subtreeEtag produces zero
    /// working-set delta" test).
    private func harvestSubtreeEtags(
        key: CacheKey,
        remoteChildren: [String: PathEntry],
        cachedByPath: [String: MetadataRecord],
        upsertBatch: [MetadataRecord]
    ) async {
        let upsertedPaths = Set(upsertBatch.map(\.path))
        for (relPath, entry) in remoteChildren where entry.isDirectory {
            guard !upsertedPaths.contains(relPath) else { continue }
            let cachedSubtreeEtag = cachedByPath[relPath]?.subtreeEtag ?? ""
            guard cachedSubtreeEtag != entry.eTag else { continue }
            let childKey = CacheKey(
                accountAlias: key.accountAlias,
                workspaceID: key.workspaceID,
                itemID: key.itemID,
                path: relPath
            )
            do {
                try await cache.updateSubtreeEtag(key: childKey, etag: entry.eTag)
            } catch {
                Self.log.warning("refreshFolder: updateSubtreeEtag failed err=\(error, privacy: .public)")
            }
        }
    }

    /// Phase 6 of ``refreshFolder(key:)``: writes the parent freshness-marker row,
    /// but only when something actually changed (or the row does not yet exist).
    ///
    /// An unconditional re-upsert on every poll bumps `synced_at_ns` even when
    /// `diff.total == 0`, which makes `itemsChangedAfter` return the parent row on
    /// every poll — producing phantom working-set deltas (fpe-18).
    ///
    /// Name for the item-root row (path == ""): `baseName("") == ""`, which would
    /// produce an empty-filename cache row — a landmine even though
    /// `DomainItem.from(record:)` now rejects it. Use the itemID as a
    /// non-displayable but non-empty sentinel instead. This row is an internal
    /// freshness marker, never emitted as a delta item (fpe-18).
    private func stampParentRow(
        key: CacheKey,
        diff: Diff,
        folderItemType: String,
        nowNs: Int64
    ) async {
        let existingParent = try? await cache.fetch(key: key)
        let needsWrite = existingParent == nil
            || diff.total > 0
            || existingParent?.childrenSyncedAtNs == 0
            || existingParent?.itemType != folderItemType
        guard needsWrite else { return }

        let parentName: String
        if let existing = existingParent, !existing.name.isEmpty {
            parentName = existing.name
        } else {
            let computed = Enumerator.baseName(key.path)
            parentName = computed.isEmpty ? key.itemID : computed
        }
        let existingParentLastAccessed = existingParent?.lastAccessedNs ?? nowNs
        let parent = MetadataRecord(
            accountAlias: key.accountAlias,
            workspaceID: key.workspaceID,
            itemID: key.itemID,
            path: key.path,
            parentPath: Enumerator.parentPath(key.path),
            name: parentName,
            isDir: true,
            lastAccessedNs: existingParentLastAccessed == 0 ? nowNs : existingParentLastAccessed,
            syncedAtNs: nowNs,
            childrenSyncedAtNs: nowNs,
            itemType: folderItemType,
            // Carry the container's own subtree etag (harvested by ITS parent
            // listing, #380) forward. A full re-upsert here must never reset it to
            // "" — that would erase the skip-gate token a parent wave just stamped
            // and make refreshMaterialized always re-list.
            subtreeEtag: existingParent?.subtreeEtag ?? ""
        )
        do { try await cache.upsert(parent) } catch {
            Self.log.warning("refreshFolder: upsert parent failed err=\(error, privacy: .public)")
        }
    }

    // MARK: - Materialized-set refresh

    /// Refreshes a single materialized container, bypassing the open-time
    /// revalidate debounce.
    ///
    /// Unlike ``enumerate(key:)``, which debounces background revalidates so
    /// that a burst of opens triggers at most one round-trip, this entry point
    /// always fetches from OneLake regardless of when the last revalidate ran.
    /// The poll cadence (driven by the host loop) is the throttle; the debounce
    /// window is not appropriate here.
    ///
    /// The pause/offline guards in ``refreshFolder(key:)`` are preserved: a
    /// paused workspace throws ``SyncError/workspacePaused`` and an offline
    /// `listPath` rethrows BEFORE the destructive reconcile, so the cache is
    /// never torn on a partial result.
    ///
    /// A workspace's item listing is materialized under the ``VirtualIDs/itemID``
    /// sentinel (``CacheReader/materializedContainers(alias:)`` maps a
    /// `.workspace` container to `CacheKey(ws, VirtualIDs.itemID, "")`). Its
    /// children are Fabric items, not DFS paths, so it is routed to the Fabric
    /// item-listing refresh instead of `refreshFolder`, which would call
    /// `onelake.listPath(itemGUID: "__items__")` — a guaranteed DFS error that
    /// the refresh wave would silently swallow, leaving new items in an open
    /// workspace invisible until re-navigation (F6/C16).
    ///
    /// - Returns: The ``Diff`` produced by the appropriate refresh path.
    public func refreshMaterializedContainer(key: CacheKey) async throws -> Diff {
        if key.itemID == VirtualIDs.itemID {
            return try await refreshItemListing(alias: key.accountAlias, workspaceID: key.workspaceID)
        }
        return try await refreshFolder(key: key)
    }

    /// Refreshes a set of materialized containers, parent-driven, with a
    /// subtree-etag skip-gate (#380) and a per-alias concurrency cap.
    ///
    /// ## Skip-gate (#380)
    ///
    /// Containers are processed in **depth-ordered waves** (parents before
    /// children) so that when a parent is listed it harvests each child
    /// container's directory etag (its subtree token) onto the child's cache row
    /// via ``refreshFolder(key:)``. A child whose harvested `subtreeEtag` is
    /// unchanged since the last poll has — by the ADLS Gen2 `2023-11-03`
    /// deep-advance invariant — no descendant change anywhere below it, so its
    /// own `listPath` is skipped entirely. This collapses steady-state cost from
    /// O(materialized containers) lists to O(containers whose subtree changed).
    ///
    /// CRITICAL ORDERING: the prior `subtreeEtag` of every key is snapshotted
    /// ONCE at the very start, BEFORE any wave lists. The parent wave overwrites
    /// each child's stored `subtreeEtag`, so the child wave compares its CURRENT
    /// (post-parent-stamp) value against that prior snapshot. Snapshotting
    /// per-wave-at-its-start would compare a value against itself and never skip.
    ///
    /// An orphan child (its parent is not in `keys`) is never stamped by a parent
    /// wave this pass, so it always lists — matching today's behaviour. Safe.
    ///
    /// ## Self-heal floor (#380)
    ///
    /// As insurance against the empirical deep-advance invariant, each container
    /// is forced through a non-gated full re-list at least every
    /// `selfHealIntervalMinutes`. `0` disables the floor (always honour the
    /// skip-gate). PR B wires the interval to a configurable advanced setting.
    ///
    /// Per-key errors (offline, cancellation, workspace paused) are non-fatal:
    /// silently swallowed, never aborting the remaining keys.
    ///
    /// - Parameters:
    ///   - alias: Account alias owning all `keys`; also the per-alias semaphore key.
    ///   - keys: Containers to refresh; no FileProvider types.
    ///   - concurrencyCap: Maximum concurrent ``refreshFolder(key:)`` calls within
    ///     a single depth wave for this alias. Stored per alias; ignored on
    ///     subsequent calls once the semaphore is created.
    ///   - selfHealIntervalMinutes: Forced non-gated re-list cadence per container.
    ///     `0` disables the floor. Defaults to ``defaultSelfHealIntervalMinutes``.
    /// - Returns: `true` iff at least one container produced `diff.total > 0`.
    public func refreshMaterialized(
        alias: String,
        keys: [CacheKey],
        concurrencyCap: Int,
        selfHealIntervalMinutes: Int = SyncEngine.defaultSelfHealIntervalMinutes
    ) async -> Bool {
        guard !keys.isEmpty else { return false }

        // Per-alias re-entrancy guard (#380). Two overlapping same-alias passes
        // would interleave across the suspension points below and break the "a
        // parent vouched THIS pass" invariant the skip-gate relies on. If a pass
        // is already in flight for this alias, return early — that pass already
        // covers this poll's freshness.
        guard !refreshInFlightAliases.contains(alias) else { return false }
        refreshInFlightAliases.insert(alias)
        defer { refreshInFlightAliases.remove(alias) }

        let semaphore = refreshSemaphore(for: alias, cap: concurrencyCap)

        // 0. ONE snapshot of every key's prior subtree etag, before anything
        // lists. The parent wave will overwrite a child's stored value, so this
        // is the only point at which the pre-pass value is observable. E2: a
        // single bulk read collapses what were N serialized `cache.fetch` reads
        // into one read transaction.
        let priorSubtreeEtag = (try? await cache.subtreeEtags(for: keys)) ?? [:]

        // 1. Depth-sort into waves so parents precede children. depth is the
        // number of path segments; the item-root container (path == "") is 0.
        let waves = Dictionary(grouping: keys, by: Self.containerDepth(of:))
            .sorted { $0.key < $1.key }
            .map(\.value)

        let nowNs = nowNsProvider()
        let selfHealNsThreshold: Int64 = selfHealIntervalMinutes > 0
            ? Int64(selfHealIntervalMinutes) * 60 * 1_000_000_000
            : 0

        // Accumulate per-task diff totals via an actor-isolated counter (the
        // DiffTotalCounter pattern sidesteps the Swift 6 "sending 'group'"
        // diagnostic — each child does a clean `await counter.add(n)` hop).
        let counter = DiffTotalCounter()

        // Per-pass vouching evidence (#380). A child may be SKIPPED only when its
        // parent genuinely vouches for the child's subtree token this pass — i.e.
        // the parent either listed SUCCESSFULLY (re-stamping the child) or was
        // itself SKIPPED (its own token unchanged ⇒ nothing changed anywhere below
        // ⇒ the child is unchanged too). A parent that THREW (offline / paused /
        // cancelled, swallowed in the wave task group) re-stamped nothing, so it
        // vouches for NOTHING and the child must attempt its own list. Because
        // waves are sequential — each wave's task group is fully awaited before the
        // next wave's decisions run — both sets are complete for the parent depth
        // before any child is evaluated.
        var listedOK: Set<String> = []
        var skipped: Set<String> = []

        // 2. Process waves sequentially (a parent wave must finish stamping before
        // its child wave reads the post-stamp value); within a wave the
        // refreshFolder calls run concurrently, semaphore-capped.
        for wave in waves {
            // E2: bulk-read this wave's CURRENT subtree etags — the
            // post-parent-stamp value — in one read transaction. Taken AFTER the
            // previous wave's task group has fully completed (waves are sequential)
            // and BEFORE this wave's skip decisions, so it observes a consistent
            // snapshot of the values the parent wave just stamped. It must be
            // per-wave, not one global pre-read: the parent wave overwrites these
            // rows, so a global pre-read would compare the child against its own
            // pre-pass value and never skip.
            //
            // Depth-0 containers (item roots, path == "") have no parent key, so
            // parentVouched is always false and shouldSkip can never fire for them
            // — the current etag is never consulted. Skip the read entirely for
            // that wave to avoid a wasted query.
            let waveIsRoot = wave.first.map { Self.containerDepth(of: $0) == 0 } ?? false
            let currentSubtreeEtag = waveIsRoot ? [:] : (try? await cache.subtreeEtags(for: wave)) ?? [:]

            // Compute each key's skip decision on the actor BEFORE spawning, so the
            // decision reads consistent actor state (lastSelfHealNs) and the
            // post-parent-stamp subtree etag. The set of keys actually needing a
            // list is then fanned out concurrently.
            var toList: [CacheKey] = []
            for key in wave {
                let keyString = key.stableKeyString

                // A parent vouches only if it actually re-stamped this child
                // (listed OK) or was itself skipped (subtree unchanged below).
                // Orphan (no parent key) or a parent that threw ⇒ not vouched.
                let parentVouched = Self.parentKeyString(of: key)
                    .map { listedOK.contains($0) || skipped.contains($0) } ?? false

                let healDue = Self.healDue(
                    nowNs: nowNs,
                    last: lastSelfHealNs[keyString],
                    thresholdNs: selfHealNsThreshold
                )

                if Self.shouldSkip(
                    parentVouched: parentVouched,
                    healDue: healDue,
                    prior: priorSubtreeEtag[keyString] ?? "",
                    current: currentSubtreeEtag[keyString] ?? ""
                ) {
                    // SKIP: subtree token unchanged and a parent vouched for it this
                    // pass → nothing changed below → no listPath. Record the skip so
                    // this key's own children may in turn be vouched.
                    skipped.insert(keyString)
                    continue
                }
                toList.append(key)
            }

            guard !toList.isEmpty else { continue }

            // Fan the wave out concurrently. Each task reports (keyString,
            // listedOK, diffTotal) so the outer loop can fold success into
            // `listedOK` and advance `lastSelfHealNs` ONLY on a real list (never on
            // a swallowed throw).
            let waveResults = await runWave(toList: toList, semaphore: semaphore)

            for (keyString, ok, total) in waveResults {
                guard ok else { continue }
                listedOK.insert(keyString)
                // Record the self-heal timestamp ONLY after a successful list, so a
                // container that was offline at list time stays heal-due next poll
                // instead of deferring the backstop a full interval.
                if selfHealNsThreshold > 0 {
                    lastSelfHealNs[keyString] = nowNs
                }
                if total > 0 {
                    await counter.add(total)
                }
            }
        }

        return await counter.total > 0
    }

    /// Number of path segments in a container key's path; the item-root
    /// container (path == "") is depth 0. Used to order ``refreshMaterialized``
    /// waves parent-before-child (#380).
    private static func containerDepth(of key: CacheKey) -> Int {
        key.path.isEmpty ? 0 : key.path.split(separator: "/").count
    }

    /// The ``CacheKey/stableKeyString`` of `key`'s parent container, or `nil`
    /// when `key` is an item-root container (path == "") and therefore has no
    /// in-domain parent container. Used by ``refreshMaterialized`` to decide
    /// whether a parent vouched for the child's subtree token this pass (#380).
    private static func parentKeyString(of key: CacheKey) -> String? {
        guard !key.path.isEmpty else { return nil }
        let parentKey = CacheKey(
            accountAlias: key.accountAlias,
            workspaceID: key.workspaceID,
            itemID: key.itemID,
            path: Enumerator.parentPath(key.path)
        )
        return parentKey.stableKeyString
    }

    /// Whether a materialized container's ``refreshFolder(key:)`` may be SKIPPED
    /// this pass (#380 skip-gate, pure).
    ///
    /// A container is skipped only when ALL hold: its self-heal floor is not due,
    /// its parent vouched for it this pass (`parentVouched`), and its subtree
    /// token is unchanged — a non-empty `current` equal to the pre-pass `prior`.
    /// An empty `current` (missing row or never-harvested token) is never
    /// "unchanged", so such a container always lists.
    static func shouldSkip(parentVouched: Bool, healDue: Bool, prior: String, current: String) -> Bool {
        let unchanged = !current.isEmpty && current == prior
        return !healDue && parentVouched && unchanged
    }

    /// Whether a container's non-gated self-heal full re-list is due (#380, pure).
    ///
    /// `thresholdNs == 0` disables the floor (never due). With the floor enabled,
    /// a container with no prior heal recorded (`last == nil`) is due on first
    /// sight so its token is seeded. Otherwise it is due once `thresholdNs` has
    /// elapsed since `last` — INCLUDING the monotonic-safe branch: a backward
    /// wall-clock step (NTP/manual) makes `nowNs <= last`, which fails TOWARD
    /// healing so a stuck/negative delta never silently disables the floor.
    static func healDue(nowNs: Int64, last: Int64?, thresholdNs: Int64) -> Bool {
        guard thresholdNs > 0 else { return false }
        guard let last else { return true }
        return nowNs <= last || nowNs - last >= thresholdNs
    }

    /// Runs one depth wave of ``refreshMaterialized(alias:keys:concurrencyCap:selfHealIntervalMinutes:)``:
    /// fans `toList` out concurrently (semaphore-capped) through
    /// ``refreshMaterializedContainer(key:)``, returning `(stableKeyString,
    /// listedOK, diffTotal)` per key.
    ///
    /// A per-task throw — offline, cancellation, workspace paused, or a cancelled
    /// semaphore wait — is non-fatal and reported as `listedOK == false` with a
    /// zero diff total: `refreshFolder` rethrows before its destructive reconcile,
    /// so the cache stays intact and the key vouches for nothing. The caller folds
    /// `listedOK` and advances `lastSelfHealNs` only for `listedOK == true` keys.
    ///
    /// The `withTaskGroup` element type is `(String, Bool, Int)` — all `Sendable`,
    /// with no actor-isolated mutable state crossing the group boundary — so this
    /// avoids the Swift 6 "sending 'group'" diagnostic that the diff-total
    /// accumulation sidesteps via ``DiffTotalCounter`` in the caller.
    private func runWave(toList: [CacheKey], semaphore: AsyncSemaphore) async -> [(String, Bool, Int)] {
        await withTaskGroup(of: (String, Bool, Int).self) { group -> [(String, Bool, Int)] in
            for key in toList {
                group.addTask {
                    let keyString = key.stableKeyString
                    do {
                        try await semaphore.wait()
                    } catch {
                        // Cancellation while waiting for a slot — non-fatal.
                        return (keyString, false, 0)
                    }
                    defer { semaphore.signal() }

                    let diff: Diff
                    do {
                        // Go through refreshMaterializedContainer — the documented
                        // single-container entry that bypasses the skip-gate. The
                        // gate has already decided this key needs a list; the
                        // container refresh just performs it.
                        diff = try await self.refreshMaterializedContainer(key: key)
                    } catch {
                        // Offline, cancellation, or workspace-paused: silent no-op.
                        // refreshFolder rethrows before its destructive reconcile,
                        // so the cache is intact — and this key vouches for nothing
                        // (listedOK == false).
                        return (keyString, false, 0)
                    }
                    return (keyString, true, diff.total)
                }
            }
            var results: [(String, Bool, Int)] = []
            for await r in group {
                results.append(r)
            }
            return results
        }
    }

    // MARK: - Open (download)

    /// Result of a successful ``open(key:)``: the servable file URL plus the
    /// metadata record describing exactly what it points to.
    /// Threaded through internally so ``openReturningRecord(key:)`` gets both
    /// from the single read/write pass ``open(key:)`` already performs,
    /// instead of the caller fetching the row again afterward.
    private typealias OpenResult = (url: URL, record: MetadataRecord)

    // periphery:ignore - only test callers remain; exclude_tests: true hides them from periphery
    /// Downloads a file, serving from the local blob cache when fresh.
    ///
    /// Returns a file URL rather than in-memory `Data` so the FPE can write
    /// directly to its staging destination without buffering the entire file.
    ///
    /// Concurrent calls for the same key are coalesced: the second caller
    /// awaits the first's in-flight task rather than issuing a duplicate
    /// download. The in-flight entry is removed when the task VALUE is delivered,
    /// not when the spawning frame unwinds, so late-joining callers always
    /// find a live entry (sync-24 fix).
    ///
    /// The blob cache is checked BEFORE acquiring a download semaphore slot, so
    /// cache hits never consume a slot.
    ///
    /// The sole production caller (`FileProviderExtension.fetchContents`) now
    /// uses ``openReturningRecord(key:)`` instead, so it also needs the served
    /// record; this URL-only entry point is kept as the minimal public API for
    /// any caller that only needs the file (matching `blobURL(key:)` /
    /// `handoffBlob(key:to:)` below) and is exercised extensively by the
    /// `open()` test suite.
    public func open(key: CacheKey) async throws -> URL {
        try await performOpen(key: key).url
    }

    /// Like ``open(key:)`` but also returns the ``MetadataRecord`` describing
    /// exactly what was served.
    ///
    /// Used by the FPE's `fetchContents`, which needs a version-accurate
    /// `NSFileProviderItem` for the SAME bytes it hands back: building that
    /// item from a fetch taken before `open()` ran left its `contentVersion`
    /// stale relative to a just-completed re-download, causing a redundant
    /// re-download the next cycle. Re-fetching after `open()` instead would
    /// fix the staleness but re-read the row a second time; returning the
    /// record `open()` already has in hand needs neither.
    public func openReturningRecord(key: CacheKey) async throws -> (url: URL, record: MetadataRecord) {
        try await performOpen(key: key)
    }

    private func performOpen(key: CacheKey) async throws -> OpenResult {
        let start = Date()
        try await pauseManager.guardPaused(workspaceID: key.workspaceID, alias: key.accountAlias)

        // Fetch the cached row (optional — a miss just means we download fresh).
        let cached = try? await cache.fetch(key: key)

        if let c = cached, !c.blobSHA256.isEmpty {
            // A row synced within blobFreshnessTTL is presumed fresh — it was
            // stamped either by this file's own last download/revalidate or
            // by a refreshFolder pass that observed a real change to it, so
            // re-validating with a getProperties HEAD on every single open
            // (Quick Look, a burst of re-opens) is a redundant round trip
            // that closely-spaced opens would otherwise all pay. Skip the
            // HEAD entirely inside the window; an unchanged row's syncedAtNs
            // is not refreshed by the poll (see defaultBlobFreshnessTTL), so
            // it still re-validates with a real HEAD roughly once per window.
            let rowAgeNs = currentNowNs() - c.syncedAtNs
            let ttlNs = Int64(blobFreshnessTTL.seconds * 1_000_000_000)
            if c.syncedAtNs > 0, rowAgeNs >= 0, rowAgeNs < ttlNs,
               let blobURL = await cache.blobURL(record: c)
            {
                do { try await cache.touch(key: key) } catch {
                    Self.log.warning("open: touch failed err=\(error, privacy: .public)")
                }
                await track(eventName: "file_download", alias: key.accountAlias, start: start, outcome: .success())
                return (blobURL, c)
            }

            // Outside the TTL, a known-offline engine skips the HEAD too:
            // issuing one would just block until the network timeout before
            // falling back to the same stale blob the catch-block offline
            // path below would serve anyway.
            if await offlineTracker.currentlyOffline(), let blobURL = await cache.blobURL(record: c) {
                logger.debug("offline; serving stale cached blob without a freshness HEAD", metadata: ["path": key.path])
                await track(eventName: "file_download", alias: key.accountAlias, start: start,
                            outcome: .successWithCode("served_stale_offline"))
                return (blobURL, c)
            }

            // Attempt to serve from blob cache — done BEFORE acquiring a slot
            // so cache hits do not consume download bandwidth.
            do {
                let (fresh, _) = try await isBlobFresh(key: key, cached: c)
                if fresh {
                    await offlineTracker.observe(nil)
                    if let blobURL = await cache.blobURL(record: c) {
                        do { try await cache.touch(key: key) } catch {
                            Self.log.warning("open: touch failed err=\(error, privacy: .public)")
                        }
                        await track(eventName: "file_download", alias: key.accountAlias, start: start, outcome: .success())
                        return (blobURL, c)
                    }
                }
                // Remote moved on — fall through to download.
            } catch {
                await offlineTracker.observe(error)
                // HEAD path through markPausedIfNeeded: a paused capacity signal
                // on the freshness check must mark the workspace paused.
                if await pauseManager.markPausedIfNeeded(
                    workspaceID: key.workspaceID, alias: key.accountAlias, error: error
                ) {
                    await track(eventName: "file_download", alias: key.accountAlias, start: start, outcome: .paused)
                    throw SyncError.workspacePaused
                }
                // Offline fallback: serve stale blob when the HEAD failed offline.
                if await offlineTracker.currentlyOffline(), let blobURL = await cache.blobURL(record: c) {
                    logger.debug("offline; serving stale cached blob", metadata: ["path": key.path])
                    await track(eventName: "file_download", alias: key.accountAlias, start: start,
                                outcome: .successWithCode("served_stale_offline"))
                    return (blobURL, c)
                }
                throw error
            }
        }

        // Coalesce concurrent opens for the same key.
        //
        // The coalescing entry is inserted BEFORE any await that could allow a
        // sibling call to reach this point concurrently. The entry is removed
        // after `task.value` resolves (inside the task itself, not in a defer on
        // the spawning frame) so late-arriving joiners always find a live entry
        // while the download is running (sync-04/sync-24 fix).
        //
        // Livelock guard: if the existing task was cancelled, `existing.value`
        // throws `CancellationError`. We remove the dead map entry and fall
        // through to spawn a fresh download (sync-03: the control-flow is now
        // explicit — only CancellationError continues, other errors would
        // rethrow from the `do` below and not reach the spawn path).
        let keyString = key.stableKeyString
        if let existing = inFlightDownloads[keyString] {
            do {
                return try await existing.value
            } catch is CancellationError {
                // The first task was cancelled — clear the stale entry and fall
                // through to spawn a fresh task for this caller. Propagate the
                // cancellation normally if *this* task is also cancelled.
                inFlightDownloads.removeValue(forKey: keyString)
                try Task.checkCancellation()
                // Fall through to spawn a fresh download below.
            }
            // For any other error the entry was already cleaned up by the task
            // itself; we reach here only via the CancellationError branch above.
        }

        let myGeneration: UInt64 = {
            let next = (downloadGenerations[keyString] ?? 0) + 1
            downloadGenerations[keyString] = next
            return next
        }()

        // Snapshot mutable state needed inside the unstructured task so it
        // doesn't capture `self` via actor isolation.
        let gen = myGeneration
        let task = Task<OpenResult, any Error> { [self] in
            defer {
                // Remove the map entry after the task value is delivered so
                // late-arriving joiners always find a live entry (sync-24 fix).
                // Called directly (not wrapped in a new Task) so cleanup runs
                // in the same actor turn as task completion — no ordering gap.
                self.cleanupInflight(keyString: keyString, generation: gen)
            }
            return try await self.performDownload(key: key, start: start, cached: cached)
        }
        inFlightDownloads[keyString] = task

        // Propagate cancellation to the unstructured download task so that if
        // the caller is cancelled while awaiting the result, the inner task
        // (which may be blocked inside onelake.read()) also gets cancelled.
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    // MARK: - Put (upload)

    /// Uploads the file at `sourceURL` to OneLake and mirrors it in the blob
    /// cache.
    ///
    /// macOS metadata files are silently swallowed (no telemetry, no upload).
    public func put(key: CacheKey, sourceURL: URL) async throws {
        if isMacOSMetadata(key.path) {
            logger.debug("ignoring macOS metadata upload", metadata: ["path": key.path])
            return
        }

        try await pauseManager.guardPaused(workspaceID: key.workspaceID, alias: key.accountAlias)
        try await acquireUploadSlot(alias: key.accountAlias)
        defer { releaseUploadSlot(alias: key.accountAlias) }

        let start = Date()
        // Determine size from the file on disk. Run off-actor to avoid blocking
        // the actor thread with synchronous FileManager calls (sync-14).
        let fileSize: Int64 = try await Task.detached(priority: .userInitiated) {
            let attrs = try FileManager.default.attributesOfItem(atPath: sourceURL.path)
            return (attrs[.size] as? NSNumber)?.int64Value ?? 0
        }.value

        do {
            try await onelake.write(
                alias: key.accountAlias,
                workspaceGUID: key.workspaceID,
                itemGUID: key.itemID,
                path: key.path,
                sourceURL: sourceURL,
                size: fileSize
            )
        } catch {
            try await withRemoteOperationError(
                error: error, key: key, eventName: "file_upload",
                failCode: "write_failed", start: start
            )
        }
        await offlineTracker.observe(nil)

        // Best-effort HEAD to capture the server-assigned etag/lastmod.
        // Log a warning on failure so the missing etag is visible rather than
        // silently leaving the row with etag="" (sync-12).
        let nowNs = currentNowNs()
        // Carry the item type from the existing cache row or the parent
        // directory row so that a freshly uploaded file under a Lakehouse
        // Files/ subtree keeps writable capabilities without waiting for the
        // next refreshFolder (fp-05).
        let cached = try? await cache.fetch(key: key)
        var existingItemType = cached?.itemType ?? ""
        if existingItemType.isEmpty {
            let parentKey = CacheKey(
                accountAlias: key.accountAlias, workspaceID: key.workspaceID,
                itemID: key.itemID, path: Enumerator.parentPath(key.path)
            )
            existingItemType = (try? await cache.fetch(key: parentKey))?.itemType ?? ""
        }
        var row = MetadataRecord(
            accountAlias: key.accountAlias,
            workspaceID: key.workspaceID,
            itemID: key.itemID,
            path: key.path,
            parentPath: Enumerator.parentPath(key.path),
            name: Enumerator.baseName(key.path),
            isDir: false,
            contentLength: fileSize,
            lastAccessedNs: nowNs,
            syncedAtNs: nowNs,
            itemType: existingItemType,
            // Carry forward a previously-captured creation time so a HEAD failure
            // after upload does not overwrite a good createdNs with 0 (symmetric
            // with the performDownload path that uses cached?.createdNs ?? 0).
            createdNs: cached?.createdNs ?? 0
        )
        do {
            let props = try await onelake.getProperties(
                alias: key.accountAlias,
                workspaceGUID: key.workspaceID,
                itemGUID: key.itemID,
                path: key.path
            )
            row.etag = props.eTag
            if props.contentLength != 0 { row.contentLength = props.contentLength }
            row.lastModifiedNs = dateToNs(props.lastModified) ?? 0
            row.contentType = props.contentType
            // Capture real creation time from the HEAD response when available.
            // The entryChanged createdNs guard will fire a metadata update so
            // Finder refreshes the displayed Date Created without a re-download.
            if let cd = props.creationDate { row.createdNs = dateToNs(cd) ?? cached?.createdNs ?? 0 }
        } catch {
            // sync-12: log HEAD failure so the empty-etag outcome is detectable.
            logger.warn("put: post-upload HEAD failed; row will have empty etag",
                        metadata: ["path": key.path, "error": "\(error)"])
        }

        // sync-29: treat the metadata upsert and blob store as a logical unit.
        // Both must succeed for the cache to be consistent. Surface any error
        // from either step rather than swallowing it independently.
        let rowCopy = row
        try await cache.upsert(rowCopy)
        // Mirror locally (best-effort after upsert: upload already succeeded).
        // storeBlobFromURL prefers an atomic moveItem (same-volume, zero-copy).
        // On FPE retry the source URL may be absent; log but don't fail.
        do {
            try await cache.storeBlobFromURL(sourceURL, key: key)
        } catch {
            logger.warn("put: storeBlobFromURL failed (blob cache inconsistent)",
                        metadata: ["path": key.path, "error": "\(error)"])
        }

        await track(TelemetryEvent(
            name: "file_upload",
            accountAliasHash: TelemetryRedaction.hashAlias(key.accountAlias),
            durationMs: elapsedMs(since: start),
            success: true,
            bytesTransferred: fileSize
        ))
    }

    // MARK: - Delete

    /// Removes a file or directory from OneLake and the local cache.
    ///
    /// macOS metadata files are dropped from the local cache only (no remote
    /// call, no telemetry).
    public func delete(key: CacheKey) async throws {
        let start = Date()

        // sync-05: surface cache read error — treating a DB failure as
        // `isDir = false` risks choosing non-recursive delete on a populated
        // directory, causing a 409. Log but continue with the safe assumption.
        let cached: MetadataRecord?
        do {
            cached = try await cache.fetch(key: key)
        } catch {
            Self.log.warning("delete: cache read failed, assuming isDir=false err=\(error, privacy: .public)")
            cached = nil
        }
        let isDir = cached?.isDir ?? false
        let eventName = isDir ? "folder_delete" : "file_delete"

        if isMacOSMetadata(key.path) {
            do { try await cache.delete(key: key) } catch {
                Self.log.warning("delete: macOS metadata cache delete failed err=\(error, privacy: .public)")
            }
            return
        }

        try await pauseManager.guardPaused(workspaceID: key.workspaceID, alias: key.accountAlias)

        // When cache has no row we cannot tell file from directory; ask DFS to
        // recurse to avoid 409 on a populated directory.
        let recursive = isDir || cached == nil

        do {
            try await onelake.delete(
                alias: key.accountAlias,
                workspaceGUID: key.workspaceID,
                itemGUID: key.itemID,
                path: key.path,
                recursive: recursive
            )
        } catch OneLakeError.notFound {
            // DELETE is in SessionPool's retryable HTTP methods, and the
            // `idempotent` flag Alamofire exposes is a documented no-op. If the
            // delete already committed server-side but its ack was lost, the
            // replayed DELETE 404s. The row is gone either way — that is the
            // goal of this call — so treat it as success rather than surfacing
            // `delete_failed`, mirroring the `destinationExists` guard for a
            // replayed rename PUT below.
            Self.log.info("delete: remote 404 — already gone, treating as success")
        } catch {
            try await withRemoteOperationError(
                error: error, key: key, eventName: eventName,
                failCode: "delete_failed", start: start
            )
        }
        await offlineTracker.observe(nil)

        do { try await cache.delete(key: key) } catch {
            Self.log.warning("delete: cache delete failed err=\(error, privacy: .public)")
        }

        await track(eventName: eventName, alias: key.accountAlias, start: start, outcome: .success())
    }

    // MARK: - Mkdir

    /// Creates a directory on OneLake and upserts the matching cache row.
    public func mkdir(key: CacheKey) async throws {
        let start = Date()
        try await pauseManager.guardPaused(workspaceID: key.workspaceID, alias: key.accountAlias)

        do {
            try await onelake.createDirectory(
                alias: key.accountAlias,
                workspaceGUID: key.workspaceID,
                itemGUID: key.itemID,
                path: key.path
            )
        } catch {
            try await withRemoteOperationError(
                error: error, key: key, eventName: "folder_create",
                failCode: "mkdir_failed", start: start
            )
        }
        await offlineTracker.observe(nil)

        let nowNs = currentNowNs()
        // Carry the item type from the parent directory row so that a newly
        // created folder under a Lakehouse Files/ subtree keeps writable
        // capabilities without waiting for the next refreshFolder (fp-05).
        let parentKeyMkdir = CacheKey(
            accountAlias: key.accountAlias, workspaceID: key.workspaceID,
            itemID: key.itemID, path: Enumerator.parentPath(key.path)
        )
        let mkdirItemType = (try? await cache.fetch(key: parentKeyMkdir))?.itemType ?? ""
        let row = MetadataRecord(
            accountAlias: key.accountAlias,
            workspaceID: key.workspaceID,
            itemID: key.itemID,
            path: key.path,
            parentPath: Enumerator.parentPath(key.path),
            name: Enumerator.baseName(key.path),
            isDir: true,
            lastAccessedNs: nowNs,
            syncedAtNs: nowNs,
            itemType: mkdirItemType
        )
        do { try await cache.upsert(row) } catch {
            Self.log.warning("mkdir: upsert failed err=\(error, privacy: .public)")
        }

        await track(eventName: "folder_create", alias: key.accountAlias, start: start, outcome: .success())
    }

    // MARK: - Rename

    /// Renames a file or directory within the same parent directory on OneLake
    /// and re-keys the matching cache row (and any cached descendants).
    ///
    /// Move/reparent (changing `.parentItemIdentifier`) is out of scope: only
    /// same-directory renames where the parent directory is unchanged are handled
    /// here. The caller is responsible for ensuring `newName` does not contain
    /// a path separator.
    ///
    /// - Parameters:
    ///   - key: The current ``CacheKey`` of the item to rename.
    ///   - newName: The new leaf name (final path segment, no `"/"`).
    /// - Returns: The updated ``MetadataRecord`` under the new path so the FPE
    ///   can build a fresh ``OfemFPEItem`` without an additional cache lookup.
    public func rename(key: CacheKey, newName: String) async throws -> MetadataRecord {
        let start = Date()
        try await pauseManager.guardPaused(workspaceID: key.workspaceID, alias: key.accountAlias)

        // Compute the destination path: same parent directory, new leaf name.
        let parentDir = Enumerator.parentPath(key.path)
        let destinationPath = parentDir.isEmpty ? newName : "\(parentDir)/\(newName)"

        do {
            try await onelake.rename(
                alias: key.accountAlias,
                workspaceGUID: key.workspaceID,
                itemGUID: key.itemID,
                sourcePath: key.path,
                destinationPath: destinationPath
            )
        } catch let error as OneLakeError {
            // Rename is non-idempotent, but the session retrier retries the PUT
            // on transient failures. If a retry runs after the rename already
            // committed server-side, the source path is gone → `notFound`,
            // surfaced as a spurious failure on an operation that succeeded.
            // Conservatively swallow `notFound` (and only `notFound`) when the
            // destination is now present, confirming the rename did commit, and
            // proceed to the cache re-key. Any other error propagates as before.
            if case .notFound = error,
               await destinationExists(
                   alias: key.accountAlias,
                   workspaceID: key.workspaceID,
                   itemID: key.itemID,
                   destinationPath: destinationPath
               )
            {
                Self.log.info("rename: source gone but destination present — treating retried rename as already committed")
            } else {
                try await withRemoteOperationError(
                    error: error, key: key, eventName: "item_rename",
                    failCode: "rename_failed", start: start
                )
            }
        } catch {
            try await withRemoteOperationError(
                error: error, key: key, eventName: "item_rename",
                failCode: "rename_failed", start: start
            )
        }
        await offlineTracker.observe(nil)

        // Read the existing row up front so we can both (a) carry forward fields
        // (created/modified dates, size, type) into the synthesised fallback and
        // (b) write a tombstone for the OLD identifier after the re-key succeeds.
        let existing = try? await cache.fetch(key: key)

        // Re-key the cache: update the exact row and all descendants atomically.
        // A cache failure must NOT be swallowed — reporting rename success while
        // the cache still holds the old key would make the old name reappear on
        // the next enumeration (cache/server divergence with no retry). Let it
        // propagate so the FPE leaves `.filename` pending and the framework
        // retries.
        let renamed = try await cache.renamePathPrefix(
            accountAlias: key.accountAlias,
            workspaceID: key.workspaceID,
            itemID: key.itemID,
            oldPath: key.path,
            newPath: destinationPath,
            newName: newName
        )

        // Tombstone the OLD identifier so other enumerators (working-set poll,
        // a re-opened materialized container) retire the row under the old name
        // via itemsChangedAfter → enumerateChanges → didDeleteItems, mirroring
        // `delete`. Written only after the new-path row is committed above.
        try? await cache.recordDeletion(
            accountAlias: key.accountAlias,
            identifierString: ItemIdentifier
                .path(workspaceID: key.workspaceID, itemID: key.itemID, path: key.path)
                .identifierString
        )

        // Prefer the row read back inside the rename transaction; fall back to a
        // synthesised record only when no row existed at the old path to rename.
        let updatedRecord: MetadataRecord
        if let renamed {
            updatedRecord = renamed
        } else {
            // Best-effort: build from the old key's cached data, carrying
            // created/modified dates forward so Finder does not regress to the
            // 1970 epoch (ab283ce).
            let nowNs = currentNowNs()
            updatedRecord = MetadataRecord(
                accountAlias: key.accountAlias,
                workspaceID: key.workspaceID,
                itemID: key.itemID,
                path: destinationPath,
                parentPath: parentDir,
                name: newName,
                isDir: existing?.isDir ?? false,
                contentLength: existing?.contentLength ?? 0,
                etag: existing?.etag ?? "",
                lastModifiedNs: existing?.lastModifiedNs ?? 0,
                contentType: existing?.contentType ?? "",
                lastAccessedNs: nowNs,
                syncedAtNs: nowNs,
                itemType: existing?.itemType ?? "",
                createdNs: existing?.createdNs ?? 0
            )
        }

        await track(eventName: "item_rename", alias: key.accountAlias, start: start, outcome: .success())
        return updatedRecord
    }

    /// Returns `true` when the rename destination is confirmed to exist, used to
    /// recognise an already-committed (retried) rename whose source has vanished.
    ///
    /// Checks the cache first (cheap, no network); only when the row is absent
    /// does it issue a single HEAD (`getProperties`). Any probe error is treated
    /// as "not present" so a transient network blip cannot make a genuinely
    /// failed rename look successful.
    private func destinationExists(
        alias: String,
        workspaceID: String,
        itemID: String,
        destinationPath: String
    ) async -> Bool {
        let newKey = CacheKey(
            accountAlias: alias,
            workspaceID: workspaceID,
            itemID: itemID,
            path: destinationPath
        )
        if (try? await cache.fetch(key: newKey)) != nil {
            return true
        }
        do {
            _ = try await onelake.getProperties(
                alias: alias,
                workspaceGUID: workspaceID,
                itemGUID: itemID,
                path: destinationPath
            )
            return true
        } catch {
            return false
        }
    }

    // MARK: - Offline status

    // periphery:ignore
    /// Returns `true` when the engine is currently considered offline (recently
    /// observed an offline-class error and the cooldown has not yet expired).
    ///
    /// Matches `OfflineTracker.currentlyOffline()` naming: two consecutive calls
    /// may return different values (the cooldown can expire between them).
    public var currentlyOffline: Bool {
        get async { await offlineTracker.currentlyOffline() }
    }

    // MARK: - Private: in-flight cleanup (sync-24)

    /// Removes the coalescing map entry for `keyString` if it still belongs to
    /// `generation`. Called from within the download task after it produces its
    /// value so late-arriving joiners always find a live entry.
    private func cleanupInflight(keyString: String, generation: UInt64) {
        if downloadGenerations[keyString] == generation {
            inFlightDownloads.removeValue(forKey: keyString)
            downloadGenerations.removeValue(forKey: keyString)
        }
    }

    // MARK: - Private: download implementation

    /// Executes the actual network download for `open()`.
    ///
    /// Acquires a semaphore slot, handles the 412-resume-discard-retry path
    /// (using ``ResumePlan`` for clean state representation), and returns a
    /// file URL alongside the metadata record just written for it. All
    /// blocking filesystem I/O runs off the actor via `Task.detached` (sync-14).
    private func performDownload(key: CacheKey, start: Date, cached: MetadataRecord?) async throws -> OpenResult {
        try await acquireDownloadSlot(alias: key.accountAlias)
        defer { releaseDownloadSlot(alias: key.accountAlias) }

        // Decide resume offset from the spill file / etag sidecar (sync-09:
        // ResumePlan captures all three correlated values atomically).
        let emptyRecord = MetadataRecord(
            accountAlias: key.accountAlias, workspaceID: key.workspaceID,
            itemID: key.itemID, path: key.path, parentPath: "",
            name: Enumerator.baseName(key.path), isDir: false
        )
        let plan = partials.rangeStart(for: key, cachedRecord: cached ?? emptyRecord)

        // Run all blocking spill-file I/O off the actor (sync-14).
        let spillURL = partials.partialURL(for: key)
        try await Task.detached(priority: .userInitiated) {
            try FileManager.default.createDirectory(
                at: spillURL.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            if !FileManager.default.fileExists(atPath: spillURL.path) {
                FileManager.default.createFile(atPath: spillURL.path, contents: nil)
            }
        }.value

        // Perform the download, handling 412 on the resume path.
        let props = try await performNetworkRead(
            key: key, spillURL: spillURL, plan: plan, start: start
        )
        await offlineTracker.observe(nil)

        // Cancellation checkpoint after the (potentially long) network read.
        try Task.checkCancellation()

        // Pin the partial etag when starting fresh (no existing partial).
        if !plan.hasPartial && !props.eTag.isEmpty {
            let etagToStore = props.eTag
            do { try partials.storeEtag(etagToStore, for: key) } catch {
                Self.log.warning("open: storeEtag failed err=\(error, privacy: .public)")
            }
        }

        // Compute total expected. `plan.rangeStart` (local spill file size) and
        // `props.contentLength` (remote `Content-Length` header) are both
        // untrusted inputs; a hostile or corrupted header near `Int64.max`
        // could overflow the plain `+` and trap. Use a reporting add so an
        // absurd combination surfaces as a handled error instead.
        var expectedTotal = cached?.contentLength ?? 0
        if props.contentLength > 0 {
            if plan.hasPartial {
                let (total, overflowed) = plan.rangeStart.addingReportingOverflow(props.contentLength)
                guard !overflowed else {
                    throw SyncError.resumeOffsetOverflow(
                        rangeStart: plan.rangeStart, contentLength: props.contentLength
                    )
                }
                expectedTotal = total
            } else {
                expectedTotal = props.contentLength
            }
        }

        // Determine spill file size and verify (off actor — sync-14).
        let spillSize: Int64 = try await Task.detached(priority: .userInitiated) {
            let attrs = try FileManager.default.attributesOfItem(atPath: spillURL.path)
            return (attrs[.size] as? NSNumber)?.int64Value ?? 0
        }.value

        if expectedTotal > 0, spillSize != expectedTotal {
            if spillSize > expectedTotal { partials.discard(for: key) }
            throw SyncError.shortDownload(expected: expectedTotal, got: spillSize)
        }

        // Cancellation checkpoint before the expensive SHA pass.
        try Task.checkCancellation()

        // SHA verification when an expected hash is known. Run off actor (sync-14).
        let expectedSHA = plan.hasPartial ? cached?.blobSHA256 : nil
        if let expected = expectedSHA, !expected.isEmpty {
            let got = try await Task.detached(priority: .userInitiated) {
                try self.partials.hashSpillFile(spillURL)
            }.value
            if got != expected {
                partials.discard(for: key)
                throw SyncError.blobSHAMismatch(got: got, expected: expected)
            }
        }

        // Cancellation checkpoint before cache writes.
        try Task.checkCancellation()

        // Upsert metadata row and blob store as a logical pair (sync-29).
        let nowNs = currentNowNs()
        // Carry the item type from the cached row (or the parent directory)
        // so that a downloaded file under a Lakehouse Files/ subtree keeps
        // writable capabilities without waiting for the next refreshFolder (fp-05).
        var downloadItemType = cached?.itemType ?? ""
        if downloadItemType.isEmpty {
            let parentKeyDl = CacheKey(
                accountAlias: key.accountAlias, workspaceID: key.workspaceID,
                itemID: key.itemID, path: Enumerator.parentPath(key.path)
            )
            downloadItemType = (try? await cache.fetch(key: parentKeyDl))?.itemType ?? ""
        }
        var row = MetadataRecord(
            accountAlias: key.accountAlias,
            workspaceID: key.workspaceID,
            itemID: key.itemID,
            path: key.path,
            parentPath: Enumerator.parentPath(key.path),
            name: Enumerator.baseName(key.path),
            isDir: false,
            contentLength: expectedTotal > 0 ? expectedTotal : spillSize,
            etag: props.eTag,
            lastModifiedNs: dateToNs(props.lastModified) ?? 0,
            contentType: props.contentType,
            lastAccessedNs: nowNs,
            syncedAtNs: nowNs,
            itemType: downloadItemType,
            // Capture real creation time from GET/HEAD response header. The
            // entryChanged createdNs guard triggers a metadata-only update so
            // Finder refreshes Date Created without forcing a re-download.
            createdNs: props.creationDate.flatMap { dateToNs($0) } ?? cached?.createdNs ?? 0
        )
        if row.name.isEmpty { row.name = Enumerator.baseName(key.path) }

        // sync-29: surface paired-write errors. If the upsert fails, don't
        // proceed to storeBlobFromURL — a blob with no linking row is an orphan.
        let downloadRow = row
        do {
            try await cache.upsert(downloadRow)
        } catch {
            Self.log.warning("open: upsert failed err=\(error, privacy: .public)")
            // Blob store skipped — row not present to link SHA.
            // Fall back to the spill file so the caller gets content even though
            // the cache is inconsistent.
            await track(eventName: "file_download", alias: key.accountAlias, start: start,
                        outcome: .success(bytes: spillSize))
            return (spillURL, downloadRow)
        }

        // Move/copy spill file into the blob cache. storeBlobFromURL returns
        // the sha256/size it just computed, so `row` can carry them without a
        // redundant re-fetch of the record we just upserted.
        do {
            let (sha, size) = try await cache.storeBlobFromURL(spillURL, key: key)
            row.blobSHA256 = sha
            row.blobSize = size
        } catch {
            Self.log.warning("open: storeBlobFromURL failed (blob cache inconsistent) err=\(error, privacy: .public)")
        }

        // Return the blob URL when available; fall back to the spill file when
        // the cache store failed.
        if let blobURL = await cache.blobURL(record: row) {
            await track(eventName: "file_download", alias: key.accountAlias, start: start,
                        outcome: .success(bytes: spillSize))
            return (blobURL, row)
        } else {
            logger.warn("open: blob cache unavailable; returning spill file URL",
                        metadata: ["path": key.path])
            await track(eventName: "file_download", alias: key.accountAlias, start: start,
                        outcome: .success(bytes: spillSize))
            return (spillURL, row)
        }
    }

    /// Issues the network read for a single download attempt. Handles the 412
    /// precondition-failed path by resetting to a full restart and retrying
    /// once (sync-02/sync-09/sync-23).
    ///
    /// All blocking FileHandle operations run off the actor via `Task.detached`
    /// (sync-14).
    private func performNetworkRead(
        key: CacheKey,
        spillURL: URL,
        plan: ResumePlan,
        start: Date
    ) async throws -> PathProperties {
        // Open the spill file, seek to the resume offset, and hold the handle
        // open for the streaming read. Single FD open per attempt — the handle
        // is passed directly to onelake.read() and closed exactly once on all
        // paths below (success, error, cancellation). Runs off-actor to avoid
        // blocking on FileHandle (sync-14).
        let readHandleResult: Result<FileHandle, any Error> = await Task.detached(priority: .userInitiated) {
            do {
                let h = try FileHandle(forUpdating: spillURL)
                try h.seek(toOffset: UInt64(plan.rangeStart))
                return .success(h)
            } catch {
                return .failure(SyncError.spillFileError(error))
            }
        }.value
        let spillHandle: FileHandle
        switch readHandleResult {
        case let .failure(err): throw err
        case let .success(h): spillHandle = h
        }

        do {
            let props = try await onelake.read(
                alias: key.accountAlias,
                workspaceGUID: key.workspaceID,
                itemGUID: key.itemID,
                path: key.path,
                range: plan.range,
                ifMatch: plan.ifMatch,
                destination: spillHandle
            )
            try? spillHandle.close()
            return props
        } catch {
            try? spillHandle.close()
            // 412 on resume: discard the stale partial and retry with a full
            // download (sync-09/23: ResumePlan.fullRestart captures the reset).
            if plan.hasPartial, case OneLakeError.preconditionFailed = error {
                logger.info("resume etag changed; discarding partial and restarting",
                            metadata: ["path": key.path])
                partials.discard(for: key)
                // Re-create the spill file from scratch (off actor).
                await Task.detached(priority: .userInitiated) {
                    try? FileManager.default.removeItem(at: spillURL)
                    FileManager.default.createFile(atPath: spillURL.path, contents: nil)
                }.value
                let freshHandleResult: Result<FileHandle, any Error> = await Task.detached(priority: .userInitiated) {
                    do {
                        return .success(try FileHandle(forUpdating: spillURL))
                    } catch {
                        return .failure(SyncError.spillFileError(error))
                    }
                }.value
                let freshHandle: FileHandle
                switch freshHandleResult {
                case let .failure(e): throw e
                case let .success(h): freshHandle = h
                }
                do {
                    let props = try await onelake.read(
                        alias: key.accountAlias,
                        workspaceGUID: key.workspaceID,
                        itemGUID: key.itemID,
                        path: key.path,
                        range: nil,
                        ifMatch: "",
                        destination: freshHandle
                    )
                    try? freshHandle.close()
                    return props
                } catch {
                    try? freshHandle.close()
                    // Discard spill before rethrowing so the next open() starts fresh.
                    partials.discard(for: key)
                    try await withRemoteOperationError(
                        error: error, key: key, eventName: "file_download",
                        failCode: "read_failed", start: start
                    )
                }
            } else {
                // Non-412 failure: discard any spill + etag sidecar before
                // rethrowing so the next open() re-downloads from scratch.
                partials.discard(for: key)
                try await withRemoteOperationError(
                    error: error, key: key, eventName: "file_download",
                    failCode: "read_failed", start: start
                )
            }
        }
    }

    // MARK: - Private helpers

    /// A present cached listing: the parent directory row plus its children.
    private struct CachedListing {
        // periphery:ignore - accessed via .isDir and Enumerator.childrenEnumerated in cachedListingIfPresent
        let parent: MetadataRecord
        let children: [MetadataRecord]
    }

    /// Returns the cached listing of `key` when present, or `nil` when the cache
    /// is cold (no parent row, or a parent row that has never had its children
    /// enumerated and currently has none).
    ///
    /// Presence — not freshness — gates the cache: a populated listing is always
    /// served, however old. Freshness is driven by the host poll loop via
    /// ``refreshMaterialized(alias:keys:concurrencyCap:)``. Throws
    /// ``FPError/wrongItemKind(_:)`` when `key` refers to a file.
    private func cachedListingIfPresent(key: CacheKey) async throws -> CachedListing? {
        guard let parent = try? await cache.fetch(key: key) else { return nil }
        guard parent.isDir else {
            throw FPError.wrongItemKind("\(key.path) is not a directory")
        }
        let children = try await cache.children(of: key)
        // A folder whose children have been enumerated at least once is "present"
        // even when genuinely empty — serve it (empty listing) rather than
        // blocking on a refresh every open.
        if children.isEmpty, !Enumerator.childrenEnumerated(record: parent) {
            return nil
        }
        return CachedListing(parent: parent, children: children)
    }

    private func isBlobFresh(key: CacheKey, cached: MetadataRecord) async throws -> (Bool, PathProperties?) {
        let props = try await onelake.getProperties(
            alias: key.accountAlias,
            workspaceGUID: key.workspaceID,
            itemGUID: key.itemID,
            path: key.path
        )
        if cached.etag.isEmpty { return (false, props) }
        if !props.eTag.isEmpty, props.eTag == cached.etag { return (true, props) }
        return (false, props)
    }

    /// Indexes cache rows by their `path` (the workspace/item GUID for discovery
    /// rows, or the relative path for folder children). Used to look up each
    /// freshly-listed candidate's prior state before deciding whether to upsert.
    private static func indexByPath(_ rows: [MetadataRecord]) -> [String: MetadataRecord] {
        var byPath: [String: MetadataRecord] = [:]
        byPath.reserveCapacity(rows.count)
        for r in rows {
            byPath[r.path] = r
        }
        return byPath
    }

    /// Classifies listing candidates against their cached counterparts, returning
    /// the conditional upsert batch plus the added/updated counts.
    ///
    /// Shared new-or-changed predicate for ``refreshFolder(key:)`` and the
    /// discovery/item-listing reconciles (#361/#379), so the rule lives in one
    /// place: a candidate is written back only when it is new (absent from
    /// `cachedByPath`) or ``Enumerator/entryChanged(current:next:)`` reports a
    /// real change. An unchanged candidate is left out entirely, so its cached
    /// row (and `syncedAtNs`) stays exactly as-is — bumping it on every poll
    /// would shift the working-set delta baseline forward and produce a phantom
    /// `didUpdate` for every unchanged entry.
    private static func classifyUpserts(
        candidates: [MetadataRecord],
        cachedByPath: [String: MetadataRecord]
    ) -> (batch: [MetadataRecord], added: Int, updated: Int) {
        var batch: [MetadataRecord] = []
        var added = 0
        var updated = 0
        for next in candidates {
            guard let cur = cachedByPath[next.path] else {
                added += 1
                batch.append(next)
                continue
            }
            if Enumerator.entryChanged(current: cur, next: next) {
                updated += 1
                batch.append(next)
            }
        }
        return (batch, added, updated)
    }

    /// Phase 3 of ``refreshFolder(key:)`` (pure): builds the conditional upsert
    /// batch for `remoteChildren`, returning it plus the added/updated counts.
    ///
    /// A candidate row is materialised for every remote child (carrying forward
    /// the cached blob linkage when the etag still matches, and the harvested
    /// directory subtree etag on directory children), then
    /// ``classifyUpserts(candidates:cachedByPath:)`` keeps only new
    /// (`cur == nil`) and actually-changed
    /// (``Enumerator/entryChanged(current:next:)``) rows. Unchanged rows are
    /// dropped so their `syncedAtNs` is not bumped — bumping it on every poll
    /// would shift the working-set delta baseline forward and produce a phantom
    /// `didUpdate` for every unchanged entry.
    ///
    /// Pure and side-effect free: the orchestrator performs the `batchUpsert`.
    static func buildUpsertBatch(
        key: CacheKey,
        remoteChildren: [String: PathEntry],
        cachedByPath: [String: MetadataRecord],
        folderItemType: String,
        nowNs: Int64
    ) -> (batch: [MetadataRecord], added: Int, updated: Int) {
        var candidates: [MetadataRecord] = []
        candidates.reserveCapacity(remoteChildren.count)

        // `dateToNs` is overloaded by return type: the file-private
        // `(Date?) -> Int64?` in this file (keeps `nil` for a nil / out-of-range
        // date) and the global `CacheModels.dateToNs` `(Date?) -> Int64` (folds
        // both to `0`). In this `static` context the bare name resolves to the
        // global — which would reset `createdNs` to `0` on every row instead of
        // carrying the cached value forward. DFS listings never return a
        // creationDate, so `entry.creationDate` is always `nil`; the global's
        // `nil -> 0` fold short-circuits the `?? cur?.createdNs` fallback and
        // silently drops the creation time captured earlier via HEAD/GET (#371).
        // Bind explicitly to the nil-preserving overload so that fallback keeps
        // working (this also drops the non-optional `?? 0` warning below).
        let toNs: (Date?) -> Int64? = dateToNs

        for (relPath, entry) in remoteChildren {
            let name = Enumerator.baseName(relPath)
            let cur = cachedByPath[relPath]
            var next = MetadataRecord(
                accountAlias: key.accountAlias,
                workspaceID: key.workspaceID,
                itemID: key.itemID,
                path: relPath,
                parentPath: key.path,
                name: name,
                isDir: entry.isDirectory,
                contentLength: entry.contentLength,
                etag: entry.eTag,
                lastModifiedNs: toNs(entry.lastModified) ?? 0,
                lastAccessedNs: cur?.lastAccessedNs ?? nowNs,
                syncedAtNs: nowNs,
                childrenSyncedAtNs: cur?.childrenSyncedAtNs ?? 0,
                itemType: folderItemType,
                createdNs: toNs(entry.creationDate) ?? cur?.createdNs ?? 0,
                // #380 skip-gate harvest: a directory child's etag is its subtree
                // token (advances on any descendant write). Stamp it on the child
                // container's own row so the next refreshMaterialized can compare
                // it. Files carry "". When this row IS rewritten (e.g. its
                // itemType changed) the freshest harvested value is persisted;
                // when it is NOT — the common case, since entryChanged ignores
                // directory etag (#379) — the targeted updateSubtreeEtag pass
                // after the batch keeps the token current without a synced_at_ns
                // bump.
                subtreeEtag: entry.isDirectory ? entry.eTag : ""
            )
            // Carry blob linkage forward when the etag still matches.
            if let c = cur, !c.etag.isEmpty, c.etag == entry.eTag {
                next.blobSHA256 = c.blobSHA256
                next.blobSize = c.blobSize
                next.contentType = c.contentType
            }
            if next.lastAccessedNs == 0 { next.lastAccessedNs = nowNs }
            candidates.append(next)
        }
        return classifyUpserts(candidates: candidates, cachedByPath: cachedByPath)
    }

    /// Phase 5 of ``refreshFolder(key:)`` (pure): returns the cache keys of
    /// children that disappeared remotely — every cached child whose path is
    /// absent from `remoteChildren`.
    ///
    /// CRITICAL INVARIANT: the reference set is `remoteChildren` (the full fresh
    /// listing), NEVER the upsert batch. A child skipped from the upsert batch
    /// because it is unchanged is still present remotely; deleting based on the
    /// batch would tombstone every unchanged file (the F1 mass-spurious-delete
    /// trap). Only genuinely vanished rows are returned here.
    ///
    /// Pure and side-effect free: the orchestrator performs the tombstoning
    /// `batchDelete`. `diff.removed` is the returned count.
    static func buildDeleteBatch(
        key: CacheKey,
        remoteChildren: [String: PathEntry],
        cachedByPath: [String: MetadataRecord]
    ) -> [CacheKey] {
        var deleteBatch: [CacheKey] = []
        for (relPath, _) in cachedByPath {
            guard remoteChildren[relPath] == nil else { continue }
            deleteBatch.append(CacheKey(
                accountAlias: key.accountAlias,
                workspaceID: key.workspaceID,
                itemID: key.itemID,
                path: relPath
            ))
        }
        return deleteBatch
    }

    /// Deletes discovery `children` that are absent from `seen`, returning the
    /// number expired.
    ///
    /// Uses the authoritative `seen` set from the current listing: any cached
    /// child not in `seen` was not returned by the remote and should be expired,
    /// regardless of its `syncedAt` timestamp (sync-25 fix: removes the
    /// time-window guard that coupled folder-content TTL with discovery expiry).
    ///
    /// `children` are the rows the caller already fetched for the classification
    /// step, threaded through here to avoid a second `cache.children` query per
    /// discovery pass. Every row genuinely exists in the cache, so each key built
    /// here targets a present row that gets deleted.
    ///
    /// Evicted rows surface to Finder via two paths depending on whether the
    /// container is materialized:
    /// - **Materialized** (in the working-set): the poll loop re-pulls it on
    ///   its next tick, finds a delta, and signals `.workingSet`.
    /// - **Non-materialized**: it is re-listed fresh on the next enumeration
    ///   open (cold-cache path in ``enumerate(key:)``).
    ///
    /// (The former per-container `signalEnumerator(for:)` call was removed in
    /// #344 — it is a no-op on a replicated `NSFileProviderReplicatedExtension`.)
    @discardableResult
    private func expireDiscoveryRows(
        children: [MetadataRecord],
        seen: Set<String>,
        alias: String
    ) async -> Int {
        let deleteBatch = children
            .filter { !seen.contains($0.path) }
            .map { k in
                CacheKey(
                    accountAlias: alias,
                    workspaceID: k.workspaceID,
                    itemID: k.itemID,
                    path: k.path
                )
            }
        // Tombstone the expired discovery rows so a removed item disappears from
        // Finder incrementally. batchDelete's tombstoneIdentifierString translates
        // item-discovery rows (itemID == VirtualIDs.itemID) to their ".item"
        // identifier "<workspaceID>/<itemGUID>"; workspace-discovery rows
        // (workspaceID == VirtualIDs.workspaceID) map to nil and are never
        // tombstoned because the domain root's container deltas are remount-driven
        // via the ChangeWatcher (a root signal would force full re-enumeration).
        // NON-GOAL: this does not purge the orphaned path_metadata rows of a
        // removed item (the rows keyed by the real item GUID) — a pre-existing gap
        // tracked as a follow-up, not addressed here.
        await batchDelete(deleteBatch, recordTombstones: true, context: "expireDiscoveryRows")
        return deleteBatch.count
    }

    // MARK: - Shared remote-operation error handler

    /// Handles the common error path for remote operations: observes offline
    /// state, marks workspace paused when appropriate, emits a failure telemetry
    /// event, and always rethrows.
    private func withRemoteOperationError(
        error: any Error,
        key: CacheKey,
        eventName: String,
        failCode: String,
        start: Date
    ) async throws -> Never {
        await offlineTracker.observe(error)
        if await pauseManager.markPausedIfNeeded(
            workspaceID: key.workspaceID, alias: key.accountAlias, error: error
        ) {
            await track(eventName: eventName, alias: key.accountAlias, start: start, outcome: .paused)
            throw SyncError.workspacePaused
        }
        await track(eventName: eventName, alias: key.accountAlias, start: start, outcome: .failed(failCode))
        throw error
    }

    // MARK: - Batch cache helpers

    /// Upserts all records in one GRDB transaction.
    private func batchUpsert(_ records: [MetadataRecord], context: String) async {
        guard !records.isEmpty else { return }
        do {
            try await cache.batchUpsert(records)
        } catch {
            Self.log.warning("SyncEngine: batchUpsert failed context=\(context, privacy: .public) err=\(error, privacy: .public)")
        }
    }

    /// Deletes all keys in one GRDB transaction.
    ///
    /// `recordTombstones` is passed through to ``CacheStore/batchDelete(_:recordTombstones:)``:
    /// `true` for remote-reconcile deletes that Finder must see as removals,
    /// which is every call site in this engine.
    private func batchDelete(_ keys: [CacheKey], recordTombstones: Bool, context: String) async {
        guard !keys.isEmpty else { return }
        do {
            try await cache.batchDelete(keys, recordTombstones: recordTombstones)
        } catch {
            Self.log.warning("SyncEngine: batchDelete failed context=\(context, privacy: .public) err=\(error, privacy: .public)")
        }
    }

    // MARK: - Telemetry helpers (sync-06)

    /// Outcome descriptor for telemetry emission.
    private enum TrackOutcome {
        case success(bytes: Int64? = nil)
        case successWithCode(_ code: String)
        case failed(_ code: String)
        case paused
    }

    /// Emits a telemetry event with common fields pre-filled (sync-06: single
    /// helper replaces 15+ near-identical construction sites).
    private func track(
        eventName: String,
        alias: String,
        start: Date,
        outcome: TrackOutcome
    ) async {
        let aliasHash = TelemetryRedaction.hashAlias(alias)
        let ms = elapsedMs(since: start)
        let event = switch outcome {
        case let .success(bytes):
            // `bytesTransferred` defaults to 0 when `bytes` is nil, which means
            // "not applicable" (e.g. a cache-hit path that does no I/O). The field
            // is omitted from the AppInsights measurement map when it is 0, so a
            // nil result is correctly distinguishable from a genuine 0-byte transfer
            // at the analytics level (both emit no measurement, which is the desired
            // behaviour — a 0-byte file is a legitimate edge case but not worth
            // special-casing in the wire format).
            TelemetryEvent(
                name: eventName,
                accountAliasHash: aliasHash,
                durationMs: ms,
                success: true,
                bytesTransferred: bytes ?? 0
            )
        case let .successWithCode(code):
            TelemetryEvent(
                name: eventName,
                accountAliasHash: aliasHash,
                durationMs: ms,
                success: true,
                errorCode: code
            )
        case let .failed(code):
            TelemetryEvent(
                name: eventName,
                accountAliasHash: aliasHash,
                durationMs: ms,
                success: false,
                errorCode: code
            )
        case .paused:
            TelemetryEvent(
                name: eventName,
                accountAliasHash: aliasHash,
                durationMs: ms,
                success: false,
                errorCode: "capacity_paused"
            )
        }
        await track(event)
    }

    private func track(_ event: TelemetryEvent) async {
        await telemetry?.track(event)
    }

    // MARK: - Semaphore helpers (actor-isolated)

    private func acquireDownloadSlot(alias: String) async throws {
        let sem = downloadSemaphore(for: alias)
        try await sem.wait()
    }

    private func releaseDownloadSlot(alias: String) {
        downloadSemaphore(for: alias).signal()
    }

    private func acquireUploadSlot(alias: String) async throws {
        let sem = uploadSemaphore(for: alias)
        try await sem.wait()
    }

    private func releaseUploadSlot(alias: String) {
        uploadSemaphore(for: alias).signal()
    }

    private func downloadSemaphore(for alias: String) -> AsyncSemaphore {
        if let s = downloadSlots[alias] { return s }
        let s = AsyncSemaphore(value: maxDownloads)
        downloadSlots[alias] = s
        return s
    }

    private func uploadSemaphore(for alias: String) -> AsyncSemaphore {
        if let s = uploadSlots[alias] { return s }
        let s = AsyncSemaphore(value: maxUploads)
        uploadSlots[alias] = s
        return s
    }

    private func refreshSemaphore(for alias: String, cap: Int) -> AsyncSemaphore {
        if let s = refreshSlots[alias] { return s }
        let s = AsyncSemaphore(value: max(1, cap))
        refreshSlots[alias] = s
        return s
    }
}

// MARK: - DiffTotalCounter

/// An actor that accumulates a running total of ``Diff/total`` values from
/// the concurrent child tasks in
/// ``SyncEngine/refreshMaterialized(alias:keys:concurrencyCap:)``.
///
/// `withTaskGroup(of: Int.self)` trips a Swift 6 "sending 'group' risks
/// causing data races" error inside a `SyncEngine` actor method because child
/// closures capture actor-isolated `self` and the group is sent across
/// isolation boundaries. A dedicated counter actor avoids that: each child
/// calls `await counter.add(n)` — a clean actor hop with no shared mutable
/// state crossing isolation boundaries.
private actor DiffTotalCounter {
    private(set) var total: Int = 0

    func add(_ n: Int) {
        total += n
    }
}

// MARK: - Elapsed helper

/// Returns elapsed milliseconds since `start`, floored at 1 ms to avoid
/// reporting a sub-millisecond / zero duration in telemetry (the 1 ms floor
/// is intentional and documented here rather than as a magic literal — sync-07).
private let elapsedMsMinimum: Int64 = 1

private func elapsedMs(since start: Date) -> Int64 {
    let d = Int64(Date().timeIntervalSince(start) * 1000)
    return max(elapsedMsMinimum, d)
}

// MARK: - nowNs helper (sync-21)

/// Returns the current time as Unix nanoseconds, clamped to `Int64` range.
///
/// Replaces the six `dateToNs(Date())!` force-unwraps throughout `SyncEngine`.
/// `dateToNs` returns `nil` only for a `nil` input; passing `Date()` (never
/// nil) could only fail if the clock is radically wrong. Clamping to `0`
/// (the "unknown" sentinel) avoids both the force-unwrap and a crash (sync-21).
private func currentNowNs() -> Int64 {
    dateToNs(Date()) ?? 0
}

// MARK: - dateToNs (nonisolated helper)

/// Converts `date` to Unix nanoseconds, or `nil` if `date` is `nil` or out of
/// `Int64` range.
///
/// This mirrors `CacheModels.dateToNs` but keeps `nil` (rather than folding it
/// to `0`) so call sites can distinguish "no timestamp in this response" from
/// "timestamp is genuinely zero" and fall back to a cached value instead of
/// clobbering it — see the `createdNs` call sites above, which chain
/// `?? cached?.createdNs ?? 0`. That fallback chain is why this stays a
/// separate copy rather than routing through the canonical helper.
///
/// `Date.distantPast` has a `timeIntervalSince1970` of roughly `-6.2e10` which,
/// when multiplied by `1e9`, yields `-6.2e19` — below `Int64.min`. We return
/// `nil` in that case (and symmetrically near `Int64.max`) so callers never see
/// an overflowed value.
///
/// The upper-bound check must use `<`, not `<=`: `Double(Int64.max)` rounds
/// *up* to exactly `2^63` (one past `Int64.max`, since `Int64.max` itself isn't
/// exactly representable as a `Double`), so a date whose nanosecond value lands
/// on that rounded boundary would pass an `<=` guard and then trap in
/// `Int64(ns)`. Several call sites feed this remote, attacker-influenced
/// timestamps (DFS `lastModified` / `creationDate`), so the boundary matters.
private func dateToNs(_ date: Date?) -> Int64? {
    guard let d = date else { return nil }
    let ns = d.timeIntervalSince1970 * 1_000_000_000
    guard ns >= Double(Int64.min), ns < Double(Int64.max) else { return nil }
    return Int64(ns)
}
