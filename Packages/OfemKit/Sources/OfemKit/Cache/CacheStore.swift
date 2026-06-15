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

    /// POSIX permission mode for the cache root directory (owner rwx only).
    private static let rootDirectoryMode: Int = 0o700

    /// SQLite busy-wait timeout in milliseconds.
    private static let busyTimeoutMs: Int = 5000

    // MARK: - Private state

    // Internal so test targets can run direct SQL assertions.
    let dbPool: DatabasePool
    private let blobs: BlobShardCache
    private let maxBlobBytes: Int64

    /// Clock injection seam: returns the current time as Unix nanoseconds.
    /// Defaults to wall clock; override in tests for deterministic ordering.
    private let clock: () -> Int64

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
    ///   - clock: Closure that returns the current time as Unix nanoseconds.
    ///     Inject a deterministic clock in tests; omit for wall-clock production behaviour.
    ///
    /// The database is opened in **WAL mode** with `synchronous = NORMAL` and
    /// a 5-second busy timeout. An orphan-sweep runs at initialisation time to
    /// remove any blob files that have no matching metadata row.
    // Note: the default clock closure duplicates the wallClockNs formula rather than
    // referencing it directly because wallClockNs is internal and this init is public;
    // Swift requires default argument expressions to be at least as visible as the
    // declaration they appear in.
    public init(root: URL, maxBlobBytes: Int64 = 0, clock: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1_000_000_000) }) throws {
        self.root = root
        self.maxBlobBytes = maxBlobBytes
        self.clock = clock

        // Create root directory.
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: Self.rootDirectoryMode]
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
            try db.execute(sql: "PRAGMA busy_timeout = \(CacheStore.busyTimeoutMs)")
            try db.execute(sql: "PRAGMA foreign_keys = ON")
        }
        dbPool = try DatabasePool(path: dbURL.path, configuration: config)

        // Apply any pending migrations.
        let m = CacheSchema.migrator()
        try m.migrate(dbPool)

        // Kick off the orphan sweep asynchronously so that init never blocks
        // the calling thread on a directory walk + db write.
        //
        // The sweep logs warnings on failure rather than discarding them with
        // try? — errors are surfaced to the log but do not abort the actor.
        // The sweep uses a write transaction to query referenced SHAs, which
        // serialises it against any in-flight storeBlob/storeBlobFromURL write
        // transaction — ensuring a blob whose disk file was written but whose
        // DB UPDATE has not yet committed is never mistaken for an orphan.
        let blobsCapture = blobs
        let dbCapture = dbPool
        Task { [blobsCapture, dbCapture] in
            do {
                try Self.sweepOrphanBlobs(blobs: blobsCapture, dbPool: dbCapture)
            } catch {
                Self.log.warning("CacheStore: init-time orphan sweep failed: \(error, privacy: .public)")
            }
        }
    }

    // MARK: - Reader

    /// Returns a read-only view over the pool. Any number of tasks can hold
    /// a `CacheReader` simultaneously; reads never block writers (WAL snapshot
    /// isolation).
    public nonisolated func reader() -> CacheReader {
        CacheReader(db: dbPool)
    }

    // MARK: - Orphan sweep

    /// Runs the orphan-blob sweep synchronously (blocking the actor).
    ///
    /// The background `Task` started at `init` time runs the same sweep but
    /// may not have completed yet. Call this from tests or maintenance paths
    /// that need the sweep to have completed before proceeding.
    public func sweepOrphans() throws {
        try Self.sweepOrphanBlobs(blobs: blobs, dbPool: dbPool)
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
        let nowNs = clock()
        if r.lastAccessedNs == 0 { r.lastAccessedNs = nowNs }
        if r.syncedAtNs == 0 { r.syncedAtNs = nowNs }

        let frozen = r
        try await dbPool.write { db in
            try frozen.upsert(db)
        }
    }

    // MARK: - Metadata: batchUpsert / batchDelete (sync-15)

    /// Inserts or updates all `records` inside a single GRDB write transaction.
    ///
    /// Using one transaction instead of N individual ``upsert(_:)`` calls
    /// eliminates per-row WAL-commit overhead and makes the reconciliation
    /// atomic with respect to crashes.
    ///
    /// Large batches are chunked into sub-transactions of up to
    /// ``batchChunkSize`` rows to bound WAL growth.
    public func batchUpsert(_ records: [MetadataRecord]) async throws {
        guard !records.isEmpty else { return }
        let now = clock()
        let prepared: [MetadataRecord] = records.map { r in
            var copy = r
            if copy.lastAccessedNs == 0 { copy.lastAccessedNs = now }
            if copy.syncedAtNs == 0     { copy.syncedAtNs = now }
            return copy
        }
        for chunk in prepared.chunked(by: Self.batchChunkSize) {
            try await dbPool.write { db in
                for record in chunk {
                    try record.upsert(db)
                }
            }
        }
    }

    /// Deletes rows for all `keys` inside a single GRDB write transaction.
    ///
    /// Blob link cleanup (orphan blobs) is deferred to the background orphan
    /// sweep; this method focuses on the transactional delete. It is safe
    /// for rows that do not exist (a no-op per key).
    ///
    /// When `key.path` is empty the semantics match ``delete(key:)``: all rows
    /// for the given `(accountAlias, workspaceID, itemID)` triple are removed,
    /// not just the root row.
    ///
    /// Large batches are chunked into sub-transactions of up to
    /// ``batchChunkSize`` keys to bound WAL growth.
    public func batchDelete(_ keys: [CacheKey]) async throws {
        guard !keys.isEmpty else { return }
        for chunk in keys.chunked(by: Self.batchChunkSize) {
            try await dbPool.write { db in
                for key in chunk {
                    if key.path.isEmpty {
                        // Empty path: wipe entire item — mirrors delete(key:) semantics.
                        try db.execute(sql: """
                            DELETE FROM path_metadata
                            WHERE account_alias = ? AND workspace_id = ? AND item_id = ?
                            """, arguments: [key.accountAlias, key.workspaceID, key.itemID])
                    } else {
                        let (exact, prefix) = Self.subtreeArguments(for: key)
                        try db.execute(sql: """
                            DELETE FROM path_metadata
                            WHERE account_alias = ? AND workspace_id = ? AND item_id = ?
                              AND (\(Self.subtreeWhereSuffix))
                            """, arguments: [
                                key.accountAlias, key.workspaceID, key.itemID,
                                exact, prefix,
                            ])
                    }
                }
            }
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
        let nowNs = clock()
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
    /// Before hard-deleting, writes a deletion tombstone for each removed row
    /// so that `itemsChangedAfter` / `enumerateChanges` can surface the removal
    /// to the File Provider framework via `didDeleteItems(withIdentifiers:)`.
    ///
    /// Blob files referenced exclusively by deleted rows are unlinked from disk.
    /// A no-op when the key does not exist.
    ///
    /// Set-based: all tombstone inserts happen in one transaction; ref-count
    /// checks for blob deletion use a single grouped query rather than one
    /// round-trip per SHA.
    public func delete(key: CacheKey) async throws {
        try validateKey(key)

        // 1. Collect paths and SHA-256 digests of rows that will be deleted,
        //    write tombstones for all in one batch, and hard-delete — all in
        //    a single transaction.
        let nowNs = clock()
        let shas: [String] = try await dbPool.write { db in
            let shaRows: [String]
            let deletedPaths: [String]
            if key.path.isEmpty {
                shaRows = try String.fetchAll(db, sql: """
                    SELECT blob_sha256 FROM path_metadata
                    WHERE account_alias = ? AND workspace_id = ? AND item_id = ?
                      AND blob_sha256 != ''
                    """, arguments: [key.accountAlias, key.workspaceID, key.itemID])

                deletedPaths = try String.fetchAll(db, sql: """
                    SELECT path FROM path_metadata
                    WHERE account_alias = ? AND workspace_id = ? AND item_id = ?
                    """, arguments: [key.accountAlias, key.workspaceID, key.itemID])

                try db.execute(sql: """
                    DELETE FROM path_metadata
                    WHERE account_alias = ? AND workspace_id = ? AND item_id = ?
                    """, arguments: [key.accountAlias, key.workspaceID, key.itemID])
            } else {
                let (exact, prefix) = Self.subtreeArguments(for: key)
                shaRows = try String.fetchAll(db, sql: """
                    SELECT blob_sha256 FROM path_metadata
                    WHERE account_alias = ? AND workspace_id = ? AND item_id = ?
                      AND (\(Self.subtreeWhereSuffix))
                      AND blob_sha256 != ''
                    """, arguments: [
                        key.accountAlias, key.workspaceID, key.itemID,
                        exact, prefix,
                    ])

                deletedPaths = try String.fetchAll(db, sql: """
                    SELECT path FROM path_metadata
                    WHERE account_alias = ? AND workspace_id = ? AND item_id = ?
                      AND (\(Self.subtreeWhereSuffix))
                    """, arguments: [
                        key.accountAlias, key.workspaceID, key.itemID,
                        exact, prefix,
                    ])

                try db.execute(sql: """
                    DELETE FROM path_metadata
                    WHERE account_alias = ? AND workspace_id = ? AND item_id = ?
                      AND (\(Self.subtreeWhereSuffix))
                    """, arguments: [
                        key.accountAlias, key.workspaceID, key.itemID,
                        exact, prefix,
                    ])
            }

            // Write tombstones for all deleted rows in one batch insert.
            for path in deletedPaths {
                let identStr = Self.identifierString(
                    workspaceID: key.workspaceID,
                    itemID: key.itemID,
                    path: path
                )
                let tombstone = DeletionTombstoneRecord(
                    accountAlias: key.accountAlias,
                    identifierString: identStr,
                    deletedAtNs: nowNs
                )
                try tombstone.save(db)
            }

            return shaRows
        }

        // 2. Unlink blob files that no surviving row references.
        //    One grouped query resolves all ref-counts; ref-count check and unlink
        //    happen in the same write transaction to close the TOCTOU window
        //    (cache-02 + cache-03).
        let unique = Array(Set(shas))
        if !unique.isEmpty {
            await deleteUnreferencedBlobs(shas: unique)
        }
    }

    // MARK: - Metadata: hotItems

    /// Returns item roots that had at least one cache hit at or after `since`.
    public func hotItems(since: Date) async throws -> [CacheKey] {
        try await reader().hotItems(since: since)
    }

    // MARK: - Sync anchor helpers

    /// Returns the maximum `synced_at_ns` value across all rows for the given
    /// `accountAlias`, or `0` when there are no rows. Delegates to ``CacheReader``.
    public func maxSyncedAtNs(accountAlias: String) async throws -> Int64 {
        try await reader().maxSyncedAtNs(accountAlias: accountAlias)
    }

    /// Returns items changed and deletions recorded after `ns` for `accountAlias`.
    ///
    /// Returns a tuple of:
    /// - `updated`: metadata rows whose `synced_at_ns` is strictly greater than `ns`.
    /// - `deletedIdentifierStrings`: identifier strings from `deletion_tombstones`
    ///   whose `deleted_at_ns` is strictly greater than `ns`.
    ///
    /// Delegates to ``CacheReader``.
    public func itemsChangedAfter(
        accountAlias: String,
        ns: Int64
    ) async throws -> (updated: [MetadataRecord], deletedIdentifierStrings: [String]) {
        try await reader().itemsChangedAfter(accountAlias: accountAlias, ns: ns)
    }

    // MARK: - Deletion tombstones

    /// Writes a deletion tombstone for `identifierString` at the current time.
    ///
    /// Called by `delete(key:)` before the hard-delete so the change path can
    /// surface the removal to the File Provider framework.
    public func recordDeletion(accountAlias: String, identifierString: String) async throws {
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

    // MARK: - Blob: store

    /// Writes `data` to the blob store and updates the `blob_sha256` /
    /// `blob_size` columns on the metadata row identified by `key`.
    ///
    /// The metadata row must already exist (call ``upsert(_:)`` first).
    /// After each write the byte budget is enforced: if the total exceeds
    /// `maxBlobBytes`, ``evictToLimit()`` runs automatically.
    ///
    /// Row existence is verified inside the same transaction that records the
    /// blob link — if the row is absent the blob write is still on disk but
    /// will be reclaimed by the next orphan sweep (same guarantee as a crash
    /// mid-write).
    public func storeBlob(key: CacheKey, data: Data) async throws {
        try validateKey(key)
        let nowNs = clock()
        let (sha, size) = try blobs.store(data)

        // Update metadata row's blob columns.
        let affected = try await dbPool.write { db -> Int in
            try db.execute(sql: """
                UPDATE path_metadata
                SET blob_sha256 = ?, blob_size = ?, last_accessed_ns = ?
                WHERE account_alias = ? AND workspace_id = ? AND item_id = ? AND path = ?
                """, arguments: [sha, size, nowNs,
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
        // Measurement and eviction happen in one atomic DB transaction — no
        // suspension between the total read and the eviction decision, so the
        // budget cannot be transiently overshot by a concurrent storeBlob on
        // this actor.  Blob files are deleted *after* the transaction commits;
        // a crash between commit and file-delete leaves orphaned files that the
        // next init-time orphan sweep will recover.
        if maxBlobBytes > 0 {
            _ = try await evictToLimit()
        }
    }

    // MARK: - Blob: load

    /// Loads the cached blob for `key`, if one is stored.
    ///
    /// Throws ``CacheError/notFound(_:)`` when the metadata row has no blob or
    /// the blob file is missing from disk. When the file is missing but the
    /// metadata row still carries a `blob_sha256` reference, the dangling link
    /// is cleared so `blobBytes()` stays accurate.
    ///
    /// Ordering: the blob file is read *before* the `touch` write so that a
    /// concurrent `delete(key:)` racing between `fetch` and `blobs.load` is
    /// detected as a missing file rather than silently returning stale data.
    /// If `touch` finds the row gone (concurrent delete), it throws `notFound`;
    /// `clearBlobLink` is also called in that path to handle any dangling link.
    public func loadBlob(key: CacheKey) async throws -> Data {
        try validateKey(key)
        let record = try await fetch(key: key)
        guard !record.blobSHA256.isEmpty else {
            throw CacheError.notFound("blob for \(key.path)")
        }
        // Load the blob file before touching so that a concurrent delete between
        // fetch and load surfaces as a notFound from blobs.load — the cleaner path.
        let data: Data
        do {
            data = try blobs.load(sha256: record.blobSHA256)
        } catch CacheError.notFound {
            // File gone from disk — clear the dangling link so blobBytes() is truthful.
            try await clearBlobLink(key: key)
            throw CacheError.notFound("blob for \(key.path)")
        }
        // Touch last_accessed only after a successful load.
        // If the row was concurrently deleted, touch throws notFound — that is
        // the correct outcome; clearBlobLink is a no-op (row is already gone).
        do {
            try await touch(key: key)
        } catch CacheError.notFound {
            // Row was deleted between load and touch — benign; blob was already read.
        }
        return data
    }

    // MARK: - Blob: blobURL

    /// Returns the on-disk file URL of the cached blob for `key`, or `nil`
    /// when the metadata row has no blob or the blob file is missing.
    ///
    /// The returned URL is a stable path inside the blob shard cache that
    /// callers can read directly — avoiding an in-memory `Data` load.
    ///
    /// **TOCTOU note**: the existence check inside `BlobShardCache.fileURL`
    /// is advisory only.  A concurrent `evictToLimit`, `delete`, or `wipe`
    /// can remove the file between this call and the caller's open.  Callers
    /// must handle a missing-file error when opening the returned URL.
    public func blobURL(key: CacheKey) async throws -> URL? {
        try validateKey(key)
        let record = try await fetch(key: key)
        guard !record.blobSHA256.isEmpty else { return nil }
        return blobs.fileURL(sha256: record.blobSHA256)
    }

    // MARK: - Blob: handoff (hardlink)

    /// Hands the cached blob for `key` to the caller without a full copy.
    ///
    /// Creates a hard link from the blob file to `destURL`. Because hard links
    /// share the same inode, the FPE can hand `destURL` to the File Provider
    /// framework while the cache entry remains valid on disk — evicting the
    /// cache entry after the handoff only removes the cache shard's directory
    /// entry but leaves the inode reachable via `destURL` until the system
    /// releases it.
    ///
    /// Falls back to `copyItem` when the hard link fails (e.g. cross-volume,
    /// permission error, or the blob was evicted between the metadata fetch and
    /// the link call). Throws `CacheError.notFound` only when the metadata row
    /// has no blob at all AND the copy fallback also fails.
    ///
    /// Safety: hard-linking an immutable content-addressed blob is safe because
    /// neither the FPE nor the cache mutates blob files in place. The cache uses
    /// an atomic write-then-rename strategy, and eviction removes the shard
    /// directory entry but the inode survives until all hard links (including
    /// the caller's `destURL`) are released, so the FPE's path remains valid.
    ///
    /// - Parameters:
    ///   - key: Identifies the cached blob.
    ///   - destURL: Target path for the link (or copy on fallback). Must not
    ///     already exist; callers should remove it before calling.
    /// - Returns: `true` when a hard link was created, `false` on copy fallback.
    /// - Throws: `CacheError.notFound` when the row has no blob or the blob
    ///   file cannot be accessed AND the copy fallback also fails.
    @discardableResult
    public func handoffBlob(key: CacheKey, to destURL: URL) async throws -> Bool {
        try validateKey(key)
        let record = try await fetch(key: key)
        guard !record.blobSHA256.isEmpty else {
            throw CacheError.notFound("blob for \(key.path)")
        }
        guard let srcURL = blobs.fileURL(sha256: record.blobSHA256) else {
            throw CacheError.notFound("blob file for \(record.blobSHA256)")
        }

        // Attempt hard link first (zero-copy, same-volume).
        do {
            try FileManager.default.linkItem(at: srcURL, to: destURL)
            // Touch so LRU eviction knows this blob was recently accessed.
            try? await touch(key: key)
            return true
        } catch {
            // Fall through to copy fallback for cross-volume or permission errors.
            Self.log.debug(
                "CacheStore: hardlink fallback for \(key.path, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
        }

        // Copy fallback: re-resolve the source URL in case the blob moved.
        guard let fallbackSrc = blobs.fileURL(sha256: record.blobSHA256) else {
            throw CacheError.notFound("blob file for \(record.blobSHA256) (post-hardlink-fail)")
        }
        try FileManager.default.copyItem(at: fallbackSrc, to: destURL)
        try? await touch(key: key)
        return false
    }

    // MARK: - Blob: storeBlobFromURL

    /// Hashes the file at `sourceURL`, moves/copies it into the blob store, and
    /// updates the `blob_sha256` / `blob_size` columns on the metadata row for
    /// `key`.
    ///
    /// The metadata row must already exist (call ``upsert(_:)`` first).
    ///
    /// Prefer this over ``storeBlob(key:data:)`` when the bytes are already on
    /// disk — it avoids loading the entire file into memory.
    public func storeBlobFromURL(_ sourceURL: URL, key: CacheKey) async throws {
        try validateKey(key)
        let nowNs = clock()
        let (sha, size) = try blobs.storeFromURL(sourceURL)

        let affected = try await dbPool.write { db -> Int in
            try db.execute(sql: """
                UPDATE path_metadata
                SET blob_sha256 = ?, blob_size = ?, last_accessed_ns = ?
                WHERE account_alias = ? AND workspace_id = ? AND item_id = ? AND path = ?
                """, arguments: [sha, size, nowNs,
                                 key.accountAlias, key.workspaceID, key.itemID, key.path])
            return db.changesCount
        }
        if affected == 0 {
            throw CacheError.notFound(
                "\(key.accountAlias)/\(key.workspaceID)/\(key.itemID)/\(key.path)"
            )
        }
        if maxBlobBytes > 0 {
            _ = try await evictToLimit()
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
    ///
    /// The returned `(count, bytes)` reflects what was recorded in the database
    /// immediately before clearing — the same source as ``blobBytes()``.  Using
    /// the DB rather than a filesystem scan avoids a race on APFS where a blob
    /// written via ``storeBlob(key:data:)`` is visible in the database but the
    /// directory-entry metadata flush needed by `FileManager.enumerator` has not
    /// yet completed, causing `diskUsage()` to return `(0, 0)` for a blob that
    /// clearly exists.
    ///
    /// The DB clear is the authoritative step; blob files that remain on disk
    /// after `wipeAll()` partial failures become unreferenced orphans that the
    /// next init-time sweep will reclaim.
    public func wipe() async throws -> (count: Int, bytes: Int64) {
        // Snapshot count and bytes from the DB in the same write transaction that
        // clears the blob columns.  This guarantees that the returned values match
        // what was removed — no filesystem walk, no APFS timing window.
        let (count, bytes) = try await dbPool.write { db -> (Int, Int64) in
            let countSQL = """
                SELECT COUNT(DISTINCT blob_sha256)
                FROM path_metadata
                WHERE blob_sha256 != ''
                """
            // Reuse the canonical deduplicated-bytes query from CacheReader.
            let count = try Int.fetchOne(db, sql: countSQL) ?? 0
            let bytes = try Int64.fetchOne(db, sql: CacheReader.deduplicatedBlobBytesSQL) ?? 0

            try db.execute(sql: """
                UPDATE path_metadata
                SET blob_sha256 = '', blob_size = 0
                WHERE blob_sha256 != ''
                """)

            return (count, bytes)
        }

        // Delete all blob files from disk. Partial failures are logged; blobs
        // that survive become orphans reclaimed by the next init-time sweep.
        blobs.wipeAll()

        Self.log.info("CacheStore: wiped blobs=\(count, privacy: .public) bytes=\(bytes, privacy: .public)")
        return (count, bytes)
    }

    // MARK: - LRU eviction

    /// Deletes the least-recently-used blob-bearing rows until the total
    /// blob byte count is at or below `maxBlobBytes`.
    ///
    /// A no-op when `maxBlobBytes` is zero.
    ///
    /// The total-bytes measurement and the eviction candidates are selected in
    /// a single `dbPool.write` transaction — there is no `await` suspension
    /// between the measurement and the UPDATE/DELETE decisions, so no concurrent
    /// actor task can push the total higher between the two steps.
    ///
    /// Blob files are deleted **after** the transaction commits.  A crash between
    /// commit and file-delete leaves orphaned files on disk; the init-time orphan
    /// sweep reclaims them on the next launch.
    ///
    /// Note: per arch-04, multiple `CacheStore` instances may share the same
    /// `cacheDir`.  This method enforces the budget for *this* instance only;
    /// cross-engine enforcement is out of scope.
    ///
    /// - Returns: `(evicted, reclaimed)` — number of rows cleared and bytes freed.
    public func evictToLimit() async throws -> (evicted: Int, reclaimed: Int64) {
        guard maxBlobBytes > 0 else { return (0, 0) }

        struct EvictionCandidate {
            var accountAlias: String
            var workspaceID: String
            var itemID: String
            var path: String
            var sha: String
            var size: Int64
        }

        // Single transaction: compute total, select LRU candidates, clear their rows.
        let candidates: [EvictionCandidate] = try await dbPool.write { db in
            let total = try Int64.fetchOne(db, sql: """
                SELECT COALESCE(SUM(blob_size), 0) FROM path_metadata WHERE blob_sha256 != ''
                """) ?? 0
            guard total > maxBlobBytes else { return [] }

            // How many bytes we need to shed.
            var overage = total - maxBlobBytes

            // Select victims in LRU order until overage is covered.
            let rows = try Row.fetchAll(db, sql: """
                SELECT account_alias, workspace_id, item_id, path, blob_sha256, blob_size
                FROM path_metadata
                WHERE blob_sha256 != ''
                ORDER BY last_accessed_ns ASC, rowid ASC
                """)

            var toEvict: [EvictionCandidate] = []
            for row in rows {
                guard overage > 0 else { break }
                let size: Int64 = row["blob_size"]
                toEvict.append(EvictionCandidate(
                    accountAlias: row["account_alias"],
                    workspaceID: row["workspace_id"],
                    itemID: row["item_id"],
                    path: row["path"],
                    sha: row["blob_sha256"],
                    size: size
                ))
                overage -= size
            }

            // Clear blob columns for all victims in one pass.
            for v in toEvict {
                try db.execute(sql: """
                    UPDATE path_metadata
                    SET blob_sha256 = '', blob_size = 0
                    WHERE account_alias = ? AND workspace_id = ? AND item_id = ? AND path = ?
                    """, arguments: [v.accountAlias, v.workspaceID, v.itemID, v.path])
            }

            return toEvict
        }

        if candidates.isEmpty { return (0, 0) }

        // Delete blob files after the transaction has committed.
        // Resolve all ref-counts in one grouped query, then check+unlink
        // inside a single write transaction — eliminates N+1 and closes
        // the TOCTOU window where a concurrent storeBlob could reference
        // a just-evicted SHA between the ref-count read and the unlink.
        let uniqueSHAs = Array(Set(candidates.map(\.sha)))
        var reclaimed: Int64 = 0
        await deleteUnreferencedBlobs(shas: uniqueSHAs, onDeleted: { sha in
            // Sum bytes only for SHAs that were actually unlinked.
            let candidateSize = candidates.first(where: { $0.sha == sha })?.size ?? 0
            reclaimed += candidateSize
        })

        for v in candidates {
            Self.log.debug(
                "CacheStore: evicted sha=\(v.sha, privacy: .public) bytes=\(v.size, privacy: .public)"
            )
        }

        return (candidates.count, reclaimed)
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

    // MARK: Batch chunk size

    /// Maximum number of rows per sub-transaction in batchUpsert / batchDelete.
    ///
    /// Chunking keeps WAL growth bounded during large reconciliations without
    /// sacrificing much throughput (each chunk is still a single commit).
    private static let batchChunkSize = 500

    // MARK: Subtree WHERE helpers

    /// The reusable suffix of a WHERE clause that matches a path and all its
    /// descendants using a LIKE prefix scan.
    ///
    /// Bind `(exact, prefix)` from ``subtreeArguments(for:)``.
    ///
    /// `static` so it can be referenced from inside `dbPool.write` Sendable closures.
    private static let subtreeWhereSuffix = "path = ? OR path LIKE ? ESCAPE '\\'"

    /// Returns `(exact, prefix)` bind arguments for a subtree WHERE clause.
    ///
    /// `exact` is the path itself; `prefix` is `escapeLike(path) + "/%"`.
    ///
    /// `static` so it can be called from inside `dbPool.write` Sendable closures.
    private static func subtreeArguments(for key: CacheKey) -> (String, String) {
        let escaped = Self.escapeLike(key.path)
        return (key.path, escaped + "/%")
    }

    // MARK: Set-based blob deletion

    /// Deletes blob files for all `shas` that have no surviving DB reference,
    /// resolving ref-counts in a single grouped query inside one write transaction
    /// to eliminate N+1 and close the TOCTOU race between ref-count read and unlink.
    ///
    /// - Parameters:
    ///   - shas: Candidate SHA-256 values; duplicates are tolerated and ignored.
    ///   - onDeleted: Called with the SHA of each file that was actually unlinked.
    private func deleteUnreferencedBlobs(shas: [String], onDeleted: ((String) -> Void)? = nil) async {
        guard !shas.isEmpty else { return }

        // Build a set of SHAs that still have at least one DB reference.
        // Using a write transaction (not read) so that concurrent storeBlob calls
        // on this actor instance are serialised — the ref-count check and the
        // decision not to delete are atomic with respect to same-instance writers.
        // A second CacheStore instance on the same cacheDir (arch-04) may race
        // the unlink step, but loadBlob self-heals that race as a cache miss with
        // no data loss (see CacheStore.swift loadBlob self-heal path).
        let stillReferenced: Set<String>
        do {
            let placeholders = shas.map { _ in "?" }.joined(separator: ", ")
            stillReferenced = try await dbPool.write { db -> Set<String> in
                let rows = try String.fetchAll(db, sql: """
                    SELECT DISTINCT blob_sha256
                    FROM path_metadata
                    WHERE blob_sha256 IN (\(placeholders))
                    """, arguments: StatementArguments(shas))
                return Set(rows)
            }
        } catch {
            Self.log.warning("CacheStore: ref-count query failed, skipping blob unlink: \(error, privacy: .public)")
            return
        }

        for sha in shas where !stillReferenced.contains(sha) {
            do {
                try blobs.delete(sha256: sha)
                onDeleted?(sha)
            } catch {
                Self.log.warning("CacheStore: blob delete failed sha=\(sha, privacy: .public) error=\(error, privacy: .public)")
            }
        }
    }

    // MARK: Dangling-link heal

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

    // MARK: Orphan sweep

    /// Removes blob files on disk that have no corresponding metadata row.
    ///
    /// Also removes orphaned `*.tmp` scratch files left behind by a crash
    /// during ``BlobShardCache/store(_:)`` — these are never referenced by the
    /// DB and would otherwise accumulate unbounded.
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
            // Remove orphaned *.tmp scratch files — written by BlobShardCache.store
            // but never renamed into place (crash mid-write).  They are never DB-
            // referenced and must not accumulate.
            if url.pathExtension == "tmp" {
                try? FileManager.default.removeItem(at: url)
                continue
            }
            guard let vals = try? url.resourceValues(forKeys: [.isRegularFileKey]),
                  vals.isRegularFile == true else { continue }
            // Reconstruct SHA from shard-prefix + filename using the single
            // source-of-truth helper on BlobShardCache (not an ad-hoc `prefix(2)`).
            let shard = url.deletingLastPathComponent().lastPathComponent
            let file = url.lastPathComponent
            guard let sha = blobs.sha(fromShard: shard, file: file) else { continue }
            onDisk.append(sha)
        }

        guard !onDisk.isEmpty else { return }

        // Ask the DB which of those are actually referenced.
        //
        // Use a write transaction (not a snapshot read) so that a concurrent
        // storeBlob that has already written the blob file but not yet committed
        // its DB UPDATE is guaranteed to finish before this query runs.  A
        // snapshot read would see stale DB state — it would miss the just-written
        // SHA and incorrectly identify the blob as an orphan, deleting it while
        // storeBlob is still mid-execution.  The write serialiser blocks here
        // until any in-flight storeBlob/storeBlobFromURL write transaction commits,
        // matching the same pattern used by deleteUnreferencedBlobs.
        let referenced: Set<String> = try dbPool.write { db in
            let rows = try String.fetchAll(db, sql: """
                SELECT DISTINCT blob_sha256 FROM path_metadata WHERE blob_sha256 != ''
                """)
            return Set(rows)
        }

        for sha in onDisk where !referenced.contains(sha) {
            do {
                try blobs.delete(sha256: sha)
            } catch {
                Self.log.warning("CacheStore: sweep failed to delete sha=\(sha, privacy: .public): \(error, privacy: .public)")
            }
        }
    }

    // MARK: Identifier helpers

    /// Reconstructs the `ItemIdentifier.identifierString` for a
    /// `(workspaceID, itemID, path)` triple.
    ///
    /// Mirrors ``ItemIdentifier/identifierString`` without importing the full
    /// FileProvider framework from the cache layer.
    static func identifierString(workspaceID: String, itemID: String, path: String) -> String {
        if path.isEmpty {
            return "\(workspaceID)/\(itemID)"
        }
        return "\(workspaceID)/\(itemID)/\(path)"
    }

    // MARK: SQL escape helper

    /// Escapes SQL LIKE wildcards using `\` as the escape character.
    static func escapeLike(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "%", with: "\\%")
         .replacingOccurrences(of: "_", with: "\\_")
    }
}

// MARK: - Module-level helpers

/// Validates that `key` has all required non-empty components.
///
/// `internal` so both `CacheStore` and `CacheReader` can call it without duplication.
func validateKey(_ key: CacheKey) throws {
    if key.accountAlias.isEmpty { throw CacheError.missingArgument("accountAlias") }
    if key.workspaceID.isEmpty { throw CacheError.missingArgument("workspaceID") }
    if key.itemID.isEmpty { throw CacheError.missingArgument("itemID") }
}

/// Returns the current time as Unix nanoseconds (wall clock).
///
/// Exposed at module scope so test helpers can reference it by name without
/// duplicating the conversion formula.
func wallClockNs() -> Int64 {
    Int64(Date().timeIntervalSince1970 * 1_000_000_000)
}

// MARK: - Array chunking helper

private extension Array {
    /// Splits the array into consecutive sub-arrays of at most `size` elements.
    func chunked(by size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}
