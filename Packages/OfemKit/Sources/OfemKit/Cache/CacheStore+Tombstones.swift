import GRDB

// MARK: - CacheStore+Tombstones

public extension CacheStore {
    /// Time-to-live for deletion tombstones. A tombstone older than this is
    /// eligible for TTL purge (``purgeExpiredTombstones(accountAlias:)``), which
    /// bounds otherwise-unbounded tombstone growth. A hardcoded constant, not a
    /// config knob: 30 days comfortably exceeds any realistic client offline
    /// window, and the safety of the purge rests on the FPE lagging-client guard,
    /// not on tuning this value.
    static let tombstoneTTLNs: Int64 = 30 * 24 * 60 * 60 * 1_000_000_000

    // MARK: - Deletion tombstones

    /// Writes a deletion tombstone for `identifierString` at the current time.
    ///
    /// Called by `delete(key:)` before the hard-delete, and by `SyncEngine.rename`
    /// for the OLD identifier after a re-key, so the change path can surface the
    /// removal to the File Provider framework.
    func recordDeletion(accountAlias: String, identifierString: String) async throws {
        guard !accountAlias.isEmpty else { throw CacheError.missingArgument("accountAlias") }
        guard !identifierString.isEmpty else { throw CacheError.missingArgument("identifierString") }
        let nowNs = clock()
        let tombstone = DeletionTombstoneRecord(
            accountAlias: accountAlias,
            identifierString: identifierString,
            deletedAtNs: nowNs
        )
        try await dbPool.write { db in
            try tombstone.save(db)
        }
    }

    // MARK: - Deletion tombstones: TTL purge

    /// Purges deletion tombstones older than ``tombstoneTTLNs`` for `accountAlias`
    /// and advances the alias's monotonic purge watermark to the newest timestamp
    /// actually reclaimed. Returns the number of tombstones deleted.
    ///
    /// One write transaction:
    /// 1. `SELECT MAX(deleted_at_ns) FROM deletion_tombstones WHERE account_alias
    ///    = ? AND deleted_at_ns < cutoff` — the newest timestamp among the rows
    ///    that are ABOUT to be purged (served by `idx_dt_deleted_at`, same
    ///    predicate as the delete below).
    /// 2. `DELETE FROM deletion_tombstones WHERE account_alias = ? AND
    ///    deleted_at_ns < cutoff`.
    /// 3. Upsert `sync_meta.tombstones_purged_through_ns = MAX(existing,
    ///    maxPurged)` — but ONLY when at least one row was deleted. A zero-row
    ///    purge leaves the watermark untouched: nothing was reclaimed, so there
    ///    is nothing new for the FPE lagging-client guard to be honest about, and
    ///    jumping the watermark to `cutoff` anyway would trip that guard for a
    ///    long-idle alias on every purge pass forever. The upsert is still
    ///    MONOTONIC (a backward clock step can never lower it).
    ///
    /// `cutoff` is derived from the same injectable ``clock`` that stamps every
    /// tombstone's `deleted_at_ns`, so the comparison is against a consistent time
    /// basis (tests drive both through one injected clock).
    ///
    /// The FPE is the single writer; this is called (throttled) from
    /// `SyncEngine.refreshMaterialized`. Because it runs inside the actor's write
    /// serialiser it never races the tombstone writers (`delete`, `batchDelete`,
    /// `recordDeletion`).
    @discardableResult
    func purgeExpiredTombstones(accountAlias: String) async throws -> Int {
        guard !accountAlias.isEmpty else { throw CacheError.missingArgument("accountAlias") }
        let cutoff = clock() - Self.tombstoneTTLNs
        return try await dbPool.write { db -> Int in
            // Newest deleted_at_ns among the rows this pass is about to purge.
            // The COALESCE fallback of 0 is never actually read as a watermark
            // value below — it's only consulted when `deleted > 0`, which by
            // construction means this same predicate matched at least one row.
            let maxPurged = try Int64.fetchOne(db, sql: """
            SELECT COALESCE(MAX(deleted_at_ns), 0) FROM deletion_tombstones
            WHERE account_alias = ? AND deleted_at_ns < ?
            """, arguments: [accountAlias, cutoff]) ?? 0

            try db.execute(sql: """
            DELETE FROM deletion_tombstones
            WHERE account_alias = ? AND deleted_at_ns < ?
            """, arguments: [accountAlias, cutoff])
            let deleted = db.changesCount

            // Monotonic watermark upsert — skipped entirely on a zero-row purge
            // so the watermark only ever advances to a timestamp that was
            // actually reclaimed. MAX guards against a backward clock step ever
            // regressing it.
            if deleted > 0 {
                try db.execute(sql: """
                INSERT INTO sync_meta (account_alias, tombstones_purged_through_ns)
                VALUES (?, ?)
                ON CONFLICT(account_alias) DO UPDATE SET
                    tombstones_purged_through_ns =
                        MAX(sync_meta.tombstones_purged_through_ns, excluded.tombstones_purged_through_ns)
                """, arguments: [accountAlias, maxPurged])
            }

            return deleted
        }
    }

    /// Returns the tombstone-purge watermark for `accountAlias` (0 if never
    /// purged). Delegates to ``CacheReader/tombstonesPurgedThroughNs(accountAlias:)``.
    func tombstonesPurgedThroughNs(accountAlias: String) async throws -> Int64 {
        try await reader().tombstonesPurgedThroughNs(accountAlias: accountAlias)
    }

    // MARK: Identifier helpers

    /// Reconstructs the `ItemIdentifier.identifierString` for a
    /// `(workspaceID, itemID, path)` triple.
    ///
    /// Mirrors ``ItemIdentifier/identifierString`` without importing the full
    /// FileProvider framework from the cache layer.
    internal static func identifierString(workspaceID: String, itemID: String, path: String) -> String {
        if path.isEmpty {
            return "\(workspaceID)/\(itemID)"
        }
        return "\(workspaceID)/\(itemID)/\(path)"
    }

    /// The delta-visible `ItemIdentifier.identifierString` for a row, or `nil`
    /// when the row must NOT be tombstoned.
    ///
    /// Discovery rows use ``VirtualIDs`` sentinels for their workspace/item id:
    /// - Workspace-discovery rows (`workspaceID == VirtualIDs.workspaceID`) map to
    ///   the domain root, whose container deltas are remount-driven via the
    ///   ChangeWatcher — never via a tombstone. Returns `nil`.
    /// - Item-discovery rows (`itemID == VirtualIDs.itemID`) store the item GUID
    ///   in `path`; their delta identifier is `"<workspaceID>/<itemGUID>"` (the
    ///   `.item` identifier form). An empty path is the item-listing root row,
    ///   which is never a delta item, so it returns `nil`.
    /// - Every other row is a real path and maps through ``identifierString``.
    internal static func tombstoneIdentifierString(workspaceID: String, itemID: String, path: String) -> String? {
        if workspaceID == VirtualIDs.workspaceID { return nil }
        if itemID == VirtualIDs.itemID { return path.isEmpty ? nil : "\(workspaceID)/\(path)" }
        return identifierString(workspaceID: workspaceID, itemID: itemID, path: path)
    }

    /// Deletes any tombstone shadowing `record`'s identifier, in `db`.
    ///
    /// A no-op when the record maps to no delta-visible identifier
    /// (``tombstoneIdentifierString(workspaceID:itemID:path:)`` returns `nil`).
    /// Called from within the same write transaction as the upsert so a
    /// re-created path never stays hidden behind its old tombstone.
    internal static func clearTombstone(_ db: Database, record: MetadataRecord) throws {
        guard let identStr = tombstoneIdentifierString(
            workspaceID: record.workspaceID,
            itemID: record.itemID,
            path: record.path
        ) else { return }
        try db.execute(sql: """
        DELETE FROM deletion_tombstones
        WHERE account_alias = ? AND identifier_string = ?
        """, arguments: [record.accountAlias, identStr])
    }
}
