import Foundation
import os.log

// MARK: - SyncEngine+Enumerate

extension SyncEngine {
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
    ///
    /// Phases 3 and 5 are committed together in ONE
    /// ``CacheStore/batchUpsertAndDelete(upserts:deletes:recordTombstones:)``
    /// transaction (not as two separate writes): a failure while deleting
    /// vanished children rolls the upserts back too, instead of leaving
    /// committed-but-un-tombstoned rows behind an already-advanced sync anchor
    /// (#427 / review finding M2).
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

        // Phase 5: cached children that disappeared remotely (pure). The
        // reference set is the FULL remote listing (`remoteChildren`), NEVER the
        // upsert batch — a child skipped from the batch because it is unchanged
        // is still present remotely and must not be tombstoned. Computed here,
        // alongside the upsert batch, so both can commit in one transaction below.
        let deleteBatch = Self.buildDeleteBatch(
            key: key,
            remoteChildren: remoteChildren,
            cachedByPath: cachedByPath
        )
        diff.removed += deleteBatch.count

        // Phases 3 + 5 commit atomically: each removed row (and any descendants
        // of a vanished directory) is tombstoned in the SAME transaction as the
        // upserts above, so enumerateChanges delivers the removal incrementally
        // AND a delete-phase failure (e.g. a transient SQLITE_BUSY/SQLITE_FULL)
        // rolls the upserts back too — never committed-but-un-tombstoned rows
        // behind an already-advanced sync anchor (#427 / review finding M2).
        try await cache.batchUpsertAndDelete(
            upserts: upsertBatch, deletes: deleteBatch, recordTombstones: true
        )

        // Phase 4: #380 subtree-etag harvest (only updateSubtreeEtag, never a
        // synced_at_ns bump).
        await harvestSubtreeEtags(
            key: key,
            remoteChildren: remoteChildren,
            cachedByPath: cachedByPath,
            upsertBatch: upsertBatch
        )

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

        // `dateToNsOrNil` (renamed from the file-private `dateToNs` on the
        // M10a/#466 family-extension split — see its doc comment in
        // `SyncEngine+Scheduler.swift`) keeps `nil` for a nil / out-of-range
        // date, unlike the global `CacheModels.dateToNs` `(Date?) -> Int64`,
        // which folds both to `0`. DFS listings never return a creationDate,
        // so `entry.creationDate` is always `nil`; the global's `nil -> 0`
        // fold would short-circuit the `?? cur?.createdNs` fallback below and
        // silently drop the creation time captured earlier via HEAD/GET
        // (#371). Bind explicitly to the nil-preserving overload so that
        // fallback keeps working (this also drops the non-optional `?? 0`
        // warning below).
        let toNs: (Date?) -> Int64? = dateToNsOrNil

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
}
