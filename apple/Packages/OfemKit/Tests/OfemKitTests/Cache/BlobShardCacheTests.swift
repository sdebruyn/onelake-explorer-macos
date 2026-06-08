import Foundation
import Testing

@testable import OfemKit

// MARK: - BlobShardCacheTests

/// Tests for `BlobShardCache` and the LRU eviction logic in `CacheStore`.
@Suite("BlobShardCache")
struct BlobShardCacheTests {

    // MARK: - Store + Load

    @Test("Store and load a blob")
    func storeAndLoad() throws {
        let (cache, _) = try makeBlobCache()
        let data = Data("hello world".utf8)
        let (sha, size) = try cache.store(data)
        #expect(sha.count == 64)
        #expect(size == Int64(data.count))

        let loaded = try cache.load(sha256: sha)
        #expect(loaded == data)
    }

    @Test("Store is idempotent")
    func storeIsIdempotent() throws {
        let (cache, _) = try makeBlobCache()
        let data = Data("test".utf8)
        let (sha1, size1) = try cache.store(data)
        let (sha2, size2) = try cache.store(data)
        #expect(sha1 == sha2)
        #expect(size1 == size2)
    }

    @Test("Load missing blob throws notFound")
    func loadMissingThrowsNotFound() throws {
        let (cache, _) = try makeBlobCache()
        let fakeSHA = String(repeating: "a", count: 64)
        #expect(throws: CacheError.self) {
            try cache.load(sha256: fakeSHA)
        }
    }

    @Test("Delete removes blob file")
    func deleteRemovesFile() throws {
        let (cache, _) = try makeBlobCache()
        let data = Data("bye".utf8)
        let (sha, _) = try cache.store(data)
        try cache.delete(sha256: sha)
        #expect(throws: CacheError.self) { try cache.load(sha256: sha) }
    }

    @Test("Delete missing blob is a no-op")
    func deleteMissingIsNoOp() throws {
        let (cache, _) = try makeBlobCache()
        let fakeSHA = String(repeating: "b", count: 64)
        try cache.delete(sha256: fakeSHA)
    }

    // MARK: - SHA validation

    @Test("Invalid SHA length throws invalidSHA")
    func invalidSHALength() throws {
        let (cache, _) = try makeBlobCache()
        #expect(throws: CacheError.self) { try cache.load(sha256: "abc") }
    }

    @Test("Uppercase SHA throws invalidSHA")
    func uppercaseSHAThrows() throws {
        let (cache, _) = try makeBlobCache()
        let upperSHA = String(repeating: "A", count: 64)
        #expect(throws: CacheError.self) { try cache.load(sha256: upperSHA) }
    }

    // MARK: - Shard layout

    @Test("Blob is stored in correct shard directory")
    func blobStoredInCorrectShard() throws {
        let (cache, rootURL) = try makeBlobCache()
        let data = Data("shard test".utf8)
        let (sha, _) = try cache.store(data)

        let prefix = String(sha.prefix(2))
        let suffix = String(sha.dropFirst(2))
        let expected = rootURL.appendingPathComponent(prefix).appendingPathComponent(suffix)
        #expect(FileManager.default.fileExists(atPath: expected.path))
    }

    // MARK: - Disk usage

    @Test("DiskUsage returns correct count and bytes")
    func diskUsageReturnsCorrect() throws {
        let (cache, _) = try makeBlobCache()
        let d1 = Data("alpha".utf8)
        let d2 = Data("beta".utf8)
        try cache.store(d1)
        try cache.store(d2)

        let (count, bytes) = try cache.diskUsage()
        #expect(count == 2)
        #expect(bytes == Int64(d1.count + d2.count))
    }

    @Test("DiskUsage is 0 for empty blob root")
    func diskUsageEmpty() throws {
        let (cache, _) = try makeBlobCache()
        let (count, bytes) = try cache.diskUsage()
        #expect(count == 0)
        #expect(bytes == 0)
    }

    // MARK: - LRU eviction via CacheStore

    @Test("EvictToLimit removes LRU blobs until under limit")
    func evictToLimit() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tmp) }

        // Max 5 bytes; we store 3 blobs of 4 bytes each = 12 total.
        let store = try CacheStore(root: tmp, maxBlobBytes: 5)

        func addBlob(path: String, content: String, accessedNs: Int64) async throws {
            var rec = MetadataRecord(
                accountAlias: "a", workspaceID: "w", itemID: "i",
                path: path, parentPath: "", name: path, isDir: false
            )
            rec.lastAccessedNs = accessedNs
            try await store.upsert(rec)
            try await store.storeBlob(
                key: CacheKey(accountAlias: "a", workspaceID: "w", itemID: "i", path: path),
                data: Data(content.utf8)
            )
        }

        try await addBlob(path: "a.txt", content: "old1", accessedNs: 100)
        try await addBlob(path: "b.txt", content: "old2", accessedNs: 200)
        try await addBlob(path: "c.txt", content: "new1", accessedNs: 300)

        let totalBefore = try await store.blobBytes()
        #expect(totalBefore == 12)

        let (evicted, reclaimed) = try await store.evictToLimit()
        #expect(evicted > 0)
        #expect(reclaimed > 0)
        let totalAfter = try await store.blobBytes()
        #expect(totalAfter <= 5)
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

/// Creates a `BlobShardCache` in a temporary directory.
private func makeBlobCache() throws -> (BlobShardCache, URL) {
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let cache = try BlobShardCache(blobRoot: tmp)
    return (cache, tmp)
}
