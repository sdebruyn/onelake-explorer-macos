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
    /// LRU eviction threshold for blob bytes. `var` (not `let`) so
    /// ``setMaxBlobBytes(_:)`` can update the budget live. Actor isolation
    /// serialises reads and writes made from actor-isolated code (e.g. the
    /// `guard maxBlobBytes > 0` checks in ``storeBlob(key:data:)`` and
    /// ``storeBlobFromURL(_:key:)``) — but it does **not** protect a read
    /// made from inside a `dbPool.write { }` closure, which runs on GRDB's
    /// writer queue, off this actor. ``evictToLimit()`` snapshots the value
    /// into a local `let` before entering any of its (possibly several)
    /// `dbPool.write { }` passes, for exactly this reason; do not reintroduce
    /// a direct `maxBlobBytes` reference inside a `dbPool.write { }` /
    /// `dbPool.read { }` closure.
    private var maxBlobBytes: Int64

    /// Clock injection seam: returns the current time as Unix nanoseconds.
    /// Defaults to wall clock; override in tests for deterministic ordering.
    private let clock: () -> Int64

    private static let log = Logger(subsystem: "dev.debruyn.ofem", category: "CacheStore")

    /// Structured logger for debug-level cache diagnostics.
    private let logger: OfemLogger

    // MARK: - Public state

    /// The root directory passed at construction time.
    // periphery:ignore
    public nonisolated let root: URL

    /// The blob root directory (`<root>/blobs`).
    // periphery:ignore
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
    /// Note: the default clock closure duplicates the wallClockNs formula rather than
    /// referencing it directly because wallClockNs is internal and this init is public;
    /// Swift requires default argument expressions to be at least as visible as the
    /// declaration they appear in.
    public init(
        root: URL,
        maxBlobBytes: Int64 = 0,
        clock: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1_000_000_000) },
        logger: OfemLogger = .init()
    ) throws {
        self.root = root
        self.maxBlobBytes = maxBlobBytes
        self.clock = clock
        self.logger = logger

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
        CacheReader(db: dbPool, logger: logger)
    }

    // MARK: - Live budget update

    /// Updates the LRU eviction budget live, without recreating `CacheStore`.
    ///
    /// The new limit applies on the next ``storeBlob(key:data:)`` /
    /// ``storeBlobFromURL(_:key:)`` write (both call ``evictToLimit()``
    /// automatically) or the next explicit ``evictToLimit()`` call — it does
    /// not retroactively evict already-cached blobs the moment this is
    /// called. `0` disables eviction (matches the `init` semantics).
    ///
    /// Actor isolation serialises this write against concurrent calls made
    /// from other actor-isolated code — no separate lock needed for *that*.
    /// It does **not**, by itself, make every existing read of
    /// `maxBlobBytes` safe; see the property's doc comment for the one call
    /// site (inside a `dbPool.write { }` closure) that has to snapshot the
    /// value instead of reading `self.maxBlobBytes` directly.
    ///
    /// Called by `FPEEngineHost.reloadEngine()` after a
    /// `setConfig(cache.max_size_gb:)` XPC call so the budget takes effect
    /// immediately — the shared `CacheStore` singleton is not rebuilt on
    /// reload.
    public func setMaxBlobBytes(_ value: Int64) {
        maxBlobBytes = value
    }

    #if DEBUG
        // periphery:ignore
        /// Current eviction budget. Test-only introspection — production
        /// callers have no legitimate need to read this back (they only ever
        /// set it). Exposed so `FPEEngineHostTests` can assert that
        /// `reloadEngine()` actually propagates a config change to the shared
        /// `CacheStore` without needing to write gigabyte-scale blob data to
        /// observe eviction behaviour (`cache.max_size_gb` is whole-GB
        /// granularity).
        ///
        /// `#if DEBUG`-gated (matching `FPEEngineHost`'s `*ForTesting` seams)
        /// so this test-only surface never ships in a Release build.
        public var maxBlobBytesForTesting: Int64 {
            maxBlobBytes
        }
    #endif

    // MARK: - Read-only factory (host process)

    /// Opens the cache at `root` in read-only mode and returns a `CacheReader`.
    ///
    /// Unlike the full `CacheStore.init`, this factory does **not** run the
    /// orphan-blob sweep — a write transaction that competes with the FPE
    /// process's writes.  Use this in the host app, which only needs to read
    /// the workspace cache; the FPE is the sole writer.
    ///
    /// Returns `nil` when the SQLite file cannot be opened (e.g. the FPE has
    /// not yet created the database).
    public static func openReadOnly(root: URL, logger: OfemLogger = .init()) -> CacheReader? {
        let dbURL = root.appendingPathComponent(CacheStore.sqliteFile)
        guard FileManager.default.fileExists(atPath: dbURL.path) else { return nil }
        var config = Configuration()
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA journal_mode = WAL")
            try db.execute(sql: "PRAGMA busy_timeout = \(CacheStore.busyTimeoutMs)")
        }
        guard let pool = try? DatabasePool(path: dbURL.path, configuration: config) else {
            return nil
        }
        return CacheReader(db: pool, logger: logger)
    }

    // MARK: - Orphan sweep

    // periphery:ignore
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
            // Clear any deletion tombstone shadowing this identifier: re-creating a
            // path must not stay hidden behind a stale tombstone. itemsChangedAfter
            // also reconciles by timestamp, but clearing here keeps the table small
            // and makes the common recreate case unambiguous.
            try Self.clearTombstone(db, record: frozen)
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
            if copy.syncedAtNs == 0 { copy.syncedAtNs = now }
            return copy
        }
        for chunk in prepared.chunked(by: Self.batchChunkSize) {
            try await dbPool.write { db in
                for record in chunk {
                    try record.upsert(db)
                    // Clear any tombstone shadowing this identifier (see upsert).
                    try Self.clearTombstone(db, record: record)
                }
            }
        }
    }

    /// Deletes rows for all `keys` inside a single GRDB write transaction.
    ///
    /// When `recordTombstones` is `true`, a deletion tombstone is written for
    /// every removed row (the delta-visible identifier from
    /// ``tombstoneIdentifierString(workspaceID:itemID:path:)``, `nil` rows
    /// skipped) BEFORE the hard-delete, in the same transaction, so
    /// `itemsChangedAfter` → `enumerateChanges` can deliver the removal to the
    /// File Provider framework via `didDeleteItems`. Pass `false` for
    /// cache-maintenance deletes that must not surface as a Finder removal.
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
    public func batchDelete(_ keys: [CacheKey], recordTombstones: Bool) async throws {
        guard !keys.isEmpty else { return }
        // One clock read for the whole batch so every tombstone shares a single
        // deleted_at_ns source with synced_at_ns (never Date() from a caller).
        let nowNs = clock()
        for chunk in keys.chunked(by: Self.batchChunkSize) {
            try await dbPool.write { db in
                for key in chunk {
                    // Collect the paths this key's delete will remove — INSIDE the
                    // transaction (not before, which would open a TOCTOU window) —
                    // so a tombstone can be written for each before the hard-delete,
                    // mirroring delete(key:).
                    let deletedPaths: [String]
                    if key.path.isEmpty {
                        deletedPaths = try String.fetchAll(db, sql: """
                        SELECT path FROM path_metadata
                        WHERE account_alias = ? AND workspace_id = ? AND item_id = ?
                        """, arguments: [key.accountAlias, key.workspaceID, key.itemID])
                    } else {
                        let (exact, prefix) = Self.subtreeArguments(for: key)
                        deletedPaths = try String.fetchAll(db, sql: """
                        SELECT path FROM path_metadata
                        WHERE account_alias = ? AND workspace_id = ? AND item_id = ?
                          AND (\(Self.subtreeWhereSuffix))
                        """, arguments: [
                            key.accountAlias, key.workspaceID, key.itemID,
                            exact, prefix,
                        ])
                    }

                    if recordTombstones {
                        for path in deletedPaths {
                            guard let identStr = Self.tombstoneIdentifierString(
                                workspaceID: key.workspaceID,
                                itemID: key.itemID,
                                path: path
                            ) else { continue }
                            let tombstone = DeletionTombstoneRecord(
                                accountAlias: key.accountAlias,
                                identifierString: identStr,
                                deletedAtNs: nowNs
                            )
                            try tombstone.save(db)
                        }
                    }

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

    // MARK: - Metadata: subtree etags (bulk read)

    /// Returns the `subtree_etag` of each key in `keys` that has a row, keyed by
    /// ``CacheKey/stableKeyString``, in a single read transaction. Delegates to
    /// ``CacheReader/subtreeEtags(for:)``.
    public func subtreeEtags(for keys: [CacheKey]) async throws -> [String: String] {
        try await reader().subtreeEtags(for: keys)
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
                           arguments: [nowNs, key.accountAlias, key.workspaceID, key.itemID, key.path])
            return db.changesCount
        }
        if affected == 0 {
            throw CacheError.notFound("\(key.accountAlias)/\(key.workspaceID)/\(key.itemID)/\(key.path)")
        }
    }

    // MARK: - Metadata: subtree etag (#380)

    /// Writes ONLY the `subtree_etag` column for `key`, leaving every other
    /// column — crucially `synced_at_ns` — untouched.
    ///
    /// The directory subtree etag (#380) is harvested from the parent listing as
    /// a refresh skip-gate token. It must update without bumping `synced_at_ns`:
    /// a `synced_at_ns` bump would surface the container row in
    /// `itemsChangedAfter` and produce a phantom working-set delta on every poll
    /// that harvested a new subtree etag (the exact regression guarded by the
    /// "writing subtreeEtag produces zero working-set delta" test). Because
    /// `entryChanged` ignores directory etag (#379) the full-row upsert path
    /// would never persist an advancing subtree etag anyway, so this targeted
    /// UPDATE is the only correct way to keep the skip-gate token fresh.
    ///
    /// A no-op (zero rows affected) when the row does not exist; the caller
    /// harvests from a listing it just performed, so a missing row simply means
    /// the container row has not been written yet and will pick the etag up on
    /// its next full upsert.
    public func updateSubtreeEtag(key: CacheKey, etag: String) async throws {
        try validateKey(key)
        try await dbPool.write { db in
            try db.execute(sql: """
                           UPDATE path_metadata
                           SET subtree_etag = ?
                           WHERE account_alias = ? AND workspace_id = ? AND item_id = ? AND path = ?
                           """,
                           arguments: [etag, key.accountAlias, key.workspaceID, key.itemID, key.path])
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

    // periphery:ignore
    /// Returns item roots that had at least one cache hit at or after `since`.
    public func hotItems(since: Date) async throws -> [CacheKey] {
        try await reader().hotItems(since: since)
    }

    // MARK: - Sync anchor helpers

    /// Returns the sync anchor for `accountAlias` — the newest of any
    /// `synced_at_ns` and any `deleted_at_ns` — or `0` when neither table has a
    /// row. Delegates to ``CacheReader``.
    public func syncAnchorNs(accountAlias: String) async throws -> Int64 {
        try await reader().syncAnchorNs(accountAlias: accountAlias)
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

    // MARK: - Rename (path-prefix rewrite)

    /// Renames a cached path and all its descendants by rewriting the `path`,
    /// `parent_path`, and `name` columns in a single transaction.
    ///
    /// - Parameters:
    ///   - accountAlias: Account alias component of the primary key.
    ///   - workspaceID: Workspace GUID.
    ///   - itemID: Item GUID.
    ///   - oldPath: The current path of the renamed entry.
    ///   - newPath: The destination path (same parent directory, different leaf name).
    ///   - newName: The new leaf name (final segment of `newPath`).
    ///
    /// The exact row at `oldPath` is updated first; then every row whose `path`
    /// starts with `oldPath + "/"` (i.e. descendants) has its `path`,
    /// `parent_path`, and `name` rewritten to substitute the old prefix with the
    /// new one. All updates happen atomically in one write transaction.
    ///
    /// DFS overwrites the destination by default, so the remote rename can
    /// succeed even when a row already exists at `newPath` (or a descendant's
    /// new path). The `path_metadata` primary key is
    /// `(account_alias, workspace_id, item_id, path)`, so a plain `UPDATE … SET
    /// path = newPath` would PK-abort against any colliding row. Each colliding
    /// destination row (and its blob refs) is therefore deleted first.
    ///
    /// - Returns: The updated ``MetadataRecord`` at `newPath`, read back inside
    ///   the same write transaction (no actor hop, no TOCTOU window), or `nil`
    ///   when no row existed at `oldPath` to rename.
    public func renamePathPrefix(
        accountAlias: String,
        workspaceID: String,
        itemID: String,
        oldPath: String,
        newPath: String,
        newName: String
    ) async throws -> MetadataRecord? {
        let nowNs = clock()
        let newParent = Enumerator.parentPath(newPath)
        return try await dbPool.write { db -> MetadataRecord? in
            // Clear any pre-existing destination row (DFS overwrites it server-
            // side) so the exact-row UPDATE below cannot PK-abort.
            try db.execute(sql: """
            DELETE FROM path_metadata
            WHERE account_alias = ? AND workspace_id = ? AND item_id = ? AND path = ?
            """, arguments: [accountAlias, workspaceID, itemID, newPath])
            // Update the exact renamed row.
            try db.execute(sql: """
            UPDATE path_metadata
            SET path = ?, parent_path = ?, name = ?, synced_at_ns = ?
            WHERE account_alias = ? AND workspace_id = ? AND item_id = ? AND path = ?
            """, arguments: [newPath, newParent, newName, nowNs, accountAlias, workspaceID, itemID, oldPath])

            // Rewrite every descendant of the renamed entry. Reuse the same
            // subtree primitive `delete` uses (`path LIKE oldPrefix%`) so the
            // selection is correct-by-construction rather than relying on an
            // in-Swift `hasPrefix` guard over a `> … < …` sort band that could
            // re-select the just-renamed row or unrelated siblings.
            let escapedOldPrefix = Self.escapeLike(oldPath) + "/%"
            // Clear any colliding destination descendant rows first (same reason
            // as the exact row above).
            try db.execute(sql: """
            DELETE FROM path_metadata
            WHERE account_alias = ? AND workspace_id = ? AND item_id = ?
              AND path LIKE ? ESCAPE '\\'
            """, arguments: [accountAlias, workspaceID, itemID, Self.escapeLike(newPath) + "/%"])
            // Set-based rewrite: SQLite has substr()/length(), so we can rewrite
            // path and parent_path for the whole subtree in one statement rather
            // than fetching + updating each row. `name` is unchanged for
            // descendants (only the prefix shifts), so it is left as-is.
            //
            // Both columns are rewritten by stripping the `oldPath` prefix
            // (length, no trailing slash) and prepending `newPath`:
            //   • every descendant `path` starts with `oldPath + "/"`, so the
            //     stripped remainder keeps its leading "/", giving newPath + "/…".
            //   • a descendant's `parent_path` is either exactly `oldPath` (direct
            //     child → stripped to "" → newPath) or `oldPath + "/…"` (deeper →
            //     newPath + "/…"). Stripping `oldPath` (not `oldPath + "/"`)
            //     handles both, where stripping the slash form would corrupt the
            //     direct-child parent into a trailing-slash value.
            // The substr start index is computed in SQL as `length(oldPath) + 1`
            // (bound, not Swift's String.count) so SQLite's own character counting
            // drives both `length()` and `substr()` — avoiding any grapheme-vs-
            // SQLite-character mismatch for non-ASCII path names.
            try db.execute(sql: """
            UPDATE path_metadata
            SET path = ? || substr(path, length(?) + 1),
                parent_path = ? || substr(parent_path, length(?) + 1),
                synced_at_ns = ?
            WHERE account_alias = ? AND workspace_id = ? AND item_id = ?
              AND path LIKE ? ESCAPE '\\'
            """, arguments: [
                newPath, oldPath,
                newPath, oldPath,
                nowNs,
                accountAlias, workspaceID, itemID, escapedOldPrefix,
            ])

            // Clear any tombstones covering the DESTINATION subtree in this same
            // transaction: renaming INTO a previously-deleted name (or over a
            // subtree that had been reconciled away) must not leave the re-created
            // rows shadowed by their old tombstones. SyncEngine.rename writes the
            // OLD-identifier tombstone only AFTER this call, so it is unaffected.
            let destIdentifier = Self.identifierString(
                workspaceID: workspaceID, itemID: itemID, path: newPath
            )
            try db.execute(sql: """
            DELETE FROM deletion_tombstones
            WHERE account_alias = ?
              AND (identifier_string = ? OR identifier_string LIKE ? ESCAPE '\\')
            """, arguments: [accountAlias, destIdentifier, Self.escapeLike(destIdentifier) + "/%"])

            // Read back the renamed row inside the same transaction so the caller
            // needs no second fetch (and cannot race a concurrent poll).
            return try MetadataRecord
                .filter(MetadataRecord.Columns.accountAlias == accountAlias)
                .filter(MetadataRecord.Columns.workspaceID == workspaceID)
                .filter(MetadataRecord.Columns.itemID == itemID)
                .filter(MetadataRecord.Columns.path == newPath)
                .fetchOne(db)
        }
    }

    // MARK: - Deletion tombstones

    /// Writes a deletion tombstone for `identifierString` at the current time.
    ///
    /// Called by `delete(key:)` before the hard-delete, and by `SyncEngine.rename`
    /// for the OLD identifier after a re-key, so the change path can surface the
    /// removal to the File Provider framework.
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

    // MARK: - Materialized containers

    /// Full-replace reconcile of the materialized-container set for `alias`.
    ///
    /// Deletes all existing rows for `alias` and inserts one row per identifier
    /// string in `identifiers`. An empty `identifiers` array clears the set.
    ///
    /// The write is atomic (single transaction) so readers never see a partial
    /// state. Timestamp `materializedAtNs` is set to the current wall clock for
    /// all inserted rows.
    ///
    /// - Parameters:
    ///   - alias: The account alias (non-empty).
    ///   - identifiers: The complete set of materialized container identifier
    ///     strings for this alias (as produced by `ItemIdentifier.identifierString`).
    public func setMaterialized(alias: String, identifiers: [String]) async throws {
        guard !alias.isEmpty else { throw CacheError.missingArgument("alias") }
        let nowNs = clock()
        try await dbPool.write { db in
            // Full replace: delete the alias's current set, then insert the new one.
            try db.execute(
                sql: "DELETE FROM materialized_containers WHERE account_alias = ?",
                arguments: [alias]
            )
            for identStr in identifiers {
                let record = MaterializedContainerRecord(
                    accountAlias: alias,
                    identifierString: identStr,
                    materializedAtNs: nowNs
                )
                try record.save(db)
            }
        }
    }

    /// Returns the materialized-container set for `alias` as ``CacheKey`` values.
    ///
    /// Delegates to ``CacheReader/materializedContainers(alias:)``.
    public func materializedContainers(alias: String) async throws -> [CacheKey] {
        try await reader().materializedContainers(alias: alias)
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
    // periphery:ignore
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

        // Enforce the byte budget after every successful write. Each pass
        // ``evictToLimit()`` runs measures and selects its candidates inside
        // one atomic DB transaction — no suspension between the total read
        // and the eviction decision within a pass, so the budget cannot be
        // transiently overshot by a concurrent storeBlob on this actor. See
        // ``evictToLimit()``'s doc comment for how it bounds the on-disk
        // orphan window when a call spans more than one pass.
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
    // periphery:ignore
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

    // periphery:ignore - only test callers remain; exclude_tests: true hides them from periphery
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
    ///
    /// `SyncEngine`'s own callers now use ``blobURL(record:)`` (they already
    /// have the record); this key-based entry point remains the minimal
    /// public API for a caller that only has a `CacheKey`.
    public func blobURL(key: CacheKey) async throws -> URL? {
        try validateKey(key)
        let record = try await fetch(key: key)
        return blobURL(record: record)
    }

    /// Like ``blobURL(key:)`` but computed directly from an already-fetched
    /// `record`, skipping the metadata read.
    ///
    /// Callers that just fetched (or built) the row for another reason —
    /// e.g. `SyncEngine.open`'s freshness check — should use this instead of
    /// re-fetching via `blobURL(key:)`. Pure path computation, no
    /// database I/O, so unlike `blobURL(key:)` it cannot throw.
    public func blobURL(record: MetadataRecord) -> URL? {
        guard !record.blobSHA256.isEmpty else { return nil }
        return blobs.fileURL(sha256: record.blobSHA256)
    }

    // MARK: - Blob: handoff (hardlink)

    // periphery:ignore - only test callers remain; exclude_tests: true hides them from periphery
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
    /// `FileProviderExtension.fetchContents` now uses ``handoffBlob(record:to:)``
    /// (it already has the record); this key-based entry point remains the
    /// minimal public API for a caller that only has a `CacheKey`.
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
        return try await handoffBlob(record: record, to: destURL)
    }

    /// Like ``handoffBlob(key:to:)`` but takes an already-fetched `record`,
    /// skipping the metadata read.
    ///
    /// Callers that already have the row in hand — e.g. the FPE's
    /// `fetchContents`, which now gets it from `SyncEngine.openReturningRecord`
    /// — should use this instead of re-fetching via `handoffBlob(key:to:)`.
    @discardableResult
    public func handoffBlob(record: MetadataRecord, to destURL: URL) async throws -> Bool {
        guard !record.blobSHA256.isEmpty else {
            throw CacheError.notFound("blob for \(record.path)")
        }
        guard let srcURL = blobs.fileURL(sha256: record.blobSHA256) else {
            throw CacheError.notFound("blob file for \(record.blobSHA256)")
        }
        let key = CacheKey(
            accountAlias: record.accountAlias, workspaceID: record.workspaceID,
            itemID: record.itemID, path: record.path
        )

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
    ///
    /// - Returns: The `sha256`/`size` just written, so callers that need them
    ///   (e.g. `SyncEngine.performDownload`, to complete the in-memory record
    ///   it already holds) don't have to re-fetch the row.
    @discardableResult
    public func storeBlobFromURL(_ sourceURL: URL, key: CacheKey) async throws -> (sha256: String, size: Int64) {
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
        return (sha, size)
    }

    // MARK: - Blob: blobBytes

    /// Returns the deduplicated on-disk byte total for all cached blobs.
    public func blobBytes() async throws -> Int64 {
        try await reader().blobBytes()
    }

    // MARK: - Blob: diskUsage

    // periphery:ignore
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

        logger.info("cache wipe", metadata: [
            "count": "\(count)",
            "bytes": "\(bytes)",
        ])
        return (count, bytes)
    }

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

    // periphery:ignore
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

    // MARK: IN-clause helper

    /// Returns `(placeholders, arguments)` for binding `shas` positionally
    /// into a `blob_sha256 IN (...)` clause.
    ///
    /// Shared by every such query in this file (``evictToLimit()``'s
    /// same-SHA-group lookup and ``deleteUnreferencedBlobs(shas:onDeleted:)``'s
    /// ref-count check) so the placeholder-building logic can't drift between
    /// the two copies.
    ///
    /// `static` so it can be called from inside `dbPool.write` Sendable closures.
    private static func inClauseBinding(_ shas: [String]) -> (placeholders: String, arguments: StatementArguments) {
        (shas.map { _ in "?" }.joined(separator: ", "), StatementArguments(shas))
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
            let (placeholders, arguments) = Self.inClauseBinding(shas)
            stillReferenced = try await dbPool.write { db -> Set<String> in
                let rows = try String.fetchAll(db, sql: """
                SELECT DISTINCT blob_sha256
                FROM path_metadata
                WHERE blob_sha256 IN (\(placeholders))
                """, arguments: arguments)
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
    static func tombstoneIdentifierString(workspaceID: String, itemID: String, path: String) -> String? {
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
    static func clearTombstone(_ db: Database, record: MetadataRecord) throws {
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
// periphery:ignore
func wallClockNs() -> Int64 {
    Int64(Date().timeIntervalSince1970 * 1_000_000_000)
}

// MARK: - Array chunking helper

private extension Array {
    /// Splits the array into consecutive sub-arrays of at most `size` elements.
    func chunked(by size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0 ..< Swift.min($0 + size, count)])
        }
    }
}
