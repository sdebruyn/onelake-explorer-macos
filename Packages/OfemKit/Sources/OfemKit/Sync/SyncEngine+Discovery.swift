import Foundation

// MARK: - SyncEngine+Discovery

extension SyncEngine {
    // MARK: - Workspace / item discovery

    /// Returns all workspaces visible to `alias`, reconciling the local cache.
    public func listWorkspaces(alias: String) async throws -> [Workspace] {
        let start = Date()
        let ws: [Workspace]
        let droppedCount: Int
        do {
            (ws, droppedCount) = try await fabric.listAllWorkspacesDetailed(alias: alias)
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
            logger.warn("listWorkspaces: upsert root failed", error: error)
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
        // The destructive workspace purge below must never run on an INCOMPLETE
        // listing: WireWorkspace.toWorkspace() silently drops any element
        // missing its `id` (fabric-06 leniency), and a dropped element means
        // that live workspace is absent from `seen` — purgeRemovedWorkspaces
        // would then wipe its entire cache on an ostensibly-successful call.
        // expireDiscoveryRows above is unaffected by this guard: it still
        // reconciles the discovery rows for the workspaces that DID decode,
        // which is a cheap, self-healing remount at worst — not the
        // destructive full-cache wipe a dropped element must never trigger.
        if droppedCount == 0 {
            await purgeRemovedWorkspaces(alias: alias, seen: seen)
        } else {
            logger.warn(
                "listWorkspaces: skipping purgeRemovedWorkspaces — incomplete listing",
                metadata: ["alias": alias, "droppedCount": "\(droppedCount)"]
            )
        }

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
            logger.warn("reconcileItemListing: upsert root failed", error: error)
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
        let removedGUIDs = await expireDiscoveryRows(children: cachedChildren, seen: seen, alias: alias)
        // Purge each removed item's orphaned real `path_metadata` rows and
        // materialized-container entries so a vanished item leaves no residue and
        // the freshness poll loop stops DFS-404ing its dead containers every tick.
        await purgeRemovedItems(alias: alias, workspaceID: workspaceID, itemGUIDs: removedGUIDs)

        var diff = Diff()
        diff.added = added
        diff.updated = updated
        diff.removed = removedGUIDs.count
        return (storageItems, diff)
    }

    /// The throttle/coalesce map key for a `(alias, workspaceID)` pair.
    /// A NUL separator keeps the two components unambiguous.
    private static func itemListKey(alias: String, workspaceID: String) -> String {
        "\(alias)\u{0}\(workspaceID)"
    }

    /// Deletes discovery `children` that are absent from `seen`, returning the
    /// `path` of each expired row — the removed item GUIDs for the item caller
    /// (`reconcileItemListing`, where a discovery row's `path` is the item GUID)
    /// or workspace GUIDs for the workspace caller (`listWorkspaces`, which
    /// discards the result).
    ///
    /// This method only TOMBSTONES the discovery rows. `reconcileItemListing`
    /// feeds the returned GUIDs into ``purgeRemovedItems(alias:workspaceID:itemGUIDs:)``
    /// to purge each removed item's orphaned real `path_metadata` rows and
    /// materialized-container entries.
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
    ) async -> [String] {
        let expired = children.filter { !seen.contains($0.path) }
        let deleteBatch = expired.map { k in
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
        // The removed items' orphaned real rows + materialized entries are purged
        // by reconcileItemListing via the returned GUIDs (purgeRemovedItems).
        await batchDelete(deleteBatch, recordTombstones: true, context: "expireDiscoveryRows")
        return expired.map(\.path)
    }

    /// Purges the orphaned residue of items that just vanished from the Fabric
    /// listing (their discovery rows were tombstoned by ``expireDiscoveryRows``).
    ///
    /// For each removed item GUID:
    /// - Wipe every real `path_metadata` row keyed by the item GUID —
    ///   `CacheKey(alias, ws, guid, "")`, empty path = whole item — with
    ///   `recordTombstones: false`. The `"ws/guid"` tombstone was already written
    ///   by the discovery-row delete; the item-root row shares that same identifier
    ///   (so re-tombstoning is redundant), and tombstoning every descendant would
    ///   flood `didDeleteItems` when the single parent removal already tells Finder
    ///   the item is gone. Blob files orphaned by the wipe are reclaimed by the
    ///   existing orphan sweep — this uses `batchDelete`, NOT `delete(key:)` (which
    ///   would unconditionally write per-row tombstones).
    /// - Drop the item's `materialized_containers` rows (`removeMaterialized`) so
    ///   the freshness poll loop stops refreshing — and DFS-404ing — the dead
    ///   item's containers on every tick.
    ///
    /// Race-safe by eventual consistency (no locking): if a concurrent
    /// `refreshFolder` re-upsert or a stale re-listing repopulates the item after
    /// this runs, the next reconcile finds the item still absent and purges again.
    private func purgeRemovedItems(alias: String, workspaceID: String, itemGUIDs: [String]) async {
        guard !itemGUIDs.isEmpty else { return }
        let itemKeys = itemGUIDs.map {
            CacheKey(accountAlias: alias, workspaceID: workspaceID, itemID: $0, path: "")
        }
        await batchDelete(itemKeys, recordTombstones: false, context: "purgeRemovedItems")
        for guid in itemGUIDs {
            let identifierPrefix = CacheStore.identifierString(
                workspaceID: workspaceID, itemID: guid, path: ""
            )
            do {
                try await cache.removeMaterialized(alias: alias, identifierPrefix: identifierPrefix)
            } catch {
                logger.warn(
                    "purgeRemovedItems: removeMaterialized failed",
                    error: error,
                    metadata: ["prefix": identifierPrefix]
                )
            }
        }
    }

    /// Purges the orphaned residue of workspaces that are no longer part of a
    /// successful Fabric listing.
    ///
    /// SET-BASED, not edge-triggered: unlike ``purgeRemovedItems(alias:workspaceID:itemGUIDs:)``,
    /// which reacts to the discovery-row deltas ``expireDiscoveryRows`` just
    /// computed, this re-derives the orphan set directly from the cache's live
    /// workspace IDs vs `seen` (the fresh Fabric listing) on every successful
    /// reconcile. That converges after any race — a re-upsert that slips in
    /// between reconciles is caught again on the very next pass, with no
    /// discovery row required to trigger it — AND retroactively reclaims
    /// pre-existing leaks: a workspace whose discovery row is already gone (for
    /// whatever reason) still gets its residue swept the next time
    /// `listWorkspaces` succeeds. An edge-triggered purge could do neither.
    ///
    /// Safety relies entirely on the caller, which gates this call on TWO
    /// completeness signals before invoking it: ``listWorkspaces(alias:)``
    /// rethrows on any `fabric.listAllWorkspacesDetailed` failure *before*
    /// reaching this call (and `listAllWorkspacesDetailed` itself throws
    /// `FabricError.paginationExceeded` / `.loopingPagination` rather than
    /// returning a partial page list on pagination truncation); AND the caller
    /// only invokes this when `droppedCount == 0` — i.e. no wire element was
    /// silently dropped by `WireWorkspace.toWorkspace()`'s per-element
    /// leniency (fabric-06), which would otherwise put a still-live workspace
    /// into `seen`'s complement and trigger a full destructive wipe of its
    /// cache on what looks like a clean listing. So this only ever runs
    /// against a COMPLETE successful listing. An empty-but-successful `seen`
    /// purging every cached workspace for the alias is therefore intentional,
    /// not a bug to guard against: it mirrors the already-visible behavior of
    /// an empty listing expiring every discovery row and remounting to an
    /// empty domain — this just aligns storage with what the user already
    /// sees. No absent-twice or debounce guard is added on top.
    ///
    /// No tombstones are written — see
    /// ``CacheStore/purgeWorkspaceRows(accountAlias:workspaceID:)``'s doc comment
    /// for why the workspace's disappearance from Finder needs none.
    private func purgeRemovedWorkspaces(alias: String, seen: Set<String>) async {
        let cachedWorkspaceIDs = (try? await cache.workspaceIDs(accountAlias: alias)) ?? []
        let removed = cachedWorkspaceIDs.filter { !seen.contains($0) }
        guard !removed.isEmpty else { return }
        for workspaceID in removed {
            do {
                _ = try await cache.purgeWorkspaceRows(accountAlias: alias, workspaceID: workspaceID)
            } catch {
                logger.warn(
                    "purgeRemovedWorkspaces: purgeWorkspaceRows failed",
                    error: error,
                    metadata: ["workspaceID": workspaceID]
                )
            }
            do {
                try await cache.removeMaterialized(alias: alias, identifierPrefix: workspaceID)
            } catch {
                logger.warn(
                    "purgeRemovedWorkspaces: removeMaterialized failed",
                    error: error,
                    metadata: ["workspaceID": workspaceID]
                )
            }
        }
    }
}
