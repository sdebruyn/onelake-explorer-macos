import Foundation
import GRDB
@testable import OfemKit
import Testing

// MARK: - Deletion tombstone tests

/// Unit tests for the tombstoned batch-delete reconcile (F1), the
/// tombstone-clear-on-recreate write path (F9), the deletion-aware sync anchor
/// (F10), and the v7 legacy-purge migration.
///
/// SQL is asserted directly against `store.dbPool` and timestamps are driven by
/// an injected clock so the ordering is deterministic.
@Suite("Deletion tombstones")
struct DeletionTombstoneTests {
    private static let alias = "acct"
    private static let ws = "ws-guid"
    private static let item = "item-guid"

    /// A settable Unix-nanosecond clock (thread-safe: the store reads it off the
    /// actor's executor while the test body mutates it).
    private final class StepClock: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Int64
        init(_ v: Int64) {
            value = v
        }

        var now: Int64 {
            get { lock.withLock { value } }
            set { lock.withLock { value = newValue } }
        }
    }

    private func fileKey(_ path: String) -> CacheKey {
        CacheKey(accountAlias: Self.alias, workspaceID: Self.ws, itemID: Self.item, path: path)
    }

    private func seedFile(_ store: CacheStore, path: String, syncedAtNs: Int64 = 0) async throws {
        try await store.upsert(MetadataRecord(
            accountAlias: Self.alias, workspaceID: Self.ws, itemID: Self.item,
            path: path, parentPath: Enumerator.parentPath(path),
            name: Enumerator.baseName(path), isDir: false, syncedAtNs: syncedAtNs
        ))
    }

    /// Reads all tombstones for `alias`, ordered by identifier, as `(id, ns)`.
    private func tombstones(
        _ store: CacheStore, alias: String = alias
    ) async throws -> [(id: String, ns: Int64)] {
        try await store.dbPool.read { db in
            try Row.fetchAll(db, sql: """
            SELECT identifier_string, deleted_at_ns FROM deletion_tombstones
            WHERE account_alias = ? ORDER BY identifier_string
            """, arguments: [alias]).map { row in
                let id: String = row["identifier_string"]
                let ns: Int64 = row["deleted_at_ns"]
                return (id: id, ns: ns)
            }
        }
    }

    // MARK: - 1. file-key → single tombstone at the clock value

    @Test("batchDelete(recordTombstones: true) writes one tombstone at the clock value")
    func fileKeyWritesTombstone() async throws {
        let clock = StepClock(1000)
        let store = try makeTempStore(clock: { clock.now })
        defer { try? FileManager.default.removeItem(at: store.root) }

        try await seedFile(store, path: "f.txt")
        clock.now = 42000
        try await store.batchDelete([fileKey("f.txt")], recordTombstones: true)

        let rows = try await tombstones(store)
        #expect(rows.count == 1)
        #expect(rows.first?.id == "\(Self.ws)/\(Self.item)/f.txt")
        #expect(rows.first?.ns == 42000)
    }

    // MARK: - 2. dir-key → tombstone for the directory and every descendant

    @Test("batchDelete tombstones a directory and all cached descendants")
    func dirKeyTombstonesSubtree() async throws {
        let store = try makeTempStore()
        defer { try? FileManager.default.removeItem(at: store.root) }

        for path in ["dir", "dir/a.txt", "dir/nested/b.txt"] {
            try await store.upsert(MetadataRecord(
                accountAlias: Self.alias, workspaceID: Self.ws, itemID: Self.item,
                path: path, parentPath: Enumerator.parentPath(path),
                name: Enumerator.baseName(path), isDir: path == "dir"
            ))
        }
        try await store.batchDelete([fileKey("dir")], recordTombstones: true)

        let ids = try await tombstones(store).map(\.id)
        #expect(ids.contains("\(Self.ws)/\(Self.item)/dir"))
        #expect(ids.contains("\(Self.ws)/\(Self.item)/dir/a.txt"))
        #expect(ids.contains("\(Self.ws)/\(Self.item)/dir/nested/b.txt"))
        #expect(ids.count == 3)
    }

    // MARK: - 3. recordTombstones: false writes nothing

    @Test("batchDelete(recordTombstones: false) writes no tombstones")
    func noTombstonesWhenDisabled() async throws {
        let store = try makeTempStore()
        defer { try? FileManager.default.removeItem(at: store.root) }

        try await seedFile(store, path: "f.txt")
        try await store.batchDelete([fileKey("f.txt")], recordTombstones: false)

        let rows = try await tombstones(store)
        #expect(rows.isEmpty)
    }

    // MARK: - 4. Identifier translation for discovery rows

    @Test("Discovery rows translate to .item identifiers, workspace rows are never tombstoned")
    func discoveryRowIdentifierTranslation() async throws {
        let store = try makeTempStore()
        defer { try? FileManager.default.removeItem(at: store.root) }

        // Item-discovery row: itemID == VirtualIDs.itemID, item GUID stored in path.
        try await store.upsert(MetadataRecord(
            accountAlias: Self.alias, workspaceID: Self.ws, itemID: VirtualIDs.itemID,
            path: "lakehouse-guid", parentPath: "", name: "Lakehouse", isDir: true
        ))
        // Workspace-discovery row: workspaceID == itemID == VirtualIDs.workspaceID.
        try await store.upsert(MetadataRecord(
            accountAlias: Self.alias, workspaceID: VirtualIDs.workspaceID,
            itemID: VirtualIDs.workspaceID, path: "workspace-guid",
            parentPath: "", name: "My Workspace", isDir: true
        ))

        try await store.batchDelete([
            CacheKey(accountAlias: Self.alias, workspaceID: Self.ws, itemID: VirtualIDs.itemID, path: "lakehouse-guid"),
            CacheKey(accountAlias: Self.alias, workspaceID: VirtualIDs.workspaceID, itemID: VirtualIDs.workspaceID, path: "workspace-guid"),
        ], recordTombstones: true)

        let ids = try await tombstones(store).map(\.id)
        // Item-discovery row → ".item" identifier "<workspaceID>/<itemGUID>".
        #expect(ids == ["\(Self.ws)/lakehouse-guid"])
        // Workspace-discovery row produced no tombstone.
        #expect(!ids.contains { $0.contains("workspace-guid") })
        // Regression: no VirtualIDs sentinel ever leaks into an identifier.
        #expect(!ids.contains { $0.contains(VirtualIDs.itemID) })
        #expect(!ids.contains { $0.contains(VirtualIDs.workspaceID) })
    }

    // MARK: - 5. upsert / batchUpsert clear an existing tombstone

    @Test("upsert and batchUpsert clear a tombstone shadowing the re-created identifier")
    func writeClearsTombstone() async throws {
        let store = try makeTempStore()
        defer { try? FileManager.default.removeItem(at: store.root) }

        try await store.recordDeletion(accountAlias: Self.alias, identifierString: "\(Self.ws)/\(Self.item)/f.txt")
        try await store.recordDeletion(accountAlias: Self.alias, identifierString: "\(Self.ws)/\(Self.item)/g.txt")
        #expect(try await tombstones(store).count == 2)

        // upsert clears f.txt's tombstone.
        try await seedFile(store, path: "f.txt")
        // batchUpsert clears g.txt's tombstone.
        try await store.batchUpsert([MetadataRecord(
            accountAlias: Self.alias, workspaceID: Self.ws, itemID: Self.item,
            path: "g.txt", parentPath: "", name: "g.txt", isDir: false
        )])

        let ids = try await tombstones(store).map(\.id)
        #expect(ids.isEmpty)
    }

    // MARK: - 6. renamePathPrefix clears destination-subtree tombstones

    @Test("renamePathPrefix clears tombstones covering the destination subtree")
    func renameClearsDestinationTombstones() async throws {
        let store = try makeTempStore()
        defer { try? FileManager.default.removeItem(at: store.root) }

        // Stale tombstones over the destination subtree, plus an unrelated one.
        try await store.recordDeletion(accountAlias: Self.alias, identifierString: "\(Self.ws)/\(Self.item)/newdir")
        try await store.recordDeletion(accountAlias: Self.alias, identifierString: "\(Self.ws)/\(Self.item)/newdir/child.txt")
        try await store.recordDeletion(accountAlias: Self.alias, identifierString: "\(Self.ws)/\(Self.item)/other")

        // A row to rename into the destination name.
        try await store.upsert(MetadataRecord(
            accountAlias: Self.alias, workspaceID: Self.ws, itemID: Self.item,
            path: "olddir", parentPath: "", name: "olddir", isDir: true
        ))
        _ = try await store.renamePathPrefix(
            accountAlias: Self.alias, workspaceID: Self.ws, itemID: Self.item,
            oldPath: "olddir", newPath: "newdir", newName: "newdir"
        )

        let ids = try await tombstones(store).map(\.id)
        #expect(!ids.contains("\(Self.ws)/\(Self.item)/newdir"))
        #expect(!ids.contains("\(Self.ws)/\(Self.item)/newdir/child.txt"))
        // The unrelated tombstone survives (LIKE scope is the destination only).
        #expect(ids.contains("\(Self.ws)/\(Self.item)/other"))
    }

    // MARK: - 7. syncAnchorNs folds in tombstones and never regresses

    @Test("syncAnchorNs uses the newest tombstone and does not drop when the newest row is deleted")
    func syncAnchorFoldsTombstones() async throws {
        let clock = StepClock(500)
        let store = try makeTempStore(clock: { clock.now })
        defer { try? FileManager.default.removeItem(at: store.root) }

        // Newest path row at 500.
        try await seedFile(store, path: "newest.txt", syncedAtNs: 500)
        try await seedFile(store, path: "older.txt", syncedAtNs: 300)

        // A tombstone newer than every path row.
        clock.now = 900
        try await store.recordDeletion(accountAlias: Self.alias, identifierString: "\(Self.ws)/\(Self.item)/gone.txt")

        let anchorBefore = try await store.syncAnchorNs(accountAlias: Self.alias)
        #expect(anchorBefore == 900)

        // Delete the newest path row WITHOUT a new tombstone: the anchor must not
        // regress — the tombstone still holds it at 900.
        try await store.batchDelete([fileKey("newest.txt")], recordTombstones: false)
        let anchorAfter = try await store.syncAnchorNs(accountAlias: Self.alias)
        #expect(anchorAfter == 900)
    }

    // MARK: - 8. itemsChangedAfter reconciles overlaps by timestamp

    @Test("itemsChangedAfter drops a stale tombstone but honours a fresher one")
    func itemsChangedAfterReconciles() async throws {
        let clock = StepClock(0)
        let store = try makeTempStore(clock: { clock.now })
        defer { try? FileManager.default.removeItem(at: store.root) }

        // f.txt: live row (200) newer than its tombstone (100) → the row wins.
        try await seedFile(store, path: "f.txt", syncedAtNs: 200)
        clock.now = 100
        try await store.recordDeletion(accountAlias: Self.alias, identifierString: "\(Self.ws)/\(Self.item)/f.txt")

        // g.txt: tombstone (300) newer than its live row (200) → the deletion wins.
        try await seedFile(store, path: "g.txt", syncedAtNs: 200)
        clock.now = 300
        try await store.recordDeletion(accountAlias: Self.alias, identifierString: "\(Self.ws)/\(Self.item)/g.txt")

        let changes = try await store.itemsChangedAfter(accountAlias: Self.alias, ns: 50)

        let updatedPaths = changes.updated.map(\.path)
        #expect(updatedPaths.contains("f.txt"))
        #expect(!updatedPaths.contains("g.txt"))

        #expect(!changes.deletedIdentifierStrings.contains("\(Self.ws)/\(Self.item)/f.txt"))
        #expect(changes.deletedIdentifierStrings.contains("\(Self.ws)/\(Self.item)/g.txt"))
    }

    // MARK: - 9. v7 migration purges legacy stale tombstones

    @Test("v7 migration purges tombstones shadowed by a fresher live row, keeps the rest")
    func v7PurgesLegacyStaleTombstones() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let pool = try DatabasePool(path: tmp.appendingPathComponent("cache.sqlite").path)

        let migrator = CacheSchema.migrator()
        // Build the schema through v6 (before the tombstone-clear-on-recreate work).
        try migrator.migrate(pool, upTo: "v6")

        try await pool.write { db in
            // A live row fresher than a shadowing tombstone (must be purged).
            try db.execute(sql: """
            INSERT INTO path_metadata
                (account_alias, workspace_id, item_id, path, parent_path, name, is_dir, last_accessed_ns, synced_at_ns)
            VALUES (?, ?, ?, ?, ?, ?, 0, 0, 200)
            """, arguments: [Self.alias, Self.ws, Self.item, "stale.txt", "", "stale.txt"])
            try db.execute(sql: """
            INSERT INTO deletion_tombstones (account_alias, identifier_string, deleted_at_ns)
            VALUES (?, ?, 100)
            """, arguments: [Self.alias, "\(Self.ws)/\(Self.item)/stale.txt"])
            // A tombstone with no live row (must survive).
            try db.execute(sql: """
            INSERT INTO deletion_tombstones (account_alias, identifier_string, deleted_at_ns)
            VALUES (?, ?, 300)
            """, arguments: [Self.alias, "\(Self.ws)/\(Self.item)/gone.txt"])
        }

        // Apply v7.
        try migrator.migrate(pool)

        let ids = try await pool.read { db in
            try String.fetchAll(db, sql: "SELECT identifier_string FROM deletion_tombstones ORDER BY identifier_string")
        }
        #expect(ids == ["\(Self.ws)/\(Self.item)/gone.txt"])
    }

    // MARK: - 10. ws/<itemGUID> discovery-vs-real identifier collision (#413)

    // Two structurally different rows alias to the SAME delta identifier
    // "<workspaceID>/<itemGUID>": the item-DISCOVERY row (ws, VirtualIDs.itemID,
    // path=itemGUID) via `tombstoneIdentifierString`, and the real item-ROOT row
    // (ws, itemGUID, path="") — the shape `SyncEngine.stampParentRow` writes —
    // via `identifierString`. `CacheReader.itemsChangedAfter`'s tombstone
    // reconcile depends on that equality to shadow a stale root row behind a
    // fresher discovery tombstone and vice versa. These cases pin the contract
    // so a future refactor of either identifier-building side can't silently
    // break it.

    @Test("tombstoneIdentifierString for an item-discovery row equals identifierString for the real item-root row")
    func discoveryAndRealItemRootShareIdentifier() {
        let discoveryIdent = CacheStore.tombstoneIdentifierString(
            workspaceID: Self.ws, itemID: VirtualIDs.itemID, path: Self.item
        )
        let realRootIdent = CacheStore.identifierString(
            workspaceID: Self.ws, itemID: Self.item, path: ""
        )
        #expect(discoveryIdent == realRootIdent)
        #expect(discoveryIdent == "\(Self.ws)/\(Self.item)")
    }

    @Test("A fresher discovery tombstone shadows a stale real item-root row: deletion wins")
    func discoveryTombstoneShadowsStaleItemRootRow() async throws {
        let clock = StepClock(0)
        let store = try makeTempStore(clock: { clock.now })
        defer { try? FileManager.default.removeItem(at: store.root) }

        // Real item-root row (the stampParentRow shape) at T1.
        clock.now = 100
        try await store.upsert(MetadataRecord(
            accountAlias: Self.alias, workspaceID: Self.ws, itemID: Self.item,
            path: "", parentPath: "", name: "Lakehouse", isDir: true
        ))

        // A discovery tombstone for the SAME item, newer than the root row, at T2.
        clock.now = 200
        try await store.recordDeletion(accountAlias: Self.alias, identifierString: "\(Self.ws)/\(Self.item)")

        let changes = try await store.itemsChangedAfter(accountAlias: Self.alias, ns: 0)

        #expect(changes.deletedIdentifierStrings.contains("\(Self.ws)/\(Self.item)"))
        #expect(!changes.updated.contains {
            $0.workspaceID == Self.ws && $0.itemID == Self.item && $0.path.isEmpty
        })
    }

    @Test("A discovery re-upsert after a tombstone clears it (unconditional write-order match): recreate is reported as an update")
    func discoveryReupsertAfterTombstoneClearsItAndReportsUpdate() async throws {
        let clock = StepClock(0)
        let store = try makeTempStore(clock: { clock.now })
        defer { try? FileManager.default.removeItem(at: store.root) }

        // Discovery tombstone at T2.
        clock.now = 200
        try await store.recordDeletion(accountAlias: Self.alias, identifierString: "\(Self.ws)/\(Self.item)")

        // The item reappears in a workspace listing at T3 > T2, written through
        // batchUpsert — the reconcile path SyncEngine uses for a full listing.
        //
        // clearTombstone deletes on an unconditional identifier match at write
        // time — it does not compare deletedAtNs/syncedAtNs. The tombstone is
        // gone here because this upsert runs AFTER it (T3 > T2, enforced by this
        // test's write order), not because CacheStore itself timestamp-gates the
        // clear. The T2/T3 ordering only matters for the case where a stale row
        // is already in the DB when a tombstone lands (see the "shadows a stale
        // real item-root row" case above), where itemsChangedAfter does compare
        // timestamps.
        clock.now = 300
        try await store.batchUpsert([MetadataRecord(
            accountAlias: Self.alias, workspaceID: Self.ws, itemID: VirtualIDs.itemID,
            path: Self.item, parentPath: "", name: "Lakehouse", isDir: true
        )])

        let changes = try await store.itemsChangedAfter(accountAlias: Self.alias, ns: 0)

        #expect(changes.updated.contains {
            $0.workspaceID == Self.ws && $0.itemID == VirtualIDs.itemID && $0.path == Self.item
        })
        #expect(!changes.deletedIdentifierStrings.contains("\(Self.ws)/\(Self.item)"))
    }

    @Test("Upserting the real item-root row also clears the discovery tombstone (cross-shape collision, self-healing)")
    func realItemRootUpsertClearsDiscoveryTombstoneCrossShape() async throws {
        let clock = StepClock(0)
        let store = try makeTempStore(clock: { clock.now })
        defer { try? FileManager.default.removeItem(at: store.root) }

        // Discovery tombstone at T2 (e.g. a workspace listing no longer saw the item).
        clock.now = 200
        try await store.recordDeletion(accountAlias: Self.alias, identifierString: "\(Self.ws)/\(Self.item)")
        #expect(try await tombstones(store).map(\.id) == ["\(Self.ws)/\(Self.item)"])

        // A DIFFERENT row shape — the real item-root row `stampParentRow` writes
        // when a folder refresh stamps its parent container — is upserted at
        // T3 > T2. Because `identifierString(ws, itemGUID, "")` collides with
        // `tombstoneIdentifierString(ws, .itemID, itemGUID)` (both "ws/guid", see
        // the equality test above), `clearTombstone` deletes the SAME tombstone
        // row even though this write came through a structurally different path.
        //
        // This is intended and self-healing, not a bug: if the item is genuinely
        // still gone, the next workspace-listing reconcile re-tombstones it via
        // its own discovery-row batchDelete, so the deletion is only delayed by
        // one poll cycle, never lost.
        clock.now = 300
        try await store.upsert(MetadataRecord(
            accountAlias: Self.alias, workspaceID: Self.ws, itemID: Self.item,
            path: "", parentPath: "", name: "Lakehouse", isDir: true
        ))

        let ids = try await tombstones(store).map(\.id)
        #expect(ids.isEmpty)
    }

    @Test("A real path row nested under the item does not collide with or clear the ws/<itemGUID> tombstone")
    func realPathRowUnderItemDoesNotCollideWithItemRootIdentifier() async throws {
        let clock = StepClock(0)
        let store = try makeTempStore(clock: { clock.now })
        defer { try? FileManager.default.removeItem(at: store.root) }

        // Discovery tombstone for the item itself at T2.
        clock.now = 200
        try await store.recordDeletion(accountAlias: Self.alias, identifierString: "\(Self.ws)/\(Self.item)")

        // A real path row nested under the SAME item, upserted at T3 > T2.
        clock.now = 300
        try await store.upsert(MetadataRecord(
            accountAlias: Self.alias, workspaceID: Self.ws, itemID: Self.item,
            path: "sub/file", parentPath: "sub", name: "file", isDir: false
        ))

        // Its own identifier is a distinct, longer string — not the item-root one.
        let pathIdent = CacheStore.tombstoneIdentifierString(
            workspaceID: Self.ws, itemID: Self.item, path: "sub/file"
        )
        #expect(pathIdent == "\(Self.ws)/\(Self.item)/sub/file")

        // clearTombstone deletes by exact identifier_string match, not by prefix,
        // so a descendant path never clears the item-root tombstone.
        let ids = try await tombstones(store).map(\.id)
        #expect(ids == ["\(Self.ws)/\(Self.item)"])

        let changes = try await store.itemsChangedAfter(accountAlias: Self.alias, ns: 0)
        #expect(changes.deletedIdentifierStrings.contains("\(Self.ws)/\(Self.item)"))
        #expect(changes.updated.contains { $0.path == "sub/file" })
    }
}
