import Foundation
import GRDB

// MARK: - CacheStore+Eviction

extension CacheStore {
    // MARK: - LRU eviction

    /// Deletes the least-recently-used blob-bearing rows until the total
    /// blob byte count is at or below `maxBlobBytes`.
    ///
    /// A no-op when `maxBlobBytes` is zero.
    ///
    /// ## Deduplicated accounting (C4)
    ///
    /// The over-budget decision is made with the SAME deduplicated total
    /// ``CacheReader/deduplicatedBlobBytesSQL`` that ``blobBytes()`` and
    /// ``wipe()`` use — a blob shared by several metadata rows counts once,
    /// not once per row. A plain `SUM(blob_size)` over all rows (the pre-fix
    /// behaviour) double-counts shared blobs, which can make the store think
    /// it is over budget when the real on-disk footprint is not — evicting
    /// rows whose blob file survives (still referenced by another row) for
    /// zero bytes actually reclaimed, and forcing a needless re-download.
    ///
    /// Because of this, a shared blob is evicted or kept as a whole: whenever
    /// a SHA is chosen for eviction, every row referencing it — not just the
    /// oldest one — is cleared in the same transaction. Clearing only some of
    /// a shared blob's rows would not free the blob file
    /// (``deleteUnreferencedBlobs(shas:onDeleted:)`` only unlinks a file once
    /// no row references it any more), so counting those bytes as reclaimed
    /// without clearing every referencing row would reproduce the same
    /// accounting bug. A row that happens to share a blob with an older row
    /// is therefore evicted alongside it even if the row itself was recently
    /// accessed — an inherent consequence of content-addressed dedup, not an
    /// LRU violation of the underlying bytes.
    ///
    /// ## Bounded scan (E5)
    ///
    /// Each pass scans at most ``evictionWindowSize`` of the oldest
    /// blob-bearing rows, then — for every distinct SHA that window
    /// introduces — fetches the full set of rows referencing that SHA
    /// (wherever they sort in LRU order) so a shared blob is never resolved
    /// partially. This bounds the per-pass query instead of loading every
    /// blob-bearing row into memory up front.
    ///
    /// The total measurement and the candidate selection for a given pass
    /// happen inside a single `dbPool.write` transaction — there is no
    /// `await` suspension between them, so no concurrent actor task can push
    /// the total higher between the two steps.
    ///
    /// A pass's blob files are deleted **immediately after that pass's
    /// transaction commits** — not deferred until the whole (possibly
    /// multi-pass) call finishes. This matters because each pass is its own
    /// committed transaction: if a *later* pass throws (plausible causes
    /// include `SQLITE_BUSY` after the busy-timeout under write contention,
    /// or `SQLITE_FULL` — precisely the condition eviction exists to
    /// relieve), the `throw` propagates out of `evictToLimit()` immediately,
    /// but every **earlier** pass already committed its `blob_sha256 = ''`
    /// clears. Deleting per-pass means those earlier passes' blob files are
    /// already unlinked by the time the throw happens, bounding the
    /// file-orphan window to at most the one pass that failed — matching the
    /// old single-transaction design's guarantee. There is no periodic
    /// runtime sweep (`sweepOrphanBlobs` only runs from `CacheStore.init`
    /// and the test-only ``sweepOrphans()``); an FPE process can stay alive
    /// for a long time, so deferring every pass's deletion to the end would
    /// let a plain in-process throw (no crash) strand disk space for the
    /// rest of the process's life — the opposite of what eviction exists to
    /// do. A crash between a pass's commit and that pass's blob-delete still
    /// leaves that pass's files orphaned; the init-time orphan sweep
    /// reclaims them on the next launch, same as before this method existed.
    ///
    /// Note: per arch-04, multiple `CacheStore` instances may share the same
    /// `cacheDir`.  This method enforces the budget for *this* instance only;
    /// cross-engine enforcement is out of scope.
    ///
    /// - Returns: `(evicted, reclaimed)` — number of rows cleared and bytes freed.
    public func evictToLimit() async throws -> (evicted: Int, reclaimed: Int64) {
        // Snapshot the budget on the actor's own executor *before* entering
        // `dbPool.write { }` below. That closure runs on GRDB's writer queue,
        // not on this actor — since `setMaxBlobBytes(_:)` made `maxBlobBytes`
        // a `var`, referencing `self.maxBlobBytes` directly from inside the
        // closure would be a data race with a concurrent `setMaxBlobBytes`
        // call (actor isolation only serialises access from actor-isolated
        // code; it does not extend into a closure handed to another queue).
        // `budget` is a frozen `let` Int64 — trivially `Sendable`, safe to
        // capture into every pass's closure below. One consequence of
        // snapshotting once for the whole (possibly multi-pass) call: a
        // `setMaxBlobBytes()` arriving mid-loop — only reachable when a
        // single call needs more than `evictionWindowSize` rows evicted —
        // is not honoured until the *next* `evictToLimit()` call, matching
        // the already-documented "not retroactive until the next write"
        // semantics on `setMaxBlobBytes(_:)`.
        let budget = maxBlobBytes
        guard budget > 0 else { return (0, 0) }

        struct EvictionCandidate {
            var accountAlias: String
            var workspaceID: String
            var itemID: String
            var path: String
            var sha: String
            var size: Int64
        }

        var totalEvicted = 0
        var totalReclaimed: Int64 = 0

        // Loop passes until the deduplicated total is at or below budget, or
        // there is nothing left to scan. Each pass clears at least one
        // complete SHA group when it evicts anything, so the table shrinks
        // monotonically and the loop is guaranteed to terminate.
        while true {
            let candidates: [EvictionCandidate] = try await dbPool.write { db in
                // Deduplicated total — see the C4 note on this method.
                let total = try Int64.fetchOne(db, sql: CacheReader.deduplicatedBlobBytesSQL) ?? 0
                guard total > budget else { return [] }
                var overage = total - budget

                // Bounded window of the oldest remaining blob-bearing rows (E5).
                let windowRows = try Row.fetchAll(db, sql: """
                SELECT account_alias, workspace_id, item_id, path, blob_sha256, blob_size
                FROM path_metadata
                WHERE blob_sha256 != ''
                ORDER BY last_accessed_ns ASC, rowid ASC
                LIMIT \(Self.evictionWindowSize)
                """)
                guard !windowRows.isEmpty else { return [] }

                // Distinct SHAs in the window, oldest-first (first-occurrence order).
                var shaOrder: [String] = []
                var seenSHAs = Set<String>()
                for row in windowRows {
                    let sha: String = row["blob_sha256"]
                    if seenSHAs.insert(sha).inserted { shaOrder.append(sha) }
                }

                // Every row referencing any of those SHAs — including rows
                // outside the window — so a shared blob is resolved as one
                // complete group, never partially (see the C4 note above).
                let (placeholders, arguments) = Self.inClauseBinding(shaOrder)
                let groupRows = try Row.fetchAll(db, sql: """
                SELECT account_alias, workspace_id, item_id, path, blob_sha256, blob_size
                FROM path_metadata
                WHERE blob_sha256 IN (\(placeholders))
                """, arguments: arguments)

                var rowsBySHA: [String: [EvictionCandidate]] = [:]
                for row in groupRows {
                    let candidate = EvictionCandidate(
                        accountAlias: row["account_alias"],
                        workspaceID: row["workspace_id"],
                        itemID: row["item_id"],
                        path: row["path"],
                        sha: row["blob_sha256"],
                        size: row["blob_size"]
                    )
                    rowsBySHA[candidate.sha, default: []].append(candidate)
                }

                // Select whole SHA groups, oldest-first, until overage is covered.
                var toEvict: [EvictionCandidate] = []
                for sha in shaOrder {
                    guard overage > 0 else { break }
                    guard let group = rowsBySHA[sha], let size = group.first?.size else { continue }
                    toEvict.append(contentsOf: group)
                    overage -= size
                }

                // Clear blob columns for every victim row in one pass.
                for v in toEvict {
                    try db.execute(sql: """
                    UPDATE path_metadata
                    SET blob_sha256 = '', blob_size = 0
                    WHERE account_alias = ? AND workspace_id = ? AND item_id = ? AND path = ?
                    """, arguments: [v.accountAlias, v.workspaceID, v.itemID, v.path])
                }

                return toEvict
            }

            if candidates.isEmpty { break }

            // Delete THIS PASS's blob files now, right after its transaction
            // committed — see the doc comment above for why deferring this
            // to the end of the (possibly multi-pass) loop would reopen a
            // disk-leak window. Resolve ref-counts in one grouped query, then
            // check+unlink inside a single write transaction — eliminates
            // N+1 and closes the TOCTOU window where a concurrent storeBlob
            // could reference a just-evicted SHA between the ref-count read
            // and the unlink.
            let uniqueSHAs = Array(Set(candidates.map(\.sha)))
            // Every row sharing a SHA was cleared together above, so each SHA
            // maps to exactly one size; `uniquingKeysWith` never has to pick
            // between different values.
            let sizeBySHA = Dictionary(candidates.map { ($0.sha, $0.size) }, uniquingKeysWith: { first, _ in first })
            await deleteUnreferencedBlobs(shas: uniqueSHAs, onDeleted: { sha in
                totalReclaimed += sizeBySHA[sha] ?? 0
            })
            totalEvicted += candidates.count
        }

        if totalEvicted > 0 {
            logger.debug("cache eviction", metadata: [
                "evicted": "\(totalEvicted)",
                "reclaimed": "\(totalReclaimed)",
            ])
        }

        return (totalEvicted, totalReclaimed)
    }

    // MARK: Eviction window size

    /// Maximum number of oldest blob-bearing rows scanned per
    /// ``evictToLimit()`` pass.
    ///
    /// Bounds each pass's query so it never materializes every blob-bearing
    /// row in the table (E5). If the deduplicated total is still over budget
    /// after a pass, `evictToLimit()` loops for another pass — rows cleared
    /// by the previous pass no longer match `blob_sha256 != ''`, so each
    /// pass naturally scans past what came before it.
    private static let evictionWindowSize = 200
}
