import Foundation
import GRDB
import Testing

@testable import OfemKit

// MARK: - CacheStoreTests

/// Tests for the `CacheStore` CRUD operations and WAL concurrency behaviour.
@Suite("CacheStore")
struct CacheStoreTests {

    // MARK: - Upsert + Fetch

    @Test("Upsert and fetch a metadata row")
    func upsertAndFetch() async throws {
        let store = try makeInMemoryStore()
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

    @Test("Upsert updates an existing row")
    func upsertUpdatesExistingRow() async throws {
        let store = try makeInMemoryStore()
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
        let store = try makeInMemoryStore()
        let key = CacheKey(accountAlias: "work", workspaceID: "ws1", itemID: "item1", path: "nope")
        await #expect(throws: CacheError.self) {
            try await store.fetch(key: key)
        }
    }

    @Test("Upsert fills timestamps when zero")
    func upsertFillsTimestamps() async throws {
        let store = try makeInMemoryStore()
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
        let store = try makeInMemoryStore()
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
        let store = try makeInMemoryStore()
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
        let store = try makeInMemoryStore()
        let key = CacheKey(accountAlias: "a", workspaceID: "w", itemID: "i", path: "f.txt")
        try await store.upsert(MetadataRecord(
            accountAlias: "a", workspaceID: "w", itemID: "i",
            path: "f.txt", parentPath: "", name: "f.txt", isDir: false
        ))
        try await store.delete(key: key)
        await #expect(throws: CacheError.self) { try await store.fetch(key: key) }
    }

    @Test("Delete cascades to descendants")
    func deleteCascadesToDescendants() async throws {
        let store = try makeInMemoryStore()
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
            await #expect(throws: CacheError.self) { try await store.fetch(key: k) }
        }
    }

    @Test("Delete is a no-op for missing keys")
    func deleteMissingKeyIsNoOp() async throws {
        let store = try makeInMemoryStore()
        let key = CacheKey(accountAlias: "a", workspaceID: "w", itemID: "i", path: "ghost.txt")
        try await store.delete(key: key)
    }

    // MARK: - Touch

    @Test("Touch bumps last_accessed_ns")
    func touchBumpsLastAccessed() async throws {
        let store = try makeInMemoryStore()
        let key = CacheKey(accountAlias: "a", workspaceID: "w", itemID: "i", path: "f.txt")
        var r = MetadataRecord(
            accountAlias: "a", workspaceID: "w", itemID: "i",
            path: "f.txt", parentPath: "", name: "f.txt", isDir: false
        )
        r.lastAccessedNs = 1_000
        try await store.upsert(r)

        try await store.touch(key: key)
        let fetched = try await store.fetch(key: key)
        #expect(fetched.lastAccessedNs > 1_000)
    }

    @Test("Touch throws notFound for missing row")
    func touchMissingThrows() async throws {
        let store = try makeInMemoryStore()
        let key = CacheKey(accountAlias: "a", workspaceID: "w", itemID: "i", path: "ghost.txt")
        await #expect(throws: CacheError.self) { try await store.touch(key: key) }
    }

    // MARK: - HotItems

    @Test("HotItems returns items accessed at or after since")
    func hotItemsReturnsRecentItems() async throws {
        let store = try makeInMemoryStore()
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

    // MARK: - Validation

    @Test("Missing accountAlias throws missingArgument")
    func missingAliasThrows() async throws {
        let store = try makeInMemoryStore()
        let key = CacheKey(accountAlias: "", workspaceID: "w", itemID: "i", path: "f.txt")
        await #expect(throws: CacheError.self) { try await store.fetch(key: key) }
    }

    @Test("Missing workspaceID throws missingArgument")
    func missingWorkspaceIDThrows() async throws {
        let store = try makeInMemoryStore()
        let key = CacheKey(accountAlias: "a", workspaceID: "", itemID: "i", path: "f.txt")
        await #expect(throws: CacheError.self) { try await store.fetch(key: key) }
    }

    @Test("Missing itemID throws missingArgument")
    func missingItemIDThrows() async throws {
        let store = try makeInMemoryStore()
        let key = CacheKey(accountAlias: "a", workspaceID: "w", itemID: "", path: "f.txt")
        await #expect(throws: CacheError.self) { try await store.fetch(key: key) }
    }

    // MARK: - Reader

    @Test("Reader can read rows written by the store")
    func readerSeesWrittenRows() async throws {
        let store = try makeInMemoryStore()
        let key = CacheKey(accountAlias: "a", workspaceID: "w", itemID: "i", path: "f.txt")
        try await store.upsert(MetadataRecord(
            accountAlias: "a", workspaceID: "w", itemID: "i",
            path: "f.txt", parentPath: "", name: "f.txt", isDir: false,
            contentLength: 77
        ))

        let reader = await store.reader()
        let row = try await reader.fetch(key: key)
        #expect(row.contentLength == 77)
    }

    @Test("Reader.children returns correct rows")
    func readerChildrenWorks() async throws {
        let store = try makeInMemoryStore()
        let alias = "a"; let ws = "w"; let item = "i"
        try await store.upsert(MetadataRecord(
            accountAlias: alias, workspaceID: ws, itemID: item,
            path: "dir", parentPath: "", name: "dir", isDir: true
        ))
        try await store.upsert(MetadataRecord(
            accountAlias: alias, workspaceID: ws, itemID: item,
            path: "dir/child.txt", parentPath: "dir", name: "child.txt", isDir: false
        ))

        let reader = await store.reader()
        let children = try await reader.children(of: CacheKey(
            accountAlias: alias, workspaceID: ws, itemID: item, path: "dir"
        ))
        #expect(children.count == 1)
        #expect(children[0].name == "child.txt")
    }
}
