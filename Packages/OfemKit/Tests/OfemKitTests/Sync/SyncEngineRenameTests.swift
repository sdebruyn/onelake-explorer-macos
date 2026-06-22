import Foundation
@testable import OfemKit
import Testing

// MARK: - SyncEngine Rename Tests

@Suite("SyncEngine.rename")
struct SyncEngineRenameTests {
    // MARK: - Helpers

    private func makeEngine(
        onelake: any OneLakeClientProtocol = MockOneLakeClient(),
        fabric: MockFabricClient = MockFabricClient()
    ) throws -> (SyncEngine, CacheStore) {
        let store = try makeTempStore()
        let scratchDir = store.root.appending(path: "scratch", directoryHint: .isDirectory)
        let engine = SyncEngine(
            cache: store,
            onelake: onelake,
            fabric: fabric,
            scratchBase: scratchDir
        )
        return (engine, store)
    }

    private static let alias = "test"
    private static let wsID = "ws-rename"
    private static let itID = "item-rename"

    // MARK: - Happy path: rename calls client and re-keys cache row

    @Test("rename() calls onelake.rename with correct paths and re-keys the cache row")
    func renameRekeysRow() async throws {
        let ol = MockOneLakeClient()
        ol.renameResults.append(.success(()))

        let (engine, store) = try makeEngine(onelake: ol)
        defer { try? FileManager.default.removeItem(at: store.root) }

        // Seed a cache row for the old path.
        let oldPath = "Files/untitled folder"
        let newName = "my folder"
        let key = CacheKey(accountAlias: Self.alias, workspaceID: Self.wsID, itemID: Self.itID, path: oldPath)
        let record = MetadataRecord(
            accountAlias: Self.alias,
            workspaceID: Self.wsID,
            itemID: Self.itID,
            path: oldPath,
            parentPath: "Files",
            name: "untitled folder",
            isDir: true,
            itemType: "Lakehouse"
        )
        try await store.upsert(record)

        let updated = try await engine.rename(key: key, newName: newName)

        // The client was called once with the correct paths.
        #expect(ol.renameCalls.count == 1)
        let call = try #require(ol.renameCalls.first)
        #expect(call.alias == Self.alias)
        #expect(call.workspaceGUID == Self.wsID)
        #expect(call.itemGUID == Self.itID)
        #expect(call.sourcePath == "Files/untitled folder")
        #expect(call.destinationPath == "Files/my folder")

        // The returned record has the new name and path.
        #expect(updated.name == "my folder")
        #expect(updated.path == "Files/my folder")
        #expect(updated.parentPath == "Files")

        // The old key is gone; the new key is present.
        await #expect(throws: (any Error).self) {
            _ = try await store.fetch(key: key)
        }
        let newKey = CacheKey(accountAlias: Self.alias, workspaceID: Self.wsID, itemID: Self.itID, path: "Files/my folder")
        let fetched = try await store.fetch(key: newKey)
        #expect(fetched.name == "my folder")
        #expect(fetched.path == "Files/my folder")
    }

    // MARK: - Descendants re-keyed after non-empty-folder rename

    @Test("rename() re-keys cached descendants when a non-empty folder is renamed")
    func renameRekeysDescendants() async throws {
        let ol = MockOneLakeClient()
        ol.renameResults.append(.success(()))

        let (engine, store) = try makeEngine(onelake: ol)
        defer { try? FileManager.default.removeItem(at: store.root) }

        let oldDir = "Files/alpha"
        let dirKey = CacheKey(accountAlias: Self.alias, workspaceID: Self.wsID, itemID: Self.itID, path: oldDir)

        // Seed parent + two descendants.
        let rows: [MetadataRecord] = [
            MetadataRecord(
                accountAlias: Self.alias, workspaceID: Self.wsID, itemID: Self.itID,
                path: oldDir, parentPath: "Files", name: "alpha", isDir: true
            ),
            MetadataRecord(
                accountAlias: Self.alias, workspaceID: Self.wsID, itemID: Self.itID,
                path: "Files/alpha/child.txt", parentPath: "Files/alpha",
                name: "child.txt", isDir: false
            ),
            MetadataRecord(
                accountAlias: Self.alias, workspaceID: Self.wsID, itemID: Self.itID,
                path: "Files/alpha/sub/deep.txt", parentPath: "Files/alpha/sub",
                name: "deep.txt", isDir: false
            ),
        ]
        for r in rows {
            try await store.upsert(r)
        }

        _ = try await engine.rename(key: dirKey, newName: "beta")

        // Old paths gone, new paths present.
        for old in ["Files/alpha", "Files/alpha/child.txt", "Files/alpha/sub/deep.txt"] {
            let k = CacheKey(accountAlias: Self.alias, workspaceID: Self.wsID, itemID: Self.itID, path: old)
            await #expect(throws: (any Error).self) {
                _ = try await store.fetch(key: k)
            }
        }
        let newDir = CacheKey(accountAlias: Self.alias, workspaceID: Self.wsID, itemID: Self.itID, path: "Files/beta")
        let newChild = CacheKey(accountAlias: Self.alias, workspaceID: Self.wsID, itemID: Self.itID, path: "Files/beta/child.txt")
        let newDeep = CacheKey(accountAlias: Self.alias, workspaceID: Self.wsID, itemID: Self.itID, path: "Files/beta/sub/deep.txt")
        let fetched = try await store.fetch(key: newDir)
        #expect(fetched.name == "beta")
        let fetchedChild = try await store.fetch(key: newChild)
        #expect(fetchedChild.name == "child.txt")
        #expect(fetchedChild.parentPath == "Files/beta")
        let fetchedDeep = try await store.fetch(key: newDeep)
        #expect(fetchedDeep.name == "deep.txt")
        #expect(fetchedDeep.parentPath == "Files/beta/sub")
    }

    // MARK: - Network failure leaves item pending

    @Test("rename() rethrows when the OneLake client call fails")
    func renameClientFailurePropagates() async throws {
        let ol = MockOneLakeClient()
        ol.renameResults.append(.failure(OneLakeError.notFound))

        let (engine, store) = try makeEngine(onelake: ol)
        defer { try? FileManager.default.removeItem(at: store.root) }

        let key = CacheKey(accountAlias: Self.alias, workspaceID: Self.wsID, itemID: Self.itID, path: "Files/old")
        try await store.upsert(MetadataRecord(
            accountAlias: Self.alias, workspaceID: Self.wsID, itemID: Self.itID,
            path: "Files/old", parentPath: "Files", name: "old", isDir: true
        ))

        await #expect(throws: (any Error).self) {
            _ = try await engine.rename(key: key, newName: "new")
        }
    }
}
