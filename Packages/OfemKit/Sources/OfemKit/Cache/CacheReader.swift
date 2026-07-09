import Foundation
import GRDB

// MARK: - CacheReader

/// Read-only view over the cache database.
///
/// `CacheReader` wraps a GRDB `DatabaseReader` and exposes only the queries
/// needed by the File Provider Extension enumerator. It holds no mutable
/// state and is safe to share across concurrent tasks.
///
/// In the final FPE wiring, the FPE receives a
/// `CacheReader` handle while the host-app-facing `CacheStore` retains the
/// write lock. For now `CacheStore` exposes its reader via ``CacheStore/reader``.
///
/// `CacheStore` read methods delegate here — there is exactly one copy of each
/// query.
public final class CacheReader: Sendable {
    private let db: any DatabaseReader
    private let logger: OfemLogger

    init(db: any DatabaseReader, logger: OfemLogger = .init()) {
        self.db = db
        self.logger = logger
    }

    // MARK: - Metadata reads

    /// Fetches the metadata row for `key`.
    ///
    /// Throws ``CacheError/notFound(_:)`` when the row does not exist.
    public func fetch(key: CacheKey) async throws -> MetadataRecord {
        try validateKey(key)
        do {
            let row = try await db.read { db -> MetadataRecord in
                guard let row = try MetadataRecord
                    .filter(MetadataRecord.Columns.accountAlias == key.accountAlias)
                    .filter(MetadataRecord.Columns.workspaceID == key.workspaceID)
                    .filter(MetadataRecord.Columns.itemID == key.itemID)
                    .filter(MetadataRecord.Columns.path == key.path)
                    .fetchOne(db)
                else {
                    // Redacted at the throw site: `CacheError` is `LocalizedError`
                    // AND directly interpolatable, so any raw path embedded here
                    // reaches every `.public` log of this error, at any call site,
                    // forever — not just the ones we've grepped for today.
                    throw CacheError.notFound(key.opaqueLogPrefix)
                }
                return row
            }
            if logger.isDebugEnabled {
                logger.debug("cache fetch", metadata: [
                    "result": "hit",
                    "accountAlias": key.accountAlias,
                    "workspaceID": key.workspaceID,
                    "itemID": key.itemID,
                    "pathSegments": "\(key.path.split(separator: "/", omittingEmptySubsequences: false).count)",
                ])
            }
            return row
        } catch let e as CacheError {
            if case .notFound = e, logger.isDebugEnabled {
                logger.debug("cache fetch", metadata: [
                    "result": "miss",
                    "accountAlias": key.accountAlias,
                    "workspaceID": key.workspaceID,
                    "itemID": key.itemID,
                    "pathSegments": "\(key.path.split(separator: "/", omittingEmptySubsequences: false).count)",
                ])
            }
            throw e
        }
    }

    /// Returns every direct child of the directory identified by `key`.
    ///
    /// Direct children are rows whose `parent_path` equals `key.path` within
    /// the same `(account_alias, workspace_id, item_id)` scope. The root
    /// row itself is excluded by requiring `path != parent_path`.
    ///
    /// Results are sorted directories-first, then by name ascending.
    public func children(of key: CacheKey) async throws -> [MetadataRecord] {
        try validateKey(key)
        return try await db.read { db in
            try MetadataRecord
                .filter(MetadataRecord.Columns.accountAlias == key.accountAlias)
                .filter(MetadataRecord.Columns.workspaceID == key.workspaceID)
                .filter(MetadataRecord.Columns.itemID == key.itemID)
                .filter(MetadataRecord.Columns.parentPath == key.path)
                .filter(MetadataRecord.Columns.path != MetadataRecord.Columns.parentPath)
                .order(
                    MetadataRecord.Columns.isDir.desc,
                    MetadataRecord.Columns.name.asc
                )
                .fetchAll(db)
        }
    }

    // MARK: - Metadata: subtree etags (bulk read)

    /// Returns the `subtree_etag` of each key in `keys` that has a row, keyed by
    /// ``CacheKey/stableKeyString``.
    ///
    /// Collapses what would otherwise be one read transaction (and one actor hop)
    /// per key into a SINGLE `db.read` snapshot wrapping N primary-key point
    /// lookups. ``SyncEngine/refreshMaterialized(alias:keys:concurrencyCap:)``
    /// uses it once for the pre-pass prior snapshot and once per depth wave for
    /// the post-parent-stamp current values (#380).
    ///
    /// A key is omitted from the result when it has no row, or when its
    /// `subtree_etag` is SQL NULL (`String.fetchOne` returns `nil` for NULL). A
    /// present, non-NULL value is returned as-is. The caller treats an absent key
    /// as an empty token (`""`), matching the previous per-key `fetch` plus `try?`
    /// path.
    ///
    /// Each lookup is wrapped in its own `try?` inside the shared read
    /// transaction so that a per-row DRIVER-level read failure (a corrupt page or
    /// an I/O fault — not a missing row) is isolated to that one key, dropped like
    /// a missing row rather than aborting the whole snapshot. This preserves the
    /// old per-key failure isolation while still using a single transaction. Such
    /// a fault cannot be provoked with crafted data — `String.fetchOne` resolves
    /// to the `sqlite3_column_text()` fast path, which coerces every non-NULL
    /// storage class (INTEGER/REAL/TEXT/BLOB) to text and only NULL yields `nil`,
    /// never a throw — so the `try?` has no dedicated regression test; it is
    /// purely defensive.
    ///
    /// ``validateKey(_:)`` is intentionally skipped: a malformed key simply
    /// matches no row here (there are no rows with empty key components), and
    /// throwing on one bad key would defeat the per-key isolation above.
    public func subtreeEtags(for keys: [CacheKey]) async throws -> [String: String] {
        guard !keys.isEmpty else { return [:] }
        return try await db.read { db in
            var result: [String: String] = [:]
            result.reserveCapacity(keys.count)
            for key in keys {
                // Per-key `try?`: a missing row or a NULL etag yields nil (this key
                // is omitted), and a per-row driver-level read failure is isolated
                // to this key rather than aborting the batch (see the method doc).
                if let etag = try? String.fetchOne(db, sql: """
                SELECT subtree_etag FROM path_metadata
                WHERE account_alias = ? AND workspace_id = ? AND item_id = ? AND path = ?
                """, arguments: [key.accountAlias, key.workspaceID, key.itemID, key.path]) {
                    result[key.stableKeyString] = etag
                }
            }
            return result
        }
    }

    /// Returns the distinct `(accountAlias, workspaceID, itemID)` triples for
    /// which at least one metadata row was accessed at or after `since`.
    public func hotItems(since: Date) async throws -> [CacheKey] {
        let sinceNs = dateToNs(since)
        return try await db.read { db in
            let rows = try Row.fetchAll(db, sql: """
            SELECT DISTINCT account_alias, workspace_id, item_id
            FROM path_metadata
            WHERE last_accessed_ns >= ? AND last_accessed_ns > 0
            ORDER BY account_alias, workspace_id, item_id
            """, arguments: [sinceNs])
            return rows.map { row in
                CacheKey(
                    accountAlias: row["account_alias"],
                    workspaceID: row["workspace_id"],
                    itemID: row["item_id"],
                    path: ""
                )
            }
        }
    }

    /// Returns the distinct `workspace_id` values present in `path_metadata`
    /// for `accountAlias`, excluding the ``VirtualIDs/workspaceID`` sentinel
    /// (the workspace-discovery row itself, not a real workspace).
    ///
    /// Used by ``SyncEngine/purgeRemovedWorkspaces(alias:seen:)`` to detect
    /// workspaces the cache still holds rows for that a fresh Fabric listing
    /// no longer reports.
    public func workspaceIDs(accountAlias: String) async throws -> [String] {
        guard !accountAlias.isEmpty else { throw CacheError.missingArgument("accountAlias") }
        return try await db.read { db in
            try String.fetchAll(db, sql: """
            SELECT DISTINCT workspace_id FROM path_metadata
            WHERE account_alias = ? AND workspace_id != ?
            """, arguments: [accountAlias, VirtualIDs.workspaceID])
        }
    }

    // MARK: - Workspace status reads

    /// Reads the persisted status for the given workspace.
    ///
    /// Throws ``CacheError/notFound(_:)`` when no row exists (treat as `.active`).
    public func workspaceStatus(accountAlias: String, workspaceID: String) async throws -> WorkspaceStatusRecord {
        guard !accountAlias.isEmpty, !workspaceID.isEmpty else {
            throw CacheError.missingArgument("accountAlias and workspaceID")
        }
        return try await db.read { db in
            guard let row = try WorkspaceStatusRecord
                .filter(WorkspaceStatusRecord.Columns.accountAlias == accountAlias)
                .filter(WorkspaceStatusRecord.Columns.workspaceID == workspaceID)
                .fetchOne(db)
            else {
                throw CacheError.notFound("workspace_status \(accountAlias)/\(workspaceID)")
            }
            return row
        }
    }

    /// Returns all persisted workspace status rows ordered by
    /// `(account_alias, workspace_id)`.
    public func allWorkspaceStatuses() async throws -> [WorkspaceStatusRecord] {
        try await db.read { db in
            try WorkspaceStatusRecord
                .order(
                    WorkspaceStatusRecord.Columns.accountAlias,
                    WorkspaceStatusRecord.Columns.workspaceID
                )
                .fetchAll(db)
        }
    }

    // MARK: - Sync anchor

    /// Returns the sync anchor for `accountAlias`: the maximum of the newest
    /// `synced_at_ns` in `path_metadata` and the newest `deleted_at_ns` in
    /// `deletion_tombstones`, or `0` when neither table has a row.
    ///
    /// Deletions must be part of the anchor. A poll that only removes rows bumps
    /// no `synced_at_ns`, so an anchor derived from `path_metadata` alone would
    /// not advance and `enumerateChanges` — which reads changes strictly after
    /// the caller's anchor — would strand the deletion until the next unrelated
    /// upsert. Folding `deleted_at_ns` in keeps the anchor moving on a pure
    /// deletion so the removal is delivered incrementally.
    public func syncAnchorNs(accountAlias: String) async throws -> Int64 {
        try await db.read { db in
            let sql = """
            SELECT MAX(
                (SELECT COALESCE(MAX(synced_at_ns), 0) FROM path_metadata WHERE account_alias = ?),
                (SELECT COALESCE(MAX(deleted_at_ns), 0) FROM deletion_tombstones WHERE account_alias = ?)
            )
            """
            return try Int64.fetchOne(db, sql: sql, arguments: [accountAlias, accountAlias]) ?? 0
        }
    }

    // MARK: - Tombstone purge watermark

    /// Returns the tombstone-purge watermark for `accountAlias` — the monotonic
    /// horizon (Unix ns) below which expired deletion tombstones have been
    /// TTL-purged by ``CacheStore/purgeExpiredTombstones(accountAlias:)`` — or `0`
    /// when the alias has no `sync_meta` row (never purged).
    ///
    /// The FPE lagging-client guard compares an incoming sync anchor against this
    /// value: a client whose anchor predates the horizon may have deletions that
    /// were purged and are now invisible in an incremental delta, so it must be
    /// forced into a full re-enumeration (`.syncAnchorExpired`).
    public func tombstonesPurgedThroughNs(accountAlias: String) async throws -> Int64 {
        try await db.read { db in
            try Int64.fetchOne(db, sql: """
            SELECT tombstones_purged_through_ns FROM sync_meta WHERE account_alias = ?
            """, arguments: [accountAlias]) ?? 0
        }
    }

    // MARK: - Changed items since anchor

    /// Returns items changed and deletions recorded after `ns` for `accountAlias`.
    ///
    /// - `updated`: metadata rows whose `synced_at_ns` is strictly greater than `ns`.
    /// - `deletedIdentifierStrings`: identifier strings from `deletion_tombstones`
    ///   whose `deleted_at_ns` is strictly greater than `ns`.
    ///
    /// The two sets are reconciled by timestamp before returning so a stale
    /// tombstone and a live row for the same identifier never both surface: if a
    /// live row is at least as fresh as its tombstone (`syncedAtNs >=
    /// deletedAtNs` — ties go to the live row), the tombstone is dropped and the
    /// row is emitted as an update; otherwise the deletion is newer and the row
    /// is dropped from `updated`. This mirrors the recreate-clears-tombstone
    /// write path and defends the read side against any residual overlap.
    ///
    /// Used by `enumerateChanges` so the FPE can call both `didUpdate` and
    /// `didDeleteItems(withIdentifiers:)` in a single delta pass.
    public func itemsChangedAfter(
        accountAlias: String,
        ns: Int64
    ) async throws -> (updated: [MetadataRecord], deletedIdentifierStrings: [String]) {
        let result = try await db.read { db -> (updated: [MetadataRecord], deletedIdentifierStrings: [String]) in
            let updatedRaw = try MetadataRecord
                .filter(MetadataRecord.Columns.accountAlias == accountAlias)
                .filter(MetadataRecord.Columns.syncedAtNs > ns)
                .fetchAll(db)

            // Fetch tombstones with their timestamps so we can reconcile against
            // the live rows. The PK (account_alias, identifier_string) makes each
            // identifier unique, so one deleted_at_ns per identifier.
            let tombstoneRows = try Row.fetchAll(db, sql: """
            SELECT identifier_string, deleted_at_ns FROM deletion_tombstones
            WHERE account_alias = ? AND deleted_at_ns > ?
            """, arguments: [accountAlias, ns])
            var tombstoneNsByIdent: [String: Int64] = [:]
            for row in tombstoneRows {
                let ident: String = row["identifier_string"]
                let deletedNs: Int64 = row["deleted_at_ns"]
                tombstoneNsByIdent[ident] = deletedNs
            }

            var suppressedIdents: Set<String> = []
            var updated: [MetadataRecord] = []
            updated.reserveCapacity(updatedRaw.count)
            for record in updatedRaw {
                guard let ident = CacheStore.tombstoneIdentifierString(
                    workspaceID: record.workspaceID,
                    itemID: record.itemID,
                    path: record.path
                ), let deletedNs = tombstoneNsByIdent[ident] else {
                    // No overlapping tombstone → a genuine update.
                    updated.append(record)
                    continue
                }
                if record.syncedAtNs >= deletedNs {
                    // Live row wins (ties included): emit as update, drop the tombstone.
                    updated.append(record)
                    suppressedIdents.insert(ident)
                }
                // else: the tombstone is newer → the deletion wins; drop the
                // updated record and let the tombstone surface below.
            }

            let deleted = tombstoneRows
                .map { row -> String in row["identifier_string"] }
                .filter { !suppressedIdents.contains($0) }

            return (updated, deleted)
        }
        logger.debug("cache changes", metadata: [
            "updated": "\(result.updated.count)",
            "deleted": "\(result.deletedIdentifierStrings.count)",
            "sinceNs": "\(ns)",
        ])
        return result
    }

    // MARK: - Materialized containers

    /// Returns the materialized-container set for `alias` as ``CacheKey`` values.
    ///
    /// Queries `materialized_containers`, parses each `identifier_string` back
    /// to an ``ItemIdentifier`` via ``ItemIdentifierParser``, and maps directory-
    /// bearing cases (`.item`, `.path`) to a ``CacheKey``. Workspace-level
    /// identifiers (`.workspace`) map to a ``CacheKey`` with
    /// ``VirtualIDs/itemID`` as the item component so the freshness poller can
    /// address the workspace's item listing. That container is refreshed via the
    /// Fabric item listing (``SyncEngine/refreshMaterializedContainer(key:)``
    /// routes the `VirtualIDs.itemID` sentinel to `refreshItemListing`), so new
    /// items in an open workspace now appear incrementally rather than only on
    /// re-navigation.
    ///
    /// Identifiers that cannot be parsed or that are not directory containers
    /// (`.root`, `.trash`, `.workingSet`) are silently skipped — the same
    /// tolerant policy applied throughout the FPE enumerate paths.
    ///
    /// - Parameter alias: The account alias (non-empty).
    /// - Returns: The set of ``CacheKey`` values for each known-good materialized
    ///   container, in unspecified order.
    public func materializedContainers(alias: String) async throws -> [CacheKey] {
        let rows = try await db.read { db in
            try MaterializedContainerRecord
                .filter(MaterializedContainerRecord.Columns.accountAlias == alias)
                .fetchAll(db)
        }
        var keys: [CacheKey] = []
        keys.reserveCapacity(rows.count)
        for row in rows {
            guard let key = Self.cacheKey(alias: alias, identifierString: row.identifierString) else {
                logger.debug("materializedContainers: skip unresolvable identifier", metadata: [
                    "accountAlias": alias,
                    "identifierString": row.identifierString,
                ])
                continue
            }
            keys.append(key)
        }
        return keys
    }

    /// Parses `identifierString` to a ``CacheKey`` for directory containers.
    ///
    /// Returns `nil` for sentinels (`.root`, `.trash`, `.workingSet`) and for
    /// identifiers that fail to parse. `.workspace` identifiers are mapped to
    /// the workspace's item-listing container (``VirtualIDs/itemID``).
    private static func cacheKey(alias: String, identifierString: String) -> CacheKey? {
        guard let parsed = try? ItemIdentifierParser.parse(identifierString) else {
            return nil
        }
        switch parsed {
        case .root, .trash, .workingSet:
            return nil
        case let .workspace(workspaceID):
            // The workspace's item listing is stored under VirtualIDs.itemID.
            return CacheKey(
                accountAlias: alias,
                workspaceID: workspaceID,
                itemID: VirtualIDs.itemID,
                path: ""
            )
        case let .item(workspaceID, itemID):
            return CacheKey(accountAlias: alias, workspaceID: workspaceID, itemID: itemID, path: "")
        case let .path(workspaceID, itemID, path):
            return CacheKey(accountAlias: alias, workspaceID: workspaceID, itemID: itemID, path: path)
        }
    }

    // MARK: - Blob byte totals

    /// Returns the sum of `blob_size` across distinct `blob_sha256` values.
    ///
    /// Counts each unique blob once, regardless of how many metadata rows
    /// reference it — matching the Go implementation's `BlobBytes` semantics.
    public func blobBytes() async throws -> Int64 {
        try await db.read { db in
            try Int64.fetchOne(db, sql: Self.deduplicatedBlobBytesSQL) ?? 0
        }
    }

    // MARK: - Shared SQL fragments

    /// SQL that sums blob_size once per distinct SHA-256, used by both
    /// `blobBytes()` and `wipe()` so the dedup semantics live in one place.
    static let deduplicatedBlobBytesSQL = """
    SELECT COALESCE(SUM(blob_size), 0)
    FROM (
        SELECT blob_size FROM path_metadata
        WHERE blob_sha256 != ''
        GROUP BY blob_sha256
    )
    """
}
