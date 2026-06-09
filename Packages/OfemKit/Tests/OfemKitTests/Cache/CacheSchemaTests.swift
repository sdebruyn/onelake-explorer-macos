import Foundation
import GRDB
import Testing

@testable import OfemKit

// MARK: - CacheSchemaTests

/// Tests for fresh-database schema creation and the migration sequence.
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

