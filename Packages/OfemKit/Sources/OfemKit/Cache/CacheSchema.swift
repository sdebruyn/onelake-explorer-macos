import Foundation
import GRDB

// MARK: - CacheSchema

/// SQLite schema definition and migration sequence for the OFEM metadata cache.
///
/// ## Version history
///
/// - **v1** — initial `path_metadata` + `idx_pm_children` + `idx_pm_blob_lru`.
/// - **v2** — added `idx_pm_last_accessed` (non-partial counterpart for the
/// adaptive poller's HotItems query which cannot use the partial blob index).
/// - **v3** — added `workspace_status` table so the sync engine can persist
/// paused-capacity / unreachable-workspace signals.
/// - **v4** — added `path_metadata.children_synced_at_ns` so the enumerator
/// can distinguish a genuinely empty directory from one never listed.
public enum CacheSchema {

    /// The current schema version this binary supports.
    public static let currentVersion = 4

    /// Name of the `schema_version` table's single row.
    static let schemaVersionTable = "schema_version"

    // MARK: - Migrator

    /// Returns a fully configured `DatabaseMigrator` that applies all
    /// migrations from a blank database up to ``currentVersion``.
    ///
    /// Each migration is idempotent when run on an already-migrated database
    /// because GRDB's migrator tracks applied migrations in the
    /// `grdb_migrations` table and skips already-applied steps.
    public static func migrator() -> DatabaseMigrator {
        var m = DatabaseMigrator()

        // v1: base schema — path_metadata + two indexes.
        m.registerMigration("v1") { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS path_metadata (
                    account_alias         TEXT    NOT NULL,
                    workspace_id          TEXT    NOT NULL,
                    item_id               TEXT    NOT NULL,
                    path                  TEXT    NOT NULL,
                    parent_path           TEXT    NOT NULL,
                    name                  TEXT    NOT NULL,
                    is_dir                INTEGER NOT NULL,
                    content_length        INTEGER NOT NULL DEFAULT 0,
                    etag                  TEXT    NOT NULL DEFAULT '',
                    last_modified_ns      INTEGER NOT NULL DEFAULT 0,
                    content_type          TEXT    NOT NULL DEFAULT '',
                    blob_sha256           TEXT    NOT NULL DEFAULT '',
                    blob_size             INTEGER NOT NULL DEFAULT 0,
                    last_accessed_ns      INTEGER NOT NULL,
                    synced_at_ns          INTEGER NOT NULL,
                    PRIMARY KEY (account_alias, workspace_id, item_id, path)
                );
                """)

            try db.execute(sql: """
                CREATE INDEX IF NOT EXISTS idx_pm_children
                    ON path_metadata (account_alias, workspace_id, item_id, parent_path);
                """)

            // Partial index for LRU eviction: only blob-bearing rows.
            try db.execute(sql: """
                CREATE INDEX IF NOT EXISTS idx_pm_blob_lru
                    ON path_metadata (last_accessed_ns)
                    WHERE blob_sha256 != '';
                """)

            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS schema_version (
                    version INTEGER PRIMARY KEY
                );
                """)

            try db.execute(sql: "INSERT OR IGNORE INTO schema_version (version) VALUES (1)")
        }

        // v2: non-partial last_accessed index for the adaptive poller's
        // HotItems query (which does not filter on blob_sha256).
        m.registerMigration("v2") { db in
            try db.execute(sql: """
                CREATE INDEX IF NOT EXISTS idx_pm_last_accessed
                    ON path_metadata (last_accessed_ns);
                """)

            try db.execute(sql: "INSERT OR REPLACE INTO schema_version (version) VALUES (2)")
        }

        // v3: workspace_status table.
        m.registerMigration("v3") { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS workspace_status (
                    account_alias  TEXT    NOT NULL,
                    workspace_id   TEXT    NOT NULL,
                    state          TEXT    NOT NULL DEFAULT 'active',
                    reason         TEXT    NOT NULL DEFAULT '',
                    detected_at_ns INTEGER NOT NULL DEFAULT 0,
                    probed_at_ns   INTEGER NOT NULL DEFAULT 0,
                    PRIMARY KEY (account_alias, workspace_id)
                );
                """)

            try db.execute(sql: "INSERT OR REPLACE INTO schema_version (version) VALUES (3)")
        }

        // v4: children_synced_at_ns column on path_metadata. ALTER TABLE
        // ADD COLUMN via addColumnIfMissing keeps the migration
        // idempotent against pre-v4 databases.
        m.registerMigration("v4") { db in
            try addColumnIfMissing(
                db,
                table: "path_metadata",
                column: "children_synced_at_ns",
                definition: "INTEGER NOT NULL DEFAULT 0"
            )
            try db.execute(sql: "INSERT OR REPLACE INTO schema_version (version) VALUES (4)")
        }

        return m
    }

    // MARK: - Helpers

    /// Adds `column` to `table` when the column is not already present.
    ///
    /// Idempotent: a no-op when the column exists.
    static func addColumnIfMissing(
        _ db: Database,
        table: String,
        column: String,
        definition: String
    ) throws {
        let columns = try db.columns(in: table)
        if columns.contains(where: { $0.name == column }) { return }
        // Column and definition are compile-time constants; not user input.
        try db.execute(sql: "ALTER TABLE \(table) ADD COLUMN \(column) \(definition)")
    }
}
