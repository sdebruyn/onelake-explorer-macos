import Foundation
import os.log

// MARK: - SyncEngine+MaterializedRefresh

extension SyncEngine {
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

        // Bound tombstone growth: TTL-purge expired tombstones for this alias,
        // throttled to at most once per 24 h. Runs at the top of the pass (inside
        // the re-entrancy guard, so overlapping polls never double-purge) before
        // any listing I/O. Non-fatal — a purge failure never aborts the refresh.
        await purgeExpiredTombstonesThrottled(alias: alias)

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

    /// TTL-purges expired deletion tombstones for `alias`, throttled to at most
    /// once per ``tombstonePurgeThrottleNs``.
    ///
    /// Mirrors the ``refreshItemListing`` throttle: skip inside the window; stamp
    /// ``lastTombstonePurgeNs`` only AFTER a successful purge so a thrown attempt
    /// stays due next poll. A backward clock step (`nowNs < last`) fails toward
    /// purging rather than freezing. The purge is best-effort maintenance — a
    /// failure is logged and swallowed so it can never abort the enclosing
    /// materialized refresh.
    private func purgeExpiredTombstonesThrottled(alias: String) async {
        let nowNs = nowNsProvider()
        if let last = lastTombstonePurgeNs[alias], nowNs >= last, nowNs - last < Self.tombstonePurgeThrottleNs {
            return
        }
        do {
            let purged = try await cache.purgeExpiredTombstones(accountAlias: alias)
            lastTombstonePurgeNs[alias] = nowNs
            if purged > 0 {
                logger.debug("tombstone purge", metadata: [
                    "alias": alias,
                    "purged": "\(purged)",
                ])
            }
        } catch {
            Self.log.warning(
                "refreshMaterialized: tombstone purge failed alias=\(alias, privacy: .public) err=\(error, privacy: .public)"
            )
        }
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

    // MARK: - Semaphore helper (materialized-refresh concurrency cap)

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
