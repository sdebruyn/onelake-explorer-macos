import Foundation
import GRDB
import os.log

// MARK: - CacheStore+Blobs

extension CacheStore {
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
            // Redacted at the throw site — see `CacheKey.opaqueLogPrefix`'s doc.
            throw CacheError.notFound(key.opaqueLogPrefix)
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
            // Redacted at the throw site — see `CacheKey.opaqueLogPrefix`'s doc.
            throw CacheError.notFound("blob for \(key.opaqueLogPrefix)")
        }
        // Load the blob file before touching so that a concurrent delete between
        // fetch and load surfaces as a notFound from blobs.load — the cleaner path.
        let data: Data
        do {
            data = try blobs.load(sha256: record.blobSHA256)
        } catch CacheError.notFound {
            // File gone from disk — clear the dangling link so blobBytes() is truthful.
            try await clearBlobLink(key: key)
            // Redacted at the throw site — see `CacheKey.opaqueLogPrefix`'s doc.
            throw CacheError.notFound("blob for \(key.opaqueLogPrefix)")
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
        let key = CacheKey(
            accountAlias: record.accountAlias, workspaceID: record.workspaceID,
            itemID: record.itemID, path: record.path
        )
        // Redacted at the throw site itself, not just where it's logged:
        // `CacheError` IS `LocalizedError` (`errorDescription` echoes the raw
        // associated string), so a raw path in the payload would leak through
        // `.localizedDescription` at every `.public`-tagged call site that
        // logs this error — not only the one below. See
        // `CacheKey.opaqueLogPrefix`'s doc.
        guard !record.blobSHA256.isEmpty else {
            throw CacheError.notFound("blob for \(key.opaqueLogPrefix)")
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
                "CacheStore: hardlink fallback for \(key.opaqueLogPrefix, privacy: .public): \(error.localizedDescription, privacy: .public)"
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
            // Redacted at the throw site — see `CacheKey.opaqueLogPrefix`'s doc.
            throw CacheError.notFound(key.opaqueLogPrefix)
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
    static func inClauseBinding(_ shas: [String]) -> (placeholders: String, arguments: StatementArguments) {
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
    func deleteUnreferencedBlobs(shas: [String], onDeleted: ((String) -> Void)? = nil) async {
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
}
