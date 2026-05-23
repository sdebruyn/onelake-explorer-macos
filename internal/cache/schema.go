package cache

// schemaVersion is the integer pinned in the one-row schema_version table.
// Bump it (and add a migration in migrate) when a schema change cannot be
// expressed with CREATE TABLE IF NOT EXISTS / CREATE INDEX IF NOT EXISTS.
//
// History:
//   - v1: initial path_metadata + idx_pm_children + idx_pm_blob_lru.
//   - v2: add idx_pm_last_accessed so HotItems' WHERE last_accessed_ns >= ?
//     scan can use an index. The existing idx_pm_blob_lru is partial
//     (WHERE blob_sha256 is non-empty) and therefore unusable for the
//     poller's query, which matches any row regardless of blob presence.
const schemaVersion = 2

// schemaSQL creates every persistent object the cache relies on. It is
// designed to be safe to execute on every Open: each statement uses
// IF NOT EXISTS so reopening an already-migrated database is a no-op.
const schemaSQL = `
CREATE TABLE IF NOT EXISTS path_metadata (
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
);

CREATE INDEX IF NOT EXISTS idx_pm_children
    ON path_metadata (account_alias, workspace_id, item_id, parent_path);

CREATE INDEX IF NOT EXISTS idx_pm_blob_lru
    ON path_metadata (last_accessed_ns)
    WHERE blob_sha256 != '';

-- Non-partial counterpart to idx_pm_blob_lru. The adaptive poller's
-- HotItems query filters on last_accessed_ns regardless of blob_sha256;
-- the partial index above cannot serve it, which forced a full table
-- scan before this index existed.
CREATE INDEX IF NOT EXISTS idx_pm_last_accessed
    ON path_metadata (last_accessed_ns);

CREATE TABLE IF NOT EXISTS schema_version (
    version INTEGER PRIMARY KEY
);
`
