import Foundation
import GRDB

// MARK: - CacheStore+Metadata

public extension CacheStore {
    // MARK: - Metadata: upsert

    /// Inserts or updates the metadata row for `record`.
    ///
    /// If `lastAccessedNs` or `syncedAtNs` are zero, the current wall-clock
    /// time is substituted so eviction and reconciliation always have a
    /// timestamp to work with.
    func upsert(_ record: MetadataRecord) async throws {
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
    func batchUpsert(_ records: [MetadataRecord]) async throws {
        guard !records.isEmpty else { return }
        let now = clock()
        for chunk in records.chunked(by: Self.batchChunkSize) {
            try await dbPool.write { db in try Self.upsertChunk(chunk, now: now, db: db) }
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
    func batchDelete(_ keys: [CacheKey], recordTombstones: Bool) async throws {
        guard !keys.isEmpty else { return }
        // One clock read for the whole batch so every tombstone shares a single
        // deleted_at_ns source with synced_at_ns (never Date() from a caller).
        let nowNs = clock()
        for chunk in keys.chunked(by: Self.batchChunkSize) {
            try await dbPool.write { db in
                try Self.deleteChunk(chunk, recordTombstones: recordTombstones, nowNs: nowNs, db: db)
            }
        }
    }

    /// Upserts `upserts` and deletes `deletes` inside ONE GRDB write
    /// transaction, so a failure in either phase rolls back both.
    ///
    /// ``SyncEngine/refreshFolder(key:)`` reconciles a folder by upserting
    /// changed children and then tombstone-deleting vanished ones. When those
    /// two phases were separate transactions, a transient failure on the
    /// delete phase — after the upsert phase had already committed — left
    /// vanished rows in the cache with no tombstone (invisible to
    /// `itemsChangedAfter`'s incremental delta), while ``syncAnchorNs(accountAlias:)``
    /// — the max `synced_at_ns` across the table, already advanced by the
    /// committed upserts — had moved past them regardless of the delete
    /// outcome. Folding both phases into one transaction means a delete-phase
    /// failure rolls the upserts back too, so the anchor never advances over an
    /// unreflected removal (#427 / review finding M2).
    ///
    /// Unlike ``batchUpsert(_:)`` / ``batchDelete(_:recordTombstones:)``, this
    /// does not chunk: it exists for a single folder's reconcile pass, which is
    /// bounded by one directory listing, and chunking would reintroduce the
    /// exact split-transaction problem this method exists to close. This is a
    /// deliberate trade-off: a very large first-time folder listing lands as
    /// ONE WAL-held write transaction instead of the old 500-row chunks — a
    /// larger memory/WAL burst than before, which matters in the FPE's
    /// constrained-memory process — accepted in exchange for atomicity.
    ///
    /// `now` is read once and shared by both phases, so every upserted row's
    /// `synced_at_ns` and every deleted row's tombstone `deleted_at_ns` come
    /// from the same clock read (never `Date()` from a caller).
    func batchUpsertAndDelete(
        upserts: [MetadataRecord],
        deletes: [CacheKey],
        recordTombstones: Bool
    ) async throws {
        guard !upserts.isEmpty || !deletes.isEmpty else { return }
        let now = clock()
        try await dbPool.write { db in
            if !upserts.isEmpty {
                try Self.upsertChunk(upserts, now: now, db: db)
            }
            if !deletes.isEmpty {
                try Self.deleteChunk(deletes, recordTombstones: recordTombstones, nowNs: now, db: db)
            }
        }
    }

    /// Per-chunk upsert body shared by ``batchUpsert(_:)`` and
    /// ``batchUpsertAndDelete(upserts:deletes:recordTombstones:)``.
    private static func upsertChunk(_ records: [MetadataRecord], now: Int64, db: Database) throws {
        for record in records {
            var copy = record
            if copy.lastAccessedNs == 0 { copy.lastAccessedNs = now }
            if copy.syncedAtNs == 0 { copy.syncedAtNs = now }
            try copy.upsert(db)
            // Clear any tombstone shadowing this identifier (see upsert).
            try Self.clearTombstone(db, record: copy)
        }
    }

    /// Per-chunk delete body shared by ``batchDelete(_:recordTombstones:)`` and
    /// ``batchUpsertAndDelete(upserts:deletes:recordTombstones:)``.
    private static func deleteChunk(
        _ keys: [CacheKey],
        recordTombstones: Bool,
        nowNs: Int64,
        db: Database
    ) throws {
        for key in keys {
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

    // MARK: - Metadata: fetch

    /// Fetches the metadata row for `key`.
    ///
    /// Throws ``CacheError/notFound(_:)`` when the row does not exist.
    func fetch(key: CacheKey) async throws -> MetadataRecord {
        try await reader().fetch(key: key)
    }

    // MARK: - Metadata: children

    /// Returns every direct child of the directory identified by `key`.
    func children(of key: CacheKey) async throws -> [MetadataRecord] {
        try await reader().children(of: key)
    }

    // MARK: - Metadata: subtree etags (bulk read)

    /// Returns the `subtree_etag` of each key in `keys` that has a row, keyed by
    /// ``CacheKey/stableKeyString``, in a single read transaction. Delegates to
    /// ``CacheReader/subtreeEtags(for:)``.
    func subtreeEtags(for keys: [CacheKey]) async throws -> [String: String] {
        try await reader().subtreeEtags(for: keys)
    }

    // MARK: - Metadata: touch

    /// Bumps `last_accessed_ns` for `key` to the current time.
    ///
    /// Throws ``CacheError/notFound(_:)`` when the row does not exist.
    func touch(key: CacheKey) async throws {
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
            // Redacted at the throw site — see `CacheKey.opaqueLogPrefix`'s doc.
            throw CacheError.notFound(key.opaqueLogPrefix)
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
    func updateSubtreeEtag(key: CacheKey, etag: String) async throws {
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
    func delete(key: CacheKey) async throws {
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
    func hotItems(since: Date) async throws -> [CacheKey] {
        try await reader().hotItems(since: since)
    }

    // MARK: - Sync anchor helpers

    /// Returns the sync anchor for `accountAlias` — the newest of any
    /// `synced_at_ns` and any `deleted_at_ns` — or `0` when neither table has a
    /// row. Delegates to ``CacheReader``.
    func syncAnchorNs(accountAlias: String) async throws -> Int64 {
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
    func itemsChangedAfter(
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
    func renamePathPrefix(
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
    func setMaterialized(alias: String, identifiers: [String]) async throws {
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
    func materializedContainers(alias: String) async throws -> [CacheKey] {
        try await reader().materializedContainers(alias: alias)
    }

    /// Removes the `materialized_containers` rows for one removed item:
    /// `identifierPrefix` itself (the item-root container identifier `"ws/guid"`)
    /// and every descendant container (`"ws/guid/…"`).
    ///
    /// Called when a Fabric item vanishes from a workspace listing so the
    /// freshness poll loop stops trying to refresh — and DFS-404ing — the dead
    /// item's containers on every tick. A no-op when no rows match.
    ///
    /// Prefix match is anchored: the exact `identifierPrefix` OR
    /// `identifierPrefix + "/…"`, so a sibling whose identifier merely shares this
    /// string as a prefix without the `/` boundary (there is none for GUIDs, but
    /// the anchoring is defensive) is never removed. Race-safe by eventual
    /// consistency — no locking; if a concurrent refresh re-materializes a
    /// container after this deletes, the next reconcile removes it again.
    func removeMaterialized(alias: String, identifierPrefix: String) async throws {
        guard !alias.isEmpty else { throw CacheError.missingArgument("alias") }
        guard !identifierPrefix.isEmpty else { throw CacheError.missingArgument("identifierPrefix") }
        try await dbPool.write { db in
            try db.execute(sql: """
            DELETE FROM materialized_containers
            WHERE account_alias = ?
              AND (identifier_string = ? OR identifier_string LIKE ? ESCAPE '\\')
            """, arguments: [alias, identifierPrefix, Self.escapeLike(identifierPrefix) + "/%"])
        }
    }

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
