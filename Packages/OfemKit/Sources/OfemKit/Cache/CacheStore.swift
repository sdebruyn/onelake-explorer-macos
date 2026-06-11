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
/// cache.sqlite ← GRDB DatabasePool (WAL mode)
/// cache.sqlite-wal
/// cache.sqlite-shm
/// blobs/
/// <2-hex>/
/// <62-hex> ← blob content
/// ```
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
    /// - root: Directory that holds `cache.sqlite` and `blobs/`. Created
    /// with mode 0o700 if missing.
    /// - maxBlobBytes: LRU eviction threshold for blob bytes. Zero = no
    /// eviction (``evictToLimit()`` becomes a no-op).
    ///
    /// The database is opened in **WAL mode** with `synchronous = NORMAL` and
    /// a 5-second busy timeout. An orphan-sweep runs at initialisation time to
    /// remove any blob files that have no matching metadata row.
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

        // Apply any pending migrations.
        let m = CacheSchema.migrator()
        try m.migrate(dbPool)

        // Remove orphaned blob files (files on disk with no DB reference).
        try Self.sweepOrphanBlobs(blobs: blobs, dbPool: dbPool)
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
    public func upsert(_ record: MetadataRecord) async throws {
        try validateKey(CacheKey(
            accountAlias: record.accountAlias,
            workspaceID: record.workspaceID,
            itemID: record.itemID,
            path: record.path
        ))
        var r = record
        let nowNs = currentNs()
        if r.lastAccessedNs == 0 { r.lastAccessedNs = nowNs }
        if r.syncedAtNs == 0 { r.syncedAtNs = nowNs }

        let frozen = r
        try await dbPool.write { db in
            try frozen.upsert(db)
        }
    }

    // MARK: - Metadata: fetch

    /// Fetches the metadata row for `key`.
    ///
    /// Throws ``CacheError/notFound(_:)`` when the row does not exist.
    public func fetch(key: CacheKey) async throws -> MetadataRecord {
        try await reader().fetch(key: key)
    }

    // MARK: - Metadata: children

    /// Returns every direct child of the directory identified by `key`.
    public func children(of key: CacheKey) async throws -> [MetadataRecord] {
        try await reader().children(of: key)
    }

    // MARK: - Metadata: touch

    /// Bumps `last_accessed_ns` for `key` to the current time.
    ///
    /// Throws ``CacheError/notFound(_:)`` when the row does not exist.
    public func touch(key: CacheKey) async throws {
        try validateKey(key)
        let nowNs = currentNs()
        let affected = try await dbPool.write { db -> Int in
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
    public func delete(key: CacheKey) async throws {
        try validateKey(key)

        // 1. Collect SHA-256 digests of blobs that will be deleted.
        let shas: [String] = try await dbPool.write { db in
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
            await maybeDeleteBlob(sha: sha)
        }
    }

    // MARK: - Metadata: hotItems

    /// Returns item roots that had at least one cache hit at or after `since`.
    public func hotItems(since: Date) async throws -> [CacheKey] {
        try await reader().hotItems(since: since)
    }

    // MARK: - Blob: store

    /// Writes `data` to the blob store and updates the `blob_sha256` /
    /// `blob_size` columns on the metadata row identified by `key`.
    ///
    /// The metadata row must already exist (call ``upsert(_:)`` first).
    /// After each write the byte budget is enforced: if the total exceeds
    /// `maxBlobBytes`, ``evictToLimit()`` runs automatically.
    public func storeBlob(key: CacheKey, data: Data) async throws {
        try validateKey(key)
        let (sha, size) = try blobs.store(data)

        // Update metadata row's blob columns.
        let affected = try await dbPool.write { db -> Int in
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
            // blob will be reclaimed by the next eviction pass or init sweep.
            throw CacheError.notFound(
                "\(key.accountAlias)/\(key.workspaceID)/\(key.itemID)/\(key.path)"
            )
        }

        // Enforce the byte budget after every successful write.
        if maxBlobBytes > 0 {
            let total = try await blobBytes()
            if total > maxBlobBytes {
                _ = try await evictToLimit()
            }
        }
    }

    // MARK: - Blob: load

    /// Loads the cached blob for `key`, if one is stored.
    ///
    /// Throws ``CacheError/notFound(_:)`` when the metadata row has no blob or
    /// the blob file is missing from disk. When the file is missing but the
    /// metadata row still carries a `blob_sha256` reference, the dangling link
    /// is cleared so `blobBytes()` stays accurate.
    public func loadBlob(key: CacheKey) async throws -> Data {
        try validateKey(key)
        let record = try await fetch(key: key)
        guard !record.blobSHA256.isEmpty else {
            throw CacheError.notFound("blob for \(key.path)")
        }
        // Touch last_accessed on blob read.
        try await touch(key: key)
        do {
            return try blobs.load(sha256: record.blobSHA256)
        } catch CacheError.notFound {
            // File gone from disk — clear the dangling link so blobBytes() is truthful.
            try await clearBlobLink(key: key)
            throw CacheError.notFound("blob for \(key.path)")
        }
    }

    // MARK: - Blob: blobBytes

    /// Returns the deduplicated on-disk byte total for all cached blobs.
    public func blobBytes() async throws -> Int64 {
        try await reader().blobBytes()
    }

    // MARK: - Blob: diskUsage

    /// Walks the blob root and returns the file count and total bytes on disk.
    public func diskUsage() async throws -> (count: Int, bytes: Int64) {
        try blobs.diskUsage()
    }

    // MARK: - Blob: wipe

    /// Clears all blob links in the metadata table and deletes all blob files.
    ///
    /// Metadata rows survive — the next access treats them as "not cached" and
    /// re-downloads the blob.
    public func wipe() async throws -> (count: Int, bytes: Int64) {
        let usage = try blobs.diskUsage()

        // Clear blob columns in one transaction.
        try await dbPool.write { db in
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
    /// - Returns: `(evicted, reclaimed)` — number of rows cleared and bytes freed.
    public func evictToLimit() async throws -> (evicted: Int, reclaimed: Int64) {
        guard maxBlobBytes > 0 else { return (0, 0) }

        var total = try await blobBytes()
        if total <= maxBlobBytes { return (0, 0) }

        var evicted = 0
        var reclaimed: Int64 = 0

        while total > maxBlobBytes {
            guard let result = try await evictOldest() else { break }
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
    public func setWorkspaceStatus(_ status: WorkspaceStatusRecord) async throws {
        guard !status.accountAlias.isEmpty, !status.workspaceID.isEmpty else {
            throw CacheError.missingArgument("accountAlias and workspaceID")
        }

        try await dbPool.write { db in
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

            var row = status
            row.detectedAtNs = detectedNs
            row.probedAtNs = probedNs
            try row.upsert(db)
        }
    }

    /// Reads the persisted status for the given workspace.
    ///
    /// Throws ``CacheError/notFound(_:)`` when no row exists.
    public func workspaceStatus(accountAlias: String, workspaceID: String) async throws -> WorkspaceStatusRecord {
        try await reader().workspaceStatus(accountAlias: accountAlias, workspaceID: workspaceID)
    }

    /// Returns all persisted workspace status rows ordered by
    /// `(account_alias, workspace_id)`.
    public func allWorkspaceStatuses() async throws -> [WorkspaceStatusRecord] {
        try await reader().allWorkspaceStatuses()
    }

    /// Returns only the workspace status rows whose state is `.paused`,
    /// ordered by `(account_alias, workspace_id)`.
    ///
    /// Used by the menu-bar host to build the paused-workspaces badge.
    public func listPausedWorkspaces() async throws -> [WorkspaceStatusRecord] {
        try await dbPool.read { db in
            try WorkspaceStatusRecord
                .filter(WorkspaceStatusRecord.Columns.state == WorkspaceStatusRecord.State.paused.rawValue)
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
    private func evictOldest() async throws -> (sha: String, size: Int64, freed: Bool)? {
        struct VictimResult {
            var accountAlias: String
            var workspaceID: String
            var itemID: String
            var path: String
            var sha: String
            var size: Int64
            var refs: Int64
        }

        let result: VictimResult? = try await dbPool.write { db in
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
    /// eviction pass.
    private func maybeDeleteBlob(sha: String) async {
        do {
            let refs = try await dbPool.read { db in
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

    /// Clears the `blob_sha256` and `blob_size` columns for `key`, healing a
    /// dangling metadata link when the blob file has been removed from disk.
    private func clearBlobLink(key: CacheKey) async throws {
        try await dbPool.write { db in
            try db.execute(sql: """
                UPDATE path_metadata
                SET blob_sha256 = '', blob_size = 0
                WHERE account_alias = ? AND workspace_id = ? AND item_id = ? AND path = ?
                """, arguments: [key.accountAlias, key.workspaceID, key.itemID, key.path])
        }
    }

    /// Removes blob files on disk that have no corresponding metadata row.
    ///
    /// Called once at initialisation time to reconcile shard-dir contents
    /// against DB references and eliminate files orphaned by prior crashes
    /// or bugs.
    private static func sweepOrphanBlobs(blobs: BlobShardCache, dbPool: DatabasePool) throws {
        // Walk the blob root and collect all SHA-256 values present on disk.
        guard FileManager.default.fileExists(atPath: blobs.blobRoot.path) else { return }

        let enumerator = FileManager.default.enumerator(
            at: blobs.blobRoot,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        var onDisk: [String] = []
        while let url = enumerator?.nextObject() as? URL {
            guard url.pathExtension != "tmp" else { continue }
            guard let vals = try? url.resourceValues(forKeys: [.isRegularFileKey]),
                  vals.isRegularFile == true else { continue }
            // Reconstruct SHA from shard-prefix + filename.
            let shard = url.deletingLastPathComponent().lastPathComponent
            let file = url.lastPathComponent
            let sha = shard + file
            guard sha.count == BlobShardCache.shaLength else { continue }
            onDisk.append(sha)
        }

        guard !onDisk.isEmpty else { return }

        // Ask the DB which of those are actually referenced.
        let referenced: Set<String> = try dbPool.read { db in
            let rows = try String.fetchAll(db, sql: """
                SELECT DISTINCT blob_sha256 FROM path_metadata WHERE blob_sha256 != ''
                """)
            return Set(rows)
        }

        for sha in onDisk where !referenced.contains(sha) {
            try? blobs.delete(sha256: sha)
        }
    }
}

// MARK: - Validation helpers

/// Validates that `key` has all required non-empty components.
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
private func escapeLike(_ s: String) -> String {
    s.replacingOccurrences(of: "\\", with: "\\\\")
     .replacingOccurrences(of: "%", with: "\\%")
     .replacingOccurrences(of: "_", with: "\\_")
}
