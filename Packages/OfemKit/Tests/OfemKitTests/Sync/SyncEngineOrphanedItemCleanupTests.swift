import Foundation
import GRDB
@testable import OfemKit
import Testing

// MARK: - SyncEngine orphaned-item cleanup tests

/// Tests that when a Fabric item vanishes from a workspace listing,
/// ``SyncEngine/reconcileItemListing(alias:workspaceID:)`` (via
/// `expireDiscoveryRows` → `purgeRemovedItems`) purges the item's orphaned real
/// `path_metadata` rows and its `materialized_containers` entries — so no residue
/// is left and the freshness poll loop stops DFS-404ing the dead item's
/// containers. Blob reclaim rides the existing orphan sweep.
@Suite("SyncEngine orphaned-item cleanup")
struct SyncEngineOrphanedItemCleanupTests {
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

    private func item(_ id: String) -> Item {
        Item(id: id, displayName: "Lake \(id)", type: "Lakehouse", workspaceID: Self.ws)
    }

    /// Seeds the real `path_metadata` rows an item accrues after a folder refresh
    /// (keyed by the real item GUID, NOT the discovery sentinel).
    private func seedRealItemRows(_ store: CacheStore, itemID: String, paths: [String]) async throws {
        for path in paths {
            try await store.upsert(MetadataRecord(
                accountAlias: Self.alias, workspaceID: Self.ws, itemID: itemID,
                path: path, parentPath: Enumerator.parentPath(path),
                name: Enumerator.baseName(path), isDir: !path.contains(".")
            ))
        }
    }

    private func realRowCount(_ store: CacheStore, itemID: String) async throws -> Int {
        try await store.dbPool.read { db in
            try Int.fetchOne(db, sql: """
            SELECT COUNT(*) FROM path_metadata
            WHERE account_alias = ? AND workspace_id = ? AND item_id = ?
            """, arguments: [Self.alias, Self.ws, itemID]) ?? -1
        }
    }

    private func materializedIdentifiers(_ store: CacheStore) async throws -> [String] {
        try await store.dbPool.read { db in
            try String.fetchAll(db, sql: """
            SELECT identifier_string FROM materialized_containers
            WHERE account_alias = ? ORDER BY identifier_string
            """, arguments: [Self.alias])
        }
    }

    // MARK: - 1. Vanished item purges real rows + materialized entries (alias-scoped)

    @Test("a vanished item's orphaned rows and materialized entries are purged; an unrelated item survives")
    func vanishedItemPurgesRowsAndMaterialized() async throws {
        let fabric = MockFabricClient()
        fabric.listItemsResults.append(.success([item("it-a"), item("it-b")])) // pass 1: both present
        fabric.listItemsResults.append(.success([item("it-b")])) // pass 2: it-a gone, it-b stays

        let (engine, store) = try makeEngine(fabric: fabric)
        defer { try? FileManager.default.removeItem(at: store.root) }

        // Pass 1 creates the it-a / it-b discovery rows.
        _ = try await engine.listItems(alias: Self.alias, workspaceID: Self.ws)

        // Seed the real item rows a folder refresh would have written for it-a, and
        // materialize it-a's containers plus an unrelated it-b container.
        try await seedRealItemRows(store, itemID: "it-a", paths: ["", "Files", "Files/data.txt"])
        try await store.setMaterialized(alias: Self.alias, identifiers: [
            "\(Self.ws)/it-a", "\(Self.ws)/it-a/Files", "\(Self.ws)/it-b",
        ])
        #expect(try await realRowCount(store, itemID: "it-a") == 3)

        // Pass 2: it-a vanished → reconcile purges its residue.
        _ = try await engine.listItems(alias: Self.alias, workspaceID: Self.ws)

        // Real item rows for it-a are gone.
        #expect(try await realRowCount(store, itemID: "it-a") == 0)

        // Materialized entries for it-a (exact + descendant) are gone; it-b survives.
        let materialized = try await materializedIdentifiers(store)
        #expect(!materialized.contains("\(Self.ws)/it-a"))
        #expect(!materialized.contains("\(Self.ws)/it-a/Files"))
        #expect(materialized.contains("\(Self.ws)/it-b"))
    }

    // MARK: - 2. The vanished item's blob is reclaimed by the orphan sweep

    @Test("a vanished item's blob is left for the orphan sweep (batchDelete does not unlink)")
    func vanishedItemBlobReclaimedBySweep() async throws {
        let fabric = MockFabricClient()
        fabric.listItemsResults.append(.success([item("it-a")]))
        fabric.listItemsResults.append(.success([])) // it-a gone

        let (engine, store) = try makeEngine(fabric: fabric)
        defer { try? FileManager.default.removeItem(at: store.root) }

        _ = try await engine.listItems(alias: Self.alias, workspaceID: Self.ws)

        // A real item row carrying a blob.
        let key = CacheKey(accountAlias: Self.alias, workspaceID: Self.ws, itemID: "it-a", path: "Files/data.txt")
        try await store.upsert(MetadataRecord(
            accountAlias: Self.alias, workspaceID: Self.ws, itemID: "it-a",
            path: "Files/data.txt", parentPath: "Files", name: "data.txt", isDir: false
        ))
        try await store.storeBlob(key: key, data: Data("hello".utf8))
        #expect(try await store.blobBytes() > 0)

        // Pass 2: it-a vanished → reconcile wipes the row via batchDelete
        // (recordTombstones: false), which does NOT unlink the blob file.
        _ = try await engine.listItems(alias: Self.alias, workspaceID: Self.ws)

        // The row is gone, so nothing references the blob any more.
        #expect(try await realRowCount(store, itemID: "it-a") == 0)
        #expect(try await store.blobBytes() == 0)

        // The now-orphaned blob file is reclaimed by the sweep (same code path as
        // the init-time sweep) — matching cache-20's storeBlob-orphan pattern.
        try await store.sweepOrphans()
        let (diskCount, _) = try await store.diskUsage()
        #expect(diskCount == 0, "the vanished item's orphan blob must be reclaimed by the sweep")
    }

    // MARK: - 3. A raced re-population of a still-absent item converges on the next reconcile

    @Test("re-populated state for a still-absent item converges on the next reconcile (eventual consistency)")
    func rePopulatedItemConvergesOnNextReconcile() async throws {
        let fabric = MockFabricClient()
        fabric.listItemsResults.append(.success([item("it-a")])) // pass 1: present
        fabric.listItemsResults.append(.success([])) // pass 2: gone → purge
        fabric.listItemsResults.append(.success([])) // pass 3: still gone → re-purge

        let (engine, store) = try makeEngine(fabric: fabric)
        defer { try? FileManager.default.removeItem(at: store.root) }

        _ = try await engine.listItems(alias: Self.alias, workspaceID: Self.ws)
        try await seedRealItemRows(store, itemID: "it-a", paths: ["", "Files/data.txt"])
        try await store.setMaterialized(alias: Self.alias, identifiers: ["\(Self.ws)/it-a"])

        // Pass 2: purge it-a's residue.
        _ = try await engine.listItems(alias: Self.alias, workspaceID: Self.ws)
        #expect(try await realRowCount(store, itemID: "it-a") == 0)
        #expect(try await materializedIdentifiers(store).isEmpty)

        // RACE: model a concurrent stale re-listing + in-flight refreshFolder that,
        // after the purge, repopulate the discovery row, a real row, and the
        // materialized entry for the (still-absent) item. No locking guards this.
        try await store.upsert(MetadataRecord(
            accountAlias: Self.alias, workspaceID: Self.ws, itemID: VirtualIDs.itemID,
            path: "it-a", parentPath: "", name: "Lake it-a", isDir: true
        ))
        try await seedRealItemRows(store, itemID: "it-a", paths: ["Files/data.txt"])
        try await store.setMaterialized(alias: Self.alias, identifiers: ["\(Self.ws)/it-a"])

        // Pass 3: it-a STILL absent from the listing → reconcile re-expires the
        // re-created discovery row and re-purges → the state converges to clean.
        _ = try await engine.listItems(alias: Self.alias, workspaceID: Self.ws)
        #expect(try await realRowCount(store, itemID: "it-a") == 0)
        #expect(try await materializedIdentifiers(store).isEmpty)
    }

    // MARK: - 4. The vanished item's deletion tombstone survives the purge

    /// The `"<ws>/<guid>"` deletion tombstone written by `expireDiscoveryRows`
    /// (`recordTombstones: true` on the discovery row) MUST survive
    /// `purgeRemovedItems`' `recordTombstones: false` wipe of the real item rows —
    /// it is what `enumerateChanges` delivers to the client so Finder drops the
    /// item. This is the PR's most important safety property; asserting it directly
    /// makes it regression-proof against a future reorder that wiped the item
    /// before its tombstone landed.
    @Test("a vanished item's deletion tombstone survives the purge (deletion stays deliverable)")
    func vanishedItemDeletionTombstoneSurvivesPurge() async throws {
        let fabric = MockFabricClient()
        fabric.listItemsResults.append(.success([item("it-a")])) // pass 1: present
        fabric.listItemsResults.append(.success([])) // pass 2: gone

        let (engine, store) = try makeEngine(fabric: fabric)
        defer { try? FileManager.default.removeItem(at: store.root) }

        _ = try await engine.listItems(alias: Self.alias, workspaceID: Self.ws)
        // Seed real rows (incl. the item-root row, whose identifier is "ws/guid")
        // so purgeRemovedItems' recordTombstones:false wipe actually runs over them.
        try await seedRealItemRows(store, itemID: "it-a", paths: ["", "Files/data.txt"])

        // Pass 2: it-a vanished → discovery-row tombstone written, then real rows wiped.
        _ = try await engine.listItems(alias: Self.alias, workspaceID: Self.ws)

        // The "ws/it-a" tombstone is present post-reconcile (delivered as a deletion)...
        let tombstones = try await store.dbPool.read { db in
            try String.fetchAll(db, sql: """
            SELECT identifier_string FROM deletion_tombstones WHERE account_alias = ?
            """, arguments: [Self.alias])
        }
        #expect(tombstones.contains("\(Self.ws)/it-a"))
        // ...and it also surfaces through the delta read the FPE consumes.
        let (_, deleted) = try await store.itemsChangedAfter(accountAlias: Self.alias, ns: 0)
        #expect(deleted.contains("\(Self.ws)/it-a"))
        // The recordTombstones:false wipe did run (real rows gone).
        #expect(try await realRowCount(store, itemID: "it-a") == 0)
    }
}
