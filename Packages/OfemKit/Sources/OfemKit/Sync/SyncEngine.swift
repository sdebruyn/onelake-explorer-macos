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
/// - Concurrency caps are enforced per account alias via `AsyncSemaphore`.
/// - Last-write-wins semantics: `put` and `delete` never use `If-Match` for
/// writes. This matches the agreed conflict policy in `docs/auth.md`.
public actor SyncEngine {

    // MARK: - Configuration

    /// Default refresh interval for recently-visited folders.
    public static let defaultRecentFolderTTL: TimeInterval = 5 * 60  // 5 min

    /// Default per-account cap on concurrent downloads.
    public static let defaultMaxConcurrentDownloads = 8

    /// Default per-account cap on concurrent uploads.
    public static let defaultMaxConcurrentUploads = 4

    // MARK: - Dependencies (nonisolated for injection without crossing actor boundary)

    nonisolated let cache: CacheStore
    nonisolated let onelake: any OneLakeClientProtocol
    nonisolated let fabric: any FabricClientProtocol

    private let logger: OfemLogger
    private let telemetry: TelemetryClient?

    // MARK: - Internal state

    private let recentFolderTTL: TimeInterval
    private let pauseManager: PauseManager
    private let offlineTracker: OfflineTracker
    private let partials: PartialManager

    /// Per-account semaphores for downloads and uploads.
    private var downloadSlots: [String: AsyncSemaphore] = [:]
    private var uploadSlots:   [String: AsyncSemaphore] = [:]
    private let maxDownloads: Int
    private let maxUploads:   Int

    /// In-flight download tasks keyed by CacheKey string representation.
    /// A second `open()` for the same key awaits the first's result rather than
    /// racing on the spill file (sync-06).
    private var inFlightDownloads: [String: Task<Data, any Error>] = [:]

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
    /// - recentFolderTTL: Freshness window for recently-visited folders.
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
        recentFolderTTL: TimeInterval = SyncEngine.defaultRecentFolderTTL,
        maxConcurrentDownloads: Int = SyncEngine.defaultMaxConcurrentDownloads,
        maxConcurrentUploads: Int = SyncEngine.defaultMaxConcurrentUploads,
        scratchBase: URL? = nil,
        pauseProbeInterval: Duration = PauseManager.defaultProbeInterval
    ) {
        self.cache = cache
        self.onelake = onelake
        self.fabric = fabric
        self.logger = logger
        self.telemetry = telemetry
        self.recentFolderTTL = max(1, recentFolderTTL)
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
        // FileManager traversal or kill(2) probes on the main thread (sync-21).
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
            // Route Fabric errors through markPausedIfNeeded so that a paused-
            // capacity response here also marks the workspace paused (sync-11).
            if await pauseManager.markPausedIfNeeded(
                workspaceID: VirtualIDs.workspaceID, alias: alias, error: error
            ) {
                await track(TelemetryEvent(
                    name: "workspace_list",
                    accountAliasHash: TelemetryRedaction.hashAlias(alias),
                    durationMs: elapsedMs(since: start),
                    success: false,
                    errorCode: "capacity_paused"
                ))
                throw SyncError.workspacePaused
            }
            await track(TelemetryEvent(
                name: "workspace_list",
                accountAliasHash: TelemetryRedaction.hashAlias(alias),
                durationMs: elapsedMs(since: start),
                success: false,
                errorCode: "list_failed"
            ))
            throw error
        }
        await offlineTracker.observe(nil)

        // Stamp virtual parent + one row per workspace.
        let now = Date()
        let nowNs = dateToNs(now)!
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
        await loggedTry({ try await self.cache.upsert(root) }, "listWorkspaces: upsert root")

        var seen: Set<String> = []
        var rows: [MetadataRecord] = []
        for w in ws {
            seen.insert(w.id)
            rows.append(MetadataRecord(
                accountAlias: alias,
                workspaceID: VirtualIDs.workspaceID,
                itemID: VirtualIDs.workspaceID,
                path: w.id,
                parentPath: "",
                name: w.displayName,
                isDir: true,
                lastAccessedNs: nowNs,
                syncedAtNs: nowNs
            ))
        }
        await batchUpsert(rows, context: "listWorkspaces")
        await expireDiscoveryRows(parent: parentKey, seen: seen, alias: alias, now: now)

        await track(TelemetryEvent(
            name: "workspace_list",
            accountAliasHash: TelemetryRedaction.hashAlias(alias),
            durationMs: elapsedMs(since: start),
            success: true
        ))
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
            // Route Fabric errors through markPausedIfNeeded (sync-11).
            if await pauseManager.markPausedIfNeeded(
                workspaceID: workspaceID, alias: alias, error: error
            ) {
                await track(TelemetryEvent(
                    name: "item_list",
                    accountAliasHash: TelemetryRedaction.hashAlias(alias),
                    durationMs: elapsedMs(since: start),
                    success: false,
                    errorCode: "capacity_paused"
                ))
                throw SyncError.workspacePaused
            }
            await track(TelemetryEvent(
                name: "item_list",
                accountAliasHash: TelemetryRedaction.hashAlias(alias),
                durationMs: elapsedMs(since: start),
                success: false,
                errorCode: "list_failed"
            ))
            throw error
        }
        await offlineTracker.observe(nil)

        let now = Date()
        let nowNs = dateToNs(now)!
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
        await loggedTry({ try await self.cache.upsert(root) }, "listItems: upsert root")

        var seen: Set<String> = []
        var rows: [MetadataRecord] = []
        for it in items {
            seen.insert(it.id)
            rows.append(MetadataRecord(
                accountAlias: alias,
                workspaceID: workspaceID,
                itemID: VirtualIDs.itemID,
                path: it.id,
                parentPath: "",
                name: it.displayName,
                isDir: true,
                lastAccessedNs: nowNs,
                syncedAtNs: nowNs
            ))
        }
        await batchUpsert(rows, context: "listItems")
        await expireDiscoveryRows(parent: parentKey, seen: seen, alias: alias, now: now)

        await track(TelemetryEvent(
            name: "item_list",
            accountAliasHash: TelemetryRedaction.hashAlias(alias),
            durationMs: elapsedMs(since: start),
            success: true
        ))
        return items
    }

    // MARK: - Enumerate

    /// Returns the children of the container identified by `key`.
    ///
    /// Uses the cache when the listing is within `recentFolderTTL`; otherwise
    /// calls ``refreshFolder(key:)`` first.
    ///
    /// Throws ``FPError/wrongItemKind(_:)`` when `key` refers to a file, not a
    /// directory. The error propagates rather than falling through to a remote
    /// refresh (sync-22).
    public func enumerate(key: CacheKey) async throws -> [MetadataRecord] {
        let start = Date()

        // Fast path: serve from cache when fresh.
        // `enumerateFromCache` throws `FPError.wrongItemKind` for files —
        // propagate that error directly instead of swallowing it (sync-22).
        let fastPathResult = try await enumerateFromCache(key: key)
        if let (fresh, cached) = fastPathResult, fresh {
            await track(TelemetryEvent(
                name: "folder_list",
                accountAliasHash: TelemetryRedaction.hashAlias(key.accountAlias),
                durationMs: elapsedMs(since: start),
                success: true
            ))
            return cached
        }

        // Slow path: refresh from remote.
        do {
            _ = try await refreshFolder(key: key)
        } catch {
            await track(TelemetryEvent(
                name: "folder_list",
                accountAliasHash: TelemetryRedaction.hashAlias(key.accountAlias),
                durationMs: elapsedMs(since: start),
                success: false,
                errorCode: "list_failed"
            ))
            throw error
        }
        let entries = try await cache.children(of: key)
        await track(TelemetryEvent(
            name: "folder_list",
            accountAliasHash: TelemetryRedaction.hashAlias(key.accountAlias),
            durationMs: elapsedMs(since: start),
            success: true
        ))
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

        let now = Date()
        let nowNs = dateToNs(now)!

        // Build remote children set, filtering macOS metadata artefacts at emit
        // time so that remote .DS_Store / ._* files never appear in listings and
        // cannot resurrect after a local-only delete (sync-14).
        var remoteChildren: [String: PathEntry] = [:]
        for entry in result.entries {
            guard let rel = Enumerator.stripItemPrefix(name: entry.name, itemGUID: key.itemID),
                  !rel.isEmpty,
                  Enumerator.isDirectChild(parent: key.path, child: rel),
                  !isMacOSMetadata(rel)
            else { continue }
            remoteChildren[rel] = entry
        }

        // Load existing cached children.
        let cachedChildren = (try? await cache.children(of: key)) ?? []
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
                childrenSyncedAtNs: cur?.childrenSyncedAtNs ?? 0
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

        // Delete cached children that disappeared remotely in one batch (sync-15).
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
        let existingParentLastAccessed = (try? await cache.fetch(key: key))?.lastAccessedNs ?? nowNs
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
            childrenSyncedAtNs: nowNs
        )
        await loggedTry({ try await self.cache.upsert(parent) }, "refreshFolder: upsert parent")

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
            ]
        )
        return diff
    }

    // MARK: - Open (download)

    /// Downloads a file, serving from the local blob cache when fresh.
    ///
    /// Concurrent calls for the same key are coalesced: the second caller
    /// awaits the first's in-flight task rather than issuing a duplicate
    /// download (sync-06).
    ///
    /// The blob cache is checked BEFORE acquiring a download semaphore slot, so
    /// cache hits never consume a slot (sync-19).
    public func open(key: CacheKey) async throws -> Data {
        let start = Date()
        try await pauseManager.guardPaused(workspaceID: key.workspaceID, alias: key.accountAlias)

        // Fetch the cached row (optional — a miss just means we download fresh).
        let cached = try? await cache.fetch(key: key)

        if let c = cached, !c.blobSHA256.isEmpty {
            // Attempt to serve from blob cache — done BEFORE acquiring a slot
            // so cache hits do not consume download bandwidth (sync-19).
            do {
                let (fresh, _) = try await isBlobFresh(key: key, cached: c)
                if fresh {
                    await offlineTracker.observe(nil)
                    if let data = try? await cache.loadBlob(key: key) {
                        await loggedTry({ try await self.cache.touch(key: key) }, "open: touch")
                        await track(TelemetryEvent(
                            name: "file_download",
                            accountAliasHash: TelemetryRedaction.hashAlias(key.accountAlias),
                            durationMs: elapsedMs(since: start),
                            success: true
                        ))
                        return data
                    }
                }
                // Remote moved on — fall through to download.
            } catch {
                await offlineTracker.observe(error)
                // HEAD path through markPausedIfNeeded (sync-11): a paused
                // capacity signal on the freshness check must mark the workspace
                // paused and throw workspacePaused, not a raw error.
                if await pauseManager.markPausedIfNeeded(
                    workspaceID: key.workspaceID, alias: key.accountAlias, error: error
                ) {
                    await track(TelemetryEvent(
                        name: "file_download",
                        accountAliasHash: TelemetryRedaction.hashAlias(key.accountAlias),
                        durationMs: elapsedMs(since: start),
                        success: false,
                        errorCode: "capacity_paused"
                    ))
                    throw SyncError.workspacePaused
                }
                // Offline fallback: serve stale bytes when the HEAD failed offline.
                if await offlineTracker.isOffline, let data = try? await cache.loadBlob(key: key) {
                    logger.debug("offline; serving stale cached blob", metadata: ["path": key.path])
                    await track(TelemetryEvent(
                        name: "file_download",
                        accountAliasHash: TelemetryRedaction.hashAlias(key.accountAlias),
                        durationMs: elapsedMs(since: start),
                        success: true,
                        errorCode: "served_stale_offline"
                    ))
                    return data
                }
                throw error
            }
        }

        // Coalesce concurrent opens for the same key (sync-06).
        //
        // Livelock guard: if the first task was cancelled, `existing.value`
        // throws `CancellationError`. We remove the dead map entry and spawn a
        // fresh download for this caller so the key is not permanently poisoned.
        // A generation token ensures the stale task's cleanup does not remove an
        // entry that belongs to the new task we are about to register.
        let keyString = "\(key.accountAlias)\0\(key.workspaceID)\0\(key.itemID)\0\(key.path)"
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
            // For any other error the entry was already cleaned up by the
            // spawning task's defer; re-throw directly.
            // (Swift does not reach here — the only non-CancellationError path
            // re-throws from the `do` block above.)
        }

        let myGeneration: UInt64 = {
            let next = (downloadGenerations[keyString] ?? 0) + 1
            downloadGenerations[keyString] = next
            return next
        }()

        let task = Task<Data, any Error> { [self] in
            try await self.performDownload(key: key, start: start, cached: cached)
        }
        inFlightDownloads[keyString] = task

        defer {
            // Only remove the entry when it still belongs to this generation,
            // so a stale cleanup from a cancelled task does not evict a newer
            // task registered for the same key.
            if downloadGenerations[keyString] == myGeneration {
                inFlightDownloads.removeValue(forKey: keyString)
                downloadGenerations.removeValue(forKey: keyString)
            }
        }
        return try await task.value
    }

    // MARK: - Put (upload)

    /// Uploads `content` to OneLake and mirrors the result in the blob cache.
    ///
    /// macOS metadata files are silently swallowed (no telemetry, no upload).
    public func put(key: CacheKey, content: Data) async throws {
        if isMacOSMetadata(key.path) {
            logger.debug("ignoring macOS metadata upload", metadata: ["path": key.path])
            return
        }

        try await pauseManager.guardPaused(workspaceID: key.workspaceID, alias: key.accountAlias)
        try await acquireUploadSlot(alias: key.accountAlias)
        defer { releaseUploadSlot(alias: key.accountAlias) }

        let start = Date()
        let size = Int64(content.count)

        do {
            try await onelake.write(
                alias: key.accountAlias,
                workspaceGUID: key.workspaceID,
                itemGUID: key.itemID,
                path: key.path,
                content: content,
                size: size
            )
        } catch {
            try await withRemoteOperationError(
                error: error, key: key, eventName: "file_upload",
                failCode: "write_failed", start: start
            )
        }
        await offlineTracker.observe(nil)

        // Best-effort HEAD to capture the server-assigned etag/lastmod.
        let now = Date()
        let nowNs = dateToNs(now)!
        var row = MetadataRecord(
            accountAlias: key.accountAlias,
            workspaceID: key.workspaceID,
            itemID: key.itemID,
            path: key.path,
            parentPath: Enumerator.parentPath(key.path),
            name: Enumerator.baseName(key.path),
            isDir: false,
            contentLength: size,
            lastAccessedNs: nowNs,
            syncedAtNs: nowNs
        )
        if let props = try? await onelake.getProperties(
            alias: key.accountAlias,
            workspaceGUID: key.workspaceID,
            itemGUID: key.itemID,
            path: key.path
        ) {
            row.etag = props.eTag
            if props.contentLength != 0 { row.contentLength = props.contentLength }
            row.lastModifiedNs = dateToNs(props.lastModified) ?? 0
            row.contentType = props.contentType
        }
        let rowCopy = row
        await loggedTry({ try await self.cache.upsert(rowCopy) }, "put: upsert")
        // Mirror bytes locally (best-effort: upload already succeeded).
        await loggedTry({ try await self.cache.storeBlob(key: key, data: content) }, "put: storeBlob")

        await track(TelemetryEvent(
            name: "file_upload",
            accountAliasHash: TelemetryRedaction.hashAlias(key.accountAlias),
            durationMs: elapsedMs(since: start),
            success: true,
            bytesTransferred: size
        ))
    }

    // MARK: - Delete

    /// Removes a file or directory from OneLake and the local cache.
    ///
    /// macOS metadata files are dropped from the local cache only (no remote
    /// call, no telemetry).
    public func delete(key: CacheKey) async throws {
        let start = Date()

        let cached = try? await cache.fetch(key: key)
        let isDir = cached?.isDir ?? false
        let eventName = isDir ? "folder_delete" : "file_delete"

        if isMacOSMetadata(key.path) {
            await loggedTry({ try await self.cache.delete(key: key) }, "delete: macOS metadata cache delete")
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

        await loggedTry({ try await self.cache.delete(key: key) }, "delete: cache delete")

        await track(TelemetryEvent(
            name: eventName,
            accountAliasHash: TelemetryRedaction.hashAlias(key.accountAlias),
            durationMs: elapsedMs(since: start),
            success: true
        ))
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

        let now = Date()
        let nowNs = dateToNs(now)!
        let row = MetadataRecord(
            accountAlias: key.accountAlias,
            workspaceID: key.workspaceID,
            itemID: key.itemID,
            path: key.path,
            parentPath: Enumerator.parentPath(key.path),
            name: Enumerator.baseName(key.path),
            isDir: true,
            lastAccessedNs: nowNs,
            syncedAtNs: nowNs
        )
        await loggedTry({ try await self.cache.upsert(row) }, "mkdir: upsert")

        await track(TelemetryEvent(
            name: "folder_create",
            accountAliasHash: TelemetryRedaction.hashAlias(key.accountAlias),
            durationMs: elapsedMs(since: start),
            success: true
        ))
    }

    // MARK: - Offline status

    /// Returns `true` when the engine recently observed an offline-class error.
    public var isOffline: Bool {
        get async { await offlineTracker.isOffline }
    }

    // MARK: - Private: download implementation

    /// Executes the actual network download for `open()`.
    ///
    /// Acquires a semaphore slot, handles the 412-resume-discard-retry path
    /// with correct state reset (sync-01), and ensures downloaded bytes are
    /// returned even when the blob-store write fails (sync-07).
    private func performDownload(key: CacheKey, start: Date, cached: MetadataRecord?) async throws -> Data {
        try await acquireDownloadSlot(alias: key.accountAlias)
        defer { releaseDownloadSlot(alias: key.accountAlias) }

        // Decide resume offset from the spill file / etag sidecar.
        var (rangeStart, pinnedEtag, hasPartial) = partials.rangeStart(
            for: key, cachedRecord: cached ?? MetadataRecord(
                accountAlias: key.accountAlias, workspaceID: key.workspaceID,
                itemID: key.itemID, path: key.path, parentPath: "",
                name: Enumerator.baseName(key.path), isDir: false
            )
        )

        let range: Range<Int64>? = hasPartial ? rangeStart..<Int64.max : nil
        let ifMatch = pinnedEtag ?? ""

        var bodyData: Data
        var props: PathProperties
        do {
            (bodyData, props) = try await onelake.read(
                alias: key.accountAlias,
                workspaceGUID: key.workspaceID,
                itemGUID: key.itemID,
                path: key.path,
                range: range,
                ifMatch: ifMatch
            )
        } catch {
            // 412 on resume: reset ALL resume state so the full-file retry
            // starts from offset 0 with no stale rangeStart (sync-01).
            if hasPartial, case OneLakeError.preconditionFailed = error {
                logger.info("resume etag changed; discarding partial and restarting", metadata: ["path": key.path])
                partials.discard(for: key)
                rangeStart = 0
                hasPartial = false
                pinnedEtag = nil
                do {
                    (bodyData, props) = try await onelake.read(
                        alias: key.accountAlias,
                        workspaceGUID: key.workspaceID,
                        itemGUID: key.itemID,
                        path: key.path,
                        range: nil,
                        ifMatch: ""
                    )
                } catch {
                    // C3: route the retry's error through the shared handler so
                    // telemetry is emitted and the pause manager is consulted,
                    // even if the server sends a second 412 (non-spec but observed).
                    try await withRemoteOperationError(
                        error: error, key: key, eventName: "file_download",
                        failCode: "read_failed", start: start
                    )
                }
            } else {
                try await withRemoteOperationError(
                    error: error, key: key, eventName: "file_download",
                    failCode: "read_failed", start: start
                )
            }
        }
        await offlineTracker.observe(nil)

        // Pin the partial etag.
        if !hasPartial && !props.eTag.isEmpty {
            let etagToStore = props.eTag
        await loggedTry({ try self.partials.storeEtag(etagToStore, for: key) }, "open: storeEtag")
        }

        // Compute total expected.
        var expectedTotal = cached?.contentLength ?? 0
        if props.contentLength > 0 {
            expectedTotal = hasPartial ? rangeStart + props.contentLength : props.contentLength
        }

        let expectedSHA = hasPartial ? cached?.blobSHA256 : nil
        let allBytes = try partials.finalise(
            key: key,
            body: bodyData,
            rangeStart: rangeStart,
            expectedTotal: expectedTotal,
            expectedSHA: expectedSHA
        )

        // Upsert metadata row first (needed before storeBlob can link the SHA).
        let now = Date()
        let nowNs = dateToNs(now)!
        var row = MetadataRecord(
            accountAlias: key.accountAlias,
            workspaceID: key.workspaceID,
            itemID: key.itemID,
            path: key.path,
            parentPath: Enumerator.parentPath(key.path),
            name: Enumerator.baseName(key.path),
            isDir: false,
            contentLength: expectedTotal > 0 ? expectedTotal : Int64(allBytes.count),
            etag: props.eTag,
            lastModifiedNs: dateToNs(props.lastModified) ?? 0,
            contentType: props.contentType,
            lastAccessedNs: nowNs,
            syncedAtNs: nowNs
        )
        if row.name.isEmpty { row.name = Enumerator.baseName(key.path) }
        let downloadRow = row
        await loggedTry({ try await self.cache.upsert(downloadRow) }, "open: upsert")
        // C2: storeBlob updates blob_sha256 on success. When it fails (e.g.
        // disk-full), blob_sha256 stays empty on the upserted row. The next
        // open() skips the blob-fresh fast-path and issues a full HEAD + download
        // again — acceptable per the project's best-effort cache policy (the
        // remote download already succeeded; the local persistence is optional).
        await loggedTry({ try await self.cache.storeBlob(key: key, data: allBytes) }, "open: storeBlob")

        // Return bytes from cache when available; fall back to in-memory bytes
        // when the blob store write failed (cache failure must not discard a
        // successful download — sync-07).
        let data: Data
        if let cached = try? await cache.loadBlob(key: key) {
            data = cached
        } else {
            logger.warn("open: blob cache unavailable; returning in-memory bytes",
                        metadata: ["path": key.path])
            data = allBytes
        }

        await track(TelemetryEvent(
            name: "file_download",
            accountAliasHash: TelemetryRedaction.hashAlias(key.accountAlias),
            durationMs: elapsedMs(since: start),
            success: true,
            bytesTransferred: Int64(data.count)
        ))
        return data
    }

    // MARK: - Private helpers

    /// Returns `(isFresh, children)` from the metadata cache.
    ///
    /// - `(true, children)` — parent row exists, is a directory, and is within
    ///   the `recentFolderTTL` freshness window. `children` contains the cached
    ///   child rows.
    /// - `(false, [])` — parent row is missing or stale. Caller should issue a
    ///   remote refresh.
    ///
    /// Throws `FPError.wrongItemKind` when `key` refers to a file, not a
    /// directory, so the caller can surface the typed error without attempting
    /// a remote listing.
    private func enumerateFromCache(key: CacheKey) async throws -> (Bool, [MetadataRecord])? {
        guard let parent = try? await cache.fetch(key: key) else { return (false, []) }
        guard parent.isDir else {
            throw FPError.wrongItemKind("\(key.path) is not a directory")
        }
        guard Enumerator.isFresh(record: parent, ttl: recentFolderTTL) else {
            return (false, [])
        }
        let children = try await cache.children(of: key)
        return (true, children)
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

    private func expireDiscoveryRows(parent: CacheKey, seen: Set<String>, alias: String, now: Date) async {
        guard let kids = try? await cache.children(of: parent) else { return }
        var deleteBatch: [CacheKey] = []
        for k in kids {
            guard !seen.contains(k.path) else { continue }
            if let syncedAt = k.syncedAt, now.timeIntervalSince(syncedAt) < recentFolderTTL { continue }
            deleteBatch.append(CacheKey(
                accountAlias: alias,
                workspaceID: k.workspaceID,
                itemID: k.itemID,
                path: k.path
            ))
        }
        await batchDelete(deleteBatch, context: "expireDiscoveryRows")
    }

    // MARK: - Shared remote-operation error handler (sync-09)

    /// Handles the common error path for remote operations: observes offline
    /// state, marks workspace paused when appropriate, emits a failure telemetry
    /// event, and always rethrows.
    ///
    /// This collapses the five formerly copy-pasted catch/telemetry/pause blocks.
    @discardableResult
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
            await track(TelemetryEvent(
                name: eventName,
                accountAliasHash: TelemetryRedaction.hashAlias(key.accountAlias),
                durationMs: elapsedMs(since: start),
                success: false,
                errorCode: "capacity_paused"
            ))
            throw SyncError.workspacePaused
        }
        await track(TelemetryEvent(
            name: eventName,
            accountAliasHash: TelemetryRedaction.hashAlias(key.accountAlias),
            durationMs: elapsedMs(since: start),
            success: false,
            errorCode: failCode
        ))
        throw error
    }

    // MARK: - Batch cache helpers (sync-15)

    /// Upserts all records in one GRDB transaction to avoid N individual
    /// write transactions (sync-15).
    private func batchUpsert(_ records: [MetadataRecord], context: String) async {
        guard !records.isEmpty else { return }
        do {
            try await cache.batchUpsert(records)
        } catch {
            Self.log.warning("SyncEngine: batchUpsert failed context=\(context, privacy: .public) err=\(error, privacy: .public)")
        }
    }

    /// Deletes all keys in one GRDB transaction to avoid N individual
    /// write transactions (sync-15).
    private func batchDelete(_ keys: [CacheKey], context: String) async {
        guard !keys.isEmpty else { return }
        do {
            try await cache.batchDelete(keys)
        } catch {
            Self.log.warning("SyncEngine: batchDelete failed context=\(context, privacy: .public) err=\(error, privacy: .public)")
        }
    }

    // MARK: - Logged try helper (sync-16)

    /// Runs `body`, logging a warning on failure. Silent retry is the
    /// documented policy for network errors; local persistence failures are
    /// a different class and belong in the log (sync-16).
    private func loggedTry(_ body: @Sendable () async throws -> Void, _ context: String) async {
        do {
            try await body()
        } catch {
            Self.log.warning("SyncEngine: \(context, privacy: .public) failed err=\(error, privacy: .public)")
        }
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

    // MARK: - Telemetry helper

    private func track(_ event: TelemetryEvent) async {
        await telemetry?.track(event)
    }
}

// MARK: - Elapsed helper

private func elapsedMs(since start: Date) -> Int64 {
    let d = Int64(Date().timeIntervalSince(start) * 1000)
    return max(1, d)
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
