import Foundation
import GRDB
import Testing

@testable import OfemKit

// MARK: - CacheSchemaTests

/// Tests for schema creation, migrations, and backwards-compatibility with
/// Go-daemon-written databases.
///
/// Critical compatibility guarantee: a database created by the Go daemon
/// (any v1–v4 schema) must be openable by the Swift implementation without
/// data loss or corruption.
@Suite("CacheSchema")
struct CacheSchemaTests {

    // MARK: - Fresh database migration

    @Test("Fresh database migrates to v4")
    func freshDatabaseMigratestoV4() async throws {
        let store = try makeInMemoryStore()
        let version = try await store.dbVersion()
        #expect(version == 4)
    }

    @Test("Fresh database creates path_metadata table")
    func freshDatabaseCreatesPathMetadata() async throws {
        let store = try makeInMemoryStore()
        let columns = try await store.readColumns(in: "path_metadata")
        let expected = [
            "account_alias", "workspace_id", "item_id", "path",
            "parent_path", "name", "is_dir",
            "content_length", "etag", "last_modified_ns", "content_type",
            "blob_sha256", "blob_size",
            "last_accessed_ns", "synced_at_ns", "children_synced_at_ns",
        ]
        for col in expected {
            #expect(columns.contains(col), "Missing column: \(col)")
        }
    }

    @Test("Fresh database creates workspace_status table")
    func freshDatabaseCreatesWorkspaceStatus() async throws {
        let store = try makeInMemoryStore()
        let exists = try await store.tableExists("workspace_status")
        #expect(exists)
    }

    @Test("Fresh database creates all indexes")
    func freshDatabaseCreatesIndexes() async throws {
        let store = try makeInMemoryStore()
        let indexes = try await store.indexes(on: "path_metadata")
        #expect(indexes.contains("idx_pm_children"))
        #expect(indexes.contains("idx_pm_blob_lru"))
        #expect(indexes.contains("idx_pm_last_accessed"))
    }

    // MARK: - Go-database bootstrap

    @Test("Go v1 database is migrated to v4")
    func goDatabaseV1MigratestoV4() throws {
        let dbQueue = try DatabaseQueue()
        try dbQueue.write { db in
            try db.execute(sql: """
                CREATE TABLE path_metadata (
                    account_alias    TEXT    NOT NULL,
                    workspace_id     TEXT    NOT NULL,
                    item_id          TEXT    NOT NULL,
                    path             TEXT    NOT NULL,
                    parent_path      TEXT    NOT NULL,
                    name             TEXT    NOT NULL,
                    is_dir           INTEGER NOT NULL,
                    content_length   INTEGER NOT NULL DEFAULT 0,
                    etag             TEXT    NOT NULL DEFAULT '',
                    last_modified_ns INTEGER NOT NULL DEFAULT 0,
                    content_type     TEXT    NOT NULL DEFAULT '',
                    blob_sha256      TEXT    NOT NULL DEFAULT '',
                    blob_size        INTEGER NOT NULL DEFAULT 0,
                    last_accessed_ns INTEGER NOT NULL,
                    synced_at_ns     INTEGER NOT NULL,
                    PRIMARY KEY (account_alias, workspace_id, item_id, path)
                )
                """)
            try db.execute(sql: "CREATE INDEX idx_pm_children ON path_metadata (account_alias, workspace_id, item_id, parent_path)")
            try db.execute(sql: "CREATE INDEX idx_pm_blob_lru ON path_metadata (last_accessed_ns) WHERE blob_sha256 != ''")
            try db.execute(sql: "CREATE TABLE schema_version (version INTEGER PRIMARY KEY)")
            try db.execute(sql: "INSERT INTO schema_version (version) VALUES (1)")

            // Seed a row.
            try db.execute(sql: """
                INSERT INTO path_metadata
                    (account_alias, workspace_id, item_id, path,
                     parent_path, name, is_dir,
                     last_accessed_ns, synced_at_ns)
                VALUES ('work', 'ws1', 'item1', 'Files/test.txt',
                        'Files', 'test.txt', 0, 1000000, 2000000)
                """)
        }

        try dbQueue.write { db in try CacheSchema.applyIfGoDatabase(db) }
        try CacheSchema.migrator().migrate(dbQueue)

        try dbQueue.read { db in
            let version = try Int.fetchOne(db, sql: "SELECT MAX(version) FROM schema_version")
            #expect(version == 4)

            let columns = try db.columns(in: "path_metadata").map(\.name)
            #expect(columns.contains("children_synced_at_ns"))
            #expect(try db.tableExists("workspace_status"))

            let name = try String.fetchOne(db, sql: "SELECT name FROM path_metadata WHERE path = 'Files/test.txt'")
            #expect(name == "test.txt")

            let csa = try Int64.fetchOne(db, sql: "SELECT children_synced_at_ns FROM path_metadata WHERE path = 'Files/test.txt'")
            #expect(csa == 0)
        }
    }

    @Test("Go v3 database skips already-applied migrations")
    func goDatabaseV3SkipsAppliedMigrations() throws {
        let dbQueue = try DatabaseQueue()
        try dbQueue.write { db in
            try db.execute(sql: """
                CREATE TABLE path_metadata (
                    account_alias    TEXT    NOT NULL,
                    workspace_id     TEXT    NOT NULL,
                    item_id          TEXT    NOT NULL,
                    path             TEXT    NOT NULL,
                    parent_path      TEXT    NOT NULL,
                    name             TEXT    NOT NULL,
                    is_dir           INTEGER NOT NULL,
                    content_length   INTEGER NOT NULL DEFAULT 0,
                    etag             TEXT    NOT NULL DEFAULT '',
                    last_modified_ns INTEGER NOT NULL DEFAULT 0,
                    content_type     TEXT    NOT NULL DEFAULT '',
                    blob_sha256      TEXT    NOT NULL DEFAULT '',
                    blob_size        INTEGER NOT NULL DEFAULT 0,
                    last_accessed_ns INTEGER NOT NULL,
                    synced_at_ns     INTEGER NOT NULL,
                    PRIMARY KEY (account_alias, workspace_id, item_id, path)
                )
                """)
            try db.execute(sql: "CREATE INDEX idx_pm_children ON path_metadata (account_alias, workspace_id, item_id, parent_path)")
            try db.execute(sql: "CREATE INDEX idx_pm_blob_lru ON path_metadata (last_accessed_ns) WHERE blob_sha256 != ''")
            try db.execute(sql: "CREATE INDEX idx_pm_last_accessed ON path_metadata (last_accessed_ns)")
            try db.execute(sql: """
                CREATE TABLE workspace_status (
                    account_alias  TEXT NOT NULL, workspace_id TEXT NOT NULL,
                    state TEXT NOT NULL DEFAULT 'active', reason TEXT NOT NULL DEFAULT '',
                    detected_at_ns INTEGER NOT NULL DEFAULT 0, probed_at_ns INTEGER NOT NULL DEFAULT 0,
                    PRIMARY KEY (account_alias, workspace_id)
                )
                """)
            try db.execute(sql: "CREATE TABLE schema_version (version INTEGER PRIMARY KEY)")
            try db.execute(sql: "INSERT INTO schema_version (version) VALUES (3)")
        }

        try dbQueue.write { db in try CacheSchema.applyIfGoDatabase(db) }
        try CacheSchema.migrator().migrate(dbQueue)

        try dbQueue.read { db in
            let version = try Int.fetchOne(db, sql: "SELECT MAX(version) FROM schema_version")
            #expect(version == 4)
            let columns = try db.columns(in: "path_metadata").map(\.name)
            #expect(columns.contains("children_synced_at_ns"))
        }
    }

    @Test("Schema-too-new error is thrown for version > 4")
    func schemaTooNewThrowsError() throws {
        let dbQueue = try DatabaseQueue()
        try dbQueue.write { db in
            try db.execute(sql: "CREATE TABLE schema_version (version INTEGER PRIMARY KEY)")
            try db.execute(sql: "INSERT INTO schema_version (version) VALUES (99)")
        }
        #expect(throws: CacheError.self) {
            try dbQueue.write { db in try CacheSchema.applyIfGoDatabase(db) }
        }
    }

    @Test("Bootstrap is a no-op on already-Swift-migrated database")
    func bootstrapIsNoOpOnSwiftDatabase() throws {
        let dbQueue = try DatabaseQueue()
        try dbQueue.write { db in
            try db.execute(sql: "CREATE TABLE grdb_migrations (identifier TEXT NOT NULL PRIMARY KEY)")
            try db.execute(sql: "CREATE TABLE schema_version (version INTEGER PRIMARY KEY)")
            try db.execute(sql: "INSERT INTO schema_version (version) VALUES (4)")
        }
        try dbQueue.write { db in try CacheSchema.applyIfGoDatabase(db) }
        try dbQueue.read { db in
            let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM grdb_migrations") ?? 0
            #expect(count == 0)
        }
    }
}

// MARK: - CacheStore test-inspection helpers (actor-isolated, call with await)

extension CacheStore {
    /// Reads the `MAX(version)` from `schema_version` for test assertions.
    func dbVersion() throws -> Int {
        try dbPool.read { db in
            try Int.fetchOne(db, sql: "SELECT MAX(version) FROM schema_version") ?? 0
        }
    }

    /// Returns column names for `table` for test assertions.
    func readColumns(in table: String) throws -> [String] {
        try dbPool.read { db in
            try db.columns(in: table).map(\.name)
        }
    }

    /// Returns whether `table` exists for test assertions.
    func tableExists(_ table: String) throws -> Bool {
        try dbPool.read { try $0.tableExists(table) }
    }

    /// Returns index names for `table` for test assertions.
    func indexes(on table: String) throws -> [String] {
        try dbPool.read { try $0.indexes(on: table).map(\.name) }
    }
}

