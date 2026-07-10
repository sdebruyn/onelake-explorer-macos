import Foundation
import GRDB

// MARK: - CacheSchema

/// SQLite schema definition and migration sequence for the OFEM metadata cache.
///
/// ## Schema
///
/// - `v1` — complete initial schema: `path_metadata`, `workspace_status`,
///   `deletion_tombstones`, and their associated indexes.
/// - `v2` — adds `idx_pm_path` to back the `path LIKE 'prefix/%'` subtree
///   queries in `delete(key:)` / `batchDelete` with a B-tree scan. That scan
///   is only actually range-bound (rather than a row-by-row filter) once
///   paired with `PRAGMA case_sensitive_like = ON`, added later by #426 —
///   see the `idx_pm_path` bullet below.
/// - `v3` — adds `item_type` column to `path_metadata`.
/// - `v4` — adds `materialized_containers` table and `idx_mc_alias` index.
/// - `v5` — adds `created_ns` column to `path_metadata` for creation timestamps.
/// - `v6` — adds `subtree_etag` column to `path_metadata`. Only container rows
///   carry it (the directory etag harvested from the parent listing); it gates
///   the materialized-refresh skip-gate (#380) and never feeds item versions.
/// - `v7` — one-time purge of legacy stale tombstones: deletes every
///   `deletion_tombstones` row that is shadowed by a live `path_metadata` row at
///   least as fresh as the tombstone. Cleans rows left behind before upsert
///   started clearing tombstones on recreate; adds no schema objects.
/// - `v8` — adds `sync_meta(account_alias PK, tombstones_purged_through_ns)` to
///   record the monotonic per-alias watermark below which expired deletion
///   tombstones have been TTL-purged (``CacheStore/purgeExpiredTombstones``).
///   The FPE's lagging-client guard expires a client whose sync anchor predates
///   this watermark, forcing a full re-enumeration so purged deletions are
///   reconciled by absence rather than silently lost.
/// - `v9` — adds `idx_pm_blob_dedup`, a partial covering index backing the
///   `GROUP BY blob_sha256` in ``CacheReader/deduplicatedBlobBytesSQL``, which
///   `evictToLimit()` runs on every ``CacheStore/storeBlob(key:data:)`` call.
///   Without it that query was a full `path_metadata` scan plus a temp B-tree
///   sort for the GROUP BY on every download.
///
/// Key indexes:
/// - `idx_pm_synced_at`: composite on `(account_alias, synced_at_ns)` used
///   by `itemsChangedAfter` to avoid full `path_metadata` scans.
/// - `idx_pm_path`: composite on `(account_alias, workspace_id, item_id, path)`
///   to serve the `path LIKE 'prefix/%'` prefix scan in subtree deletes. The
///   scan is case-sensitive (`PRAGMA case_sensitive_like = ON`, set at
///   connection open in `CacheStore` — #426) so it stays index-backed: SQLite
///   only turns `LIKE` into a B-tree range scan against a BINARY-collated
///   column, like `path`, when the pragma is on.
/// - `idx_dt_deleted_at`: composite on `(account_alias, deleted_at_ns)` used
///   by `itemsChangedAfter` to avoid full `deletion_tombstones` scans.
/// - `materialized_containers` PK `(account_alias, identifier_string)`: its
///   B-tree prefix serves the `WHERE account_alias = ?` scan; no separate index.
/// - `idx_pm_blob_dedup`: partial covering index on `(blob_sha256, blob_size)
///   WHERE blob_sha256 != ''`, added in v9. Column order matches the `GROUP BY
///   blob_sha256` in `deduplicatedBlobBytesSQL` exactly, so SQLite can walk the
///   index in blob_sha256 order instead of a temp B-tree sort; including
///   `blob_size` makes it a covering index, so the SUM never touches the main
///   `path_metadata` B-tree at all.
public enum CacheSchema {
    // MARK: - Migrator

    /// Returns a fully configured `DatabaseMigrator` that applies all
    /// migrations from a blank database up to the current schema.
    ///
    /// GRDB's migrator tracks which migrations have already run in the
    /// `grdb_migrations` table and skips them automatically — no hand-rolled
    /// idempotency guards are needed.
    ///
    /// One migration per schema version, registered linearly in order;
    /// splitting the function would only obscure that order.
    // swiftlint:disable:next function_body_length
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

            // deletion_tombstones: soft-delete log consumed by itemsChangedAfter →
            // enumerateChanges → didDeleteItems. Writers: delete(key:),
            // batchDelete(recordTombstones: true) — the refreshFolder reconcile and
            // expireDiscoveryRows — and SyncEngine.rename via recordDeletion. A
            // tombstone is cleared when its identifier is re-created (upsert /
            // batchUpsert / renamePathPrefix) and reconciled by timestamp in
            // itemsChangedAfter.
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
        // this field to decide whether a path is writable.
        m.registerMigration("v3") { db in
            try db.execute(sql: """
            ALTER TABLE path_metadata
                ADD COLUMN item_type TEXT NOT NULL DEFAULT '';
            """)
        }

        // v4: add materialized_containers to track the set of containers that
        // the user has expanded locally. Written by the FPE's
        // materializedItemsDidChange callback; read by the freshness poll loop
        // to know which containers to keep fresh. Keyed by identifier_string
        // (the opaque File Provider identifier) rather than a CacheKey because
        // materialised directories include item roots whose CacheKey uses
        // VirtualIDs sentinels, making a separate identifier-keyed table simpler.
        //
        // No explicit alias index: the composite PK (account_alias, identifier_string)
        // B-tree prefix already serves `WHERE account_alias = ?` efficiently.
        m.registerMigration("v4") { db in
            try db.execute(sql: """
            CREATE TABLE materialized_containers (
                account_alias       TEXT    NOT NULL,
                identifier_string   TEXT    NOT NULL,
                materialized_at_ns  INTEGER NOT NULL,
                PRIMARY KEY (account_alias, identifier_string)
            );
            """)
        }

        // v5: add created_ns to persist the creation timestamp for every path.
        // Zero means "not yet captured". Sourced from the x-ms-creation-time header
        // (RFC1123 HTTP-date) returned by HEAD/GET on ADLS Gen2 service version ≥ 2023-05-03.
        m.registerMigration("v5") { db in
            try db.execute(sql: """
            ALTER TABLE path_metadata
                ADD COLUMN created_ns INTEGER NOT NULL DEFAULT 0;
            """)
        }

        // v6: add subtree_etag to persist the directory etag harvested from the
        // PARENT listing for each child container (#380). Only a container's own
        // row carries it; child file rows leave it "". It is read as a refresh
        // skip-gate (subtree etag unchanged ⇒ nothing changed below ⇒ skip the
        // child list+diff) and must NEVER feed any item contentVersion/
        // metadataVersion. Empty default so a row that has never been harvested
        // from a parent listing reads as "" and forces a list.
        //
        // No migration ceremony: the project is pre-go-live and a cache rebuild
        // on upgrade is acceptable. A plain ADD COLUMN (mirroring v3/v5) is the
        // minimal mechanism — it both defines the column in the running schema
        // and gives already-migrated dev DBs the column without any
        // data-preserving / backward-compat logic.
        m.registerMigration("v6") { db in
            try db.execute(sql: """
            ALTER TABLE path_metadata
                ADD COLUMN subtree_etag TEXT NOT NULL DEFAULT '';
            """)
        }

        // v7: one-time purge of legacy stale tombstones. Before this release a
        // re-created path kept the tombstone from its earlier deletion (nothing
        // cleared it on upsert), so itemsChangedAfter could report a live row as
        // deleted. Delete every tombstone shadowed by a live path_metadata row at
        // least as fresh as the tombstone (reconstructing the row's identifier via
        // the same shape as ItemIdentifier.identifierString); fresh tombstones
        // with no live row survive. From here on upsert / batchUpsert /
        // renamePathPrefix clear tombstones inline and itemsChangedAfter reconciles
        // by timestamp, so this only cleans pre-existing rows.
        m.registerMigration("v7") { db in
            try db.execute(sql: """
            DELETE FROM deletion_tombstones WHERE EXISTS (
                SELECT 1 FROM path_metadata p
                WHERE p.account_alias = deletion_tombstones.account_alias
                  AND p.synced_at_ns >= deletion_tombstones.deleted_at_ns
                  AND deletion_tombstones.identifier_string =
                      CASE WHEN p.path = '' THEN p.workspace_id || '/' || p.item_id
                           ELSE p.workspace_id || '/' || p.item_id || '/' || p.path END
            );
            """)
        }

        // v8: add sync_meta to persist the per-alias tombstone-purge watermark.
        // `tombstones_purged_through_ns` is the monotonic horizon below which
        // expired deletion tombstones have been TTL-purged
        // (CacheStore.purgeExpiredTombstones advances it to the newest
        // deleted_at_ns actually reclaimed, never lowers it, and leaves it
        // untouched on a zero-row purge so an idle alias doesn't trip the
        // guard below with a horizon that reclaimed nothing). The FPE reads it
        // via CacheReader.tombstonesPurgedThroughNs to expire any client whose
        // sync anchor predates the horizon, forcing a full re-enumeration so
        // purged deletions are reconciled by absence.
        //
        // Plain additive migration (mirrors v3/v5/v6): the project is pre-go-live,
        // so a cache rebuild on upgrade is acceptable and no data-migration
        // ceremony is needed.
        m.registerMigration("v8") { db in
            try db.execute(sql: """
            CREATE TABLE sync_meta (
                account_alias                TEXT    PRIMARY KEY,
                tombstones_purged_through_ns INTEGER NOT NULL DEFAULT 0
            );
            """)
        }

        // v9: partial covering index backing the `GROUP BY blob_sha256` in
        // `CacheReader.deduplicatedBlobBytesSQL`. That query runs on every
        // `evictToLimit()` pass, which every `storeBlob(key:data:)` call
        // triggers — i.e. on every download — so an unindexed GROUP BY meant
        // a full `path_metadata` scan plus a temp B-tree sort on the hot path.
        // Column order is `(blob_sha256, blob_size)`: `blob_sha256` first to
        // match the GROUP BY key so SQLite walks the index pre-sorted instead
        // of building a temp B-tree, and `blob_size` included to make the
        // index covering — the SUM(blob_size) is answered entirely from the
        // index, never touching the `path_metadata` B-tree. The partial
        // `WHERE blob_sha256 != ''` mirrors `idx_pm_blob_lru` (v1): only
        // blob-bearing rows (a small minority) are indexed.
        m.registerMigration("v9") { db in
            try db.execute(sql: """
            CREATE INDEX idx_pm_blob_dedup
                ON path_metadata (blob_sha256, blob_size)
                WHERE blob_sha256 != '';
            """)
        }

        return m
    }
}
