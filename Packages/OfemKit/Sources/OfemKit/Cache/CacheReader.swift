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
public final class CacheReader: Sendable {

    private let db: any DatabaseReader

    init(db: any DatabaseReader) {
        self.db = db
    }

    // MARK: - Metadata reads

    /// Fetches the metadata row for `key`.
    ///
    /// Throws ``CacheError/notFound(_:)`` when the row does not exist.
    public func fetch(key: CacheKey) async throws -> MetadataRecord {
        try validateKey(key)
        return try await db.read { db in
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
    }

    /// Returns every direct child of the directory identified by `key`.
    ///
    /// Direct children are rows whose `parent_path` equals `key.path` within
    /// the same `(account_alias, workspace_id, item_id)` scope. The root
    /// row itself is excluded via `path <> parent_path` (matching the Go query).
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
                .filter(sql: "path <> parent_path")
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

    // MARK: - Blob byte totals

    /// Returns the sum of `blob_size` across distinct `blob_sha256` values.
    ///
    /// Counts each unique blob once, regardless of how many metadata rows
    /// reference it — matching the Go implementation's `BlobBytes` semantics.
    public func blobBytes() async throws -> Int64 {
        try await db.read { db in
            let sql = """
                SELECT COALESCE(SUM(blob_size), 0)
                FROM (
                    SELECT blob_size FROM path_metadata
                    WHERE blob_sha256 != ''
                    GROUP BY blob_sha256
                )
                """
            return try Int64.fetchOne(db, sql: sql) ?? 0
        }
    }
}
