package cache

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"log/slog"
	"os"
	"path/filepath"
)

// EvictToLimit deletes the least-recently-used blob-bearing rows until
// the sum of blob_size across the table is <= Options.MaxBlobBytes.
// Metadata rows survive — only blob_sha256 / blob_size are cleared and
// the blob files are unlinked on disk — so the entry simply stops being
// locally cached.
//
// When [Options.MaxBlobBytes] is zero the call is a no-op and returns
// (0, 0, nil).
//
// EvictToLimit walks one row at a time inside short transactions so it
// never holds a writer lock long enough to block Finder enumerations.
func (c *Cache) EvictToLimit(ctx context.Context) (evicted int, reclaimed int64, err error) {
	limit := c.opts.MaxBlobBytes
	if limit <= 0 {
		return 0, 0, nil
	}

	total, err := c.BlobBytes(ctx)
	if err != nil {
		return 0, 0, fmt.Errorf("cache.EvictToLimit: total: %w", err)
	}
	if total <= limit {
		return 0, 0, nil
	}

	for total > limit {
		if err := ctx.Err(); err != nil {
			return evicted, reclaimed, err
		}
		victim, victimSize, victimSHA, freed, ok, err := c.evictOldest(ctx)
		if err != nil {
			return evicted, reclaimed, err
		}
		if !ok {
			// No more blob-bearing rows; we are as evicted as we can get.
			break
		}
		evicted++
		// Only count bytes against the budget when this eviction actually
		// freed the physical file. Evicting one of several rows that share
		// a blob unlinks no disk (another row still references it), so
		// decrementing total per row would under-count the budget and stop
		// evicting too early. The running total mirrors BlobBytes, which
		// counts distinct shas, so it must only drop when a sha hits zero
		// references and its file is removed.
		if freed {
			reclaimed += victimSize
			total -= victimSize
		}

		c.logger.Debug("evicted blob",
			slog.String("event", "blob.evict"),
			slog.String("account_alias", victim.AccountAlias),
			slog.String("path", victim.Path),
			slog.String("sha256", victimSHA),
			slog.Int64("bytes", victimSize),
			slog.Bool("freed", freed),
			slog.Int64("remaining_bytes", total),
		)
	}
	return evicted, reclaimed, nil
}

// evictOldest selects the row with the oldest last_accessed_ns among
// rows that have a blob attached, clears its blob link, and deletes the
// blob file when no other row references it. ok is false when no
// blob-bearing row remains. freed reports whether the physical blob file
// was actually unlinked (i.e. this was the last row referencing that sha)
// — the caller uses it to decrement the byte budget only when real disk
// was reclaimed.
//
// A single short transaction owns the select + update so two concurrent
// evictors don't race on the same victim.
func (c *Cache) evictOldest(ctx context.Context) (k Key, size int64, sha string, freed, ok bool, err error) {
	tx, err := c.db.BeginTx(ctx, nil)
	if err != nil {
		return Key{}, 0, "", false, false, fmt.Errorf("evictOldest: begin: %w", err)
	}
	defer func() { _ = tx.Rollback() }()

	row := tx.QueryRowContext(ctx, `
SELECT account_alias, workspace_id, item_id, path, blob_sha256, blob_size
FROM path_metadata
WHERE blob_sha256 != ''
ORDER BY last_accessed_ns ASC, rowid ASC
LIMIT 1
`)
	if err := row.Scan(&k.AccountAlias, &k.WorkspaceID, &k.ItemID, &k.Path, &sha, &size); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return Key{}, 0, "", false, false, nil
		}
		return Key{}, 0, "", false, false, fmt.Errorf("evictOldest: scan: %w", err)
	}

	if _, err := tx.ExecContext(ctx, `
UPDATE path_metadata
SET blob_sha256 = '', blob_size = 0
WHERE account_alias = ? AND workspace_id = ? AND item_id = ? AND path = ?
`,
		k.AccountAlias, k.WorkspaceID, k.ItemID, k.Path,
	); err != nil {
		return Key{}, 0, "", false, false, fmt.Errorf("evictOldest: clear link: %w", err)
	}

	// Count any other surviving references inside the transaction so we
	// observe a consistent view across the unlink and the count.
	var refs int64
	if err := tx.QueryRowContext(ctx, `
SELECT COUNT(*) FROM path_metadata WHERE blob_sha256 = ?
`, sha).Scan(&refs); err != nil {
		return Key{}, 0, "", false, false, fmt.Errorf("evictOldest: count refs: %w", err)
	}

	if err := tx.Commit(); err != nil {
		return Key{}, 0, "", false, false, fmt.Errorf("evictOldest: commit: %w", err)
	}

	if refs == 0 {
		freed = true
		_, path := blobShardPath(c.blobRoot, sha)
		if rmErr := os.Remove(path); rmErr != nil && !errors.Is(rmErr, os.ErrNotExist) {
			c.logger.Warn("evict unlink failed",
				slog.String("event", "blob.evict.unlink_failed"),
				slog.String("sha256", sha),
				slog.Any("err", rmErr),
			)
		} else {
			// Try cleaning up the shard directory; ignore failures.
			_ = os.Remove(filepath.Dir(path))
		}
	}
	return k, size, sha, freed, true, nil
}
