import Foundation
import GRDB
@testable import OfemKit
import Testing

// MARK: - CacheStoreTests

/// Tests for the `CacheStore` CRUD operations and WAL concurrency behaviour.
@Suite("CacheStore")
struct CacheStoreTests {
    // MARK: - Upsert + Fetch

    @Test("Upsert and fetch a metadata row")
    func upsertAndFetch() async throws {
        let store = try makeTempStore()
        defer { try? FileManager.default.removeItem(at: store.root) }
        let key = CacheKey(accountAlias: "work", workspaceID: "ws1", itemID: "item1", path: "Files/hello.txt")
        let record = MetadataRecord(
            accountAlias: "work",
            workspaceID: "ws1",
            itemID: "item1",
            path: "Files/hello.txt",
            parentPath: "Files",
            name: "hello.txt",
            isDir: false,
            contentLength: 42,
            etag: "abc123"
        )
        try await store.upsert(record)

        let fetched = try await store.fetch(key: key)
        #expect(fetched.name == "hello.txt")
        #expect(fetched.contentLength == 42)
        #expect(fetched.etag == "abc123")
        #expect(!fetched.isDir)
    }

    @Test("Upsert with empty blobSHA256 clears an existing blob link (documented behaviour)")
    func upsertWithEmptySHAClearsBlobLink() async throws {
        let store = try makeTempStore()
        defer { try? FileManager.default.removeItem(at: store.root) }
        let key = CacheKey(accountAlias: "a", workspaceID: "w", itemID: "i", path: "linked.bin")

        // Set up a row with a blob link.
        try await store.upsert(MetadataRecord(
            accountAlias: "a", workspaceID: "w", itemID: "i",
            path: "linked.bin", parentPath: "", name: "linked.bin", isDir: false
        ))
        try await store.storeBlob(key: key, data: Data("content".utf8))
        let before = try await store.fetch(key: key)
        #expect(!before.blobSHA256.isEmpty, "precondition: blob link must be set")

        // Re-upsert the same row but with blobSHA256 == "" (default).
        // This is the documented ON CONFLICT DO UPDATE SET behaviour: every
        // column in encode(to:) is overwritten, so callers must carry forward
        // the current blob columns if they want to preserve them.
        var cleared = before
        cleared.blobSHA256 = ""
        cleared.blobSize = 0
        try await store.upsert(cleared)

        let after = try await store.fetch(key: key)
        #expect(after.blobSHA256.isEmpty, "upsert with empty SHA must clear the blob link")
        #expect(after.blobSize == 0)
    }

    @Test("Upsert updates an existing row")
    func upsertUpdatesExistingRow() async throws {
        let store = try makeTempStore()
        defer { try? FileManager.default.removeItem(at: store.root) }
        let key = CacheKey(accountAlias: "work", workspaceID: "ws1", itemID: "item1", path: "Files/hello.txt")
        var r = MetadataRecord(
            accountAlias: "work", workspaceID: "ws1", itemID: "item1",
            path: "Files/hello.txt", parentPath: "Files", name: "hello.txt", isDir: false,
            contentLength: 10
        )
        try await store.upsert(r)
        r.contentLength = 99
        r.etag = "new-etag"
        try await store.upsert(r)

        let fetched = try await store.fetch(key: key)
        #expect(fetched.contentLength == 99)
        #expect(fetched.etag == "new-etag")
    }

    @Test("Fetch missing row throws notFound")
    func fetchMissingRowThrowsNotFound() async throws {
        let store = try makeTempStore()
        defer { try? FileManager.default.removeItem(at: store.root) }
        let key = CacheKey(accountAlias: "work", workspaceID: "ws1", itemID: "item1", path: "nope")
        await #expect(throws: CacheError.notFound("work/ws1/item1/nope")) {
            try await store.fetch(key: key)
        }
    }

    @Test("Upsert fills timestamps when zero")
    func upsertFillsTimestamps() async throws {
        let store = try makeTempStore()
        defer { try? FileManager.default.removeItem(at: store.root) }
        let record = MetadataRecord(
            accountAlias: "work", workspaceID: "ws1", itemID: "item1",
            path: "Files/x.txt", parentPath: "Files", name: "x.txt", isDir: false
        )
        #expect(record.lastAccessedNs == 0)
        #expect(record.syncedAtNs == 0)
        try await store.upsert(record)

        let fetched = try await store.fetch(key: CacheKey(
            accountAlias: "work", workspaceID: "ws1", itemID: "item1", path: "Files/x.txt"
        ))
        #expect(fetched.lastAccessedNs > 0)
        #expect(fetched.syncedAtNs > 0)
    }

    // MARK: - Children

    @Test("Children returns direct children only")
    func childrenReturnsDirect() async throws {
        let store = try makeTempStore()
        defer { try? FileManager.default.removeItem(at: store.root) }
        let alias = "work"; let ws = "ws1"; let item = "item1"

        try await store.upsert(MetadataRecord(
            accountAlias: alias, workspaceID: ws, itemID: item,
            path: "", parentPath: "", name: "item1", isDir: true
        ))
        try await store.upsert(MetadataRecord(
            accountAlias: alias, workspaceID: ws, itemID: item,
            path: "Files", parentPath: "", name: "Files", isDir: true
        ))
        try await store.upsert(MetadataRecord(
            accountAlias: alias, workspaceID: ws, itemID: item,
            path: "readme.md", parentPath: "", name: "readme.md", isDir: false
        ))
        // Grandchild — should NOT appear.
        try await store.upsert(MetadataRecord(
            accountAlias: alias, workspaceID: ws, itemID: item,
            path: "Files/deep.txt", parentPath: "Files", name: "deep.txt", isDir: false
        ))

        let rootKey = CacheKey(accountAlias: alias, workspaceID: ws, itemID: item, path: "")
        let children = try await store.children(of: rootKey)
        #expect(children.count == 2)
        // Sorted: dirs first, then files.
        #expect(children[0].name == "Files")
        #expect(children[1].name == "readme.md")
    }

    @Test("Root row excluded from its own children")
    func rootExcludedFromChildren() async throws {
        let store = try makeTempStore()
        defer { try? FileManager.default.removeItem(at: store.root) }
        try await store.upsert(MetadataRecord(
            accountAlias: "a", workspaceID: "w", itemID: "i",
            path: "", parentPath: "", name: "item", isDir: true
        ))
        let rootKey = CacheKey(accountAlias: "a", workspaceID: "w", itemID: "i", path: "")
        let children = try await store.children(of: rootKey)
        #expect(children.isEmpty)
    }

    // MARK: - Delete

    @Test("Delete removes a single row")
    func deleteSingleRow() async throws {
        let store = try makeTempStore()
        defer { try? FileManager.default.removeItem(at: store.root) }
        let key = CacheKey(accountAlias: "a", workspaceID: "w", itemID: "i", path: "f.txt")
        try await store.upsert(MetadataRecord(
            accountAlias: "a", workspaceID: "w", itemID: "i",
            path: "f.txt", parentPath: "", name: "f.txt", isDir: false
        ))
        try await store.delete(key: key)
        await #expect(throws: CacheError.notFound("a/w/i/f.txt")) { try await store.fetch(key: key) }
    }

    @Test("Delete cascades to descendants")
    func deleteCascadesToDescendants() async throws {
        let store = try makeTempStore()
        defer { try? FileManager.default.removeItem(at: store.root) }
        let alias = "a"; let ws = "w"; let item = "i"
        for path in ["dir", "dir/a.txt", "dir/b.txt", "dir/sub/c.txt"] {
            try await store.upsert(MetadataRecord(
                accountAlias: alias, workspaceID: ws, itemID: item,
                path: path, parentPath: "", name: path, isDir: path == "dir"
            ))
        }
        let dirKey = CacheKey(accountAlias: alias, workspaceID: ws, itemID: item, path: "dir")
        try await store.delete(key: dirKey)

        for path in ["dir", "dir/a.txt", "dir/b.txt", "dir/sub/c.txt"] {
            let k = CacheKey(accountAlias: alias, workspaceID: ws, itemID: item, path: path)
            await #expect(throws: CacheError.notFound("\(alias)/\(ws)/\(item)/\(path)")) {
                try await store.fetch(key: k)
            }
        }
    }

    @Test("Delete is a no-op for missing keys")
    func deleteMissingKeyIsNoOp() async throws {
        let store = try makeTempStore()
        defer { try? FileManager.default.removeItem(at: store.root) }
        let key = CacheKey(accountAlias: "a", workspaceID: "w", itemID: "i", path: "ghost.txt")
        try await store.delete(key: key)
    }

    // MARK: - Delete blob lifecycle (store-26 regression tests)

    @Test("Delete removes blob file and clears metadata link")
    func deleteBlobFileAndClearsMetadataLink() async throws {
        let store = try makeTempStore()
        defer { try? FileManager.default.removeItem(at: store.root) }
        let key = CacheKey(accountAlias: "a", workspaceID: "w", itemID: "i", path: "file.bin")
        try await store.upsert(MetadataRecord(
            accountAlias: "a", workspaceID: "w", itemID: "i",
            path: "file.bin", parentPath: "", name: "file.bin", isDir: false
        ))
        try await store.storeBlob(key: key, data: Data("content".utf8))

        // Confirm blob is linked.
        let before = try await store.fetch(key: key)
        #expect(!before.blobSHA256.isEmpty)

        try await store.delete(key: key)

        // Blob file must be gone from disk.
        let (diskCount, _) = try await store.diskUsage()
        #expect(diskCount == 0)
    }

    @Test("Delete preserves sibling blob in same shard (store-01 regression)")
    func deletePreservesSiblingInSameShard() async throws {
        let store = try makeTempStore()
        defer { try? FileManager.default.removeItem(at: store.root) }

        // We need two blobs whose SHA-256 values share the same 2-hex prefix so
        // they land in the same shard directory.  Build them by brute-force search
        // over small deterministic byte strings.
        var shaA = ""
        var dataA = Data()
        var shaB = ""
        var dataB = Data()

        var i = 0
        var j = 1
        while true {
            let da = Data("blob-\(i)".utf8)
            let db2 = Data("blob-\(j)".utf8)
            let sa = SHA256HexString(da)
            let sb = SHA256HexString(db2)
            if String(sa.prefix(2)) == String(sb.prefix(2)), sa != sb {
                shaA = sa; dataA = da
                shaB = sb; dataB = db2
                break
            }
            j += 1
            if j > 1000 { i += 1; j = i + 1 }
        }

        let keyA = CacheKey(accountAlias: "a", workspaceID: "w", itemID: "i", path: "a.bin")
        let keyB = CacheKey(accountAlias: "a", workspaceID: "w", itemID: "i", path: "b.bin")
        try await store.upsert(MetadataRecord(
            accountAlias: "a", workspaceID: "w", itemID: "i",
            path: "a.bin", parentPath: "", name: "a.bin", isDir: false
        ))
        try await store.upsert(MetadataRecord(
            accountAlias: "a", workspaceID: "w", itemID: "i",
            path: "b.bin", parentPath: "", name: "b.bin", isDir: false
        ))
        try await store.storeBlob(key: keyA, data: dataA)
        try await store.storeBlob(key: keyB, data: dataB)

        // Verify both land in the same shard directory.
        let prefix = String(shaA.prefix(2))
        #expect(String(shaB.prefix(2)) == prefix, "Test precondition: both blobs must share a shard prefix")

        // Delete only A.
        try await store.delete(key: keyA)

        // Sibling B must still be loadable.
        let loaded = try await store.loadBlob(key: keyB)
        #expect(loaded == dataB)

        // B's shard directory still exists on disk.
        let shardDir = store.blobRoot.appendingPathComponent(prefix, isDirectory: true)
        #expect(FileManager.default.fileExists(atPath: shardDir.path))
    }

    @Test("Deleting last blob in shard prunes the empty shard directory")
    func deletePrunesEmptyShardDirectory() async throws {
        let store = try makeTempStore()
        defer { try? FileManager.default.removeItem(at: store.root) }
        let key = CacheKey(accountAlias: "a", workspaceID: "w", itemID: "i", path: "solo.bin")
        try await store.upsert(MetadataRecord(
            accountAlias: "a", workspaceID: "w", itemID: "i",
            path: "solo.bin", parentPath: "", name: "solo.bin", isDir: false
        ))
        let data = Data("unique content xyz".utf8)
        try await store.storeBlob(key: key, data: data)

        let sha = try await store.fetch(key: key)
        let shardDir = store.blobRoot.appendingPathComponent(String(sha.blobSHA256.prefix(2)), isDirectory: true)

        try await store.delete(key: key)

        // The shard directory should have been pruned since it is now empty.
        #expect(!FileManager.default.fileExists(atPath: shardDir.path))
    }

    @Test("Shared blob SHA survives when one of two referencing rows is deleted")
    func sharedSHASurvivesPartialDelete() async throws {
        let store = try makeTempStore()
        defer { try? FileManager.default.removeItem(at: store.root) }
        let data = Data("shared content".utf8)
        let keyA = CacheKey(accountAlias: "a", workspaceID: "w", itemID: "i", path: "a.txt")
        let keyB = CacheKey(accountAlias: "a", workspaceID: "w", itemID: "i", path: "b.txt")
        try await store.upsert(MetadataRecord(
            accountAlias: "a", workspaceID: "w", itemID: "i",
            path: "a.txt", parentPath: "", name: "a.txt", isDir: false
        ))
        try await store.upsert(MetadataRecord(
            accountAlias: "a", workspaceID: "w", itemID: "i",
            path: "b.txt", parentPath: "", name: "b.txt", isDir: false
        ))
        // Both reference the same SHA (identical data).
        try await store.storeBlob(key: keyA, data: data)
        try await store.storeBlob(key: keyB, data: data)

        // Delete only A — the blob file must survive because B still references it.
        try await store.delete(key: keyA)
        let loaded = try await store.loadBlob(key: keyB)
        #expect(loaded == data)
    }

    @Test("escapeLike path containing wildcard characters is deleted correctly")
    func deleteWithLikeMetacharsInPath() async throws {
        let store = try makeTempStore()
        defer { try? FileManager.default.removeItem(at: store.root) }
        let path = "dir_with%special/file.txt"
        let key = CacheKey(accountAlias: "a", workspaceID: "w", itemID: "i", path: path)
        try await store.upsert(MetadataRecord(
            accountAlias: "a", workspaceID: "w", itemID: "i",
            path: path, parentPath: "", name: "file.txt", isDir: false
        ))
        // Must not throw and must delete only this row.
        try await store.delete(key: key)
        await #expect(throws: CacheError.notFound("a/w/i/\(path)")) { try await store.fetch(key: key) }
    }

    // MARK: - Touch

    @Test("Touch bumps last_accessed_ns")
    func touchBumpsLastAccessed() async throws {
        let store = try makeTempStore()
        defer { try? FileManager.default.removeItem(at: store.root) }
        let key = CacheKey(accountAlias: "a", workspaceID: "w", itemID: "i", path: "f.txt")
        var r = MetadataRecord(
            accountAlias: "a", workspaceID: "w", itemID: "i",
            path: "f.txt", parentPath: "", name: "f.txt", isDir: false
        )
        r.lastAccessedNs = 1000
        try await store.upsert(r)

        try await store.touch(key: key)
        let fetched = try await store.fetch(key: key)
        #expect(fetched.lastAccessedNs > 1000)
    }

    @Test("Touch throws notFound for missing row")
    func touchMissingThrows() async throws {
        let store = try makeTempStore()
        defer { try? FileManager.default.removeItem(at: store.root) }
        let key = CacheKey(accountAlias: "a", workspaceID: "w", itemID: "i", path: "ghost.txt")
        await #expect(throws: CacheError.notFound("a/w/i/ghost.txt")) {
            try await store.touch(key: key)
        }
    }

    // MARK: - HotItems

    @Test("HotItems returns items accessed at or after since")
    func hotItemsReturnsRecentItems() async throws {
        let store = try makeTempStore()
        defer { try? FileManager.default.removeItem(at: store.root) }
        let nowNs = Int64(Date().timeIntervalSince1970 * 1_000_000_000)
        let oneHourAgoNs = nowNs - 3_600_000_000_000

        try await store.upsert(MetadataRecord(
            accountAlias: "a", workspaceID: "hot-ws", itemID: "hot-item",
            path: "f.txt", parentPath: "", name: "f.txt", isDir: false,
            lastAccessedNs: nowNs
        ))
        try await store.upsert(MetadataRecord(
            accountAlias: "a", workspaceID: "cold-ws", itemID: "cold-item",
            path: "f.txt", parentPath: "", name: "f.txt", isDir: false,
            lastAccessedNs: oneHourAgoNs - 1
        ))

        let since = Date(timeIntervalSince1970: Double(oneHourAgoNs) / 1_000_000_000)
        let hot = try await store.hotItems(since: since)
        #expect(hot.count == 1)
        #expect(hot[0].workspaceID == "hot-ws")
    }

    // MARK: - Validation (tests-16: specific error cases)

    @Test("Missing accountAlias throws missingArgument")
    func missingAliasThrows() async throws {
        let store = try makeTempStore()
        defer { try? FileManager.default.removeItem(at: store.root) }
        let key = CacheKey(accountAlias: "", workspaceID: "w", itemID: "i", path: "f.txt")
        await #expect(throws: CacheError.missingArgument("accountAlias")) {
            try await store.fetch(key: key)
        }
    }

    @Test("Missing workspaceID throws missingArgument")
    func missingWorkspaceIDThrows() async throws {
        let store = try makeTempStore()
        defer { try? FileManager.default.removeItem(at: store.root) }
        let key = CacheKey(accountAlias: "a", workspaceID: "", itemID: "i", path: "f.txt")
        await #expect(throws: CacheError.missingArgument("workspaceID")) {
            try await store.fetch(key: key)
        }
    }

    @Test("Missing itemID throws missingArgument")
    func missingItemIDThrows() async throws {
        let store = try makeTempStore()
        defer { try? FileManager.default.removeItem(at: store.root) }
        let key = CacheKey(accountAlias: "a", workspaceID: "w", itemID: "", path: "f.txt")
        await #expect(throws: CacheError.missingArgument("itemID")) {
            try await store.fetch(key: key)
        }
    }

    // MARK: - Reader

    @Test("Reader can read rows written by the store")
    func readerSeesWrittenRows() async throws {
        let store = try makeTempStore()
        defer { try? FileManager.default.removeItem(at: store.root) }
        let key = CacheKey(accountAlias: "a", workspaceID: "w", itemID: "i", path: "f.txt")
        try await store.upsert(MetadataRecord(
            accountAlias: "a", workspaceID: "w", itemID: "i",
            path: "f.txt", parentPath: "", name: "f.txt", isDir: false,
            contentLength: 77
        ))

        let reader = store.reader()
        let row = try await reader.fetch(key: key)
        #expect(row.contentLength == 77)
    }

    // MARK: - StoreBlob

    @Test("StoreBlob throws notFound when metadata row is missing")
    func storeBlobMissingRowThrows() async throws {
        let store = try makeTempStore()
        defer { try? FileManager.default.removeItem(at: store.root) }
        let key = CacheKey(accountAlias: "a", workspaceID: "w", itemID: "i", path: "ghost.txt")
        await #expect(throws: CacheError.notFound("a/w/i/ghost.txt")) {
            try await store.storeBlob(key: key, data: Data("hello".utf8))
        }
    }

    // MARK: - loadBlob dangling link (store-04 regression)

    @Test("LoadBlob clears dangling blob_sha256 link when file is missing from disk")
    func loadBlobClearsDanglingLink() async throws {
        let store = try makeTempStore()
        defer { try? FileManager.default.removeItem(at: store.root) }
        let key = CacheKey(accountAlias: "a", workspaceID: "w", itemID: "i", path: "f.bin")
        try await store.upsert(MetadataRecord(
            accountAlias: "a", workspaceID: "w", itemID: "i",
            path: "f.bin", parentPath: "", name: "f.bin", isDir: false
        ))
        try await store.storeBlob(key: key, data: Data("data".utf8))

        // Manually delete the blob file on disk to simulate external removal.
        let sha = try await store.fetch(key: key)
        let blobCache = try BlobShardCache(blobRoot: store.blobRoot)
        let (shardDir, blobFile) = blobCache.shardPath(for: sha.blobSHA256)
        try FileManager.default.removeItem(at: blobFile)
        // Remove the shard dir if empty so it doesn't interfere.
        try? FileManager.default.removeItem(at: shardDir)

        // loadBlob must throw notFound.
        await #expect(throws: CacheError.notFound("blob for f.bin")) {
            try await store.loadBlob(key: key)
        }

        // After the failed load, the metadata row's blob_sha256 must be cleared.
        let after = try await store.fetch(key: key)
        #expect(after.blobSHA256.isEmpty)
        #expect(after.blobSize == 0)

        // blobBytes() must reflect the cleared link.
        let bytes = try await store.blobBytes()
        #expect(bytes == 0)
    }

    // MARK: - Auto-eviction after storeBlob (store-02 regression)

    @Test("StoreBlob auto-evicts to stay under maxBlobBytes budget")
    func storeBlobAutoEvictsToLimit() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tmp) }

        // Budget: 6 bytes; each blob is 4 bytes — first two fit (8 > 6 triggers eviction).
        let store = try CacheStore(root: tmp, maxBlobBytes: 6)

        func add(path: String, accessedNs: Int64) async throws {
            var rec = MetadataRecord(
                accountAlias: "a", workspaceID: "w", itemID: "i",
                path: path, parentPath: "", name: path, isDir: false
            )
            rec.lastAccessedNs = accessedNs
            try await store.upsert(rec)
            try await store.storeBlob(
                key: CacheKey(accountAlias: "a", workspaceID: "w", itemID: "i", path: path),
                data: Data(path.utf8.prefix(4))
            )
        }

        try await add(path: "old.txt", accessedNs: 100)
        try await add(path: "new.txt", accessedNs: 200)

        let total = try await store.blobBytes()
        #expect(total <= 6)
    }

    // MARK: - Orphan sweep at init (store-03 regression)

    @Test("Init-time orphan sweep removes blob files with no DB reference")
    func initTimeSweepRemovesOrphans() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tmp) }

        // Create an initial store and write a blob.
        do {
            let store = try CacheStore(root: tmp)
            let key = CacheKey(accountAlias: "a", workspaceID: "w", itemID: "i", path: "f.bin")
            try await store.upsert(MetadataRecord(
                accountAlias: "a", workspaceID: "w", itemID: "i",
                path: "f.bin", parentPath: "", name: "f.bin", isDir: false
            ))
            try await store.storeBlob(key: key, data: Data("blob content".utf8))

            // Delete the metadata row but leave the blob file — simulates an orphan.
            try await store.dbPool.write { db in
                try db.execute(sql: "UPDATE path_metadata SET blob_sha256 = '', blob_size = 0")
            }
        }

        // Reopen the store and run the orphan sweep explicitly — the background
        // Task started at init time may not have completed yet.
        let store2 = try CacheStore(root: tmp)
        defer { try? FileManager.default.removeItem(at: store2.root) }
        try await store2.sweepOrphans()
        let (diskCount, _) = try await store2.diskUsage()
        #expect(diskCount == 0)
    }

    // MARK: - Reader

    @Test("Reader.children returns correct rows")
    func readerChildrenWorks() async throws {
        let store = try makeTempStore()
        defer { try? FileManager.default.removeItem(at: store.root) }
        let alias = "a"; let ws = "w"; let item = "i"
        try await store.upsert(MetadataRecord(
            accountAlias: alias, workspaceID: ws, itemID: item,
            path: "dir", parentPath: "", name: "dir", isDir: true
        ))
        try await store.upsert(MetadataRecord(
            accountAlias: alias, workspaceID: ws, itemID: item,
            path: "dir/child.txt", parentPath: "dir", name: "child.txt", isDir: false
        ))

        let reader = store.reader()
        let children = try await reader.children(of: CacheKey(
            accountAlias: alias, workspaceID: ws, itemID: item, path: "dir"
        ))
        #expect(children.count == 1)
        #expect(children[0].name == "child.txt")
    }

    // MARK: - Deletion tombstones (C1)

    @Test("delete writes a tombstone; itemsChangedAfter returns the deleted identifier")
    func deletionTombstoneAppearsInChangedAfter() async throws {
        let store = try makeTempStore()
        defer { try? FileManager.default.removeItem(at: store.root) }

        let anchorNs: Int64 = 1_000_000_000

        // Insert a file entry with a synced_at_ns before the anchor.
        let record = MetadataRecord(
            accountAlias: "dev",
            workspaceID: "ws-1",
            itemID: "lh-1",
            path: "Files/gone.txt",
            parentPath: "Files",
            name: "gone.txt",
            isDir: false,
            contentLength: 10,
            etag: "\"v1\"",
            syncedAtNs: anchorNs - 1
        )
        try await store.upsert(record)

        // Snapshot: at anchorNs, the file exists and no deletions are pending.
        let (updatedBefore, deletedBefore) = try await store.itemsChangedAfter(
            accountAlias: "dev",
            ns: anchorNs
        )
        #expect(updatedBefore.isEmpty)
        #expect(deletedBefore.isEmpty)

        // Simulate reconciliation: remote no longer lists "Files/gone.txt".
        let key = CacheKey(accountAlias: "dev", workspaceID: "ws-1", itemID: "lh-1", path: "Files/gone.txt")
        try await store.delete(key: key)

        // The item must be gone from path_metadata.
        let fetched = try? await store.fetch(key: key)
        #expect(fetched == nil)

        // itemsChangedAfter must surface the deletion via the tombstone table.
        let (updatedAfter, deletedAfter) = try await store.itemsChangedAfter(
            accountAlias: "dev",
            ns: anchorNs
        )
        #expect(updatedAfter.isEmpty)
        #expect(deletedAfter.count == 1)
        #expect(deletedAfter.first == "ws-1/lh-1/Files/gone.txt")
    }

    @Test("delete of a directory writes tombstones for all descendants")
    func deletionTombstoneCoversDescendants() async throws {
        let store = try makeTempStore()
        defer { try? FileManager.default.removeItem(at: store.root) }

        let anchorNs: Int64 = 1_000_000_000

        // Insert parent dir + two children.
        for (path, parentPath, name, isDir) in [
            ("Files/dir", "Files", "dir", true),
            ("Files/dir/a.csv", "Files/dir", "a.csv", false),
            ("Files/dir/b.csv", "Files/dir", "b.csv", false),
        ] {
            try await store.upsert(MetadataRecord(
                accountAlias: "dev", workspaceID: "ws-1", itemID: "lh-1",
                path: path, parentPath: parentPath, name: name, isDir: isDir,
                syncedAtNs: anchorNs - 1
            ))
        }

        // Delete the parent directory (should cascade to children).
        let dirKey = CacheKey(accountAlias: "dev", workspaceID: "ws-1", itemID: "lh-1", path: "Files/dir")
        try await store.delete(key: dirKey)

        let (_, deleted) = try await store.itemsChangedAfter(accountAlias: "dev", ns: anchorNs)
        // All three rows must have tombstones.
        let sortedDeleted = deleted.sorted()
        #expect(sortedDeleted.contains("ws-1/lh-1/Files/dir"))
        #expect(sortedDeleted.contains("ws-1/lh-1/Files/dir/a.csv"))
        #expect(sortedDeleted.contains("ws-1/lh-1/Files/dir/b.csv"))
    }

    // MARK: - Batch operations (tests-12: moved from SyncEngineTests)

    @Test("batchUpsert inserts multiple records in a single call")
    func batchUpsertInsertsAll() async throws {
        let store = try makeTempStore()
        defer { try? FileManager.default.removeItem(at: store.root) }

        let records = (0 ..< 10).map { i in
            MetadataRecord(
                accountAlias: "a", workspaceID: "ws", itemID: "it",
                path: "f\(i).txt", parentPath: "", name: "f\(i).txt",
                isDir: false, contentLength: Int64(i)
            )
        }
        try await store.batchUpsert(records)

        let root = MetadataRecord(
            accountAlias: "a", workspaceID: "ws", itemID: "it",
            path: "", parentPath: "", name: "root", isDir: true
        )
        try await store.upsert(root)

        let key = CacheKey(accountAlias: "a", workspaceID: "ws", itemID: "it", path: "")
        let children = try await store.children(of: key)
        #expect(children.count == 10)
    }

    @Test("batchDelete removes multiple keys in one call")
    func batchDeleteRemovesAll() async throws {
        let store = try makeTempStore()
        defer { try? FileManager.default.removeItem(at: store.root) }

        let root = MetadataRecord(
            accountAlias: "a", workspaceID: "ws", itemID: "it",
            path: "", parentPath: "", name: "root", isDir: true
        )
        try await store.upsert(root)
        for i in 0 ..< 5 {
            let r = MetadataRecord(
                accountAlias: "a", workspaceID: "ws", itemID: "it",
                path: "f\(i).txt", parentPath: "", name: "f\(i).txt", isDir: false
            )
            try await store.upsert(r)
        }

        let keys = (0 ..< 5).map { i in
            CacheKey(accountAlias: "a", workspaceID: "ws", itemID: "it", path: "f\(i).txt")
        }
        try await store.batchDelete(keys)

        let parentKey = CacheKey(accountAlias: "a", workspaceID: "ws", itemID: "it", path: "")
        let remaining = try await store.children(of: parentKey)
        #expect(remaining.isEmpty)
    }
}

// MARK: - Test helper: SHA-256 hex string

import CryptoKit

/// Returns the lowercase hex SHA-256 of `data`.
private func SHA256HexString(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}
