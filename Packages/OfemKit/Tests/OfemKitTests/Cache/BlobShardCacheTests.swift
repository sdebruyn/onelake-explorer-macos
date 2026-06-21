import CryptoKit
import Foundation
@testable import OfemKit
import Testing

// MARK: - BlobShardCacheTests

/// Tests for `BlobShardCache` and the LRU eviction logic in `CacheStore`.
@Suite("BlobShardCache")
struct BlobShardCacheTests {
    // MARK: - Store + Load

    @Test("Store and load a blob")
    func storeAndLoad() throws {
        let (cache, tmp) = try makeBlobCache()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let data = Data("hello world".utf8)
        let (sha, size) = try cache.store(data)
        #expect(sha.count == 64)
        #expect(size == Int64(data.count))

        let loaded = try cache.load(sha256: sha)
        #expect(loaded == data)
    }

    @Test("Store is idempotent")
    func storeIsIdempotent() throws {
        let (cache, tmp) = try makeBlobCache()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let data = Data("test".utf8)
        let (sha1, size1) = try cache.store(data)
        let (sha2, size2) = try cache.store(data)
        #expect(sha1 == sha2)
        #expect(size1 == size2)
    }

    @Test("Load missing blob throws notFound")
    func loadMissingThrowsNotFound() throws {
        let (cache, tmp) = try makeBlobCache()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let fakeSHA = String(repeating: "a", count: 64)
        #expect(throws: CacheError.notFound("blob \(fakeSHA)")) {
            try cache.load(sha256: fakeSHA)
        }
    }

    @Test("Delete removes blob file")
    func deleteRemovesFile() throws {
        let (cache, tmp) = try makeBlobCache()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let data = Data("bye".utf8)
        let (sha, _) = try cache.store(data)
        try cache.delete(sha256: sha)
        #expect(throws: CacheError.notFound("blob \(sha)")) {
            try cache.load(sha256: sha)
        }
    }

    @Test("Delete missing blob is a no-op")
    func deleteMissingIsNoOp() throws {
        let (cache, tmp) = try makeBlobCache()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let fakeSHA = String(repeating: "b", count: 64)
        try cache.delete(sha256: fakeSHA)
    }

    // MARK: - SHA validation (tests-16: specific error cases)

    @Test("Invalid SHA length throws invalidSHA")
    func invalidSHALength() throws {
        let (cache, tmp) = try makeBlobCache()
        defer { try? FileManager.default.removeItem(at: tmp) }
        #expect(throws: CacheError.invalidSHA("abc")) {
            try cache.load(sha256: "abc")
        }
    }

    @Test("Uppercase SHA throws invalidSHA")
    func uppercaseSHAThrows() throws {
        let (cache, tmp) = try makeBlobCache()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let upperSHA = String(repeating: "A", count: 64)
        #expect(throws: CacheError.invalidSHA(upperSHA)) {
            try cache.load(sha256: upperSHA)
        }
    }

    // MARK: - Shard layout

    @Test("Blob is stored in correct shard directory")
    func blobStoredInCorrectShard() throws {
        let (cache, rootURL) = try makeBlobCache()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let data = Data("shard test".utf8)
        let (sha, _) = try cache.store(data)

        let prefix = String(sha.prefix(2))
        let suffix = String(sha.dropFirst(2))
        let expected = rootURL.appendingPathComponent(prefix).appendingPathComponent(suffix)
        #expect(FileManager.default.fileExists(atPath: expected.path))
    }

    // MARK: - Shard sibling safety (store-01 regression)

    @Test("Delete removes only the keyed file and leaves shard siblings intact")
    func deletePreservesSiblingBlobs() throws {
        let (cache, tmp) = try makeBlobCache()
        defer { try? FileManager.default.removeItem(at: tmp) }

        // Find two blobs that share a shard prefix (same first two hex chars).
        var shaA = "", shaB = ""
        var dataA = Data(), dataB = Data()
        var i = 0
        var j = 1
        while true {
            let da = Data("sibling-\(i)".utf8)
            let db2 = Data("sibling-\(j)".utf8)
            let sa = sha256Hex(da)
            let sb = sha256Hex(db2)
            if String(sa.prefix(2)) == String(sb.prefix(2)), sa != sb {
                shaA = sa; dataA = da; shaB = sb; dataB = db2; break
            }
            j += 1
            if j > 1000 { i += 1; j = i + 1 }
        }

        _ = try cache.store(dataA)
        _ = try cache.store(dataB)

        // Delete A — B must survive and remain loadable.
        try cache.delete(sha256: shaA)

        // A is gone.
        #expect(throws: CacheError.notFound("blob \(shaA)")) {
            try cache.load(sha256: shaA)
        }

        // B is intact.
        let loaded = try cache.load(sha256: shaB)
        #expect(loaded == dataB)
    }

    @Test("Delete prunes empty shard directory when last blob is removed")
    func deleteEmptyShardDirectoryPruned() throws {
        let (cache, tmp) = try makeBlobCache()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let data = Data("only blob in its shard hopefully".utf8)
        let (sha, _) = try cache.store(data)
        let shardDir = tmp.appendingPathComponent(String(sha.prefix(2)), isDirectory: true)
        try cache.delete(sha256: sha)
        #expect(!FileManager.default.fileExists(atPath: shardDir.path))
    }

    @Test("Delete does not prune shard directory when siblings remain")
    func deleteDoesNotPruneNonEmptyShard() throws {
        let (cache, tmp) = try makeBlobCache()
        defer { try? FileManager.default.removeItem(at: tmp) }

        var shaA = ""
        var dataA = Data(), dataB = Data()
        var i = 0; var j = 1
        while true {
            let da = Data("keepA-\(i)".utf8); let db2 = Data("keepB-\(j)".utf8)
            let sa = sha256Hex(da); let sb = sha256Hex(db2)
            if String(sa.prefix(2)) == String(sb.prefix(2)), sa != sb {
                shaA = sa; dataA = da; dataB = db2; break
            }
            j += 1; if j > 1000 { i += 1; j = i + 1 }
        }

        _ = try cache.store(dataA)
        _ = try cache.store(dataB)
        let shardDir = tmp.appendingPathComponent(String(shaA.prefix(2)), isDirectory: true)

        try cache.delete(sha256: shaA)

        // Shard dir must still exist because B is still there.
        #expect(FileManager.default.fileExists(atPath: shardDir.path))
    }

    // MARK: - Disk usage

    @Test("DiskUsage returns correct count and bytes")
    func diskUsageReturnsCorrect() throws {
        let (cache, tmp) = try makeBlobCache()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let d1 = Data("alpha".utf8)
        let d2 = Data("beta".utf8)
        _ = try cache.store(d1)
        _ = try cache.store(d2)

        let (count, bytes) = try cache.diskUsage()
        #expect(count == 2)
        #expect(bytes == Int64(d1.count + d2.count))
    }

    @Test("DiskUsage is 0 for empty blob root")
    func diskUsageEmpty() throws {
        let (cache, tmp) = try makeBlobCache()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let (count, bytes) = try cache.diskUsage()
        #expect(count == 0)
        #expect(bytes == 0)
    }

    // MARK: - LRU eviction via CacheStore (tests-15: assert strict LRU order)

    @Test("EvictToLimit removes LRU blobs first, MRU blob survives")
    func evictToLimitEnforcesLRUOrder() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tmp) }

        // Seed blobs via a no-budget store so auto-eviction doesn't fire during
        // setup.  Use a `do` block to ensure seedStore releases its DatabasePool
        // WAL handles before limitedStore opens the same file — opening two pools
        // on the same path simultaneously is fragile and would also hold WAL locks
        // that prevent the defer cleanup from removing the tmp directory.
        let keyA = CacheKey(accountAlias: "a", workspaceID: "w", itemID: "i", path: "a.txt")
        let keyB = CacheKey(accountAlias: "a", workspaceID: "w", itemID: "i", path: "b.txt")
        let keyC = CacheKey(accountAlias: "a", workspaceID: "w", itemID: "i", path: "c.txt")

        do {
            // Max 0 bytes = no auto-eviction; lets us build a known state.
            let seedStore = try CacheStore(root: tmp, maxBlobBytes: 0)
            // LRU order: a.txt (100) < b.txt (200) < c.txt (300).
            try await seedStore.upsert(MetadataRecord(
                accountAlias: "a", workspaceID: "w", itemID: "i",
                path: "a.txt", parentPath: "", name: "a.txt", isDir: false, lastAccessedNs: 100
            ))
            try await seedStore.upsert(MetadataRecord(
                accountAlias: "a", workspaceID: "w", itemID: "i",
                path: "b.txt", parentPath: "", name: "b.txt", isDir: false, lastAccessedNs: 200
            ))
            try await seedStore.upsert(MetadataRecord(
                accountAlias: "a", workspaceID: "w", itemID: "i",
                path: "c.txt", parentPath: "", name: "c.txt", isDir: false, lastAccessedNs: 300
            ))
            // Max 5 bytes; 3 blobs of 4 bytes each = 12 total.
            try await seedStore.storeBlob(key: keyA, data: Data("old1".utf8))
            try await seedStore.storeBlob(key: keyB, data: Data("old2".utf8))
            try await seedStore.storeBlob(key: keyC, data: Data("new1".utf8))
        }
        // seedStore is now out of scope — its DatabasePool is deallocated and
        // WAL handles are released before limitedStore opens the same file.

        // Now open with the actual budget (5 bytes) and evict.
        let limitedStore = try CacheStore(root: tmp, maxBlobBytes: 5)
        let totalBefore = try await limitedStore.blobBytes()
        #expect(totalBefore == 12)

        let (evicted, reclaimed) = try await limitedStore.evictToLimit()
        #expect(evicted > 0)
        #expect(reclaimed > 0)
        let totalAfter = try await limitedStore.blobBytes()
        #expect(totalAfter <= 5)

        // c.txt (MRU, lastAccessed=300) must survive.
        let cRec = try await limitedStore.fetch(key: keyC)
        #expect(!cRec.blobSHA256.isEmpty, "c.txt (MRU) must not be evicted")

        // a.txt (LRU, lastAccessed=100) must be gone.
        let aRec = try await limitedStore.fetch(key: keyA)
        #expect(aRec.blobSHA256.isEmpty, "a.txt (LRU) must be evicted first")
    }

    @Test("EvictToLimit is no-op when maxBlobBytes is 0")
    func evictToLimitNoOpWhenZero() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let store = try CacheStore(root: tmp, maxBlobBytes: 0)
        try await store.upsert(MetadataRecord(
            accountAlias: "a", workspaceID: "w", itemID: "i",
            path: "f.txt", parentPath: "", name: "f.txt", isDir: false
        ))
        try await store.storeBlob(
            key: CacheKey(accountAlias: "a", workspaceID: "w", itemID: "i", path: "f.txt"),
            data: Data("x".utf8)
        )

        let (evicted, reclaimed) = try await store.evictToLimit()
        #expect(evicted == 0)
        #expect(reclaimed == 0)
    }

    // MARK: - storeFromURL dedup returns correct size (blocker-4 regression)

    @Test("storeFromURL deduplicate path returns the source file size, not 0 (blocker-4)")
    func storeFromURLDedupReturnsCorrectSize() throws {
        let (cache, tmp) = try makeBlobCache()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let content = Data(repeating: 0x42, count: 256)

        // Write a temp file and store it (first store — moves it to the blob store).
        let src1 = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try content.write(to: src1)
        // Use a copy so the original stays available for the second store call.
        let src2 = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try content.write(to: src2)

        let (sha1, size1) = try cache.storeFromURL(src1)
        #expect(size1 == 256, "first store must return 256 bytes")

        // Second store: the blob already exists — dedup path must return 256, not 0.
        let (sha2, size2) = try cache.storeFromURL(src2)
        #expect(sha1 == sha2, "SHA must match — same content")
        #expect(size2 == 256, "dedup store must return the actual size, not 0 (blocker-4)")
    }

    // MARK: - fileURL

    @Test("fileURL returns the on-disk URL for a stored blob")
    func fileURLReturnsURLForStoredBlob() throws {
        let (cache, tmp) = try makeBlobCache()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let data = Data("file url test".utf8)
        let (sha, _) = try cache.store(data)
        let url = cache.fileURL(sha256: sha)
        #expect(url != nil)
        #expect(FileManager.default.fileExists(atPath: try #require(url?.path)))
    }

    @Test("fileURL returns nil when blob is not present")
    func fileURLReturnsNilForMissingBlob() throws {
        let (cache, tmp) = try makeBlobCache()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let fakeSHA = String(repeating: "c", count: 64)
        #expect(cache.fileURL(sha256: fakeSHA) == nil)
    }

    @Test("fileURL returns nil for a SHA with incorrect length")
    func fileURLReturnsNilForBadLength() throws {
        let (cache, tmp) = try makeBlobCache()
        defer { try? FileManager.default.removeItem(at: tmp) }
        #expect(cache.fileURL(sha256: "tooshort") == nil)
    }

    // MARK: - storeFromURL (first-time move path)

    @Test("storeFromURL moves source file into the blob store on first store")
    func storeFromURLFirstStore() throws {
        let (cache, tmp) = try makeBlobCache()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let content = Data("storeFromURL content".utf8)
        let srcURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try content.write(to: srcURL)
        // Source is in the same temp volume; moveItem should succeed.

        let (sha, size) = try cache.storeFromURL(srcURL)
        #expect(sha.count == 64)
        #expect(size == Int64(content.count))

        // Blob must be loadable.
        let loaded = try cache.load(sha256: sha)
        #expect(loaded == content)
    }

    @Test("storeFromURL dedup path: second store of same content returns correct sha and size")
    func storeFromURLDedup() throws {
        let (cache, tmp) = try makeBlobCache()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let content = Data(repeating: 0x99, count: 128)
        let src1 = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let src2 = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try content.write(to: src1)
        try content.write(to: src2)

        let (sha1, size1) = try cache.storeFromURL(src1)
        let (sha2, size2) = try cache.storeFromURL(src2)

        #expect(sha1 == sha2)
        #expect(size1 == 128)
        #expect(size2 == 128)
    }

    @Test("storeFromURL preserves blob content identically")
    func storeFromURLPreservesContent() throws {
        let (cache, tmp) = try makeBlobCache()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let content = Data((0 ..< 512).map { UInt8($0 & 0xFF) })
        let srcURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try content.write(to: srcURL)

        let (sha, _) = try cache.storeFromURL(srcURL)
        let loaded = try cache.load(sha256: sha)
        #expect(loaded == content)
    }

    // MARK: - diskUsage when blobRoot is gone

    @Test("diskUsage returns (0, 0) when blobRoot does not exist")
    func diskUsageWhenRootMissing() throws {
        let (cache, tmp) = try makeBlobCache()
        // Manually remove the root to simulate missing directory.
        try FileManager.default.removeItem(at: tmp)

        let (count, bytes) = try cache.diskUsage()
        #expect(count == 0)
        #expect(bytes == 0)
    }

    @Test("diskUsage excludes .tmp files")
    func diskUsageExcludesTmpFiles() throws {
        let (cache, tmp) = try makeBlobCache()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let data = Data("real blob".utf8)
        _ = try cache.store(data)

        // Plant a stray .tmp file directly under blobRoot.
        let strayTmp = tmp.appendingPathComponent("leftover.tmp")
        try Data("garbage".utf8).write(to: strayTmp)

        let (count, bytes) = try cache.diskUsage()
        #expect(count == 1)
        #expect(bytes == Int64(data.count))
    }

    // MARK: - wipeAll (BlobShardCache struct, not CacheStore)

    @Test("wipeAll removes all shard directories")
    func wipeAllRemovesShards() throws {
        let (cache, tmp) = try makeBlobCache()
        defer { try? FileManager.default.removeItem(at: tmp) }

        _ = try cache.store(Data("a".utf8))
        _ = try cache.store(Data("b".utf8))

        let (countBefore, _) = try cache.diskUsage()
        #expect(countBefore == 2)

        cache.wipeAll()

        let (countAfter, bytesAfter) = try cache.diskUsage()
        #expect(countAfter == 0)
        #expect(bytesAfter == 0)
    }

    // MARK: - SHA validation in delete

    @Test("delete throws invalidSHA for a too-short SHA")
    func deleteThrowsInvalidSHAForBadLength() throws {
        let (cache, tmp) = try makeBlobCache()
        defer { try? FileManager.default.removeItem(at: tmp) }
        #expect(throws: CacheError.invalidSHA("bad")) {
            try cache.delete(sha256: "bad")
        }
    }

    @Test("delete throws invalidSHA for non-hex characters")
    func deleteThrowsInvalidSHAForNonHex() throws {
        let (cache, tmp) = try makeBlobCache()
        defer { try? FileManager.default.removeItem(at: tmp) }
        // 64 chars, but contains 'g' which is not valid hex.
        let badSHA = String(repeating: "g", count: 64)
        #expect(throws: CacheError.invalidSHA(badSHA)) {
            try cache.delete(sha256: badSHA)
        }
    }

    // MARK: - shardPath layout

    @Test("shardPath splits SHA into 2-char prefix and 62-char suffix")
    func shardPathLayout() throws {
        let (cache, tmp) = try makeBlobCache()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let sha = String(repeating: "a", count: 64)
        let (dir, file) = cache.shardPath(for: sha)
        #expect(dir.lastPathComponent == "aa")
        #expect(file.lastPathComponent == String(repeating: "a", count: 62))
        #expect(file.deletingLastPathComponent() == dir)
    }

    // MARK: - validateSHA

    @Test("validateSHA accepts a valid 64-char lowercase hex string")
    func validateSHAAcceptsValid() throws {
        let (cache, tmp) = try makeBlobCache()
        defer { try? FileManager.default.removeItem(at: tmp) }
        // All hex digits 0-9 and a-f are valid.
        let valid = "0123456789abcdef" + String(repeating: "a", count: 48)
        // Should not throw.
        try cache.validateSHA(valid)
    }

    @Test("validateSHA rejects SHA with uppercase letters")
    func validateSHARejectsUppercase() throws {
        let (cache, tmp) = try makeBlobCache()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let upper = String(repeating: "A", count: 64)
        do {
            try cache.validateSHA(upper)
            Issue.record("Expected invalidSHA")
        } catch let CacheError.invalidSHA(sha) {
            #expect(sha == upper)
        }
    }

    @Test("validateSHA rejects SHA with 63 characters (one short)")
    func validateSHARejectsTooShort() throws {
        let (cache, tmp) = try makeBlobCache()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let short = String(repeating: "a", count: 63)
        do {
            try cache.validateSHA(short)
            Issue.record("Expected invalidSHA")
        } catch let CacheError.invalidSHA(sha) {
            #expect(sha == short)
        }
    }

    // MARK: - load throws blobIOError for non-missing filesystem errors

    @Test("load throws notFound for a SHA that points to a missing file")
    func loadThrowsNotFoundForMissingFile() throws {
        let (cache, tmp) = try makeBlobCache()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let sha = String(repeating: "d", count: 64)
        do {
            _ = try cache.load(sha256: sha)
            Issue.record("Expected notFound")
        } catch let CacheError.notFound(desc) {
            #expect(desc.contains(sha))
        }
    }

    // MARK: - Concurrent store of the same SHA

    @Test("Concurrent stores of the same content produce identical SHA and are idempotent")
    func concurrentStoresSameContent() async throws {
        let (cache, tmp) = try makeBlobCache()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let content = Data(repeating: 0x42, count: 1024)
        let expectedSHA = sha256Hex(content)

        // Launch multiple concurrent stores of the same data.
        try await withThrowingTaskGroup(of: (String, Int64).self) { group in
            for _ in 0 ..< 8 {
                group.addTask {
                    try cache.store(content)
                }
            }
            for try await (sha, size) in group {
                #expect(sha == expectedSHA)
                #expect(size == Int64(content.count))
            }
        }

        // Exactly one blob file must exist.
        let (count, bytes) = try cache.diskUsage()
        #expect(count == 1)
        #expect(bytes == Int64(content.count))
    }

    // MARK: - Wipe

    @Test("Wipe clears all blobs and metadata links")
    func wipeAll() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let store = try CacheStore(root: tmp)
        let key = CacheKey(accountAlias: "a", workspaceID: "w", itemID: "i", path: "f.txt")
        try await store.upsert(MetadataRecord(
            accountAlias: "a", workspaceID: "w", itemID: "i",
            path: "f.txt", parentPath: "", name: "f.txt", isDir: false
        ))
        try await store.storeBlob(key: key, data: Data("hello".utf8))
        #expect(try await store.blobBytes() == 5)

        let (count, bytes) = try await store.wipe()
        #expect(count == 1)
        #expect(bytes == 5)
        #expect(try await store.blobBytes() == 0)

        // Metadata row still exists but blob columns are cleared.
        let row = try await store.fetch(key: key)
        #expect(row.blobSHA256.isEmpty)
        #expect(row.blobSize == 0)
    }
}

// MARK: - Helpers

/// Creates a `BlobShardCache` in a unique temporary directory.
private func makeBlobCache() throws -> (BlobShardCache, URL) {
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let cache = try BlobShardCache(blobRoot: tmp)
    return (cache, tmp)
}

/// Returns the lowercase hex SHA-256 of `data` using CryptoKit directly.
private func sha256Hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}
