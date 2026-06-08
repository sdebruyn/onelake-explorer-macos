import Foundation
import CryptoKit
import os.log

// MARK: - SyncEngine

/// The top-level sync coordinator.
///
/// `SyncEngine` wires `OfemAuth`, `CacheStore`, `OneLakeClient`,
/// `FabricClient`, `TelemetryClient`, and `OfemLogger` into the core OFEM
/// file-system operations: enumerate, open, put, delete, mkdir, and workspace
/// / item discovery.
///
/// ## Design notes
///
/// - `SyncEngine` is a Swift `actor` so all mutable state (the per-account
///   download / upload semaphore tables) is automatically serialised.
/// - Network-heavy methods (`open`, `put`) release the actor while the network
///   call is in flight so other tasks are not blocked (Swift structured
///   concurrency: `async` automatically suspends the caller).
/// - Concurrency caps are enforced per account alias via `AsyncSemaphore`.
/// - Last-write-wins semantics: `put` and `delete` never use `If-Match` for
///   writes. This matches the agreed conflict policy in `docs/auth.md`.
///
/// ## Mirrors
///
/// `internal/sync/engine.go` — `Engine` and all its methods.
public actor SyncEngine {

    // MARK: - Configuration

    /// Default refresh interval for recently-visited folders.
    ///
    /// Mirrors `internal/sync/engine.go` — `DefaultRecentFolderTTL`.
    public static let defaultRecentFolderTTL: TimeInterval = 5 * 60  // 5 min

    /// Default per-account cap on concurrent downloads.
    ///
    /// Mirrors `internal/sync/concurrency.go` — `DefaultMaxConcurrentDownloads`.
    public static let defaultMaxConcurrentDownloads = 8

    /// Default per-account cap on concurrent uploads.
    ///
    /// Mirrors `internal/sync/concurrency.go` — `DefaultMaxConcurrentUploads`.
    public static let defaultMaxConcurrentUploads = 4

    // MARK: - Dependencies (nonisolated for injection without crossing actor boundary)

    nonisolated let cache: CacheStore
    nonisolated let onelake: OneLakeClient
    nonisolated let fabric: FabricClient

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

    private static let log = Logger(subsystem: "dev.debruyn.ofem", category: "SyncEngine")

    // MARK: - Init

    /// Creates a `SyncEngine`.
    ///
    /// - Parameters:
    ///   - cache: Metadata + blob cache (required).
    ///   - onelake: DFS HTTP client (required).
    ///   - fabric: Fabric REST client (required).
    ///   - logger: Structured logger.
    ///   - telemetry: Optional telemetry sink.
    ///   - recentFolderTTL: Freshness window for recently-visited folders.
    ///   - maxConcurrentDownloads: Per-account download cap.
    ///   - maxConcurrentUploads: Per-account upload cap.
    ///   - scratchBase: Directory for download spill files. Defaults to
    ///     `<tmp>/ofem-download-partials/<pid>`.
    ///   - pauseProbeInterval: Minimum gap between workspace-recovery probes.
    public init(
        cache: CacheStore,
        onelake: OneLakeClient,
        fabric: FabricClient,
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
        // Reap stale partials from dead processes.
        PartialManager.reapStalePartialDirs(under: base)
        let pid = ProcessInfo.processInfo.processIdentifier
        let scratchDir = base.appendingPathComponent("\(pid)")
        self.partials = PartialManager(scratchDir: scratchDir)

        self.pauseManager  = PauseManager(cache: cache, onelake: onelake, probeInterval: pauseProbeInterval)
        self.offlineTracker = OfflineTracker()
    }

    // MARK: - Workspace / item discovery

    /// Returns all workspaces visible to `alias`, reconciling the local cache.
    ///
    /// Mirrors `internal/sync/discover.go` — `Engine.ListWorkspaces`.
    public func listWorkspaces(alias: String) async throws -> [Workspace] {
        let start = Date()
        let ws: [Workspace]
        do {
            ws = try await fabric.listAllWorkspaces(alias: alias)
        } catch {
            await offlineTracker.observe(error)
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
        try? await cache.upsert(root)

        var seen: Set<String> = []
        for w in ws {
            seen.insert(w.id)
            let row = MetadataRecord(
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
            try? await cache.upsert(row)
        }
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
    ///
    /// Mirrors `internal/sync/discover.go` — `Engine.ListItems`.
    public func listItems(alias: String, workspaceID: String) async throws -> [Item] {
        let start = Date()
        let items: [Item]
        do {
            items = try await fabric.listAllItems(alias: alias, workspaceID: workspaceID)
        } catch {
            await offlineTracker.observe(error)
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
        try? await cache.upsert(root)

        var seen: Set<String> = []
        for it in items {
            seen.insert(it.id)
            let row = MetadataRecord(
                accountAlias: alias,
                workspaceID: workspaceID,
                itemID: VirtualIDs.itemID,
                path: it.id,
                parentPath: "",
                name: it.displayName,
                isDir: true,
                lastAccessedNs: nowNs,
                syncedAtNs: nowNs
            )
            try? await cache.upsert(row)
        }
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
    /// Mirrors `internal/sync/enumerate.go` — `Engine.Enumerate`.
    public func enumerate(key: CacheKey) async throws -> [MetadataRecord] {
        let start = Date()

        // Fast path: serve from cache when fresh.
        if let (fresh, cached) = try? await enumerateFromCache(key: key), fresh {
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
    ///
    /// Mirrors `internal/sync/enumerate.go` — `Engine.RefreshFolder`.
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

        // Build remote children set.
        var remoteChildren: [String: PathEntry] = [:]
        for entry in result.entries {
            guard let rel = Enumerator.stripItemPrefix(name: entry.name, itemGUID: key.itemID),
                  !rel.isEmpty,
                  Enumerator.isDirectChild(parent: key.path, child: rel)
            else { continue }
            remoteChildren[rel] = entry
        }

        // Load existing cached children.
        let cachedChildren = (try? await cache.children(of: key)) ?? []
        var cachedByPath: [String: MetadataRecord] = [:]
        for c in cachedChildren { cachedByPath[c.path] = c }

        var diff = Diff()

        // Upsert remote children.
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
            try? await cache.upsert(next)
        }

        // Delete cached children that disappeared remotely.
        for (relPath, _) in cachedByPath {
            guard remoteChildren[relPath] == nil else { continue }
            let victimKey = CacheKey(
                accountAlias: key.accountAlias,
                workspaceID: key.workspaceID,
                itemID: key.itemID,
                path: relPath
            )
            try? await cache.delete(key: victimKey)
            diff.removed += 1
        }

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
        try? await cache.upsert(parent)

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
    /// Mirrors `internal/sync/download.go` — `Engine.Open`.
    public func open(key: CacheKey) async throws -> Data {
        let start = Date()
        try await pauseManager.guardPaused(workspaceID: key.workspaceID, alias: key.accountAlias)
        try await acquireDownloadSlot(alias: key.accountAlias)
        defer { releaseDownloadSlot(alias: key.accountAlias) }

        // Fetch the cached row (optional — a miss just means we download fresh).
        let cached = try? await cache.fetch(key: key)

        if let c = cached, !c.blobSHA256.isEmpty {
            // Attempt to serve from blob cache.
            do {
                let (fresh, props) = try await isBlobFresh(key: key, cached: c)
                if fresh {
                    await offlineTracker.observe(nil)
                    if let data = try? await cache.loadBlob(key: key) {
                        try? await cache.touch(key: key)
                        await track(TelemetryEvent(
                            name: "file_download",
                            accountAliasHash: TelemetryRedaction.hashAlias(key.accountAlias),
                            durationMs: elapsedMs(since: start),
                            success: true
                        ))
                        return data
                    }
                } else if let p = props {
                    // Remote moved on: update cached fields and fall through.
                    _ = p // used below when rebuilding the row
                }
            } catch {
                await offlineTracker.observe(error)
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

        // Download from OneLake.
        let (rangeStart, pinnedEtag, hasPartial) = partials.rangeStart(
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
            // 412 on resume: discard partial and retry from scratch.
            if hasPartial, case OneLakeError.preconditionFailed = error {
                logger.info("resume etag changed; discarding partial and restarting", metadata: ["path": key.path])
                partials.discard(for: key)
                (bodyData, props) = try await onelake.read(
                    alias: key.accountAlias,
                    workspaceGUID: key.workspaceID,
                    itemGUID: key.itemID,
                    path: key.path
                )
            } else {
                await offlineTracker.observe(error)
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
                await track(TelemetryEvent(
                    name: "file_download",
                    accountAliasHash: TelemetryRedaction.hashAlias(key.accountAlias),
                    durationMs: elapsedMs(since: start),
                    success: false,
                    errorCode: "read_failed"
                ))
                throw error
            }
        }
        await offlineTracker.observe(nil)

        // Pin the partial etag.
        if !hasPartial && !props.eTag.isEmpty {
            try? partials.storeEtag(props.eTag, for: key)
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
        try? await cache.upsert(row)

        // Store blob and link to the metadata row.
        try? await cache.storeBlob(key: key, data: allBytes)

        // Return the bytes from the blob store.
        let data = try await cache.loadBlob(key: key)
        await track(TelemetryEvent(
            name: "file_download",
            accountAliasHash: TelemetryRedaction.hashAlias(key.accountAlias),
            durationMs: elapsedMs(since: start),
            success: true,
            bytesTransferred: Int64(data.count)
        ))
        return data
    }

    // MARK: - Put (upload)

    /// Uploads `content` to OneLake and mirrors the result in the blob cache.
    ///
    /// macOS metadata files are silently swallowed (no telemetry, no upload).
    ///
    /// Mirrors `internal/sync/upload.go` — `Engine.Put`.
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
            await offlineTracker.observe(error)
            if await pauseManager.markPausedIfNeeded(
                workspaceID: key.workspaceID, alias: key.accountAlias, error: error
            ) {
                await track(TelemetryEvent(
                    name: "file_upload",
                    accountAliasHash: TelemetryRedaction.hashAlias(key.accountAlias),
                    durationMs: elapsedMs(since: start),
                    success: false,
                    errorCode: "capacity_paused"
                ))
                throw SyncError.workspacePaused
            }
            await track(TelemetryEvent(
                name: "file_upload",
                accountAliasHash: TelemetryRedaction.hashAlias(key.accountAlias),
                durationMs: elapsedMs(since: start),
                success: false,
                errorCode: "write_failed"
            ))
            throw error
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
        try? await cache.upsert(row)
        // Mirror bytes locally (best-effort: upload already succeeded).
        try? await cache.storeBlob(key: key, data: content)

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
    ///
    /// Mirrors `internal/sync/delete.go` — `Engine.Delete`.
    public func delete(key: CacheKey) async throws {
        let start = Date()

        let cached = try? await cache.fetch(key: key)
        let isDir = cached?.isDir ?? false
        let eventName = isDir ? "folder_delete" : "file_delete"

        if isMacOSMetadata(key.path) {
            try? await cache.delete(key: key)
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
                errorCode: "delete_failed"
            ))
            throw error
        }
        await offlineTracker.observe(nil)

        try? await cache.delete(key: key)

        await track(TelemetryEvent(
            name: eventName,
            accountAliasHash: TelemetryRedaction.hashAlias(key.accountAlias),
            durationMs: elapsedMs(since: start),
            success: true
        ))
    }

    // MARK: - Mkdir

    /// Creates a directory on OneLake and upserts the matching cache row.
    ///
    /// Mirrors `internal/sync/mkdir.go` — `Engine.Mkdir`.
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
            await offlineTracker.observe(error)
            if await pauseManager.markPausedIfNeeded(
                workspaceID: key.workspaceID, alias: key.accountAlias, error: error
            ) {
                await track(TelemetryEvent(
                    name: "folder_create",
                    accountAliasHash: TelemetryRedaction.hashAlias(key.accountAlias),
                    durationMs: elapsedMs(since: start),
                    success: false,
                    errorCode: "capacity_paused"
                ))
                throw SyncError.workspacePaused
            }
            await track(TelemetryEvent(
                name: "folder_create",
                accountAliasHash: TelemetryRedaction.hashAlias(key.accountAlias),
                durationMs: elapsedMs(since: start),
                success: false,
                errorCode: "mkdir_failed"
            ))
            throw error
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
        try? await cache.upsert(row)

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

    // MARK: - Private helpers

    private func enumerateFromCache(key: CacheKey) async throws -> (Bool, [MetadataRecord]) {
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
        for k in kids {
            guard !seen.contains(k.path) else { continue }
            if let syncedAt = k.syncedAt, now.timeIntervalSince(syncedAt) < recentFolderTTL { continue }
            let key = CacheKey(
                accountAlias: alias,
                workspaceID: k.workspaceID,
                itemID: k.itemID,
                path: k.path
            )
            try? await cache.delete(key: key)
        }
    }

    // MARK: - Semaphore helpers (actor-isolated)

    private func acquireDownloadSlot(alias: String) async throws {
        let sem = downloadSemaphore(for: alias)
        await sem.wait()
    }

    private func releaseDownloadSlot(alias: String) {
        downloadSemaphore(for: alias).signal()
    }

    private func acquireUploadSlot(alias: String) async throws {
        let sem = uploadSemaphore(for: alias)
        await sem.wait()
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

private func dateToNs(_ date: Date?) -> Int64? {
    guard let d = date else { return nil }
    return Int64(d.timeIntervalSince1970 * 1_000_000_000)
}

