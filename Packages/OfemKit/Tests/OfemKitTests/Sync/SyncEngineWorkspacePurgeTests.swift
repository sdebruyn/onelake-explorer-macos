import Foundation
import GRDB
@testable import OfemKit
import Testing

// MARK: - SyncEngine workspace-orphan cleanup tests

/// Tests that when a workspace vanishes from a successful `listWorkspaces`
/// listing, ``SyncEngine/purgeRemovedWorkspaces(alias:seen:)`` reclaims its
/// cached residue: every `path_metadata` row under the workspace (real item
/// rows, item-discovery rows, and the item-listing root marker), its
/// `workspace_status` row, and its `materialized_containers` entries.
///
/// Unlike the item-level cleanup (#421), this is SET-BASED, not
/// edge-triggered: it re-derives the orphan set from the cache's live
/// workspace IDs vs the fresh listing on every successful reconcile, rather
/// than reacting to a discovery-row delta. `rePopulatedWorkspaceConvergesOnNextReconcile`
/// and `preExistingOrphanReclaimedOnFirstPass` below are the tests that
/// specifically pin this — an edge-triggered purge could pass neither.
@Suite("SyncEngine workspace-orphan cleanup")
struct SyncEngineWorkspacePurgeTests {
    private static let alias = "acct"

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

    private func workspace(_ id: String) -> Workspace {
        Workspace(id: id, displayName: id, type: "Workspace")
    }

    private func item(_ id: String, ws: String) -> Item {
        Item(id: id, displayName: "Lake \(id)", type: "Lakehouse", workspaceID: ws)
    }

    /// Seeds the real `path_metadata` rows an item accrues after a folder
    /// refresh (keyed by the real item GUID, NOT the discovery sentinel).
    private func seedRealItemRows(_ store: CacheStore, workspaceID: String, itemID: String, paths: [String]) async throws {
        for path in paths {
            try await store.upsert(MetadataRecord(
                accountAlias: Self.alias, workspaceID: workspaceID, itemID: itemID,
                path: path, parentPath: Enumerator.parentPath(path),
                name: Enumerator.baseName(path), isDir: !path.contains(".")
            ))
        }
    }

    private func pathMetadataRowCount(_ store: CacheStore, workspaceID: String) async throws -> Int {
        try await store.dbPool.read { db in
            try Int.fetchOne(db, sql: """
            SELECT COUNT(*) FROM path_metadata
            WHERE account_alias = ? AND workspace_id = ?
            """, arguments: [Self.alias, workspaceID]) ?? -1
        }
    }

    private func workspaceStatusExists(_ store: CacheStore, workspaceID: String) async throws -> Bool {
        let count = try await store.dbPool.read { db in
            try Int.fetchOne(db, sql: """
            SELECT COUNT(*) FROM workspace_status
            WHERE account_alias = ? AND workspace_id = ?
            """, arguments: [Self.alias, workspaceID]) ?? 0
        }
        return count > 0
    }

    private func materializedIdentifiers(_ store: CacheStore) async throws -> [String] {
        try await store.dbPool.read { db in
            try String.fetchAll(db, sql: """
            SELECT identifier_string FROM materialized_containers
            WHERE account_alias = ? ORDER BY identifier_string
            """, arguments: [Self.alias])
        }
    }

    private func tombstoneCount(_ store: CacheStore) async throws -> Int {
        try await store.dbPool.read { db in
            try Int.fetchOne(db, sql: """
            SELECT COUNT(*) FROM deletion_tombstones WHERE account_alias = ?
            """, arguments: [Self.alias]) ?? -1
        }
    }

    // MARK: - 1. Vanished workspace purges rows + status + materialized (alias-scoped, zero tombstones)

    @Test("a vanished workspace's rows, status, and materialized entries are purged; a sibling workspace survives; zero tombstones are written")
    func vanishedWorkspacePurgesRowsStatusAndMaterialized() async throws {
        let fabric = MockFabricClient()
        fabric.listWorkspacesResults.append(.success([workspace("ws-a"), workspace("ws-b")])) // pass 1: both present
        fabric.listWorkspacesResults.append(.success([workspace("ws-b")])) // pass 2: ws-a gone

        let (engine, store) = try makeEngine(fabric: fabric)
        defer { try? FileManager.default.removeItem(at: store.root) }

        _ = try await engine.listWorkspaces(alias: Self.alias)

        // Seed each workspace's item-listing root marker + one item-discovery
        // row (a listItems pass), plus the real item rows a folder refresh
        // would leave, so the purge has real residue to reclaim.
        fabric.listItemsResults.append(.success([item("it-a", ws: "ws-a")]))
        _ = try await engine.listItems(alias: Self.alias, workspaceID: "ws-a")
        try await seedRealItemRows(store, workspaceID: "ws-a", itemID: "it-a", paths: ["", "Files/data.txt"])

        fabric.listItemsResults.append(.success([item("it-b", ws: "ws-b")]))
        _ = try await engine.listItems(alias: Self.alias, workspaceID: "ws-b")
        try await seedRealItemRows(store, workspaceID: "ws-b", itemID: "it-b", paths: ["", "Files/data.txt"])

        try await store.setMaterialized(alias: Self.alias, identifiers: [
            "ws-a", "ws-a/it-a", "ws-b", "ws-b/it-b",
        ])
        try await store.setWorkspaceStatus(WorkspaceStatusRecord(
            accountAlias: Self.alias, workspaceID: "ws-a", state: .paused, reason: "capacity_paused"
        ))
        try await store.setWorkspaceStatus(WorkspaceStatusRecord(
            accountAlias: Self.alias, workspaceID: "ws-b", state: .active
        ))

        #expect(try await pathMetadataRowCount(store, workspaceID: "ws-a") > 0)
        let tombstonesBefore = try await tombstoneCount(store)

        // Pass 2: ws-a vanished from the listing → the set-based purge fires.
        _ = try await engine.listWorkspaces(alias: Self.alias)

        // All of ws-a's path_metadata rows are gone — real item rows, the
        // item-discovery row, and the item-listing root marker all share the
        // workspace_id column, so one predicate wipes them together.
        #expect(try await pathMetadataRowCount(store, workspaceID: "ws-a") == 0)
        #expect(try await workspaceStatusExists(store, workspaceID: "ws-a") == false)

        let materialized = try await materializedIdentifiers(store)
        #expect(!materialized.contains("ws-a"))
        #expect(!materialized.contains("ws-a/it-a"))

        // ws-b (the sibling workspace) is fully untouched.
        #expect(try await pathMetadataRowCount(store, workspaceID: "ws-b") > 0)
        #expect(try await workspaceStatusExists(store, workspaceID: "ws-b"))
        #expect(materialized.contains("ws-b"))
        #expect(materialized.contains("ws-b/it-b"))

        // No tombstones were written by the workspace purge: a workspace's
        // own discovery row never tombstones (its removal is remount-driven,
        // not delta-driven — tombstoneIdentifierString returns nil for
        // workspaceID == VirtualIDs.workspaceID rows), and
        // CacheStore.purgeWorkspaceRows writes none either.
        #expect(try await tombstoneCount(store) == tombstonesBefore)
    }

    // MARK: - 2. A failed Fabric listing rethrows before the reconcile — nothing purged

    @Test("a failed Fabric listing (offline / paused / pagination truncation) rethrows before the reconcile; cached rows are untouched")
    func fabricListingFailureSkipsPurge() async throws {
        let fabric = MockFabricClient()
        fabric.listWorkspacesResults.append(.success([workspace("ws-a")])) // pass 1: present
        fabric.listWorkspacesResults.append(.failure(MockError.intentional("offline"))) // pass 2: fails

        let (engine, store) = try makeEngine(fabric: fabric)
        defer { try? FileManager.default.removeItem(at: store.root) }

        _ = try await engine.listWorkspaces(alias: Self.alias)
        fabric.listItemsResults.append(.success([item("it-a", ws: "ws-a")]))
        _ = try await engine.listItems(alias: Self.alias, workspaceID: "ws-a")
        try await seedRealItemRows(store, workspaceID: "ws-a", itemID: "it-a", paths: ["", "Files/data.txt"])

        let rowsBefore = try await pathMetadataRowCount(store, workspaceID: "ws-a")
        #expect(rowsBefore > 0)

        // Pass 2: fabric.listAllWorkspaces throws → listWorkspaces rethrows
        // BEFORE reaching the reconcile, so purgeRemovedWorkspaces never runs.
        // This same early-rethrow guards every failure mode (offline,
        // capacity-paused, and listAllWorkspaces' own pagination-truncation
        // throw) — there is only one catch site to cover.
        await #expect(throws: (any Error).self) {
            _ = try await engine.listWorkspaces(alias: Self.alias)
        }

        #expect(try await pathMetadataRowCount(store, workspaceID: "ws-a") == rowsBefore)
    }

    // MARK: - 3. Convergence: a raced re-upsert with NO discovery row is purged again

    @Test("a raced re-upsert into an already-purged workspace, with no discovery row at all, is purged again on the next reconcile")
    func rePopulatedWorkspaceConvergesOnNextReconcile() async throws {
        let fabric = MockFabricClient()
        fabric.listWorkspacesResults.append(.success([workspace("ws-a"), workspace("ws-b")])) // pass 1
        fabric.listWorkspacesResults.append(.success([workspace("ws-b")])) // pass 2: ws-a gone → purged
        fabric.listWorkspacesResults.append(.success([workspace("ws-b")])) // pass 3: ws-a still gone

        let (engine, store) = try makeEngine(fabric: fabric)
        defer { try? FileManager.default.removeItem(at: store.root) }

        _ = try await engine.listWorkspaces(alias: Self.alias)
        fabric.listItemsResults.append(.success([item("it-a", ws: "ws-a")]))
        _ = try await engine.listItems(alias: Self.alias, workspaceID: "ws-a")
        try await seedRealItemRows(store, workspaceID: "ws-a", itemID: "it-a", paths: ["", "a/b.txt"])

        // Pass 2: ws-a purged (including its discovery row and tombstone).
        _ = try await engine.listWorkspaces(alias: Self.alias)
        #expect(try await pathMetadataRowCount(store, workspaceID: "ws-a") == 0)

        // RACE: a stray re-upsert lands for ws-a with NO discovery row
        // present at all — the case an edge-triggered (discovery-row-diff)
        // purge could never catch, because there is no discovery-row delta
        // left to trigger off.
        try await store.upsert(MetadataRecord(
            accountAlias: Self.alias, workspaceID: "ws-a", itemID: "it-race",
            path: "a/b.txt", parentPath: "a", name: "b.txt", isDir: false
        ))
        #expect(try await pathMetadataRowCount(store, workspaceID: "ws-a") == 1)

        // Pass 3: ws-a is still absent from a successful listing → the
        // set-based check (cache's live workspace IDs vs `seen`) fires again
        // purely from the row's presence — re-purged.
        _ = try await engine.listWorkspaces(alias: Self.alias)
        #expect(try await pathMetadataRowCount(store, workspaceID: "ws-a") == 0)
    }

    // MARK: - 4. Pre-existing/historical orphan with no discovery row is reclaimed on the first pass

    @Test("a pre-existing workspace with no discovery row at all is reclaimed on the very first successful listing")
    func preExistingOrphanReclaimedOnFirstPass() async throws {
        let fabric = MockFabricClient()
        fabric.listWorkspacesResults.append(.success([workspace("ws-b")])) // ws-orphan is never listed

        let (engine, store) = try makeEngine(fabric: fabric)
        defer { try? FileManager.default.removeItem(at: store.root) }

        // Seed a historical leak directly: real rows for "ws-orphan" with no
        // workspace-discovery row ever written for it (models a leak that
        // predates this cleanup, or whose discovery row is gone for any
        // other reason). Edge-triggered detection could never see this —
        // there is no discovery-row delta to react to.
        try await store.upsert(MetadataRecord(
            accountAlias: Self.alias, workspaceID: "ws-orphan", itemID: VirtualIDs.itemID,
            path: "", parentPath: "", name: "ws-orphan", isDir: true
        ))
        try await store.upsert(MetadataRecord(
            accountAlias: Self.alias, workspaceID: "ws-orphan", itemID: "it-x",
            path: "", parentPath: "", name: "it-x", isDir: true
        ))
        #expect(try await pathMetadataRowCount(store, workspaceID: "ws-orphan") == 2)

        // First-ever successful listing already reclaims it — set-based
        // detection compares the cache's live workspace IDs directly against
        // the fresh listing, so it needs no discovery-row delta to trigger.
        _ = try await engine.listWorkspaces(alias: Self.alias)
        #expect(try await pathMetadataRowCount(store, workspaceID: "ws-orphan") == 0)
    }

    // MARK: - 5. An empty-but-successful listing purges every cached workspace

    @Test("an empty-but-successful listing purges every cached workspace for the alias")
    func emptySuccessfulListingPurgesEverything() async throws {
        let fabric = MockFabricClient()
        fabric.listWorkspacesResults.append(.success([workspace("ws-a"), workspace("ws-b")])) // pass 1
        fabric.listWorkspacesResults.append(.success([])) // pass 2: empty but SUCCESSFUL

        let (engine, store) = try makeEngine(fabric: fabric)
        defer { try? FileManager.default.removeItem(at: store.root) }

        _ = try await engine.listWorkspaces(alias: Self.alias)
        fabric.listItemsResults.append(.success([item("it-a", ws: "ws-a")]))
        _ = try await engine.listItems(alias: Self.alias, workspaceID: "ws-a")
        fabric.listItemsResults.append(.success([item("it-b", ws: "ws-b")]))
        _ = try await engine.listItems(alias: Self.alias, workspaceID: "ws-b")

        #expect(try await pathMetadataRowCount(store, workspaceID: "ws-a") > 0)
        #expect(try await pathMetadataRowCount(store, workspaceID: "ws-b") > 0)

        // Pass 2: an empty listing is a SUCCESSFUL listing (no throw), so it
        // reaches the reconcile. This is intended, authoritative-success
        // semantics, not a bug: it exactly mirrors the discovery-row behavior
        // already visible today — an empty listing already expires every
        // workspace-discovery row and remounts the domain to empty. This
        // purge just aligns cache storage with what the user already sees, so
        // no absent-twice or debounce guard is layered on top of it.
        _ = try await engine.listWorkspaces(alias: Self.alias)

        #expect(try await pathMetadataRowCount(store, workspaceID: "ws-a") == 0)
        #expect(try await pathMetadataRowCount(store, workspaceID: "ws-b") == 0)
    }

    // MARK: - 6. An incomplete listing (a dropped wire element) skips the destructive purge

    @Test("an incomplete listing (a dropped wire element) skips purgeRemovedWorkspaces, though the discovery-row reconcile still runs")
    func incompleteListingSkipsDestructivePurge() async throws {
        let fabric = MockFabricClient()
        fabric.listWorkspacesResults.append(.success([workspace("ws-a"), workspace("ws-b")])) // pass 1: both present

        let (engine, store) = try makeEngine(fabric: fabric)
        defer { try? FileManager.default.removeItem(at: store.root) }

        // Pass 1 (droppedCounts queue is empty → defaults to 0/complete, as
        // it must for every other test in this file).
        _ = try await engine.listWorkspaces(alias: Self.alias)
        fabric.listItemsResults.append(.success([item("it-a", ws: "ws-a")]))
        _ = try await engine.listItems(alias: Self.alias, workspaceID: "ws-a")
        try await seedRealItemRows(store, workspaceID: "ws-a", itemID: "it-a", paths: ["", "Files/data.txt"])
        try await store.setWorkspaceStatus(WorkspaceStatusRecord(accountAlias: Self.alias, workspaceID: "ws-a"))

        let rowsBefore = try await pathMetadataRowCount(store, workspaceID: "ws-a")
        #expect(rowsBefore > 0)

        // Pass 2: only ws-b comes back. Models ws-a being the element whose
        // wire row was missing `id` and got silently dropped by
        // WireWorkspace.toWorkspace() (fabric-06) — NOT a genuine removal.
        // The Fabric call itself still succeeds (no throw), but the listing
        // is INCOMPLETE, signalled by droppedCount == 1. Pushed only now (not
        // alongside pass 1's stub above) so it lines up with the pass-2
        // dequeue — the mock consumes both queues in call order.
        fabric.listWorkspacesResults.append(.success([workspace("ws-b")]))
        fabric.listWorkspacesDroppedCounts.append(1)

        // ws-a is absent from `seen` (dropped, not genuinely removed) and
        // droppedCount == 1 → the destructive purge must be skipped.
        _ = try await engine.listWorkspaces(alias: Self.alias)

        // Nothing was purged: ws-a's real rows and workspace_status survive.
        #expect(try await pathMetadataRowCount(store, workspaceID: "ws-a") == rowsBefore)
        #expect(try await workspaceStatusExists(store, workspaceID: "ws-a"))

        // The PRE-EXISTING expireDiscoveryRows reconcile is unaffected by this
        // guard and still ran: ws-a's workspace-discovery row is gone from the
        // domain-root listing (a cheap, self-healing remount — not the
        // destructive full-cache wipe the guard above prevents).
        let rootChildren = try await store.children(of: CacheKey(
            accountAlias: Self.alias, workspaceID: VirtualIDs.workspaceID,
            itemID: VirtualIDs.workspaceID, path: ""
        ))
        #expect(!rootChildren.contains { $0.path == "ws-a" })
    }
}

// MARK: - CacheStore.purgeWorkspaceRows unit tests

/// Lower-level tests of ``CacheStore/purgeWorkspaceRows(accountAlias:workspaceID:)``
/// directly, without going through ``SyncEngine``.
@Suite("CacheStore.purgeWorkspaceRows")
struct CacheStorePurgeWorkspaceRowsTests {
    @Test("purgeWorkspaceRows is alias-scoped and never touches __workspaces__ / domain-root rows")
    func purgeWorkspaceRowsIsAliasScopedAndLeavesDomainRootUntouched() async throws {
        let store = try makeTempStore()
        defer { try? FileManager.default.removeItem(at: store.root) }

        let aliasA = "acct-a"
        let aliasB = "acct-b"
        let ws = "ws-shared"

        // Real rows for the SAME workspace ID under two different aliases:
        // the item-listing root marker (itemID == VirtualIDs.itemID) + a real
        // item's own root path_metadata row (itemID == the item GUID "it-x",
        // NOT a discovery row — discovery rows are keyed itemID ==
        // VirtualIDs.itemID with path == the item GUID), plus a paused
        // workspace_status row.
        for alias in [aliasA, aliasB] {
            try await store.upsert(MetadataRecord(
                accountAlias: alias, workspaceID: ws, itemID: VirtualIDs.itemID,
                path: "", parentPath: "", name: ws, isDir: true
            ))
            try await store.upsert(MetadataRecord(
                accountAlias: alias, workspaceID: ws, itemID: "it-x",
                path: "", parentPath: "", name: "it-x", isDir: true
            ))
            try await store.setWorkspaceStatus(WorkspaceStatusRecord(
                accountAlias: alias, workspaceID: ws, state: .paused
            ))
        }

        // aliasA's domain-root / workspace-discovery rows
        // (workspace_id == VirtualIDs.workspaceID) — must never match the
        // workspace-scoped predicate, however similar `ws` looks.
        try await store.upsert(MetadataRecord(
            accountAlias: aliasA, workspaceID: VirtualIDs.workspaceID, itemID: VirtualIDs.workspaceID,
            path: "", parentPath: "", name: aliasA, isDir: true
        ))
        try await store.upsert(MetadataRecord(
            accountAlias: aliasA, workspaceID: VirtualIDs.workspaceID, itemID: VirtualIDs.workspaceID,
            path: ws, parentPath: "", name: ws, isDir: true
        ))

        let deleted = try await store.purgeWorkspaceRows(accountAlias: aliasA, workspaceID: ws)
        #expect(deleted == 2) // the item-listing root marker + it-x's own root row

        // aliasA's workspace-scoped rows and status are gone.
        #expect(try await pathMetadataCount(store, alias: aliasA, workspaceID: ws) == 0)
        let statusA = try? await store.workspaceStatus(accountAlias: aliasA, workspaceID: ws)
        #expect(statusA == nil)

        // aliasB's identically-keyed workspace rows and status are untouched.
        #expect(try await pathMetadataCount(store, alias: aliasB, workspaceID: ws) == 2)
        let statusB = try await store.workspaceStatus(accountAlias: aliasB, workspaceID: ws)
        #expect(statusB.state == .paused)

        // aliasA's domain-root / workspace-discovery rows survive untouched.
        #expect(try await pathMetadataCount(store, alias: aliasA, workspaceID: VirtualIDs.workspaceID) == 2)
    }

    private func pathMetadataCount(_ store: CacheStore, alias: String, workspaceID: String) async throws -> Int {
        try await store.dbPool.read { db in
            try Int.fetchOne(db, sql: """
            SELECT COUNT(*) FROM path_metadata
            WHERE account_alias = ? AND workspace_id = ?
            """, arguments: [alias, workspaceID]) ?? -1
        }
    }
}
