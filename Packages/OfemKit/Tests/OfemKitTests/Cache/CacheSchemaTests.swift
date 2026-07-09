import Foundation
import GRDB
@testable import OfemKit
import Testing

// MARK: - CacheSchemaTests

/// Tests for fresh-database schema creation and the migration sequence.
@Suite("CacheSchema")
struct CacheSchemaTests {
    // MARK: - Fresh database migration

    @Test("Fresh database applies all migrations")
    func freshDatabaseAppliesAllMigrations() async throws {
        let store = try makeTempStore()
        defer { try? FileManager.default.removeItem(at: store.root) }
        let applied = try await store.appliedMigrations()
        #expect(applied == ["v1", "v2", "v3", "v4", "v5", "v6", "v7", "v8", "v9"])
    }

    @Test("Fresh database creates sync_meta table")
    func freshDatabaseCreatesSyncMeta() async throws {
        let store = try makeTempStore()
        defer { try? FileManager.default.removeItem(at: store.root) }
        #expect(try await store.tableExists("sync_meta"))
        let columns = try await store.readColumns(in: "sync_meta")
        #expect(columns.contains("account_alias"))
        #expect(columns.contains("tombstones_purged_through_ns"))
    }

    @Test("Fresh database creates path_metadata table")
    func freshDatabaseCreatesPathMetadata() async throws {
        let store = try makeTempStore()
        defer { try? FileManager.default.removeItem(at: store.root) }
        let columns = try await store.readColumns(in: "path_metadata")
        let expected = [
            "account_alias", "workspace_id", "item_id", "path",
            "parent_path", "name", "is_dir",
            "content_length", "etag", "last_modified_ns", "content_type",
            "blob_sha256", "blob_size",
            "last_accessed_ns", "synced_at_ns", "children_synced_at_ns",
            "item_type", "created_ns", "subtree_etag",
        ]
        for col in expected {
            #expect(columns.contains(col), "Missing column: \(col)")
        }
    }

    @Test("Fresh database creates workspace_status table")
    func freshDatabaseCreatesWorkspaceStatus() async throws {
        let store = try makeTempStore()
        defer { try? FileManager.default.removeItem(at: store.root) }
        let exists = try await store.tableExists("workspace_status")
        #expect(exists)
    }

    @Test("Fresh database creates all indexes")
    func freshDatabaseCreatesIndexes() async throws {
        let store = try makeTempStore()
        defer { try? FileManager.default.removeItem(at: store.root) }
        let indexes = try await store.indexes(on: "path_metadata")
        #expect(indexes.contains("idx_pm_children"))
        #expect(indexes.contains("idx_pm_blob_lru"))
        #expect(indexes.contains("idx_pm_last_accessed"))
        // v2: subtree-delete supporting index.
        #expect(indexes.contains("idx_pm_path"))
        // v9: GROUP BY blob_sha256 supporting index.
        #expect(indexes.contains("idx_pm_blob_dedup"))
    }

    @Test("schema_version table is not created")
    func noSchemaVersionTable() async throws {
        let store = try makeTempStore()
        defer { try? FileManager.default.removeItem(at: store.root) }
        let exists = try await store.tableExists("schema_version")
        #expect(!exists)
    }

    // MARK: - v3 migration: item_type column

    @Test("Fresh database applies v3 migration")
    func freshDatabaseAppliesV3Migration() async throws {
        let store = try makeTempStore()
        defer { try? FileManager.default.removeItem(at: store.root) }
        let applied = try await store.appliedMigrations()
        #expect(applied.contains("v3"))
    }

    @Test("Fresh database has item_type column in path_metadata")
    func freshDatabaseHasItemTypeColumn() async throws {
        let store = try makeTempStore()
        defer { try? FileManager.default.removeItem(at: store.root) }
        let columns = try await store.readColumns(in: "path_metadata")
        #expect(columns.contains("item_type"), "Missing column: item_type")
    }

    @Test("Pre-existing rows default item_type to empty string after v3 migration")
    func preExistingRowsDefaultItemTypeToEmpty() async throws {
        let store = try makeTempStore()
        defer { try? FileManager.default.removeItem(at: store.root) }
        // Insert a row without specifying item_type to simulate a row from before v3.
        let record = MetadataRecord(
            accountAlias: "a",
            workspaceID: "ws-1",
            itemID: "item-1",
            path: "Files/data.csv",
            parentPath: "Files",
            name: "data.csv",
            isDir: false
        )
        try await store.upsert(record)
        // Read it back and confirm the default.
        let key = CacheKey(accountAlias: "a", workspaceID: "ws-1", itemID: "item-1", path: "Files/data.csv")
        let fetched = try await store.fetch(key: key)
        #expect(fetched.itemType == "", "Pre-existing rows must default item_type to ''")
    }

    // MARK: - v6 migration: subtree_etag column (#380)

    @Test("Fresh database applies v6 migration")
    func freshDatabaseAppliesV6Migration() async throws {
        let store = try makeTempStore()
        defer { try? FileManager.default.removeItem(at: store.root) }
        let applied = try await store.appliedMigrations()
        #expect(applied.contains("v6"))
    }

    @Test("Fresh database has subtree_etag column in path_metadata")
    func freshDatabaseHasSubtreeEtagColumn() async throws {
        let store = try makeTempStore()
        defer { try? FileManager.default.removeItem(at: store.root) }
        let columns = try await store.readColumns(in: "path_metadata")
        #expect(columns.contains("subtree_etag"), "Missing column: subtree_etag")
    }

    @Test("Pre-existing rows default subtree_etag to empty string after v6 migration")
    func preExistingRowsDefaultSubtreeEtagToEmpty() async throws {
        let store = try makeTempStore()
        defer { try? FileManager.default.removeItem(at: store.root) }
        // Insert a row without specifying subtree_etag to simulate a row from before v6.
        let record = MetadataRecord(
            accountAlias: "a",
            workspaceID: "ws-1",
            itemID: "item-1",
            path: "Files/sub",
            parentPath: "Files",
            name: "sub",
            isDir: true
        )
        try await store.upsert(record)
        let key = CacheKey(accountAlias: "a", workspaceID: "ws-1", itemID: "item-1", path: "Files/sub")
        let fetched = try await store.fetch(key: key)
        #expect(fetched.subtreeEtag == "", "Pre-existing rows must default subtree_etag to ''")
    }

    // MARK: - v9 migration: idx_pm_blob_dedup index (#449)

    @Test("Fresh database applies v9 migration")
    func freshDatabaseAppliesV9Migration() async throws {
        let store = try makeTempStore()
        defer { try? FileManager.default.removeItem(at: store.root) }
        let applied = try await store.appliedMigrations()
        #expect(applied.contains("v9"))
    }

    @Test("deduplicatedBlobBytesSQL's GROUP BY is index-backed by idx_pm_blob_dedup")
    func deduplicatedBlobBytesUsesIndex() async throws {
        let store = try makeTempStore()
        defer { try? FileManager.default.removeItem(at: store.root) }
        let plan = try await store.explainQueryPlan(CacheReader.deduplicatedBlobBytesSQL)
        #expect(
            plan.contains("idx_pm_blob_dedup"),
            "Expected GROUP BY blob_sha256 to be served by idx_pm_blob_dedup, got plan: \(plan)"
        )
        // A B-tree-backed GROUP BY should never need SQLite's own temp
        // b-tree sort — that's precisely the full-scan cost this index exists
        // to eliminate.
        #expect(!plan.contains("USE TEMP B-TREE"), "GROUP BY should not need a temp b-tree, got plan: \(plan)")
    }

    // MARK: - Full migration chain: old on-disk fixture (#457)

    /// Migrates an on-disk DB frozen at the OLDEST schema version (`v1`)
    /// through the ENTIRE migration chain to the current version, asserting a
    /// clean migration and that data written under the old schema survives.
    ///
    /// This is the copyable pattern for the next DATA-REWRITING migration
    /// (like `v7`'s tombstone purge): stop the migrator at a version
    /// boundary, seed rows using only the columns that existed at that
    /// version, run the migrator the rest of the way, then assert on the
    /// post-migration shape and values. `DeletionTombstoneTests
    /// .v7PurgesLegacyStaleTombstones` already does this for a single step
    /// (`v6` → `v7`); this test exercises the FULL chain from the true
    /// baseline schema (`v1` → current), so a fixture frozen at the oldest
    /// version this cache format has ever shipped is also covered — not only
    /// the step immediately before/after one migration.
    @Test("An old (v1) on-disk DB migrates cleanly through the full chain, data intact")
    func oldSchemaFixtureMigratesThroughFullChain() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let dbURL = tmp.appendingPathComponent(CacheStore.sqliteFile)
        let pool = try DatabasePool(path: dbURL.path)

        let migrator = CacheSchema.migrator()
        // Freeze the on-disk schema at v1 — the oldest version this cache
        // format has ever shipped — before inserting any data, mirroring a
        // real pre-upgrade on-disk database.
        try migrator.migrate(pool, upTo: "v1")

        // Seed rows using ONLY the columns that existed at v1 (no item_type,
        // created_ns, or subtree_etag — all added by later migrations), plus
        // a deletion tombstone shadowed by a fresher live row, which v7's
        // data-rewriting purge must clean up as part of the chain.
        try await pool.write { db in
            try db.execute(sql: """
            INSERT INTO path_metadata
                (account_alias, workspace_id, item_id, path, parent_path, name, is_dir,
                 content_length, etag, last_accessed_ns, synced_at_ns)
            VALUES (?, ?, ?, ?, ?, ?, 0, ?, ?, ?, ?)
            """, arguments: ["acct", "ws-1", "item-1", "Files/data.csv", "Files", "data.csv", 42, "\"v1\"", 0, 500])
            try db.execute(sql: """
            INSERT INTO deletion_tombstones (account_alias, identifier_string, deleted_at_ns)
            VALUES (?, ?, ?)
            """, arguments: ["acct", "ws-1/item-1/stale.txt", 100])
            try db.execute(sql: """
            INSERT INTO path_metadata
                (account_alias, workspace_id, item_id, path, parent_path, name, is_dir, last_accessed_ns, synced_at_ns)
            VALUES (?, ?, ?, ?, ?, ?, 0, 0, 200)
            """, arguments: ["acct", "ws-1", "item-1", "stale.txt", "Files", "stale.txt"])
        }

        // Migrate the rest of the way — v2 through the current version — in
        // one shot, exactly as a real app upgrade would do on first launch
        // against an old on-disk database.
        try migrator.migrate(pool)

        // (1) Every migration in the chain applied cleanly, in order.
        let applied = try await pool.read { db in
            try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations ORDER BY rowid")
        }
        #expect(applied == ["v1", "v2", "v3", "v4", "v5", "v6", "v7", "v8", "v9"])

        // (2) The pre-existing row survives with its original values intact,
        // and the columns added by later migrations (v3/v5/v6) read back
        // with their documented defaults instead of NULL or a migration
        // failure.
        let row = try await pool.read { db in
            try Row.fetchOne(db, sql: """
            SELECT etag, content_length, item_type, created_ns, subtree_etag
            FROM path_metadata WHERE path = 'Files/data.csv'
            """)
        }
        let dataRow = try #require(row, "the pre-existing row must survive the full migration chain")
        #expect(dataRow["etag"] as String == "\"v1\"")
        #expect(dataRow["content_length"] as Int64 == 42)
        #expect(dataRow["item_type"] as String == "", "v3's new column must default to '' for a pre-v3 row")
        #expect(dataRow["created_ns"] as Int64 == 0, "v5's new column must default to 0 for a pre-v5 row")
        #expect(dataRow["subtree_etag"] as String == "", "v6's new column must default to '' for a pre-v6 row")

        // (3) v7's data-rewriting step still fires correctly when applied as
        // part of the full v1→current chain (not just the isolated v6→v7
        // step covered by DeletionTombstoneTests): the tombstone shadowed by
        // the fresher "stale.txt" live row (synced at 200, after the
        // tombstone's 100) is purged.
        let tombstoneIDs = try await pool.read { db in
            try String.fetchAll(db, sql: "SELECT identifier_string FROM deletion_tombstones")
        }
        #expect(tombstoneIDs.isEmpty,
                "v7's legacy-tombstone purge must still fire when applied as part of the full v1→current chain")
    }
}

// MARK: - CacheStore test-inspection helpers (actor-isolated, call with await)

extension CacheStore {
    /// Returns the list of migration identifiers that GRDB has already applied.
    func appliedMigrations() async throws -> [String] {
        try await dbPool.read { db in
            try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations ORDER BY rowid")
        }
    }

    /// Returns column names for `table` for test assertions.
    func readColumns(in table: String) async throws -> [String] {
        try await dbPool.read { db in
            try db.columns(in: table).map(\.name)
        }
    }

    /// Returns whether `table` exists for test assertions.
    func tableExists(_ table: String) async throws -> Bool {
        try await dbPool.read { try $0.tableExists(table) }
    }

    /// Returns index names for `table` for test assertions.
    func indexes(on table: String) async throws -> [String] {
        try await dbPool.read { try $0.indexes(on: table).map(\.name) }
    }

    /// Returns the `EXPLAIN QUERY PLAN` output for `sql`, one line per plan
    /// row, joined for easy substring assertions in tests.
    func explainQueryPlan(_ sql: String) async throws -> String {
        try await dbPool.read { db in
            let rows = try Row.fetchAll(db, sql: "EXPLAIN QUERY PLAN " + sql)
            return rows.map { (row: Row) -> String in row["detail"] as String }
                .joined(separator: "\n")
        }
    }
}
