import Foundation
@testable import OfemKit
import Testing

// MARK: - SyncEngine Discovery Tests

extension SyncEngineTests {
    // MARK: - listWorkspaces: Fabric error rethrown when not capacity-paused

    @Test("listWorkspaces() rethrows non-paused Fabric errors")
    func listWorkspacesRethrowsNonPausedError() async throws {
        let ol = MockOneLakeClient()
        let fabric = MockFabricClient()
        let (engine, store) = try makeEngine(onelake: ol, fabric: fabric)
        defer { try? FileManager.default.removeItem(at: store.root) }

        fabric.listWorkspacesResults.append(.failure(MockError.intentional("network down")))

        // tests-11: assert the concrete error type (MockError.intentional), not just that
        // something threw. A wrong error type (e.g. mis-mapped SyncError) would still pass
        // the old `threw == true` check.
        do {
            _ = try await engine.listWorkspaces(alias: Self.alias)
            Issue.record("Expected MockError.intentional to be rethrown")
        } catch MockError.intentional {
            // Correct — non-paused error propagated as-is.
        } catch {
            Issue.record("Expected MockError.intentional, got \(type(of: error)): \(error)")
        }
    }

    @Test("listWorkspaces() marks paused and throws workspacePaused on capacity error")
    func listWorkspacesMarksPausedOnCapacityError() async throws {
        let ol = MockOneLakeClient()
        let fabric = MockFabricClient()
        let (engine, store) = try makeEngine(onelake: ol, fabric: fabric)
        defer { try? FileManager.default.removeItem(at: store.root) }

        let apiBody = #"{"errorCode":"CapacityPaused","message":"capacity is paused"}"#
        let apiErr = HTTPClientError.apiError(APIError(statusCode: 503, status: "503", body: try #require(apiBody.data(using: .utf8))))
        fabric.listWorkspacesResults.append(.failure(FabricError.httpError(apiErr)))

        do {
            _ = try await engine.listWorkspaces(alias: Self.alias)
            Issue.record("Expected workspacePaused")
        } catch SyncError.workspacePaused {
            // Correct.
        }

        let status = try? await store.workspaceStatus(accountAlias: Self.alias, workspaceID: VirtualIDs.workspaceID)
        #expect(status?.state == .paused)
    }

    @Test("listWorkspaces() returns workspaces and stamps cache rows on success")
    func listWorkspacesSuccessStampsCache() async throws {
        let ol = MockOneLakeClient()
        let fabric = MockFabricClient()
        let (engine, store) = try makeEngine(onelake: ol, fabric: fabric)
        defer { try? FileManager.default.removeItem(at: store.root) }

        let workspaces = [
            Workspace(id: "ws-a", displayName: "Alpha", type: "Workspace"),
            Workspace(id: "ws-b", displayName: "Beta", type: "Workspace"),
        ]
        fabric.listWorkspacesResults.append(.success(workspaces))

        let got = try await engine.listWorkspaces(alias: Self.alias)
        #expect(got.count == 2)
        #expect(got[0].id == "ws-a")

        // Cache should have rows for each workspace.
        let parentKey = CacheKey(
            accountAlias: Self.alias,
            workspaceID: VirtualIDs.workspaceID,
            itemID: VirtualIDs.workspaceID,
            path: ""
        )
        let children = try await store.children(of: parentKey)
        let paths = children.map(\.path)
        #expect(paths.contains("ws-a"))
        #expect(paths.contains("ws-b"))
    }

    // MARK: - listItems: Fabric error handling

    @Test("listItems() rethrows non-paused Fabric errors")
    func listItemsRethrowsNonPausedError() async throws {
        let ol = MockOneLakeClient()
        let fabric = MockFabricClient()
        let (engine, store) = try makeEngine(onelake: ol, fabric: fabric)
        defer { try? FileManager.default.removeItem(at: store.root) }

        fabric.listItemsResults.append(.failure(MockError.intentional("timeout")))

        // tests-11: assert the concrete error type, not just that something threw.
        do {
            _ = try await engine.listItems(alias: Self.alias, workspaceID: Self.wsID)
            Issue.record("Expected MockError.intentional to be rethrown")
        } catch MockError.intentional {
            // Correct — non-paused error propagated as-is.
        } catch {
            Issue.record("Expected MockError.intentional, got \(type(of: error)): \(error)")
        }
    }

    @Test("listItems() returns only storage-backed items and stamps their cache rows")
    func listItemsSuccessStampsCache() async throws {
        let ol = MockOneLakeClient()
        let fabric = MockFabricClient()
        let (engine, store) = try makeEngine(onelake: ol, fabric: fabric)
        defer { try? FileManager.default.removeItem(at: store.root) }

        // Fabric returns a Lakehouse and a Notebook; only the Lakehouse is storage-backed.
        let items = [
            Item(id: "it-1", displayName: "Lakehouse 1", type: "Lakehouse", workspaceID: Self.wsID),
            Item(id: "it-2", displayName: "Notebook 1", type: "Notebook", workspaceID: Self.wsID),
        ]
        fabric.listItemsResults.append(.success(items))

        let got = try await engine.listItems(alias: Self.alias, workspaceID: Self.wsID)
        // Notebook is a non-storage item and must be filtered out.
        #expect(got.count == 1)
        #expect(got[0].id == "it-1")

        let parentKey = CacheKey(
            accountAlias: Self.alias,
            workspaceID: Self.wsID,
            itemID: VirtualIDs.itemID,
            path: ""
        )
        let children = try await store.children(of: parentKey)
        let paths = children.map(\.path)
        #expect(paths.contains("it-1"))
        // Non-storage item must not appear in the cache either.
        #expect(!paths.contains("it-2"))
    }

    // MARK: - issue-296: non-storage item types filtered from workspace listing

    /// Regression test for issue #296.
    ///
    /// A Fabric Lakehouse auto-creates a SQLEndpoint and sometimes a default
    /// SemanticModel with the same `displayName`. Without filtering, both the
    /// Lakehouse and its SQLEndpoint appear as browsable folders in Finder, and
    /// macOS de-duplicates the display name by appending " 2".
    ///
    /// `listItems` must return only the four allowlisted item types
    /// (Lakehouse, Warehouse, MirroredDatabase, SQLDatabase) and exclude
    /// everything else (SQLEndpoint, SemanticModel, Notebook, Report, …).
    @Test("listItems() filters non-allowlisted item types, eliminating ' 2' duplicate entries (issue-296)")
    func listItemsFiltersNonStorageTypes() async throws {
        let ol = MockOneLakeClient()
        let fabric = MockFabricClient()
        let (engine, store) = try makeEngine(onelake: ol, fabric: fabric)
        defer { try? FileManager.default.removeItem(at: store.root) }

        // Simulate a real workspace: a Lakehouse whose auto-created SQLEndpoint
        // and default SemanticModel share the same displayName, plus a Warehouse,
        // a SQLDatabase, and a Notebook.
        let fabricItems = [
            Item(id: "lh-1", displayName: "Sales", type: "Lakehouse", workspaceID: Self.wsID),
            Item(id: "sql-1", displayName: "Sales", type: "SQLEndpoint", workspaceID: Self.wsID),
            Item(id: "sm-1", displayName: "Sales", type: "SemanticModel", workspaceID: Self.wsID),
            Item(id: "wh-1", displayName: "DW", type: "Warehouse", workspaceID: Self.wsID),
            Item(id: "sdb-1", displayName: "Mirror", type: "SQLDatabase", workspaceID: Self.wsID),
            Item(id: "nb-1", displayName: "EDA", type: "Notebook", workspaceID: Self.wsID),
        ]
        fabric.listItemsResults.append(.success(fabricItems))

        let got = try await engine.listItems(alias: Self.alias, workspaceID: Self.wsID)

        // Only the three storage-backed items must come back.
        #expect(got.count == 3)
        let ids = got.map(\.id)
        #expect(ids.contains("lh-1"), "Lakehouse must be returned")
        #expect(ids.contains("wh-1"), "Warehouse must be returned")
        #expect(ids.contains("sdb-1"), "SQLDatabase must be returned")
        #expect(!ids.contains("sql-1"), "SQLEndpoint must be filtered out")
        #expect(!ids.contains("sm-1"), "SemanticModel must be filtered out")
        #expect(!ids.contains("nb-1"), "Notebook must be filtered out")

        // Non-storage items must not appear in the discovery cache either.
        let parentKey = CacheKey(
            accountAlias: Self.alias,
            workspaceID: Self.wsID,
            itemID: VirtualIDs.itemID,
            path: ""
        )
        let cachedPaths = try await store.children(of: parentKey).map(\.path)
        #expect(cachedPaths.contains("lh-1"))
        #expect(cachedPaths.contains("wh-1"))
        #expect(cachedPaths.contains("sdb-1"))
        #expect(!cachedPaths.contains("sql-1"))
        #expect(!cachedPaths.contains("sm-1"))
        #expect(!cachedPaths.contains("nb-1"))
    }

    @Test("listItems() hides unknown item types (allowlist policy: hide by default)")
    func listItemsHidesUnknownTypes() async throws {
        let ol = MockOneLakeClient()
        let fabric = MockFabricClient()
        let (engine, store) = try makeEngine(onelake: ol, fabric: fabric)
        defer { try? FileManager.default.removeItem(at: store.root) }

        let fabricItems = [
            Item(id: "k-1", displayName: "Known", type: "Lakehouse", workspaceID: Self.wsID),
            Item(id: "u-1", displayName: "Unknown", type: "FutureItemType", workspaceID: Self.wsID),
            Item(id: "e-1", displayName: "Empty", type: "", workspaceID: Self.wsID),
        ]
        fabric.listItemsResults.append(.success(fabricItems))

        let got = try await engine.listItems(alias: Self.alias, workspaceID: Self.wsID)

        // Only the Lakehouse is in the allowlist; FutureItemType and empty type
        // are hidden by the strict allowlist policy.
        #expect(got.count == 1)
        let ids = got.map(\.id)
        #expect(ids.contains("k-1"))
        #expect(!ids.contains("u-1"), "unknown type must be hidden by allowlist")
        #expect(!ids.contains("e-1"), "empty type must be hidden by allowlist")
    }

    @Test("Item.hasOneLakeStorage reflects strict allowlist: true only for Lakehouse/Warehouse/MirroredDatabase/SQLDatabase")
    func itemHasOneLakeStorageAllowlistContents() {
        func item(type: String) -> Item {
            Item(id: "x", displayName: "x", type: type, workspaceID: "w")
        }
        // The four allowed types must be visible.
        #expect(item(type: "Lakehouse").hasOneLakeStorage)
        #expect(item(type: "Warehouse").hasOneLakeStorage)
        #expect(item(type: "MirroredDatabase").hasOneLakeStorage)
        #expect(item(type: "SQLDatabase").hasOneLakeStorage)
        // Types that have OneLake storage but are not yet supported are hidden.
        #expect(!item(type: "KQLDatabase").hasOneLakeStorage)
        #expect(!item(type: "Eventhouse").hasOneLakeStorage)
        #expect(!item(type: "MirroredWarehouse").hasOneLakeStorage)
        // Non-storage types must also be hidden.
        #expect(!item(type: "SQLEndpoint").hasOneLakeStorage)
        #expect(!item(type: "SemanticModel").hasOneLakeStorage)
        #expect(!item(type: "Notebook").hasOneLakeStorage)
        #expect(!item(type: "Report").hasOneLakeStorage)
        #expect(!item(type: "Dashboard").hasOneLakeStorage)
        #expect(!item(type: "DataPipeline").hasOneLakeStorage)
        // Unknown / future types are hidden by default.
        #expect(!item(type: "FutureItemType").hasOneLakeStorage)
        #expect(!item(type: "").hasOneLakeStorage)
    }

    @Test("Item.hasOneLakeStorage is case-insensitive for the four allowed types")
    func itemHasOneLakeStorageCaseInsensitive() {
        func item(type: String) -> Item {
            Item(id: "x", displayName: "x", type: type, workspaceID: "w")
        }
        // All-lower
        #expect(item(type: "lakehouse").hasOneLakeStorage)
        #expect(item(type: "warehouse").hasOneLakeStorage)
        #expect(item(type: "mirroreddatabase").hasOneLakeStorage)
        #expect(item(type: "sqldatabase").hasOneLakeStorage)
        // All-upper
        #expect(item(type: "LAKEHOUSE").hasOneLakeStorage)
        #expect(item(type: "WAREHOUSE").hasOneLakeStorage)
        #expect(item(type: "MIRROREDDATABASE").hasOneLakeStorage)
        #expect(item(type: "SQLDATABASE").hasOneLakeStorage)
        // Mixed case
        #expect(item(type: "LakeHouse").hasOneLakeStorage)
        #expect(item(type: "WareHouse").hasOneLakeStorage)
        #expect(item(type: "MirroredDatabase").hasOneLakeStorage)
        #expect(item(type: "SqlDatabase").hasOneLakeStorage)
        // Case-insensitive match must not accidentally allow other types.
        #expect(!item(type: "KQLDATABASE").hasOneLakeStorage)
        #expect(!item(type: "notebook").hasOneLakeStorage)
    }

    @Test("listItems() evicts previously-cached rows that are now excluded by the allowlist via expireDiscoveryRows")
    func listItemsEvictsPrecachedNonStorageRow() async throws {
        let ol = MockOneLakeClient()
        let fabric = MockFabricClient()
        let (engine, store) = try makeEngine(onelake: ol, fabric: fabric)
        defer { try? FileManager.default.removeItem(at: store.root) }

        // Simulate rows written by a pre-allowlist build: a SQLEndpoint (never had
        // storage) and a KQLDatabase (has storage but is not in the allowlist)
        // cached under the workspace items parent. expireDiscoveryRows must evict both
        // because neither "sql-stale" nor "kql-stale" is in the `seen` set built from
        // the four allowed item types (Lakehouse, Warehouse, MirroredDatabase, SQLDatabase).
        let sqlRow = MetadataRecord(
            accountAlias: Self.alias,
            workspaceID: Self.wsID,
            itemID: VirtualIDs.itemID,
            path: "sql-stale",
            parentPath: "",
            name: "Sales",
            isDir: true,
            lastAccessedNs: 0,
            syncedAtNs: 0
        )
        let kqlRow = MetadataRecord(
            accountAlias: Self.alias,
            workspaceID: Self.wsID,
            itemID: VirtualIDs.itemID,
            path: "kql-stale",
            parentPath: "",
            name: "Events",
            isDir: true,
            lastAccessedNs: 0,
            syncedAtNs: 0
        )
        try await store.upsert(sqlRow)
        try await store.upsert(kqlRow)

        // Fabric returns both excluded items and one allowed Lakehouse.
        fabric.listItemsResults.append(.success([
            Item(id: "sql-stale", displayName: "Sales", type: "SQLEndpoint", workspaceID: Self.wsID),
            Item(id: "kql-stale", displayName: "Events", type: "KQLDatabase", workspaceID: Self.wsID),
            Item(id: "lh-1", displayName: "Sales", type: "Lakehouse", workspaceID: Self.wsID),
        ]))
        _ = try await engine.listItems(alias: Self.alias, workspaceID: Self.wsID)

        let parentKey = CacheKey(
            accountAlias: Self.alias,
            workspaceID: Self.wsID,
            itemID: VirtualIDs.itemID,
            path: ""
        )
        let paths = try await store.children(of: parentKey).map(\.path)
        #expect(!paths.contains("sql-stale"), "expireDiscoveryRows must evict pre-cached SQLEndpoint rows")
        #expect(!paths.contains("kql-stale"), "expireDiscoveryRows must evict pre-cached KQLDatabase rows")
        #expect(paths.contains("lh-1"), "Lakehouse must remain in cache")
    }

    // MARK: - listItems: evicts stale discovery rows

    @Test("listItems() evicts a stale discovery row that was filtered out by the allowlist")
    func listItemsEvictsFilteredDiscoveryRow() async throws {
        let ol = MockOneLakeClient()
        let fabric = MockFabricClient()
        let (engine, store) = try makeEngine(onelake: ol, fabric: fabric)
        defer { try? FileManager.default.removeItem(at: store.root) }

        // A pre-cached SQLEndpoint that will be filtered out by the allowlist —
        // the now-filtered row that leaves a `<name> 2` duplicate in Finder.
        let staleRow = MetadataRecord(
            accountAlias: Self.alias, workspaceID: Self.wsID, itemID: VirtualIDs.itemID,
            path: "sql-stale", parentPath: "", name: "Sales", isDir: true
        )
        try await store.upsert(staleRow)

        // Fabric returns only an allowed Lakehouse; the SQLEndpoint is gone.
        fabric.listItemsResults.append(.success([
            Item(id: "lh-1", displayName: "Sales", type: "Lakehouse", workspaceID: Self.wsID),
        ]))
        _ = try await engine.listItems(alias: Self.alias, workspaceID: Self.wsID)

        // The stale row is hard-deleted (not resurrected).
        let parentKey = CacheKey(
            accountAlias: Self.alias, workspaceID: Self.wsID, itemID: VirtualIDs.itemID, path: ""
        )
        let paths = try await store.children(of: parentKey).map(\.path)
        #expect(!paths.contains("sql-stale"))
        #expect(paths.contains("lh-1"))
    }

    @Test("listItems() does not evict rows when all remote items are present in cache")
    func listItemsNoEvictionWhenNothingRemoved() async throws {
        let ol = MockOneLakeClient()
        let fabric = MockFabricClient()
        let (engine, store) = try makeEngine(onelake: ol, fabric: fabric)
        defer { try? FileManager.default.removeItem(at: store.root) }

        // Empty cache, single allowed item → nothing to expire.
        fabric.listItemsResults.append(.success([
            Item(id: "lh-1", displayName: "Sales", type: "Lakehouse", workspaceID: Self.wsID),
        ]))
        _ = try await engine.listItems(alias: Self.alias, workspaceID: Self.wsID)

        let parentKey = CacheKey(
            accountAlias: Self.alias, workspaceID: Self.wsID, itemID: VirtualIDs.itemID, path: ""
        )
        let paths = try await store.children(of: parentKey).map(\.path)
        #expect(paths.contains("lh-1"))
    }

    // MARK: - listItems: item_type persisted from Item.type

    @Test("listItems() persists item_type from Item.type onto cache rows")
    func listItemsPersistsItemType() async throws {
        let ol = MockOneLakeClient()
        let fabric = MockFabricClient()
        let (engine, store) = try makeEngine(onelake: ol, fabric: fabric)
        defer { try? FileManager.default.removeItem(at: store.root) }

        let fabricItems = [
            Item(id: "lh-1", displayName: "Sales LH", type: "Lakehouse", workspaceID: Self.wsID),
            Item(id: "wh-1", displayName: "DW", type: "Warehouse", workspaceID: Self.wsID),
            Item(id: "sdb-1", displayName: "Mirror", type: "SQLDatabase", workspaceID: Self.wsID),
            Item(id: "mdb-1", displayName: "Replicated", type: "MirroredDatabase", workspaceID: Self.wsID),
        ]
        fabric.listItemsResults.append(.success(fabricItems))
        _ = try await engine.listItems(alias: Self.alias, workspaceID: Self.wsID)

        // Each item row is stored under (alias, wsID, VirtualIDs.itemID, path: itemID).
        let itemRowKey = { (path: String) in
            CacheKey(accountAlias: Self.alias, workspaceID: Self.wsID, itemID: VirtualIDs.itemID, path: path)
        }
        let lhRow = try await store.fetch(key: itemRowKey("lh-1"))
        let whRow = try await store.fetch(key: itemRowKey("wh-1"))
        let sdbRow = try await store.fetch(key: itemRowKey("sdb-1"))
        let mdbRow = try await store.fetch(key: itemRowKey("mdb-1"))

        #expect(lhRow.itemType == "Lakehouse", "Lakehouse item_type must be persisted")
        #expect(whRow.itemType == "Warehouse", "Warehouse item_type must be persisted")
        #expect(sdbRow.itemType == "SQLDatabase", "SQLDatabase item_type must be persisted")
        #expect(mdbRow.itemType == "MirroredDatabase", "MirroredDatabase item_type must be persisted")
    }
}
