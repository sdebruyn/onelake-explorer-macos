import Foundation
import GRDB
import os.log

// MARK: - CacheStore

/// Top-level façade for the OFEM metadata + blob cache.
///
/// `CacheStore` is a Swift `actor` that serialises all writes through a single
/// GRDB `DatabasePool`. Reads can proceed concurrently via GRDB's WAL snapshot
/// isolation; the ``reader`` property returns a `CacheReader` that any number
/// of tasks may query in parallel.
///
/// ## Directory layout
///
/// ```
/// <root>/
///   cache.sqlite        ← GRDB DatabasePool (WAL mode)
///   cache.sqlite-wal
///   cache.sqlite-shm
///   blobs/
///     <2-hex>/
///       <62-hex>        ← blob content
/// ```
///
/// ## Schema compatibility
///
/// Databases created by the Go daemon (`internal/cache/`, `cache.sqlite`) use
/// the same schema and blob layout. `CacheStore` detects Go-written databases
/// at open time and injects the GRDB migration markers so that subsequent opens
/// skip already-applied migrations without re-running DDL.
///
/// ## Mirrors
///
/// `internal/cache/cache.go` — `Cache`; `internal/cache/metadata.go`;
/// `internal/cache/blob.go`; `internal/cache/eviction.go`;
/// `internal/cache/workspace_status.go`.
public actor CacheStore {

    // MARK: - Constants

    /// Name of the SQLite file inside the root directory.
    public static let sqliteFile = "cache.sqlite"

    // MARK: - Private state

    // Internal so test targets can run direct SQL assertions.
    let dbPool: DatabasePool
    private let blobs: BlobShardCache
    private let maxBlobBytes: Int64

    private static let log = Logger(subsystem: "dev.debruyn.ofem", category: "CacheStore")

    // MARK: - Public state

    /// The root directory passed at construction time.
    public nonisolated let root: URL

    /// The blob root directory (`<root>/blobs`).
    public nonisolated let blobRoot: URL

    // MARK: - Initialiser

    /// Opens (or creates) the cache at `root`.
    ///
    /// - Parameters:
    ///   - root: Directory that holds `cache.sqlite` and `blobs/`. Created
    ///     with mode 0o700 if missing.
    ///   - maxBlobBytes: LRU eviction threshold for blob bytes. Zero = no
    ///     eviction (``evictToLimit()`` becomes a no-op).
    ///
    /// The database is opened in **WAL mode** with `synchronous = NORMAL` and
    /// a 5-second busy timeout — identical to the Go daemon's DSN pragmas.
    ///
    /// Mirrors `internal/cache/cache.go` — `Open`.
    public init(root: URL, maxBlobBytes: Int64 = 0) throws {
        self.root = root
        self.maxBlobBytes = maxBlobBytes

        // Create root directory.
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        // Initialise blob store.
        let blobRootURL = root.appendingPathComponent(BlobShardCache.blobsSubdir, isDirectory: true)
        blobs = try BlobShardCache(blobRoot: blobRootURL)
        blobRoot = blobRootURL

        // Open database pool.
        let dbURL = root.appendingPathComponent(CacheStore.sqliteFile)
        var config = Configuration()
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA journal_mode = WAL")
            try db.execute(sql: "PRAGMA synchronous = NORMAL")
            try db.execute(sql: "PRAGMA busy_timeout = 5000")
            try db.execute(sql: "PRAGMA foreign_keys = ON")
        }
        dbPool = try DatabasePool(path: dbURL.path, configuration: config)

        // Bootstrap: if this is a Go-written database, inject GRDB migration
        // markers before the migrator runs so it skips already-applied steps.
        try dbPool.write { db in
            try CacheSchema.applyIfGoDatabase(db)
        }

        // Apply any pending migrations.
        let m = CacheSchema.migrator()
        try m.migrate(dbPool)
    }

    // MARK: - Reader

    /// Returns a read-only view over the pool. Any number of tasks can hold
    /// a `CacheReader` simultaneously; reads never block writers (WAL snapshot
    /// isolation).
    public nonisolated func reader() -> CacheReader {
        CacheReader(db: dbPool)
    }

    // MARK: - Metadata: upsert

    /// Inserts or updates the metadata row for `record`.
    ///
    /// If `lastAccessedNs` or `syncedAtNs` are zero, the current wall-clock
    /// time is substituted so eviction and reconciliation always have a
    /// timestamp to work with.
    ///
    /// Mirrors `internal/cache/metadata.go` — `Cache.Put`.
    public func upsert(_ record: MetadataRecord) throws {
        var r = record
        let nowNs = currentNs()
        if r.lastAccessedNs == 0 { r.lastAccessedNs = nowNs }
        if r.syncedAtNs == 0 { r.syncedAtNs = nowNs }

        try dbPool.write { db in
            try db.execute(sql: """
                INSERT INTO path_metadata (
                    account_alias, workspace_id, item_id, path,
                    parent_path, name, is_dir,
                    content_length, etag, last_modified_ns, content_type,
                    blob_sha256, blob_size,
                    last_accessed_ns, synced_at_ns, children_synced_at_ns
                ) VALUES (
                    ?, ?, ?, ?,
                    ?, ?, ?,
                    ?, ?, ?, ?,
                    ?, ?,
                    ?, ?, ?
                )
                ON CONFLICT (account_alias, workspace_id, item_id, path) DO UPDATE SET
                    parent_path            = excluded.parent_path,
                    name                   = excluded.name,
                    is_dir                 = excluded.is_dir,
                    content_length         = excluded.content_length,
                    etag                   = excluded.etag,
                    last_modified_ns       = excluded.last_modified_ns,
                    content_type           = excluded.content_type,
                    blob_sha256            = excluded.blob_sha256,
                    blob_size              = excluded.blob_size,
                    last_accessed_ns       = excluded.last_accessed_ns,
                    synced_at_ns           = excluded.synced_at_ns,
                    children_synced_at_ns  = excluded.children_synced_at_ns
                """,
                arguments: [
                    r.accountAlias, r.workspaceID, r.itemID, r.path,
                    r.parentPath, r.name, r.isDir ? 1 : 0,
                    r.contentLength, r.etag, r.lastModifiedNs, r.contentType,
                    r.blobSHA256, r.blobSize,
                    r.lastAccessedNs, r.syncedAtNs, r.childrenSyncedAtNs,
                ]
            )
        }
    }

    // MARK: - Metadata: fetch

    /// Fetches the metadata row for `key`.
    ///
    /// Throws ``CacheError/notFound(_:)`` when the row does not exist.
    public func fetch(key: CacheKey) throws -> MetadataRecord {
        try validateKey(key)
        return try dbPool.read { db in
            guard let row = try MetadataRecord
                .filter(MetadataRecord.Columns.accountAlias == key.accountAlias)
                .filter(MetadataRecord.Columns.workspaceID == key.workspaceID)
                .filter(MetadataRecord.Columns.itemID == key.itemID)
                .filter(MetadataRecord.Columns.path == key.path)
                .fetchOne(db)
            else {
                throw CacheError.notFound(
                    "\(key.accountAlias)/\(key.workspaceID)/\(key.itemID)/\(key.path)"
                )
            }
            return row
        }
    }

    // MARK: - Metadata: children

    /// Returns every direct child of the directory identified by `key`.
    ///
    /// Mirrors `internal/cache/cache.go` — `Cache.Children`.
    public func children(of key: CacheKey) throws -> [MetadataRecord] {
        try validateKey(key)
        return try dbPool.read { db in
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

    // MARK: - Metadata: touch

    /// Bumps `last_accessed_ns` for `key` to the current time.
    ///
    /// Throws ``CacheError/notFound(_:)`` when the row does not exist.
    ///
    /// Mirrors `internal/cache/cache.go` — `Cache.Touch`.
    public func touch(key: CacheKey) throws {
        try validateKey(key)
        let nowNs = currentNs()
        let affected = try dbPool.write { db -> Int in
            try db.execute(sql: """
                UPDATE path_metadata
                SET last_accessed_ns = ?
                WHERE account_alias = ? AND workspace_id = ? AND item_id = ? AND path = ?
                """,
                arguments: [nowNs, key.accountAlias, key.workspaceID, key.itemID, key.path]
            )
            return db.changesCount
        }
        if affected == 0 {
            throw CacheError.notFound("\(key.accountAlias)/\(key.workspaceID)/\(key.itemID)/\(key.path)")
        }
    }

    // MARK: - Metadata: delete

    /// Removes the row for `key` and all its descendants (for directories).
    ///
    /// Blob files referenced exclusively by deleted rows are unlinked from disk.
    /// A no-op when the key does not exist.
    ///
    /// Mirrors `internal/cache/metadata.go` — `Cache.Delete`.
    public func delete(key: CacheKey) throws {
        try validateKey(key)

        // 1. Collect SHA-256 digests of blobs that will be deleted.
        let shas: [String] = try dbPool.write { db in
            let shaRows: [String]
            if key.path.isEmpty {
                shaRows = try String.fetchAll(db, sql: """
                    SELECT blob_sha256 FROM path_metadata
                    WHERE account_alias = ? AND workspace_id = ? AND item_id = ?
                      AND blob_sha256 != ''
                    """, arguments: [key.accountAlias, key.workspaceID, key.itemID])

                try db.execute(sql: """
                    DELETE FROM path_metadata
                    WHERE account_alias = ? AND workspace_id = ? AND item_id = ?
                    """, arguments: [key.accountAlias, key.workspaceID, key.itemID])
            } else {
                let escaped = escapeLike(key.path)
                shaRows = try String.fetchAll(db, sql: """
                    SELECT blob_sha256 FROM path_metadata
                    WHERE account_alias = ? AND workspace_id = ? AND item_id = ?
                      AND (path = ? OR path LIKE ? ESCAPE '\\')
                      AND blob_sha256 != ''
                    """, arguments: [
                        key.accountAlias, key.workspaceID, key.itemID,
                        key.path, escaped + "/%",
                    ])

                try db.execute(sql: """
                    DELETE FROM path_metadata
                    WHERE account_alias = ? AND workspace_id = ? AND item_id = ?
                      AND (path = ? OR path LIKE ? ESCAPE '\\')
                    """, arguments: [
                        key.accountAlias, key.workspaceID, key.itemID,
                        key.path, escaped + "/%",
                    ])
            }
            return shaRows
        }

        // 2. Unlink blob files that no surviving row references.
        let unique = Array(Set(shas))
        for sha in unique {
            maybeDeleteBlob(sha: sha)
        }
    }

    // MARK: - Metadata: hotItems

    /// Returns item roots that had at least one cache hit at or after `since`.
    ///
    /// Mirrors `internal/cache/cache.go` — `Cache.HotItems`.
    public func hotItems(since: Date) throws -> [CacheKey] {
        let sinceNs = dateToNs(since)
        return try dbPool.read { db in
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

    // MARK: - Blob: store

    /// Writes `data` to the blob store and updates the `blob_sha256` /
    /// `blob_size` columns on the metadata row identified by `key`.
    ///
    /// The metadata row must already exist (call ``upsert(_:)`` first).
    ///
    /// Mirrors the combined `StoreBlob` + `Put` pattern in the Go
    /// implementation.
    public func storeBlob(key: CacheKey, data: Data) throws {
        try validateKey(key)
        let (sha, size) = try blobs.store(data)

        // Update metadata row's blob columns.
        let affected = try dbPool.write { db -> Int in
            try db.execute(sql: """
                UPDATE path_metadata
                SET blob_sha256 = ?, blob_size = ?, last_accessed_ns = ?
                WHERE account_alias = ? AND workspace_id = ? AND item_id = ? AND path = ?
                """, arguments: [sha, size, currentNs(),
                                 key.accountAlias, key.workspaceID, key.itemID, key.path])
            return db.changesCount
        }
        if affected == 0 {
            // The blob was written to disk but no metadata row exists — surface
            // the error so the caller can upsert the row first. The orphaned
            // blob will be reclaimed by a subsequent eviction pass.
            throw CacheError.notFound(
                "\(key.accountAlias)/\(key.workspaceID)/\(key.itemID)/\(key.path)"
            )
        }
    }

    // MARK: - Blob: load

    /// Loads the cached blob for `key`, if one is stored.
    ///
    /// Throws ``CacheError/notFound(_:)`` when the metadata row has no blob or
    /// the blob file is missing from disk.
    public func loadBlob(key: CacheKey) throws -> Data {
        try validateKey(key)
        let record = try fetch(key: key)
        guard !record.blobSHA256.isEmpty else {
            throw CacheError.notFound("blob for \(key.path)")
        }
        // Touch last_accessed on blob read.
        try touch(key: key)
        return try blobs.load(sha256: record.blobSHA256)
    }

    // MARK: - Blob: blobBytes

    /// Returns the deduplicated on-disk byte total for all cached blobs.
    ///
    /// Mirrors `internal/cache/blob.go` — `Cache.BlobBytes`.
    public func blobBytes() throws -> Int64 {
        try dbPool.read { db in
            try Int64.fetchOne(db, sql: """
                SELECT COALESCE(SUM(blob_size), 0)
                FROM (
                    SELECT blob_size FROM path_metadata
                    WHERE blob_sha256 != ''
                    GROUP BY blob_sha256
                )
                """) ?? 0
        }
    }

    // MARK: - Blob: diskUsage

    /// Walks the blob root and returns the file count and total bytes on disk.
    ///
    /// Mirrors `internal/cache/blob.go` — `Cache.DiskUsage`.
    public func diskUsage() throws -> (count: Int, bytes: Int64) {
        try blobs.diskUsage()
    }

    // MARK: - Blob: wipe

    /// Clears all blob links in the metadata table and deletes all blob files.
    ///
    /// Metadata rows survive — the next access treats them as "not cached" and
    /// re-downloads the blob.
    ///
    /// Mirrors `internal/cache/blob.go` — `Cache.Wipe`.
    public func wipe() throws -> (count: Int, bytes: Int64) {
        let usage = try blobs.diskUsage()

        // Clear blob columns in one transaction.
        try dbPool.write { db in
            try db.execute(sql: """
                UPDATE path_metadata
                SET blob_sha256 = '', blob_size = 0
                WHERE blob_sha256 != ''
                """)
        }

        // Delete all blob files from disk.
        try blobs.wipeAll()

        Self.log.info("CacheStore: wiped blobs=\(usage.count, privacy: .public) bytes=\(usage.bytes, privacy: .public)")
        return usage
    }

    // MARK: - LRU eviction

    /// Deletes the least-recently-used blob-bearing rows until the total
    /// blob byte count is at or below `maxBlobBytes`.
    ///
    /// A no-op when `maxBlobBytes` is zero.
    ///
    /// Mirrors `internal/cache/eviction.go` — `Cache.EvictToLimit`.
    ///
    /// - Returns: `(evicted, reclaimed)` — number of rows cleared and bytes freed.
    public func evictToLimit() throws -> (evicted: Int, reclaimed: Int64) {
        guard maxBlobBytes > 0 else { return (0, 0) }

        var total = try blobBytes()
        if total <= maxBlobBytes { return (0, 0) }

        var evicted = 0
        var reclaimed: Int64 = 0

        while total > maxBlobBytes {
            guard let result = try evictOldest() else { break }
            evicted += 1
            if result.freed {
                reclaimed += result.size
                total -= result.size
            }
            Self.log.debug(
                "CacheStore: evicted sha=\(result.sha, privacy: .public) bytes=\(result.size, privacy: .public) freed=\(result.freed, privacy: .public)"
            )
        }
        return (evicted, reclaimed)
    }

    // MARK: - Workspace status

    /// Upserts the workspace status row.
    ///
    /// When the new state matches the persisted state, `detected_at_ns` is
    /// preserved (continuous pause). On a state change the new `detectedAtNs`
    /// is recorded.
    ///
    /// Mirrors `internal/cache/workspace_status.go` — `Cache.SetWorkspaceStatus`.
    public func setWorkspaceStatus(_ status: WorkspaceStatusRecord) throws {
        guard !status.accountAlias.isEmpty, !status.workspaceID.isEmpty else {
            throw CacheError.missingArgument("accountAlias and workspaceID")
        }

        try dbPool.write { db in
            // Read existing row to preserve detectedAtNs on same-state updates.
            let existing = try WorkspaceStatusRecord
                .filter(WorkspaceStatusRecord.Columns.accountAlias == status.accountAlias)
                .filter(WorkspaceStatusRecord.Columns.workspaceID == status.workspaceID)
                .fetchOne(db)

            var detectedNs = status.detectedAtNs
            if let ex = existing, ex.state == status.state, ex.detectedAtNs > 0 {
                detectedNs = ex.detectedAtNs
            }

            var probedNs = status.probedAtNs
            if probedNs == 0, let ex = existing {
                probedNs = ex.probedAtNs
            }

            try db.execute(sql: """
                INSERT INTO workspace_status
                    (account_alias, workspace_id, state, reason, detected_at_ns, probed_at_ns)
                VALUES (?, ?, ?, ?, ?, ?)
                ON CONFLICT (account_alias, workspace_id) DO UPDATE SET
                    state          = excluded.state,
                    reason         = excluded.reason,
                    detected_at_ns = excluded.detected_at_ns,
                    probed_at_ns   = excluded.probed_at_ns
                """, arguments: [
                    status.accountAlias, status.workspaceID,
                    status.state.rawValue, status.reason,
                    detectedNs, probedNs,
                ])
        }
    }

    /// Reads the persisted status for the given workspace.
    ///
    /// Throws ``CacheError/notFound(_:)`` when no row exists.
    ///
    /// Mirrors `internal/cache/workspace_status.go` — `Cache.GetWorkspaceStatus`.
    public func workspaceStatus(accountAlias: String, workspaceID: String) throws -> WorkspaceStatusRecord {
        guard !accountAlias.isEmpty, !workspaceID.isEmpty else {
            throw CacheError.missingArgument("accountAlias and workspaceID")
        }
        return try dbPool.read { db in
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
    ///
    /// Mirrors `internal/cache/workspace_status.go` — `Cache.ListWorkspaceStatuses`.
    public func allWorkspaceStatuses() throws -> [WorkspaceStatusRecord] {
        try dbPool.read { db in
            try WorkspaceStatusRecord
                .order(
                    WorkspaceStatusRecord.Columns.accountAlias,
                    WorkspaceStatusRecord.Columns.workspaceID
                )
                .fetchAll(db)
        }
    }

    // MARK: - Private helpers

    /// Evicts the single LRU blob-bearing row.
    ///
    /// Returns `nil` when no blob-bearing row remains.
    ///
    /// Mirrors `internal/cache/eviction.go` — `Cache.evictOldest`.
    private func evictOldest() throws -> (sha: String, size: Int64, freed: Bool)? {
        struct VictimResult {
            var accountAlias: String
            var workspaceID: String
            var itemID: String
            var path: String
            var sha: String
            var size: Int64
            var refs: Int64
        }

        let result: VictimResult? = try dbPool.write { db in
            // Select and clear atomically within a single write transaction.
            guard let row = try Row.fetchOne(db, sql: """
                SELECT account_alias, workspace_id, item_id, path, blob_sha256, blob_size
                FROM path_metadata
                WHERE blob_sha256 != ''
                ORDER BY last_accessed_ns ASC, rowid ASC
                LIMIT 1
                """) else { return nil }

            let alias: String = row["account_alias"]
            let wsID: String = row["workspace_id"]
            let iID: String = row["item_id"]
            let p: String = row["path"]
            let sha: String = row["blob_sha256"]
            let size: Int64 = row["blob_size"]

            try db.execute(sql: """
                UPDATE path_metadata
                SET blob_sha256 = '', blob_size = 0
                WHERE account_alias = ? AND workspace_id = ? AND item_id = ? AND path = ?
                """, arguments: [alias, wsID, iID, p])

            let refs = try Int64.fetchOne(db, sql: """
                SELECT COUNT(*) FROM path_metadata WHERE blob_sha256 = ?
                """, arguments: [sha]) ?? 0

            return VictimResult(
                accountAlias: alias, workspaceID: wsID, itemID: iID, path: p,
                sha: sha, size: size, refs: refs
            )
        }

        guard let v = result else { return nil }

        var freed = false
        if v.refs == 0 {
            freed = true
            try? blobs.delete(sha256: v.sha)
        }
        return (v.sha, v.size, freed)
    }

    /// Deletes the blob file for `sha` when no metadata row references it.
    ///
    /// Logs but does not throw — a leaked blob is recoverable by a later
    /// eviction pass. Mirrors `internal/cache/blob.go` — `Cache.maybeDeleteBlob`.
    private func maybeDeleteBlob(sha: String) {
        do {
            let refs = try dbPool.read { db in
                try Int64.fetchOne(db, sql: """
                    SELECT COUNT(*) FROM path_metadata WHERE blob_sha256 = ?
                    """, arguments: [sha]) ?? 0
            }
            if refs > 0 { return }
            try blobs.delete(sha256: sha)
        } catch {
            Self.log.warning("CacheStore: maybeDeleteBlob failed sha=\(sha, privacy: .public) error=\(error, privacy: .public)")
        }
    }
}

// MARK: - Validation helpers

/// Validates that `key` has all required non-empty components.
///
/// Mirrors `internal/cache/helpers.go` — `validateKey`.
func validateKey(_ key: CacheKey) throws {
    if key.accountAlias.isEmpty { throw CacheError.missingArgument("accountAlias") }
    if key.workspaceID.isEmpty { throw CacheError.missingArgument("workspaceID") }
    if key.itemID.isEmpty { throw CacheError.missingArgument("itemID") }
}

/// Returns the current time as Unix nanoseconds.
private func currentNs() -> Int64 {
    Int64(Date().timeIntervalSince1970 * 1_000_000_000)
}

/// Escapes SQL LIKE wildcards using `\` as the escape character.
///
/// Mirrors `internal/cache/helpers.go` — `escapeLike`.
private func escapeLike(_ s: String) -> String {
    s.replacingOccurrences(of: "\\", with: "\\\\")
     .replacingOccurrences(of: "%", with: "\\%")
     .replacingOccurrences(of: "_", with: "\\_")
}
