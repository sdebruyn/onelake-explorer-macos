import Foundation
@testable import OfemKit
import Testing

// MARK: - SyncEngine deletion delivery tests

/// End-to-end tests that a remote deletion is delivered incrementally through
/// the engine → cache → `itemsChangedAfter` path: the refreshFolder reconcile
/// (F1), the rename-then-recreate clear (F9), and expireDiscoveryRows (item
/// discovery removals).
@Suite("SyncEngine deletion delivery")
struct SyncEngineDeletionTests {
    private static let alias = "acct"
    private static let ws = "ws-guid"
    private static let item = "item-guid"

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

    private static var folderKey: CacheKey {
        CacheKey(accountAlias: alias, workspaceID: ws, itemID: item, path: "")
    }

    // MARK: - 10. F1: a remote delete is delivered once, then not re-emitted

    @Test("refreshFolder delivers a remote deletion as a tombstone exactly once")
    func remoteDeleteDeliveredIncrementally() async throws {
        let ol = MockOneLakeClient()
        let (engine, store) = try makeEngine(onelake: ol)
        defer { try? FileManager.default.removeItem(at: store.root) }

        let key = Self.folderKey

        // Poll 1: both files present → populate the cache.
        ol.listPathResults.append(.success(ListResult(entries: [
            PathEntry.file(name: "a.txt", eTag: "ea"),
            PathEntry.file(name: "b.txt", eTag: "eb"),
        ])))
        _ = try await engine.refreshFolder(key: key)

        let anchor1 = try await store.syncAnchorNs(accountAlias: Self.alias)

        // Poll 2: b.txt is gone remotely.
        ol.listPathResults.append(.success(ListResult(entries: [
            PathEntry.file(name: "a.txt", eTag: "ea"),
        ])))
        let diff = try await engine.refreshFolder(key: key)
        #expect(diff.removed == 1)

        let bIdentifier = "\(Self.ws)/\(Self.item)/b.txt"
        let changes = try await store.itemsChangedAfter(accountAlias: Self.alias, ns: anchor1)
        #expect(changes.deletedIdentifierStrings.contains(bIdentifier))
        #expect(!changes.updated.contains { $0.path == "b.txt" })

        // Poll 3: from the post-delete anchor, an unchanged listing must NOT
        // re-emit the deletion (the tombstone is at-or-before the new anchor).
        let anchor2 = try await store.syncAnchorNs(accountAlias: Self.alias)
        ol.listPathResults.append(.success(ListResult(entries: [
            PathEntry.file(name: "a.txt", eTag: "ea"),
        ])))
        _ = try await engine.refreshFolder(key: key)
        let changes3 = try await store.itemsChangedAfter(accountAlias: Self.alias, ns: anchor2)
        #expect(changes3.deletedIdentifierStrings.isEmpty)
    }

    // MARK: - 11. F9: rename then recreate clears the old-identifier tombstone

    @Test("Re-creating a renamed path clears its old-identifier tombstone")
    func recreateAfterRenameClearsTombstone() async throws {
        let ol = MockOneLakeClient()
        ol.renameResults.append(.success(()))
        let (engine, store) = try makeEngine(onelake: ol)
        defer { try? FileManager.default.removeItem(at: store.root) }

        let aKey = CacheKey(accountAlias: Self.alias, workspaceID: Self.ws, itemID: Self.item, path: "a.txt")
        try await store.upsert(MetadataRecord(
            accountAlias: Self.alias, workspaceID: Self.ws, itemID: Self.item,
            path: "a.txt", parentPath: "", name: "a.txt", isDir: false, itemType: "Lakehouse"
        ))

        let anchorBefore = try await store.syncAnchorNs(accountAlias: Self.alias)

        // Rename a.txt → b.txt: writes a tombstone for the OLD identifier.
        _ = try await engine.rename(key: aKey, newName: "b.txt")

        // Re-create a.txt (e.g. a new remote file at the old name): the upsert
        // clears the stale old-identifier tombstone.
        try await store.upsert(MetadataRecord(
            accountAlias: Self.alias, workspaceID: Self.ws, itemID: Self.item,
            path: "a.txt", parentPath: "", name: "a.txt", isDir: false, itemType: "Lakehouse"
        ))

        let aIdentifier = "\(Self.ws)/\(Self.item)/a.txt"
        let changes = try await store.itemsChangedAfter(accountAlias: Self.alias, ns: anchorBefore)
        #expect(changes.updated.contains { $0.path == "a.txt" })
        #expect(!changes.deletedIdentifierStrings.contains(aIdentifier))
    }

    // MARK: - 12. Item-discovery removal tombstones the .item identifier

    @Test("expireDiscoveryRows tombstones a removed item's .item identifier")
    func removedItemTombstonedViaExpireDiscovery() async throws {
        let fabric = MockFabricClient()
        // First listItems returns two items; second returns only the first.
        let itemA = Item(id: "item-a", displayName: "Lake A", type: "Lakehouse", workspaceID: Self.ws)
        let itemB = Item(id: "item-b", displayName: "Lake B", type: "Lakehouse", workspaceID: Self.ws)
        fabric.listItemsResults.append(.success([itemA, itemB]))
        fabric.listItemsResults.append(.success([itemA]))

        let (engine, store) = try makeEngine(fabric: fabric)
        defer { try? FileManager.default.removeItem(at: store.root) }

        // Poll 1: seed both discovery rows.
        _ = try await engine.listItems(alias: Self.alias, workspaceID: Self.ws)
        let anchor = try await store.syncAnchorNs(accountAlias: Self.alias)

        // Poll 2: item-b disappeared → its discovery row is expired + tombstoned.
        _ = try await engine.listItems(alias: Self.alias, workspaceID: Self.ws)

        let changes = try await store.itemsChangedAfter(accountAlias: Self.alias, ns: anchor)
        #expect(changes.deletedIdentifierStrings.contains("\(Self.ws)/item-b"))
        // The surviving item's ".item" identifier must NOT be tombstoned, and no
        // VirtualIDs sentinel ever appears in a deletion identifier.
        #expect(!changes.deletedIdentifierStrings.contains("\(Self.ws)/item-a"))
        #expect(!changes.deletedIdentifierStrings.contains { $0.contains(VirtualIDs.itemID) })
    }
}
