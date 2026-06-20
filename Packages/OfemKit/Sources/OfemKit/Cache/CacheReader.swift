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
                    throw CacheError.notFound("\(key.accountAlias)/\(key.workspaceID)/\(key.itemID)/\(key.path)")
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

    /// Returns the maximum `synced_at_ns` value across all rows for the given
    /// `accountAlias`, or `0` when there are no rows.
    ///
    /// Used to compute a real sync anchor: whenever a new `upsert` bumps
    /// `syncedAtNs`, this value increases, making the anchor non-constant and
    /// allowing `enumerateChanges` to return real deltas rather than always
    /// throwing `.syncAnchorExpired`.
    public func maxSyncedAtNs(accountAlias: String) async throws -> Int64 {
        try await db.read { db in
            let sql = """
                SELECT COALESCE(MAX(synced_at_ns), 0)
                FROM path_metadata
                WHERE account_alias = ?
                """
            return try Int64.fetchOne(db, sql: sql, arguments: [accountAlias]) ?? 0
        }
    }

    // MARK: - Changed items since anchor

    /// Returns items changed and deletions recorded after `ns` for `accountAlias`.
    ///
    /// - `updated`: metadata rows whose `synced_at_ns` is strictly greater than `ns`.
    /// - `deletedIdentifierStrings`: identifier strings from `deletion_tombstones`
    ///   whose `deleted_at_ns` is strictly greater than `ns`.
    ///
    /// Used by `enumerateChanges` so the FPE can call both `didUpdate` and
    /// `didDeleteItems(withIdentifiers:)` in a single delta pass.
    public func itemsChangedAfter(
        accountAlias: String,
        ns: Int64
    ) async throws -> (updated: [MetadataRecord], deletedIdentifierStrings: [String]) {
        let result = try await db.read { db -> (updated: [MetadataRecord], deletedIdentifierStrings: [String]) in
            let updated = try MetadataRecord
                .filter(MetadataRecord.Columns.accountAlias == accountAlias)
                .filter(MetadataRecord.Columns.syncedAtNs > ns)
                .fetchAll(db)

            let deleted = try String.fetchAll(db, sql: """
                SELECT identifier_string FROM deletion_tombstones
                WHERE account_alias = ? AND deleted_at_ns > ?
                """, arguments: [accountAlias, ns])

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
    /// address the workspace's item listing.
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
