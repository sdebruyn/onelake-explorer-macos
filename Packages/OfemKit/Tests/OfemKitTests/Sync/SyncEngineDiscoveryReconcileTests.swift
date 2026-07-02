import Foundation
@testable import OfemKit
import Testing

// MARK: - SyncEngine discovery reconcile tests

/// Tests that ``SyncEngine/listWorkspaces(alias:)`` and
/// ``SyncEngine/listItems(alias:workspaceID:)`` apply the same
/// conditional-upsert discipline as ``SyncEngine/refreshFolder(key:)``
/// (#361/#379): an unchanged discovery row keeps its prior `syncedAtNs`
/// so it produces no phantom `itemsChangedAfter` delta, while a genuinely
/// new or changed row still advances `syncedAtNs` and is reported.
@Suite("SyncEngine discovery reconcile")
struct SyncEngineDiscoveryReconcileTests {
    private static let alias = "acct"
    private static let ws = "ws-guid"

    private func makeEngine(fabric: MockFabricClient) throws -> (SyncEngine, CacheStore) {
        let store = try makeTempStore()
        let scratchDir = store.root.appending(path: "scratch", directoryHint: .isDirectory)
        let engine = SyncEngine(
            cache: store,
            onelake: MockOneLakeClient(),
            fabric: fabric,
            scratchBase: scratchDir
        )
        return (engine, store)
    }

    // MARK: - listWorkspaces

    @Test("listWorkspaces() unchanged pass does not bump syncedAtNs for unchanged rows")
    func listWorkspacesUnchangedPassProducesNoDelta() async throws {
        let fabric = MockFabricClient()
        let workspaces = [
            Workspace(id: "ws-a", displayName: "Alpha", type: "Workspace"),
            Workspace(id: "ws-b", displayName: "Beta", type: "Workspace"),
        ]
        fabric.listWorkspacesResults.append(.success(workspaces))
        fabric.listWorkspacesResults.append(.success(workspaces))

        let (engine, store) = try makeEngine(fabric: fabric)
        defer { try? FileManager.default.removeItem(at: store.root) }

        _ = try await engine.listWorkspaces(alias: Self.alias)
        let anchor = try await store.syncAnchorNs(accountAlias: Self.alias)

        // Second pass: identical workspaces — nothing changed.
        _ = try await engine.listWorkspaces(alias: Self.alias)

        let changes = try await store.itemsChangedAfter(accountAlias: Self.alias, ns: anchor)
        #expect(!changes.updated.contains { $0.path == "ws-a" })
        #expect(!changes.updated.contains { $0.path == "ws-b" })
    }

    @Test("listWorkspaces() a changed displayName advances syncedAtNs and is reported")
    func listWorkspacesChangedRowAdvancesAndReports() async throws {
        let fabric = MockFabricClient()
        fabric.listWorkspacesResults.append(.success([
            Workspace(id: "ws-a", displayName: "Alpha", type: "Workspace"),
        ]))
        fabric.listWorkspacesResults.append(.success([
            Workspace(id: "ws-a", displayName: "Alpha Renamed", type: "Workspace"),
        ]))

        let (engine, store) = try makeEngine(fabric: fabric)
        defer { try? FileManager.default.removeItem(at: store.root) }

        _ = try await engine.listWorkspaces(alias: Self.alias)
        let anchor = try await store.syncAnchorNs(accountAlias: Self.alias)

        _ = try await engine.listWorkspaces(alias: Self.alias)

        let changes = try await store.itemsChangedAfter(accountAlias: Self.alias, ns: anchor)
        #expect(changes.updated.contains { $0.path == "ws-a" && $0.name == "Alpha Renamed" })
    }

    @Test("listWorkspaces() a newly-appeared workspace is upserted and reported")
    func listWorkspacesNewRowIsUpsertedAndReported() async throws {
        let fabric = MockFabricClient()
        fabric.listWorkspacesResults.append(.success([
            Workspace(id: "ws-a", displayName: "Alpha", type: "Workspace"),
        ]))
        fabric.listWorkspacesResults.append(.success([
            Workspace(id: "ws-a", displayName: "Alpha", type: "Workspace"),
            Workspace(id: "ws-b", displayName: "Beta", type: "Workspace"),
        ]))

        let (engine, store) = try makeEngine(fabric: fabric)
        defer { try? FileManager.default.removeItem(at: store.root) }

        _ = try await engine.listWorkspaces(alias: Self.alias)
        let anchor = try await store.syncAnchorNs(accountAlias: Self.alias)

        _ = try await engine.listWorkspaces(alias: Self.alias)

        let changes = try await store.itemsChangedAfter(accountAlias: Self.alias, ns: anchor)
        // ws-b is new → reported. ws-a is unchanged → must NOT be reported.
        #expect(changes.updated.contains { $0.path == "ws-b" })
        #expect(!changes.updated.contains { $0.path == "ws-a" })
    }

    // MARK: - listItems

    @Test("listItems() unchanged pass does not bump syncedAtNs for unchanged rows")
    func listItemsUnchangedPassProducesNoDelta() async throws {
        let fabric = MockFabricClient()
        let items = [Item(id: "it-a", displayName: "Lake A", type: "Lakehouse", workspaceID: Self.ws)]
        fabric.listItemsResults.append(.success(items))
        fabric.listItemsResults.append(.success(items))

        let (engine, store) = try makeEngine(fabric: fabric)
        defer { try? FileManager.default.removeItem(at: store.root) }

        _ = try await engine.listItems(alias: Self.alias, workspaceID: Self.ws)
        let anchor = try await store.syncAnchorNs(accountAlias: Self.alias)

        _ = try await engine.listItems(alias: Self.alias, workspaceID: Self.ws)

        let changes = try await store.itemsChangedAfter(accountAlias: Self.alias, ns: anchor)
        #expect(!changes.updated.contains { $0.path == "it-a" })
    }

    @Test("listItems() a changed itemType advances syncedAtNs and is reported")
    func listItemsChangedItemTypeAdvancesAndReports() async throws {
        let fabric = MockFabricClient()
        fabric.listItemsResults.append(.success([
            Item(id: "it-a", displayName: "Lake A", type: "Lakehouse", workspaceID: Self.ws),
        ]))
        // Same id/displayName, different (still storage-backed) type.
        fabric.listItemsResults.append(.success([
            Item(id: "it-a", displayName: "Lake A", type: "Warehouse", workspaceID: Self.ws),
        ]))

        let (engine, store) = try makeEngine(fabric: fabric)
        defer { try? FileManager.default.removeItem(at: store.root) }

        _ = try await engine.listItems(alias: Self.alias, workspaceID: Self.ws)
        let anchor = try await store.syncAnchorNs(accountAlias: Self.alias)

        _ = try await engine.listItems(alias: Self.alias, workspaceID: Self.ws)

        let changes = try await store.itemsChangedAfter(accountAlias: Self.alias, ns: anchor)
        #expect(changes.updated.contains { $0.path == "it-a" && $0.itemType == "Warehouse" })
    }

    @Test("listItems() a newly-appeared item is upserted and reported")
    func listItemsNewRowIsUpsertedAndReported() async throws {
        let fabric = MockFabricClient()
        let itemA = Item(id: "it-a", displayName: "Lake A", type: "Lakehouse", workspaceID: Self.ws)
        let itemB = Item(id: "it-b", displayName: "Lake B", type: "Lakehouse", workspaceID: Self.ws)
        fabric.listItemsResults.append(.success([itemA]))
        fabric.listItemsResults.append(.success([itemA, itemB]))

        let (engine, store) = try makeEngine(fabric: fabric)
        defer { try? FileManager.default.removeItem(at: store.root) }

        _ = try await engine.listItems(alias: Self.alias, workspaceID: Self.ws)
        let anchor = try await store.syncAnchorNs(accountAlias: Self.alias)

        _ = try await engine.listItems(alias: Self.alias, workspaceID: Self.ws)

        let changes = try await store.itemsChangedAfter(accountAlias: Self.alias, ns: anchor)
        #expect(changes.updated.contains { $0.path == "it-b" })
        #expect(!changes.updated.contains { $0.path == "it-a" })
    }
}
