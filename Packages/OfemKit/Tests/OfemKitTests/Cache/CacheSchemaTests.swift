import Foundation
import GRDB
import Testing

@testable import OfemKit

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
        #expect(applied == ["v1", "v2"])
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
    }

    @Test("schema_version table is not created")
    func noSchemaVersionTable() async throws {
        let store = try makeTempStore()
        defer { try? FileManager.default.removeItem(at: store.root) }
        let exists = try await store.tableExists("schema_version")
        #expect(!exists)
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
}
