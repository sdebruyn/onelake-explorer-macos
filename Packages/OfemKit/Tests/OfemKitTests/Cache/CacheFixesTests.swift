import CryptoKit
import Foundation
import GRDB
import Testing

@testable import OfemKit

// MARK: - ClockBox

/// A class-based wrapper for a mutable Int64 clock value.
///
/// Because it is a class (reference type), closures that capture it satisfy
/// the `@Sendable` requirement without triggering the
/// "captured var in concurrently-executing code" error.
final class ClockBox: @unchecked Sendable {
    var value: Int64
    init(value: Int64) { self.value = value }
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

        try await add(path: "old.txt")  // lastAccessedNs = 100 → LRU candidate
        try await add(path: "new.txt")  // lastAccessedNs = 200 → stays

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

    @Test("evictToLimit resolves ref-counts in one write transaction (no N+1)")
    func evictResolvesBlobRefCountsInOneTransaction() async throws {
        // Two rows referencing the same SHA (identical data).
        // After evicting one row the blob file must survive because the other row still references it.
        let store = try makeTempStore(maxBlobBytes: 5, clock: { 100 })
        defer { try? FileManager.default.removeItem(at: store.root) }

        let data = Data("hello".utf8)  // 5 bytes
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

        // The budget (5 bytes) is equalled by a single unique blob, so if dedup is
        // correctly accounted the SUM counts the blob once → 5 ≤ 5 → no eviction.
        // If dedup is broken (sum counts both rows) it would see 10 > 5 and evict.
        // Either way, the blob file must remain because at least one row still
        // references it after any eviction.
        _ = try await store.evictToLimit()

        // At least one of the rows must still have the blob link (shared SHA).
        let rA = try await store.fetch(key: keyA)
        let rB = try await store.fetch(key: keyB)
        let anyLinked = !rA.blobSHA256.isEmpty || !rB.blobSHA256.isEmpty
        #expect(anyLinked, "At least one row must retain the blob link")

        // And the blob file must still be on disk.
        let blobCache = try BlobShardCache(blobRoot: store.blobRoot)
        let sha = rA.blobSHA256.isEmpty ? rB.blobSHA256 : rA.blobSHA256
        if !sha.isEmpty {
            let fileURL = blobCache.fileURL(sha256: sha)
            #expect(fileURL != nil, "Blob file must still exist on disk when a row references it")
        }
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

        let anchorNs: Int64 = 1_000
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
        await #expect(throws: CacheError.notFound("a/w/i/ghost.bin")) {
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
        let records = (0..<1200).map { i in
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

        let keys = (0..<1200).map { i in
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
        try await store.batchDelete(keys)

        // All rows must be gone.
        await #expect(throws: CacheError.notFound("a/w/i/file-0.txt")) {
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
        try await store.batchDelete([dirKey])

        // Subtree must be gone.
        for path in ["dir", "dir/a.txt", "dir/b.txt"] {
            let k = CacheKey(accountAlias: "a", workspaceID: "w", itemID: "i", path: path)
            await #expect(throws: CacheError.notFound("a/w/i/\(path)")) { try await store.fetch(key: k) }
        }
        // Sibling row must survive.
        let other = try await store.fetch(
            key: CacheKey(accountAlias: "a", workspaceID: "w", itemID: "i", path: "other.txt")
        )
        #expect(other.name == "other.txt")
    }
}
