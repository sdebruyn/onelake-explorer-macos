import CryptoKit
import Foundation
import GRDB
@testable import OfemKit
import Testing

// MARK: - ClockBox

/// A class-based wrapper for a mutable Int64 clock value.
///
/// Because it is a class (reference type), closures that capture it satisfy
/// the `@Sendable` requirement without triggering the
/// "captured var in concurrently-executing code" error.
final class ClockBox: @unchecked Sendable {
    var value: Int64
    init(value: Int64) {
        self.value = value
    }
}

// MARK: - CacheFixesTests

//
// Tests for the findings addressed in the cache work package:
//   cache-02/03  set-based eviction + TOCTOU
//   cache-04     wipe atomicity
//   cache-07     set-based tombstones
//   cache-08     orphan sweep logs errors (not discards)
//   cache-10     injectable clock determinism
//   cache-14     storeFromURL surfaces move errors
//   cache-15     blobIOError Equatable by domain+code
//   cache-20     storeBlob orphan on missing row
//   cache-23/24  sweep SHA reconstruction via BlobShardCache helper
//   cache-25     is_dir safe cast

@Suite("CacheFixes")
struct CacheFixesTests {
    // MARK: - cache-10: Injectable clock

    @Test("Injected clock controls timestamp written to DB")
    func injectableClockControlsTimestamp() async throws {
        // ClockBox is a class so the @Sendable closure can capture it without
        // triggering the "captured var in concurrent code" error.
        let tickBox = ClockBox(value: Int64(1_000_000))
        let store = try makeTempStore(clock: { tickBox.value })
        defer { try? FileManager.default.removeItem(at: store.root) }

        let key = CacheKey(accountAlias: "a", workspaceID: "w", itemID: "i", path: "f.txt")
        try await store.upsert(MetadataRecord(
            accountAlias: "a", workspaceID: "w", itemID: "i",
            path: "f.txt", parentPath: "", name: "f.txt", isDir: false,
            lastAccessedNs: 0, syncedAtNs: 0
        ))
        let r1 = try await store.fetch(key: key)
        #expect(r1.lastAccessedNs == 1_000_000)
        #expect(r1.syncedAtNs == 1_000_000)

        // Advance the clock and touch — must record the new time.
        tickBox.value = 2_000_000
        try await store.touch(key: key)
        let r2 = try await store.fetch(key: key)
        #expect(r2.lastAccessedNs == 2_000_000)
    }

    @Test("Injected clock makes LRU eviction order deterministic")
    func injectableClockMakesEvictionDeterministic() async throws {
        // Three blobs of 4 bytes each; budget = 6 bytes (forces eviction of ≥1).
        // We control last_accessed_ns via the clock so we know which blob is LRU.
        let tickBox = ClockBox(value: Int64(100))
        let store = try makeTempStore(maxBlobBytes: 6, clock: { tickBox.value })
        defer { try? FileManager.default.removeItem(at: store.root) }

        func add(path: String) async throws {
            try await store.upsert(MetadataRecord(
                accountAlias: "a", workspaceID: "w", itemID: "i",
                path: path, parentPath: "", name: path, isDir: false
            ))
            tickBox.value += 100
            try await store.storeBlob(
                key: CacheKey(accountAlias: "a", workspaceID: "w", itemID: "i", path: path),
                data: Data(path.utf8.prefix(4))
            )
        }

        try await add(path: "old.txt") // lastAccessedNs = 100 → LRU candidate
        try await add(path: "new.txt") // lastAccessedNs = 200 → stays

        // After eviction the total must be ≤ 6 bytes.
        let total = try await store.blobBytes()
        #expect(total <= 6)

        // The LRU blob (old.txt) must have been evicted; new.txt must survive.
        let oldRecord = try await store.fetch(
            key: CacheKey(accountAlias: "a", workspaceID: "w", itemID: "i", path: "old.txt")
        )
        let newRecord = try await store.fetch(
            key: CacheKey(accountAlias: "a", workspaceID: "w", itemID: "i", path: "new.txt")
        )
        #expect(oldRecord.blobSHA256.isEmpty, "LRU blob must have been evicted")
        #expect(!newRecord.blobSHA256.isEmpty, "MRU blob must survive eviction")
    }

    // MARK: - cache-02/03: Set-based eviction — no TOCTOU

    @Test("evictToLimit does not delete a blob still referenced by a surviving row")
    func evictResolvesBlobRefCountsInOneTransaction() async throws {
        // Two rows referencing the same SHA (identical data); the budget
        // exactly fits ONE copy. This only stays a no-op if the over-budget
        // decision is made with deduplicated accounting (C4) — a plain
        // SUM(blob_size) over both rows would see 10 > 5 and evict one of
        // them for zero bytes actually reclaimed (the blob file would
        // survive via the other row, so nothing is freed on disk).
        let store = try makeTempStore(maxBlobBytes: 5, clock: { 100 })
        defer { try? FileManager.default.removeItem(at: store.root) }

        let data = Data("hello".utf8) // 5 bytes
        let keyA = CacheKey(accountAlias: "a", workspaceID: "w", itemID: "i", path: "a.txt")
        let keyB = CacheKey(accountAlias: "a", workspaceID: "w", itemID: "i", path: "b.txt")

        for path in ["a.txt", "b.txt"] {
            try await store.upsert(MetadataRecord(
                accountAlias: "a", workspaceID: "w", itemID: "i",
                path: path, parentPath: "", name: path, isDir: false
            ))
        }
        // Both reference the same content (same SHA).
        try await store.storeBlob(key: keyA, data: data)
        try await store.storeBlob(key: keyB, data: data)

        // Deduplicated total is 5 bytes (one unique blob) which equals the
        // budget, so a correctly-accounted call is a strict no-op.
        let (evicted, reclaimed) = try await store.evictToLimit()
        #expect(evicted == 0, "Deduplicated total (5) is within budget (5); nothing should be evicted")
        #expect(reclaimed == 0)

        // BOTH rows must still have the blob link — not just "at least one".
        let rA = try await store.fetch(key: keyA)
        let rB = try await store.fetch(key: keyB)
        #expect(!rA.blobSHA256.isEmpty, "a.txt must retain its blob link")
        #expect(!rB.blobSHA256.isEmpty, "b.txt must retain its blob link")
        #expect(rA.blobSHA256 == rB.blobSHA256, "both rows share the same blob")

        // And the blob file must still be on disk.
        let blobCache = try BlobShardCache(blobRoot: store.blobRoot)
        let fileURL = blobCache.fileURL(sha256: rA.blobSHA256)
        #expect(fileURL != nil, "Blob file must still exist on disk when both rows reference it")
    }

    @Test("evictToLimit evicts the oldest row and reclaims real bytes when genuinely over budget")
    func evictToLimitEvictsOldestAndReclaimsRealBytesWhenOverBudget() async throws {
        // Two DISTINCT (non-shared) 5-byte blobs; budget fits only one, so
        // this is genuinely over budget under deduplicated accounting too.
        // Unlimited at init so the two storeBlob calls below don't trigger
        // an implicit eviction before the explicit call under test. An
        // incrementing clock (not a fixed one) is essential here: storeBlob
        // always stamps last_accessed_ns = clock() on write, so a fixed
        // clock would give both rows the same timestamp and leave LRU order
        // to an incidental rowid tie-break instead of testing it directly.
        let tickBox = ClockBox(value: Int64(100))
        let store = try makeTempStore(maxBlobBytes: 0, clock: { tickBox.value })
        defer { try? FileManager.default.removeItem(at: store.root) }

        let keyOld = CacheKey(accountAlias: "a", workspaceID: "w", itemID: "i", path: "old.bin")
        let keyNew = CacheKey(accountAlias: "a", workspaceID: "w", itemID: "i", path: "new.bin")

        try await store.upsert(MetadataRecord(
            accountAlias: "a", workspaceID: "w", itemID: "i",
            path: "old.bin", parentPath: "", name: "old.bin", isDir: false
        ))
        try await store.storeBlob(key: keyOld, data: Data("AAAAA".utf8)) // 5 distinct bytes, lastAccessedNs = 100

        tickBox.value = 200
        try await store.upsert(MetadataRecord(
            accountAlias: "a", workspaceID: "w", itemID: "i",
            path: "new.bin", parentPath: "", name: "new.bin", isDir: false
        ))
        try await store.storeBlob(key: keyNew, data: Data("BBBBB".utf8)) // 5 distinct bytes, lastAccessedNs = 200

        #expect(try await store.blobBytes() == 10, "two distinct 5-byte blobs, unlimited budget so far")

        // Tighten the budget after the fact and evict explicitly.
        await store.setMaxBlobBytes(5)
        let (evicted, reclaimed) = try await store.evictToLimit()

        #expect(evicted == 1, "only the older row's blob should be evicted")
        #expect(reclaimed == 5, "the evicted blob's real, non-shared size must be reclaimed")
        #expect(try await store.blobBytes() == 5, "deduplicated total must now be at/below budget")

        let oldAfter = try await store.fetch(key: keyOld)
        let newAfter = try await store.fetch(key: keyNew)
        #expect(oldAfter.blobSHA256.isEmpty, "LRU blob must have been evicted")
        #expect(!newAfter.blobSHA256.isEmpty, "MRU blob must survive eviction")

        // The evicted blob's file must actually be gone from disk (real bytes
        // reclaimed) while the surviving blob's file remains.
        let blobCache = try BlobShardCache(blobRoot: store.blobRoot)
        let oldSHA = SHA256.hash(data: Data("AAAAA".utf8)).map { String(format: "%02x", $0) }.joined()
        #expect(blobCache.fileURL(sha256: oldSHA) == nil, "evicted blob's file must be deleted from disk")
        #expect(blobCache.fileURL(sha256: newAfter.blobSHA256) != nil, "surviving blob's file must remain on disk")
    }

    // MARK: - cache-04: wipe atomicity

    @Test("wipe returns accurate count and bytes from DB")
    func wipeReturnsAccurateCountAndBytes() async throws {
        let store = try makeTempStore()
        defer { try? FileManager.default.removeItem(at: store.root) }

        let keyA = CacheKey(accountAlias: "a", workspaceID: "w", itemID: "i", path: "a.bin")
        let keyB = CacheKey(accountAlias: "a", workspaceID: "w", itemID: "i", path: "b.bin")
        let dataA = Data("AAA".utf8)
        let dataB = Data("BBBBBB".utf8)

        for path in ["a.bin", "b.bin"] {
            try await store.upsert(MetadataRecord(
                accountAlias: "a", workspaceID: "w", itemID: "i",
                path: path, parentPath: "", name: path, isDir: false
            ))
        }
        try await store.storeBlob(key: keyA, data: dataA)
        try await store.storeBlob(key: keyB, data: dataB)

        let beforeBytes = try await store.blobBytes()
        let (count, bytes) = try await store.wipe()

        // wipe must report the same byte total as blobBytes() did before the wipe.
        #expect(bytes == beforeBytes)
        // count = distinct SHAs (2 distinct blobs here).
        #expect(count == 2)

        // After wipe: no DB links remain.
        let afterBytes = try await store.blobBytes()
        #expect(afterBytes == 0)

        // After wipe: no blob files on disk.
        let (diskCount, _) = try await store.diskUsage()
        #expect(diskCount == 0)
    }

    @Test("wipe uses the same deduplicated-bytes logic as blobBytes()")
    func wipeUsesSameDeduplicatedBytesAsBlobBytes() async throws {
        // Two rows with the same SHA — blob_size is stored per-row but the
        // dedup query should count it once.
        let store = try makeTempStore()
        defer { try? FileManager.default.removeItem(at: store.root) }

        let data = Data("shared".utf8)
        let keyA = CacheKey(accountAlias: "a", workspaceID: "w", itemID: "i", path: "a.bin")
        let keyB = CacheKey(accountAlias: "a", workspaceID: "w", itemID: "i", path: "b.bin")
        for path in ["a.bin", "b.bin"] {
            try await store.upsert(MetadataRecord(
                accountAlias: "a", workspaceID: "w", itemID: "i",
                path: path, parentPath: "", name: path, isDir: false
            ))
        }
        try await store.storeBlob(key: keyA, data: data)
        try await store.storeBlob(key: keyB, data: data)

        let blobBytesBeforeWipe = try await store.blobBytes()
        let (_, wipedBytes) = try await store.wipe()

        // wipe() and blobBytes() must agree on the byte total.
        #expect(wipedBytes == blobBytesBeforeWipe)
        // Dedup: 6 bytes stored once, not 12 (two rows × 6 bytes each).
        #expect(wipedBytes == Int64(data.count))
    }

    // MARK: - cache-07: Set-based tombstones

    @Test("delete writes all tombstones in one transaction")
    func deleteWritesTombstonesInOneTransaction() async throws {
        let store = try makeTempStore()
        defer { try? FileManager.default.removeItem(at: store.root) }

        let anchorNs: Int64 = 1000
        for path in ["dir", "dir/a.txt", "dir/b.txt", "dir/c.txt"] {
            try await store.upsert(MetadataRecord(
                accountAlias: "a", workspaceID: "w", itemID: "i",
                path: path, parentPath: path == "dir" ? "" : "dir",
                name: (path as NSString).lastPathComponent, isDir: path == "dir",
                syncedAtNs: anchorNs - 1
            ))
        }

        let dirKey = CacheKey(accountAlias: "a", workspaceID: "w", itemID: "i", path: "dir")
        try await store.delete(key: dirKey)

        let (_, deleted) = try await store.itemsChangedAfter(accountAlias: "a", ns: anchorNs)
        // All four rows must have tombstones.
        #expect(deleted.count == 4)
        let sorted = deleted.sorted()
        #expect(sorted.contains("w/i/dir"))
        #expect(sorted.contains("w/i/dir/a.txt"))
        #expect(sorted.contains("w/i/dir/b.txt"))
        #expect(sorted.contains("w/i/dir/c.txt"))
    }

    // MARK: - cache-20: storeBlob orphan on missing row

    @Test("storeBlob throws notFound when metadata row is absent (orphan is later swept)")
    func storeBlobOrphanOnMissingRow() async throws {
        let store = try makeTempStore()
        defer { try? FileManager.default.removeItem(at: store.root) }

        let key = CacheKey(accountAlias: "a", workspaceID: "w", itemID: "i", path: "ghost.bin")
        // No upsert — the row does not exist.
        await #expect(throws: CacheError.notFound(key.opaqueLogPrefix)) {
            try await store.storeBlob(key: key, data: Data("bytes".utf8))
        }

        // The orphan blob on disk must be cleaned up by the sweep.
        try await store.sweepOrphans()
        let (diskCount, _) = try await store.diskUsage()
        #expect(diskCount == 0, "Orphan blob must be reclaimed by sweep after storeBlob on missing row")
    }

    // MARK: - cache-15: blobIOError Equatable by domain+code

    @Test("blobIOError Equatable compares by NSError domain+code")
    func blobIOErrorEquatableComparesDomainAndCode() {
        let diskFull = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError)
        let permDenied = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError)
        let diskFull2 = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError)

        let e1 = CacheError.blobIOError(diskFull)
        let e2 = CacheError.blobIOError(permDenied)
        let e3 = CacheError.blobIOError(diskFull2)

        // Same domain+code → equal.
        #expect(e1 == e3)
        // Different code → not equal.
        #expect(e1 != e2)
    }

    // MARK: - cache-23: BlobShardCache.sha(fromShard:file:)

    @Test("BlobShardCache sha(fromShard:file:) reconstructs the correct SHA")
    func blobShardCacheSHAReconstruction() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let cache = try BlobShardCache(blobRoot: tmp)

        let sha = String(repeating: "a", count: BlobShardCache.shaLength)
        let shard = String(sha.prefix(BlobShardCache.shardPrefixLength))
        let file = String(sha.dropFirst(BlobShardCache.shardPrefixLength))

        let reconstructed = cache.sha(fromShard: shard, file: file)
        #expect(reconstructed == sha)
    }

    @Test("BlobShardCache sha(fromShard:file:) returns nil for malformed input")
    func blobShardCacheSHAReconstructionMalformed() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let cache = try BlobShardCache(blobRoot: tmp)

        // Too short
        #expect(cache.sha(fromShard: "ab", file: "short") == nil)
        // Empty
        #expect(cache.sha(fromShard: "", file: "") == nil)
    }

    // MARK: - cache-25: is_dir safe cast

    @Test("MetadataRecord init(row:) decodes is_dir = 1 as true")
    func metadataRecordIsDirDecoding() async throws {
        let store = try makeTempStore()
        defer { try? FileManager.default.removeItem(at: store.root) }

        try await store.upsert(MetadataRecord(
            accountAlias: "a", workspaceID: "w", itemID: "i",
            path: "dir", parentPath: "", name: "dir", isDir: true
        ))
        let record = try await store.fetch(
            key: CacheKey(accountAlias: "a", workspaceID: "w", itemID: "i", path: "dir")
        )
        #expect(record.isDir == true)
    }

    @Test("MetadataRecord init(row:) decodes is_dir = 0 as false")
    func metadataRecordIsDirDecodingFalse() async throws {
        let store = try makeTempStore()
        defer { try? FileManager.default.removeItem(at: store.root) }

        try await store.upsert(MetadataRecord(
            accountAlias: "a", workspaceID: "w", itemID: "i",
            path: "f.txt", parentPath: "", name: "f.txt", isDir: false
        ))
        let record = try await store.fetch(
            key: CacheKey(accountAlias: "a", workspaceID: "w", itemID: "i", path: "f.txt")
        )
        #expect(record.isDir == false)
    }

    // MARK: - cache-08: Orphan sweep surfaces errors (not fire-and-forget)

    @Test("sweepOrphans (synchronous) removes orphaned blobs from disk")
    func sweepOrphansSynchronousRemovesOrphans() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tmp) }

        // Write a blob, then clear the DB reference to create an orphan.
        do {
            let store = try CacheStore(root: tmp)
            let key = CacheKey(accountAlias: "a", workspaceID: "w", itemID: "i", path: "f.bin")
            try await store.upsert(MetadataRecord(
                accountAlias: "a", workspaceID: "w", itemID: "i",
                path: "f.bin", parentPath: "", name: "f.bin", isDir: false
            ))
            try await store.storeBlob(key: key, data: Data("orphan data".utf8))
            // Orphan: clear DB reference without deleting the file.
            try await store.dbPool.write { db in
                try db.execute(sql: "UPDATE path_metadata SET blob_sha256 = '', blob_size = 0")
            }
        }

        // Re-open and run sweep explicitly.
        let store2 = try CacheStore(root: tmp)
        defer { try? FileManager.default.removeItem(at: store2.root) }
        // sweepOrphans must not throw — it is the same code path as the init-time sweep.
        try await store2.sweepOrphans()

        let (diskCount, _) = try await store2.diskUsage()
        #expect(diskCount == 0, "Orphan blob must be reclaimed by synchronous sweep")
    }

    // MARK: - Batch chunking (cache-22): batchUpsert and batchDelete

    @Test("batchUpsert handles large batches without error")
    func batchUpsertLargeBatch() async throws {
        let store = try makeTempStore()
        defer { try? FileManager.default.removeItem(at: store.root) }

        // 1200 records: exceeds the chunk size of 500 so spans multiple transactions.
        let records = (0 ..< 1200).map { i in
            MetadataRecord(
                accountAlias: "a", workspaceID: "w", itemID: "i",
                path: "file-\(i).txt", parentPath: "", name: "file-\(i).txt", isDir: false,
                contentLength: Int64(i)
            )
        }
        try await store.batchUpsert(records)

        // Spot-check first and last.
        let first = try await store.fetch(
            key: CacheKey(accountAlias: "a", workspaceID: "w", itemID: "i", path: "file-0.txt")
        )
        #expect(first.contentLength == 0)
        let last = try await store.fetch(
            key: CacheKey(accountAlias: "a", workspaceID: "w", itemID: "i", path: "file-1199.txt")
        )
        #expect(last.contentLength == 1199)
    }

    @Test("batchDelete handles large batches without error")
    func batchDeleteLargeBatch() async throws {
        let store = try makeTempStore()
        defer { try? FileManager.default.removeItem(at: store.root) }

        let keys = (0 ..< 1200).map { i in
            CacheKey(accountAlias: "a", workspaceID: "w", itemID: "i", path: "file-\(i).txt")
        }
        let records = keys.map { k in
            MetadataRecord(
                accountAlias: k.accountAlias, workspaceID: k.workspaceID, itemID: k.itemID,
                path: k.path, parentPath: "", name: k.path, isDir: false
            )
        }
        try await store.batchUpsert(records)
        // Deleting all keys (large batch) must not throw.
        try await store.batchDelete(keys, recordTombstones: false)

        // All rows must be gone.
        await #expect(throws: CacheError.notFound(keys[0].opaqueLogPrefix)) {
            try await store.fetch(key: keys[0])
        }
    }

    // MARK: - cache-06: subtree WHERE helper used consistently

    @Test("batchDelete removes subtree paths using LIKE prefix scan")
    func batchDeleteRemovesSubtree() async throws {
        let store = try makeTempStore()
        defer { try? FileManager.default.removeItem(at: store.root) }

        for path in ["dir", "dir/a.txt", "dir/b.txt", "other.txt"] {
            try await store.upsert(MetadataRecord(
                accountAlias: "a", workspaceID: "w", itemID: "i",
                path: path, parentPath: path == "dir" ? "" : "dir",
                name: (path as NSString).lastPathComponent, isDir: path == "dir"
            ))
        }

        let dirKey = CacheKey(accountAlias: "a", workspaceID: "w", itemID: "i", path: "dir")
        try await store.batchDelete([dirKey], recordTombstones: false)

        // Subtree must be gone.
        for path in ["dir", "dir/a.txt", "dir/b.txt"] {
            let k = CacheKey(accountAlias: "a", workspaceID: "w", itemID: "i", path: path)
            await #expect(throws: CacheError.notFound(k.opaqueLogPrefix)) { try await store.fetch(key: k) }
        }
        // Sibling row must survive.
        let other = try await store.fetch(
            key: CacheKey(accountAlias: "a", workspaceID: "w", itemID: "i", path: "other.txt")
        )
        #expect(other.name == "other.txt")
    }

    // MARK: - Atomic upsert+delete (#427 / review M2)

    @Test("batchUpsertAndDelete upserts new rows and deletes vanished rows in one call")
    func batchUpsertAndDeleteHappyPath() async throws {
        let store = try makeTempStore()
        defer { try? FileManager.default.removeItem(at: store.root) }

        try await store.upsert(MetadataRecord(
            accountAlias: "a", workspaceID: "w", itemID: "i",
            path: "gone.txt", parentPath: "", name: "gone.txt", isDir: false
        ))

        let upsertKey = CacheKey(accountAlias: "a", workspaceID: "w", itemID: "i", path: "new.txt")
        let deleteKey = CacheKey(accountAlias: "a", workspaceID: "w", itemID: "i", path: "gone.txt")
        try await store.batchUpsertAndDelete(
            upserts: [MetadataRecord(
                accountAlias: "a", workspaceID: "w", itemID: "i",
                path: "new.txt", parentPath: "", name: "new.txt", isDir: false
            )],
            deletes: [deleteKey],
            recordTombstones: true
        )

        let created = try await store.fetch(key: upsertKey)
        #expect(created.name == "new.txt")
        // The specific deleted key (deleteKey, not upsertKey) throwing is the
        // discriminator here — the redacted payload itself doesn't need to
        // carry the raw path for that.
        await #expect(throws: CacheError.notFound(deleteKey.opaqueLogPrefix)) {
            try await store.fetch(key: deleteKey)
        }
    }

    @Test("batchUpsertAndDelete rolls back the upsert half when the delete half fails")
    func batchUpsertAndDeleteRollsBackOnDeleteFailure() async throws {
        let store = try makeTempStore()
        defer { try? FileManager.default.removeItem(at: store.root) }

        try await store.upsert(MetadataRecord(
            accountAlias: "a", workspaceID: "w", itemID: "i",
            path: "gone.txt", parentPath: "", name: "gone.txt", isDir: false
        ))

        // Fail exactly the "gone.txt" delete — a stand-in for a transient
        // SQLITE_BUSY/SQLITE_FULL landing mid-transaction.
        try await store.dbPool.write { db in
            try db.execute(sql: """
            CREATE TEMP TRIGGER fail_gone_delete BEFORE DELETE ON path_metadata
            WHEN OLD.path = 'gone.txt'
            BEGIN SELECT RAISE(ABORT, 'simulated delete-phase failure'); END;
            """)
        }

        let upsertKey = CacheKey(accountAlias: "a", workspaceID: "w", itemID: "i", path: "new.txt")
        let deleteKey = CacheKey(accountAlias: "a", workspaceID: "w", itemID: "i", path: "gone.txt")

        await #expect(throws: (any Error).self) {
            try await store.batchUpsertAndDelete(
                upserts: [MetadataRecord(
                    accountAlias: "a", workspaceID: "w", itemID: "i",
                    path: "new.txt", parentPath: "", name: "new.txt", isDir: false
                )],
                deletes: [deleteKey],
                recordTombstones: true
            )
        }

        // Neither half took effect: the upsert rolled back along with the
        // delete. Fetching the specific upsertKey (not deleteKey) throwing,
        // plus deleteKey's row surviving below, is the discriminator — not
        // the redacted payload text.
        await #expect(throws: CacheError.notFound(upsertKey.opaqueLogPrefix)) {
            try await store.fetch(key: upsertKey)
        }
        let survivor = try await store.fetch(key: deleteKey)
        #expect(survivor.name == "gone.txt")
    }
}
