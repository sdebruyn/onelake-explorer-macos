import Foundation
import CryptoKit
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

    /// Default debounce window for revalidate-on-open.
    ///
    /// After a folder is served from the cache, a background revalidate is
    /// scheduled unless one ran (or started) within this window. Listings are
    /// stale-while-revalidate: the cache is served instantly on every open and
    /// a fresh listing is fetched in the background, so this is a coalescing
    /// window (suppress a burst of opens into one DFS `listPath`), not a
    /// freshness TTL — the cache is never withheld because it is "too old".
    public static let defaultRevalidateDebounce: TimeInterval = 10  // 10 s

    /// Default per-account cap on concurrent downloads.
    public static let defaultMaxConcurrentDownloads = 8

    /// Default per-account cap on concurrent uploads.
    public static let defaultMaxConcurrentUploads = 4

    /// Default minimum gap between workspace-recovery probes (mirrors
    /// `PauseManager.defaultProbeInterval` so `SyncEngine.init` can expose it
    /// in a public default-argument without leaking the internal `PauseManager`
    /// type into the public API).
    public static let defaultPauseProbeInterval: Duration = .seconds(120)

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

    private let revalidateDebounce: TimeInterval
    private let pauseManager: PauseManager
    private let offlineTracker: OfflineTracker
    private let partials: PartialManager

    /// In-flight background revalidations keyed by ``CacheKey/stableKeyString``.
    ///
    /// A second open for the same container that arrives while a revalidate is
    /// running joins the existing task instead of spawning a second one. The
    /// task never throws (errors are handled inside it), so its value is the
    /// applied ``Diff`` — `Diff()` (total 0) for a no-op, cancelled, offline, or
    /// failed revalidate. The map entry is removed when the task value is
    /// delivered, not when the spawning frame unwinds, so late joiners always
    /// find a live entry (mirrors the in-flight download coalescing).
    private var inFlightRevalidations: [String: Task<Diff, Never>] = [:]

    /// Wall-clock instant of the last revalidate START per container key. Written
    /// synchronously in ``scheduleRevalidate(key:parent:)`` (no `await` between
    /// the debounce checks and the write) so a burst of opens within
    /// ``revalidateDebounce`` cannot each spawn a task. Pruned opportunistically
    /// of entries older than the debounce window so it does not grow unbounded
    /// with the number of distinct folders ever opened.
    private var lastRevalidateStarted: [String: Date] = [:]

    /// Set once the engine is shutting down. A late ``enumerate(key:)`` arriving
    /// while ``quiesceRevalidations()`` is draining the in-flight tasks must not
    /// re-spawn a revalidate that would write to the about-to-close cache.
    private var isShutdown = false

    /// Per-account semaphores for downloads, uploads, and materialized-set refreshes.
    ///
    /// Entries are allocated lazily on first use per alias. Growth is bounded
    /// by the number of distinct account aliases active in this process
    /// (typically 1-3) so the unbounded-map concern is negligible in practice.
    /// A future `forgetAccount(alias:)` hook can prune entries on sign-out
    /// (sync-16).
    private var downloadSlots: [String: AsyncSemaphore] = [:]
    private var uploadSlots:   [String: AsyncSemaphore] = [:]
    private var refreshSlots:  [String: AsyncSemaphore] = [:]
    private let maxDownloads: Int
    private let maxUploads:   Int

    /// In-flight download tasks keyed by ``CacheKey/stableKeyString``.
    ///
    /// A second `open()` for the same key awaits the first's task rather than
    /// spawning a duplicate download. The map entry is removed when the task
    /// VALUE is delivered (not when the spawning frame unwinds) so a second
    /// caller that arrives while the task is still running always finds the
    /// entry (sync-24 fix).
    private var inFlightDownloads: [String: Task<URL, any Error>] = [:]

    /// Generation counter per key — incremented each time a new download task is
    /// spawned for a key. Used to guard against a stale cleanup (from a previous,
    /// now-cancelled task) removing an entry that belongs to a newer task.
    private var downloadGenerations: [String: UInt64] = [:]

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
    /// - revalidateDebounce: Coalescing window for revalidate-on-open.
    /// - maxConcurrentDownloads: Per-account download cap.
    /// - maxConcurrentUploads: Per-account upload cap.
    /// - scratchBase: Directory for download spill files. Defaults to
    /// `<tmp>/ofem-download-partials/<pid>`.
    /// - pauseProbeInterval: Minimum gap between workspace-recovery probes.
    public init(
        cache: CacheStore,
        onelake: any OneLakeClientProtocol,
        fabric: any FabricClientProtocol,
        logger: OfemLogger = OfemLogger(),
        telemetry: TelemetryClient? = nil,
        revalidateDebounce: TimeInterval = SyncEngine.defaultRevalidateDebounce,
        maxConcurrentDownloads: Int = SyncEngine.defaultMaxConcurrentDownloads,
        maxConcurrentUploads: Int = SyncEngine.defaultMaxConcurrentUploads,
        scratchBase: URL? = nil,
        pauseProbeInterval: Duration = SyncEngine.defaultPauseProbeInterval
    ) {
        self.cache = cache
        self.onelake = onelake
        self.fabric = fabric
        self.logger = logger
        self.telemetry = telemetry
        self.revalidateDebounce = max(0, revalidateDebounce)
        self.maxDownloads = max(1, maxConcurrentDownloads)
        self.maxUploads   = max(1, maxConcurrentUploads)

        // Scratch dir: per-process sub-directory.
        let base: URL
        if let sb = scratchBase {
            base = sb
        } else {
            base = URL(fileURLWithPath: NSTemporaryDirectory())
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

        self.pauseManager  = PauseManager(cache: cache, onelake: onelake, probeInterval: pauseProbeInterval)
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
        let rows = ws.map { w in
            MetadataRecord(
                accountAlias: alias,
                workspaceID: VirtualIDs.workspaceID,
                itemID: VirtualIDs.workspaceID,
                path: w.id,
                parentPath: "",
                name: w.displayName,
                isDir: true,
                lastAccessedNs: nowNs,
                syncedAtNs: nowNs
            )
        }
        await batchUpsert(rows, context: "listWorkspaces")
        // The parent of the workspaces listing is the domain root — root must
        // never be signalled (a root signal forces `.syncAnchorExpired` →
        // full re-enumeration). Root stays remount-driven via ChangeWatcher.
        // Container freshness for sub-containers is surfaced by the host
        // working-set poll loop rather than any per-container signal.
        await expireDiscoveryRows(parent: parentKey, seen: seen, alias: alias)

        await track(eventName: "workspace_list", alias: alias, start: start, outcome: .success())
        return ws
    }

    /// Returns all items inside `workspaceID`, reconciling the local cache.
    public func listItems(alias: String, workspaceID: String) async throws -> [Item] {
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
            Self.log.warning("listItems: upsert root failed err=\(error, privacy: .public)")
        }

        let seen = Set(storageItems.map(\.id))
        let rows = storageItems.map { it in
            MetadataRecord(
                accountAlias: alias,
                workspaceID: workspaceID,
                itemID: VirtualIDs.itemID,
                path: it.id,
                parentPath: "",
                name: it.displayName,
                isDir: true,
                lastAccessedNs: nowNs,
                syncedAtNs: nowNs,
                itemType: it.type
            )
        }
        await batchUpsert(rows, context: "listItems")
        await expireDiscoveryRows(parent: parentKey, seen: seen, alias: alias)

        await track(eventName: "item_list", alias: alias, start: start, outcome: .success())
        return storageItems
    }

    // MARK: - Enumerate

    /// Returns the children of the container identified by `key`.
    ///
    /// Stale-while-revalidate: when the cache already holds children for `key`,
    /// they are returned immediately AND a background ``refreshFolder(key:)`` is
    /// scheduled (debounced + coalesced — see ``scheduleRevalidate(key:parent:)``).
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
            scheduleRevalidate(key: key, parent: present.parent)
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
    public func refreshFolder(key: CacheKey) async throws -> Diff {
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

        let nowNs = currentNowNs()
        let now = Date()

        // Resolve the Fabric item type for this folder so every path row can
        // carry it for capability computation. The discovery row written by
        // listItems uses VirtualIDs.itemID as its itemID and stores the actual
        // item GUID as `path`. An empty string means "unknown / not yet
        // enumerated" and is treated as read-only by computeCapabilities.
        let itemTypeKey = CacheKey(
            accountAlias: key.accountAlias,
            workspaceID: key.workspaceID,
            itemID: VirtualIDs.itemID,
            path: key.itemID
        )
        let folderItemType = (try? await cache.fetch(key: itemTypeKey))?.itemType ?? ""

        // Build remote children set, filtering macOS metadata artefacts at emit
        // time so that remote .DS_Store / ._* files never appear in listings and
        // cannot resurrect after a local-only delete.
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

        // Load existing cached children (sync-05: surface the error — a failed
        // children read could lead to deleting all cached rows on the next
        // reconcile, which is worse than throwing here).
        let cachedChildren = try await cache.children(of: key)
        var cachedByPath: [String: MetadataRecord] = [:]
        for c in cachedChildren { cachedByPath[c.path] = c }

        var diff = Diff()

        // Build the upsert batch for remote children.
        var upsertBatch: [MetadataRecord] = []
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
                lastModifiedNs: dateToNs(entry.lastModified) ?? 0,
                lastAccessedNs: cur?.lastAccessedNs ?? nowNs,
                syncedAtNs: nowNs,
                childrenSyncedAtNs: cur?.childrenSyncedAtNs ?? 0,
                itemType: folderItemType
            )
            // Carry blob linkage when etag still matches.
            if let c = cur, !c.etag.isEmpty, c.etag == entry.eTag {
                next.blobSHA256 = c.blobSHA256
                next.blobSize   = c.blobSize
                next.contentType = c.contentType
            }
            if next.lastAccessedNs == 0 { next.lastAccessedNs = nowNs }

            if cur == nil {
                diff.added += 1
            } else if let c = cur, Enumerator.entryChanged(current: c, next: next) {
                diff.updated += 1
            }
            upsertBatch.append(next)
        }
        await batchUpsert(upsertBatch, context: "refreshFolder upsert")

        // Delete cached children that disappeared remotely in one batch.
        var deleteBatch: [CacheKey] = []
        for (relPath, _) in cachedByPath {
            guard remoteChildren[relPath] == nil else { continue }
            deleteBatch.append(CacheKey(
                accountAlias: key.accountAlias,
                workspaceID: key.workspaceID,
                itemID: key.itemID,
                path: relPath
            ))
            diff.removed += 1
        }
        await batchDelete(deleteBatch, context: "refreshFolder delete")

        // Stamp parent row.
        let existingParent = try? await cache.fetch(key: key)
        let existingParentLastAccessed = existingParent?.lastAccessedNs ?? nowNs
        let parent = MetadataRecord(
            accountAlias: key.accountAlias,
            workspaceID: key.workspaceID,
            itemID: key.itemID,
            path: key.path,
            parentPath: Enumerator.parentPath(key.path),
            name: Enumerator.baseName(key.path),
            isDir: true,
            lastAccessedNs: existingParentLastAccessed == 0 ? nowNs : existingParentLastAccessed,
            syncedAtNs: nowNs,
            childrenSyncedAtNs: nowNs,
            itemType: folderItemType
        )
        do { try await cache.upsert(parent) } catch {
            Self.log.warning("refreshFolder: upsert parent failed err=\(error, privacy: .public)")
        }

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
            ]
        )
        return diff
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
    /// - Returns: The ``Diff`` produced by ``refreshFolder(key:)``.
    public func refreshMaterializedContainer(key: CacheKey) async throws -> Diff {
        try await refreshFolder(key: key)
    }

    /// Refreshes a set of materialized containers with a per-alias concurrency cap.
    ///
    /// Fans out over `keys`, calling ``refreshMaterializedContainer(key:)`` for
    /// each with at most `concurrencyCap` concurrent DFS round-trips for `alias`.
    /// The cap is stored per alias (mirroring the `downloadSlots`/`uploadSlots`
    /// pattern) so concurrent calls for the same account share the same gate.
    ///
    /// Per-key errors (offline, cancellation, workspace paused) are treated as
    /// non-fatal: they are silently swallowed and do not abort the remaining
    /// keys. No failure telemetry is emitted for individual key failures here;
    /// the caller (host poll loop) owns the lifecycle.
    ///
    /// - Parameters:
    ///   - alias: Account alias owning all `keys`; also the per-alias semaphore key.
    ///   - keys: Containers to refresh; no FileProvider types.
    ///   - concurrencyCap: Maximum concurrent ``refreshMaterializedContainer(key:)``
    ///     calls for this alias. Ignored on subsequent calls once the semaphore is
    ///     created (the stored semaphore retains its original cap).
    /// - Returns: `true` iff at least one container produced `diff.total > 0`.
    public func refreshMaterialized(
        alias: String,
        keys: [CacheKey],
        concurrencyCap: Int
    ) async -> Bool {
        guard !keys.isEmpty else { return false }

        let semaphore = refreshSemaphore(for: alias, cap: concurrencyCap)

        // Accumulate per-task diff totals via an actor-isolated counter.
        //
        // Swift 6 strict-concurrency inside a `SyncEngine` actor method:
        // `withTaskGroup(of: Int.self)` trips "sending 'group' risks causing data
        // races" because child closures capture actor-isolated `self` and the
        // group itself is sent across isolation boundaries. The DiffTotalCounter
        // actor is the correct pattern here — each child task calls `await
        // counter.add(n)` which is a well-typed actor hop rather than a raw send.
        let counter = DiffTotalCounter()

        await withTaskGroup(of: Void.self) { group in
            for key in keys {
                group.addTask {
                    do {
                        try await semaphore.wait()
                    } catch {
                        // Cancellation while waiting for a slot — non-fatal.
                        return
                    }
                    defer { semaphore.signal() }

                    let diff: Diff
                    do {
                        diff = try await self.refreshMaterializedContainer(key: key)
                    } catch {
                        // Offline, cancellation, or workspace-paused: silent no-op.
                        // refreshFolder rethrows before its destructive reconcile, so
                        // the cache is intact.
                        return
                    }

                    if diff.total > 0 {
                        await counter.add(diff.total)
                    }
                }
            }
        }

        return await counter.total > 0
    }

    // MARK: - Open (download)

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
    public func open(key: CacheKey) async throws -> URL {
        let start = Date()
        try await pauseManager.guardPaused(workspaceID: key.workspaceID, alias: key.accountAlias)

        // Fetch the cached row (optional — a miss just means we download fresh).
        let cached = try? await cache.fetch(key: key)

        if let c = cached, !c.blobSHA256.isEmpty {
            // Attempt to serve from blob cache — done BEFORE acquiring a slot
            // so cache hits do not consume download bandwidth.
            do {
                let (fresh, _) = try await isBlobFresh(key: key, cached: c)
                if fresh {
                    await offlineTracker.observe(nil)
                    if let blobURL = try? await cache.blobURL(key: key) {
                        do { try await cache.touch(key: key) } catch {
                            Self.log.warning("open: touch failed err=\(error, privacy: .public)")
                        }
                        await track(eventName: "file_download", alias: key.accountAlias, start: start, outcome: .success())
                        return blobURL
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
                if await offlineTracker.currentlyOffline(), let blobURL = try? await cache.blobURL(key: key) {
                    logger.debug("offline; serving stale cached blob", metadata: ["path": key.path])
                    await track(eventName: "file_download", alias: key.accountAlias, start: start,
                                outcome: .successWithCode("served_stale_offline"))
                    return blobURL
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
        let task = Task<URL, any Error> { [self] in
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
        var existingItemType = (try? await cache.fetch(key: key))?.itemType ?? ""
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
            itemType: existingItemType
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

    // MARK: - Offline status

    /// Returns `true` when the engine is currently considered offline (recently
    /// observed an offline-class error and the cooldown has not yet expired).
    ///
    /// Matches `OfflineTracker.currentlyOffline()` naming: two consecutive calls
    /// may return different values (the cooldown can expire between them).
    public var currentlyOffline: Bool {
        get async { await offlineTracker.currentlyOffline() }
    }

    // MARK: - Revalidate observability (internal — tests / diagnostics)

    /// The in-flight background revalidation task for `key`, or `nil` when none
    /// is running. Lets a caller deterministically join a fire-and-forget
    /// revalidate (tests `await` its value to assert the applied ``Diff`` and the
    /// resulting cache state without polling).
    func revalidationTask(for key: CacheKey) -> Task<Diff, Never>? {
        inFlightRevalidations[key.stableKeyString]
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
    /// file URL. All blocking filesystem I/O runs off the actor via
    /// `Task.detached` (sync-14).
    private func performDownload(key: CacheKey, start: Date, cached: MetadataRecord?) async throws -> URL {
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

        // Compute total expected.
        var expectedTotal = cached?.contentLength ?? 0
        if props.contentLength > 0 {
            expectedTotal = plan.hasPartial
                ? plan.rangeStart + props.contentLength
                : props.contentLength
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
            itemType: downloadItemType
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
            return spillURL
        }

        // Move/copy spill file into the blob cache.
        do {
            try await cache.storeBlobFromURL(spillURL, key: key)
        } catch {
            Self.log.warning("open: storeBlobFromURL failed (blob cache inconsistent) err=\(error, privacy: .public)")
        }

        // Return the blob URL when available; fall back to the spill file when
        // the cache store failed.
        if let blobURL = try? await cache.blobURL(key: key) {
            await track(eventName: "file_download", alias: key.accountAlias, start: start,
                        outcome: .success(bytes: spillSize))
            return blobURL
        } else {
            logger.warn("open: blob cache unavailable; returning spill file URL",
                        metadata: ["path": key.path])
            await track(eventName: "file_download", alias: key.accountAlias, start: start,
                        outcome: .success(bytes: spillSize))
            return spillURL
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
        case .failure(let err): throw err
        case .success(let h): spillHandle = h
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
                case .failure(let e): throw e
                case .success(let h): freshHandle = h
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
        let parent: MetadataRecord
        let children: [MetadataRecord]
    }

    /// Returns the cached listing of `key` when present, or `nil` when the cache
    /// is cold (no parent row, or a parent row that has never had its children
    /// enumerated and currently has none).
    ///
    /// Presence — not freshness — gates the cache: a populated listing is always
    /// served, however old, and revalidated in the background. Throws
    /// ``FPError/wrongItemKind(_:)`` when `key` refers to a file.
    private func cachedListingIfPresent(key: CacheKey) async throws -> CachedListing? {
        guard let parent = try? await cache.fetch(key: key) else { return nil }
        guard parent.isDir else {
            throw FPError.wrongItemKind("\(key.path) is not a directory")
        }
        let children = try await cache.children(of: key)
        // A folder whose children have been enumerated at least once is "present"
        // even when genuinely empty — serve it (empty listing) and revalidate in
        // the background rather than blocking on a refresh every open.
        if children.isEmpty && !Enumerator.childrenEnumerated(record: parent) {
            return nil
        }
        return CachedListing(parent: parent, children: children)
    }

    // MARK: - Background revalidate (stale-while-revalidate)

    /// Schedules a debounced, coalesced background ``refreshFolder(key:)`` for
    /// `key` after the cache has already been served.
    ///
    /// Debounce + coalescing rules (all synchronous — no `await`, so there is no
    /// suspension point at which a sibling open could double-spawn):
    /// - If the engine is shutting down, skip (no new writes to a closing cache).
    /// - If one is already in flight for this key, skip (the running task will
    ///   apply the latest remote state and fire the change handler).
    /// - If the cache row was reconciled within ``revalidateDebounce`` (its
    ///   `childrenSyncedAt`, via ``Enumerator/isFresh(record:ttl:now:)``), skip —
    ///   a fresh-enough listing does not warrant another round-trip.
    /// - If a revalidate started within ``revalidateDebounce`` of now (process
    ///   stamp), skip — coalesces a burst of opens before the first refresh has
    ///   written `childrenSyncedAt` back to the cache.
    /// - Otherwise record the start stamp and insert the in-flight task.
    ///
    /// The task is fire-and-forget: `enumerate` never awaits it. All errors
    /// (offline, cancellation, list failure) are absorbed inside the task as
    /// silent no-ops that leave the cache intact (``refreshFolder`` rethrows
    /// before its destructive reconcile, so a failed fetch deletes nothing).
    private func scheduleRevalidate(key: CacheKey, parent: MetadataRecord) {
        // After shutdown started, never spawn a task that would write to the
        // about-to-close cache (a late enumerate must not re-arm a revalidate).
        if isShutdown { return }

        let keyString = key.stableKeyString

        // Already running for this key → the in-flight task covers this open.
        if inFlightRevalidations[keyString] != nil { return }

        let now = Date()

        // Cache row reconciled within the debounce window → already fresh enough.
        if Enumerator.isFresh(record: parent, ttl: revalidateDebounce, now: now) {
            return
        }

        // A revalidate started within the debounce window → coalesce this open.
        // (Covers the gap before the first refresh writes childrenSyncedAt back.)
        if let last = lastRevalidateStarted[keyString],
           now.timeIntervalSince(last) <= revalidateDebounce {
            return
        }

        // Drop stamps older than the debounce window so the map stays bounded by
        // the number of folders opened within one window, not all folders ever
        // opened. The just-set stamp below survives (it is younger than now).
        pruneStaleRevalidateStamps(now: now)

        // Record the start stamp + in-flight entry synchronously so a burst of
        // opens (which run serially on the actor with no await between the
        // checks above and here) cannot each pass the debounce check.
        lastRevalidateStarted[keyString] = now

        let task = Task<Diff, Never> { [self] in
            await self.runRevalidate(key: key, keyString: keyString)
        }
        inFlightRevalidations[keyString] = task
    }

    /// Evicts `lastRevalidateStarted` entries older than ``revalidateDebounce``.
    ///
    /// An evicted stamp can no longer suppress a revalidate (its window has
    /// elapsed), so dropping it changes nothing about debounce semantics while
    /// bounding the map to folders touched within the current window.
    private func pruneStaleRevalidateStamps(now: Date) {
        lastRevalidateStarted = lastRevalidateStarted.filter {
            now.timeIntervalSince($0.value) <= revalidateDebounce
        }
    }

    /// Body of a single background revalidate. Never throws: offline and
    /// live-fetch failures are silent no-ops that return `Diff()`.
    ///
    /// Shutdown does not cancel this task (see ``quiesceRevalidations()``): once
    /// started it runs to a consistent end, so a reconcile that has passed
    /// `listPath` always completes its write rather than tearing it mid-flight.
    private func runRevalidate(key: CacheKey, keyString: String) async -> Diff {
        // Remove the in-flight entry once the value is produced so late joiners
        // always found a live entry while the task was running, and a future
        // open can spawn a fresh revalidate.
        defer { inFlightRevalidations.removeValue(forKey: keyString) }

        let diff: Diff
        do {
            diff = try await refreshFolder(key: key)
        } catch is CancellationError {
            // Defensive: a stray cancellation is a silent no-op (no failure
            // telemetry). Shutdown does not cancel, so this is not the normal path.
            return Diff()
        } catch {
            // Offline or any live-fetch failure: refreshFolder already observed
            // offline state and rethrew BEFORE its destructive reconcile, so the
            // cache is intact. Stay silent (this is a background refresh — the
            // cache was already served to the caller); no failure telemetry.
            return Diff()
        }

        return diff
    }

    /// Quiesces background revalidation for shutdown: blocks new revalidates and
    /// waits for the in-flight ones to finish before returning.
    ///
    /// The contract is *complete, don't abort*. A revalidate that has passed
    /// `listPath` is committed to writing; its reconcile (`batchUpsert` /
    /// `batchDelete` → GRDB `dbPool.write`) honours `Task.isCancelled` and would
    /// throw mid-write if cancelled, leaving a torn/no-op write. So this does NOT
    /// cancel the tasks — it sets `isShutdown` (so no NEW revalidate spawns, even
    /// from a late ``enumerate(key:)`` arriving during the drain) and then
    /// `await`s each in-flight task to completion, draining a consistent write.
    /// GRDB's pool is closed on dealloc only after this returns, so no write
    /// outlives shutdown.
    ///
    /// A still-running `listPath` bounds the wait: the HTTP client uses a finite
    /// per-request timeout, so a genuinely stuck call returns or throws (the task
    /// then completes via the offline/failed no-op path) rather than hanging
    /// shutdown indefinitely.
    func quiesceRevalidations() async {
        isShutdown = true
        lastRevalidateStarted.removeAll()
        // Snapshot the tasks: each task's own defer prunes inFlightRevalidations
        // as it finishes, so iterate a copy rather than the live map.
        let tasks = Array(inFlightRevalidations.values)
        // Await all in-flight tasks concurrently: all group children suspend
        // simultaneously, so the drain is bounded by a single worst-case timeout
        // regardless of how many revalidations are in flight.
        await withDiscardingTaskGroup { group in
            for task in tasks {
                group.addTask { _ = await task.value }
            }
        }
    }

    private func isBlobFresh(key: CacheKey, cached: MetadataRecord) async throws -> (Bool, PathProperties?) {
        let props = try await onelake.getProperties(
            alias: key.accountAlias,
            workspaceGUID: key.workspaceID,
            itemGUID: key.itemID,
            path: key.path
        )
        if cached.etag.isEmpty { return (false, props) }
        if !props.eTag.isEmpty && props.eTag == cached.etag { return (true, props) }
        return (false, props)
    }

    /// Deletes discovery rows for `parent` that are absent from `seen`, and
    /// returns how many rows were expired.
    ///
    /// Uses the authoritative `seen` set from the current listing: any row
    /// not in `seen` was not returned by the remote and should be expired,
    /// regardless of its `syncedAt` timestamp (sync-25 fix: removes the
    /// time-window guard that coupled folder-content TTL with discovery expiry).
    ///
    /// The count lets callers decide whether something actually changed; the
    /// next working-set poll will re-pull the container so the cleared item
    /// (e.g. a now-filtered SQLEndpoint surfacing as `<name> 2`) leaves Finder.
    @discardableResult
    private func expireDiscoveryRows(parent: CacheKey, seen: Set<String>, alias: String) async -> Int {
        guard let kids = try? await cache.children(of: parent) else {
            Self.log.warning("expireDiscoveryRows: cache.children failed, stale rows may persist")
            return 0
        }
        // `kids` are rows that currently EXIST in the cache (from
        // cache.children), so every key built here targets a present row that
        // gets deleted. The count therefore equals the real number of evictions
        // — it is not inflated by already-absent rows. The next working-set
        // poll will re-pull the affected container so the cleared rows leave
        // Finder without any per-container signal.
        let deleteBatch = kids
            .filter { !seen.contains($0.path) }
            .map { k in
                CacheKey(
                    accountAlias: alias,
                    workspaceID: k.workspaceID,
                    itemID: k.itemID,
                    path: k.path
                )
            }
        await batchDelete(deleteBatch, context: "expireDiscoveryRows")
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
    private func batchDelete(_ keys: [CacheKey], context: String) async {
        guard !keys.isEmpty else { return }
        do {
            try await cache.batchDelete(keys)
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
        let event: TelemetryEvent
        switch outcome {
        case .success(let bytes):
            // `bytesTransferred` defaults to 0 when `bytes` is nil, which means
            // "not applicable" (e.g. a cache-hit path that does no I/O). The field
            // is omitted from the AppInsights measurement map when it is 0, so a
            // nil result is correctly distinguishable from a genuine 0-byte transfer
            // at the analytics level (both emit no measurement, which is the desired
            // behaviour — a 0-byte file is a legitimate edge case but not worth
            // special-casing in the wire format).
            event = TelemetryEvent(
                name: eventName,
                accountAliasHash: aliasHash,
                durationMs: ms,
                success: true,
                bytesTransferred: bytes ?? 0
            )
        case .successWithCode(let code):
            event = TelemetryEvent(
                name: eventName,
                accountAliasHash: aliasHash,
                durationMs: ms,
                success: true,
                errorCode: code
            )
        case .failed(let code):
            event = TelemetryEvent(
                name: eventName,
                accountAliasHash: aliasHash,
                durationMs: ms,
                success: false,
                errorCode: code
            )
        case .paused:
            event = TelemetryEvent(
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

/// Converts `date` to Unix nanoseconds clamped to `Int64` range.
///
/// `Date.distantPast` has a `timeIntervalSince1970` of roughly `-6.2e10` which,
/// when multiplied by `1e9`, yields `-6.2e19` — below `Int64.min`. We clamp to
/// zero (i.e. "unknown") in that case so callers can treat zero as "no timestamp".
private func dateToNs(_ date: Date?) -> Int64? {
    guard let d = date else { return nil }
    let ns = d.timeIntervalSince1970 * 1_000_000_000
    guard ns >= Double(Int64.min), ns <= Double(Int64.max) else { return 0 }
    return Int64(ns)
}
