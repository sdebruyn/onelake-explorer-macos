import Foundation
import GRDB

// MARK: - CacheSchema

/// SQLite schema definition and migration sequence for the OFEM metadata cache.
///
/// ## Schema
///
/// - `v1` — complete initial schema: `path_metadata`, `workspace_status`,
///   `deletion_tombstones`, and their associated indexes.
/// - `v2` — adds `idx_pm_path` to guarantee a B-tree range scan for the
///   `path LIKE 'prefix/%'` subtree queries in `delete(key:)` / `batchDelete`.
///
/// Key indexes:
/// - `idx_pm_synced_at`: composite on `(account_alias, synced_at_ns)` used
///   by `itemsChangedAfter` to avoid full `path_metadata` scans.
/// - `idx_pm_path`: composite on `(account_alias, workspace_id, item_id, path)`
///   to serve the `path LIKE 'prefix/%'` prefix scan in subtree deletes.
/// - `idx_dt_deleted_at`: composite on `(account_alias, deleted_at_ns)` used
///   by `itemsChangedAfter` to avoid full `deletion_tombstones` scans.
public enum CacheSchema {

    // MARK: - Migrator

    /// Returns a fully configured `DatabaseMigrator` that applies all
    /// migrations from a blank database up to the current schema.
    ///
    /// GRDB's migrator tracks which migrations have already run in the
    /// `grdb_migrations` table and skips them automatically — no hand-rolled
    /// idempotency guards are needed.
    public static func migrator() -> DatabaseMigrator {
        var m = DatabaseMigrator()

        // v1: complete initial schema — path_metadata, workspace_status, and all indexes.
        m.registerMigration("v1") { db in
            try db.execute(sql: """
                CREATE TABLE path_metadata (
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
                    children_synced_at_ns INTEGER NOT NULL DEFAULT 0,
                    PRIMARY KEY (account_alias, workspace_id, item_id, path)
                );
                """)

            try db.execute(sql: """
                CREATE INDEX idx_pm_children
                    ON path_metadata (account_alias, workspace_id, item_id, parent_path);
                """)

            // Partial index for LRU eviction: only blob-bearing rows.
            try db.execute(sql: """
                CREATE INDEX idx_pm_blob_lru
                    ON path_metadata (last_accessed_ns)
                    WHERE blob_sha256 != '';
                """)

            // Non-partial last_accessed index for the adaptive poller's HotItems
            // query (which does not filter on blob_sha256).
            try db.execute(sql: """
                CREATE INDEX idx_pm_last_accessed
                    ON path_metadata (last_accessed_ns);
                """)

            // workspace_status: persists paused-capacity / unreachable-workspace signals.
            try db.execute(sql: """
                CREATE TABLE workspace_status (
                    account_alias  TEXT    NOT NULL,
                    workspace_id   TEXT    NOT NULL,
                    state          TEXT    NOT NULL DEFAULT 'active',
                    reason         TEXT    NOT NULL DEFAULT '',
                    detected_at_ns INTEGER NOT NULL DEFAULT 0,
                    probed_at_ns   INTEGER NOT NULL DEFAULT 0,
                    PRIMARY KEY (account_alias, workspace_id)
                );
                """)

            // deletion_tombstones: soft-delete log, one row per remote-deleted item
            // per reconciliation. `refreshFolder` writes here before hard-deleting from
            // path_metadata so `enumerateChanges` can call `didDeleteItems` and Finder
            // sees removals.
            try db.execute(sql: """
                CREATE TABLE deletion_tombstones (
                    account_alias     TEXT    NOT NULL,
                    identifier_string TEXT    NOT NULL,
                    deleted_at_ns     INTEGER NOT NULL,
                    PRIMARY KEY (account_alias, identifier_string)
                );
                """)

            // Index for the tombstone query in `itemsChangedAfter`.
            try db.execute(sql: """
                CREATE INDEX idx_dt_deleted_at
                    ON deletion_tombstones (account_alias, deleted_at_ns);
                """)

            // Index for the itemsChangedAfter query.
            try db.execute(sql: """
                CREATE INDEX idx_pm_synced_at
                    ON path_metadata (account_alias, synced_at_ns);
                """)
        }

        // v2: add idx_pm_path to support the `path LIKE 'prefix/%'` prefix scan
        // used by `delete(key:)` and `batchDelete`.  The PK covers the same columns
        // on many SQLite builds, but an explicit index makes the planner dependency
        // documented and guarantees a B-tree range scan on large subtree deletes.
        m.registerMigration("v2") { db in
            try db.execute(sql: """
                CREATE INDEX IF NOT EXISTS idx_pm_path
                    ON path_metadata (account_alias, workspace_id, item_id, path);
                """)
        }

        // v3: add item_type to persist the Fabric item type (e.g. "Lakehouse",
        // "Warehouse") on every path_metadata row. Capability computation reads
        // this field to decide whether a path is writable. Pre-existing rows
        // default to '' and are treated as read-only until re-enumerated.
        m.registerMigration("v3") { db in
            try db.execute(sql: """
                ALTER TABLE path_metadata
                    ADD COLUMN item_type TEXT NOT NULL DEFAULT '';
                """)
        }

        return m
    }
}
