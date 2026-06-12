import Foundation
import GRDB

// MARK: - CacheSchema

/// SQLite schema definition and migration sequence for the OFEM metadata cache.
///
/// ## Version history
///
/// - **v1** — initial schema: `path_metadata` + `workspace_status` + all indexes.
///   (Pre-stable product — schema started clean; no upgrade history to maintain.)
/// - **v2** — deletion tombstones + synced_at index (C1/C6):
///   - `deletion_tombstones`: soft-delete log keyed by `(account_alias, identifier_string)`.
///     `refreshFolder` writes a row here before hard-deleting from `path_metadata`
///     so `enumerateChanges` can call `didDeleteItems` and Finder reflects removals.
///   - `idx_pm_synced_at`: composite index on `(account_alias, synced_at_ns)` used
///     by `itemsChangedAfter` to avoid full `path_metadata` scans.
///   - `idx_dt_deleted_at`: composite index on `(account_alias, deleted_at_ns)` used
///     by `deletionsSince` to avoid full `deletion_tombstones` scans.
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
        }

        // v2: deletion tombstones (C1) + query-performance indexes (C6).
        m.registerMigration("v2") { db in
            // Soft-delete log: one row per remote-deleted item per reconciliation.
            // `refreshFolder` writes here before hard-deleting from path_metadata so
            // `enumerateChanges` can call `didDeleteItems` and Finder sees removals.
            try db.execute(sql: """
                CREATE TABLE deletion_tombstones (
                    account_alias     TEXT    NOT NULL,
                    identifier_string TEXT    NOT NULL,
                    deleted_at_ns     INTEGER NOT NULL,
                    PRIMARY KEY (account_alias, identifier_string)
                );
                """)

            // C6: index for the tombstone query in `deletionsSince`.
            try db.execute(sql: """
                CREATE INDEX idx_dt_deleted_at
                    ON deletion_tombstones (account_alias, deleted_at_ns);
                """)

            // C6: index for the itemsChangedAfter query.
            try db.execute(sql: """
                CREATE INDEX idx_pm_synced_at
                    ON path_metadata (account_alias, synced_at_ns);
                """)
        }

        return m
    }
}
