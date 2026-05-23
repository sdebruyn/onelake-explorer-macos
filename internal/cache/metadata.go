package cache

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"log/slog"
	"os"
	"time"
)

// Put inserts or updates the metadata row for e. The write happens in a
// single transaction. If the caller leaves [Entry.LastAccessed] or
// [Entry.SyncedAt] zero, the current wall-clock time is substituted so
// the row has the timestamps eviction and reconciliation rely on.
func (c *Cache) Put(ctx context.Context, e Entry) error {
	if err := validateKey(e.Key); err != nil {
		return fmt.Errorf("cache.Put: %w", err)
	}
	now := time.Now().UTC()
	if e.LastAccessed.IsZero() {
		e.LastAccessed = now
	}
	if e.SyncedAt.IsZero() {
		e.SyncedAt = now
	}

	tx, err := c.db.BeginTx(ctx, nil)
	if err != nil {
		return fmt.Errorf("cache.Put: begin: %w", err)
	}
	defer func() { _ = tx.Rollback() }()

	const stmt = `
INSERT INTO path_metadata (
    account_alias, workspace_id, item_id, path,
    parent_path, name, is_dir,
    content_length, etag, last_modified_ns, content_type,
    blob_sha256, blob_size,
    last_accessed_ns, synced_at_ns
) VALUES (
    ?, ?, ?, ?,
    ?, ?, ?,
    ?, ?, ?, ?,
    ?, ?,
    ?, ?
)
ON CONFLICT (account_alias, workspace_id, item_id, path) DO UPDATE SET
    parent_path     = excluded.parent_path,
    name            = excluded.name,
    is_dir          = excluded.is_dir,
    content_length  = excluded.content_length,
    etag            = excluded.etag,
    last_modified_ns = excluded.last_modified_ns,
    content_type    = excluded.content_type,
    blob_sha256     = excluded.blob_sha256,
    blob_size       = excluded.blob_size,
    last_accessed_ns = excluded.last_accessed_ns,
    synced_at_ns    = excluded.synced_at_ns
`
	if _, err := tx.ExecContext(ctx, stmt,
		e.AccountAlias, e.WorkspaceID, e.ItemID, e.Path,
		e.ParentPath, e.Name, boolToInt(e.IsDir),
		e.ContentLength, e.Etag, timeToNs(e.LastModified), e.ContentType,
		e.BlobSHA256, e.BlobSize,
		timeToNs(e.LastAccessed), timeToNs(e.SyncedAt),
	); err != nil {
		return fmt.Errorf("cache.Put: exec: %w", err)
	}
	if err := tx.Commit(); err != nil {
		return fmt.Errorf("cache.Put: commit: %w", err)
	}
	return nil
}

// Get loads the metadata row for k. It returns a wrapped [os.ErrNotExist]
// when the row does not exist; callers should use [errors.Is] to detect it.
func (c *Cache) Get(ctx context.Context, k Key) (Entry, error) {
	if err := validateKey(k); err != nil {
		return Entry{}, fmt.Errorf("cache.Get: %w", err)
	}
	row := c.db.QueryRowContext(ctx, selectByKeySQL,
		k.AccountAlias, k.WorkspaceID, k.ItemID, k.Path,
	)
	e, err := scanEntry(row)
	if errors.Is(err, sql.ErrNoRows) {
		c.logger.Debug("cache miss",
			slog.String("event", "metadata.get.miss"),
			slog.String("account_alias", k.AccountAlias),
			slog.String("workspace_id", k.WorkspaceID),
			slog.String("item_id", k.ItemID),
			slog.String("path", k.Path),
		)
		return Entry{}, fmt.Errorf("cache.Get: %w", os.ErrNotExist)
	}
	if err != nil {
		return Entry{}, fmt.Errorf("cache.Get: scan: %w", err)
	}
	c.logger.Debug("cache hit",
		slog.String("event", "metadata.get.hit"),
		slog.String("account_alias", k.AccountAlias),
		slog.String("path", k.Path),
	)
	return e, nil
}

// Delete removes the row for k. When k denotes a directory, the deletion
// cascades to every descendant: any row whose (account, workspace, item)
// matches and whose path equals k.Path or starts with k.Path+"/" is
// removed in the same transaction. Blob files referenced by deleted rows
// are unlinked from disk when no surviving row still references them.
//
// Delete is a no-op (returns nil) if k does not exist.
func (c *Cache) Delete(ctx context.Context, k Key) error {
	if err := validateKey(k); err != nil {
		return fmt.Errorf("cache.Delete: %w", err)
	}

	tx, err := c.db.BeginTx(ctx, nil)
	if err != nil {
		return fmt.Errorf("cache.Delete: begin: %w", err)
	}
	defer func() { _ = tx.Rollback() }()

	// 1. Collect the SHAs of every row about to be deleted so we can drop
	//    their blob files after the transaction commits (subject to the
	//    "no other row references this sha" rule).
	var (
		rows *sql.Rows
	)
	if k.Path == "" {
		rows, err = tx.QueryContext(ctx, `
SELECT blob_sha256 FROM path_metadata
WHERE account_alias = ? AND workspace_id = ? AND item_id = ?
  AND blob_sha256 != ''
`,
			k.AccountAlias, k.WorkspaceID, k.ItemID,
		)
	} else {
		rows, err = tx.QueryContext(ctx, `
SELECT blob_sha256 FROM path_metadata
WHERE account_alias = ? AND workspace_id = ? AND item_id = ?
  AND (path = ? OR path LIKE ? ESCAPE '\')
  AND blob_sha256 != ''
`,
			k.AccountAlias, k.WorkspaceID, k.ItemID,
			k.Path, escapeLike(k.Path)+`/%`,
		)
	}
	if err != nil {
		return fmt.Errorf("cache.Delete: select blobs: %w", err)
	}
	shas := make([]string, 0)
	for rows.Next() {
		var sha string
		if err := rows.Scan(&sha); err != nil {
			_ = rows.Close()
			return fmt.Errorf("cache.Delete: scan blob: %w", err)
		}
		shas = append(shas, sha)
	}
	if err := rows.Err(); err != nil {
		_ = rows.Close()
		return fmt.Errorf("cache.Delete: rows: %w", err)
	}
	_ = rows.Close()

	// 2. Delete the row(s).
	if k.Path == "" {
		if _, err := tx.ExecContext(ctx, `
DELETE FROM path_metadata
WHERE account_alias = ? AND workspace_id = ? AND item_id = ?
`,
			k.AccountAlias, k.WorkspaceID, k.ItemID,
		); err != nil {
			return fmt.Errorf("cache.Delete: exec: %w", err)
		}
	} else {
		if _, err := tx.ExecContext(ctx, `
DELETE FROM path_metadata
WHERE account_alias = ? AND workspace_id = ? AND item_id = ?
  AND (path = ? OR path LIKE ? ESCAPE '\')
`,
			k.AccountAlias, k.WorkspaceID, k.ItemID,
			k.Path, escapeLike(k.Path)+`/%`,
		); err != nil {
			return fmt.Errorf("cache.Delete: exec: %w", err)
		}
	}
	if err := tx.Commit(); err != nil {
		return fmt.Errorf("cache.Delete: commit: %w", err)
	}

	// 3. Drop blob files that no surviving row still references.
	for _, sha := range dedupe(shas) {
		c.maybeDeleteBlob(ctx, sha)
	}
	return nil
}

// Children returns every metadata row whose parent_path equals k.Path
// for the same (account, workspace, item). Only direct children; this
// is the data Finder paints when the user expands a folder.
//
// Note: Children does NOT require k to exist as a row itself; it just
// queries on parent_path. That lets callers use Children with an unseen
// directory to verify the directory is empty.
func (c *Cache) Children(ctx context.Context, k Key) ([]Entry, error) {
	if err := validateChildrenKey(k); err != nil {
		return nil, fmt.Errorf("cache.Children: %w", err)
	}
	rows, err := c.db.QueryContext(ctx, selectChildrenSQL,
		k.AccountAlias, k.WorkspaceID, k.ItemID, k.Path,
	)
	if err != nil {
		return nil, fmt.Errorf("cache.Children: query: %w", err)
	}
	defer func() { _ = rows.Close() }()

	out := make([]Entry, 0)
	for rows.Next() {
		e, err := scanEntry(rows)
		if err != nil {
			return nil, fmt.Errorf("cache.Children: scan: %w", err)
		}
		out = append(out, e)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("cache.Children: rows: %w", err)
	}
	return out, nil
}

// HotItems returns the distinct (AccountAlias, WorkspaceID, ItemID)
// triples for which at least one metadata row has been accessed at or
// after since. The returned [Key] values have Path = "" so they identify
// the item root and can be fed straight into [sync.Engine.RefreshFolder]
// by the daemon's adaptive poller.
//
// Rows whose LastAccessed is zero are excluded — they were never read
// since being inserted and therefore do not count as "hot". Results are
// ordered by AccountAlias, WorkspaceID, ItemID for deterministic tests.
func (c *Cache) HotItems(ctx context.Context, since time.Time) ([]Key, error) {
	rows, err := c.db.QueryContext(ctx, `
SELECT DISTINCT account_alias, workspace_id, item_id
FROM path_metadata
WHERE last_accessed_ns >= ? AND last_accessed_ns > 0
ORDER BY account_alias, workspace_id, item_id
`, timeToNs(since))
	if err != nil {
		return nil, fmt.Errorf("cache.HotItems: query: %w", err)
	}
	defer func() { _ = rows.Close() }()

	out := make([]Key, 0)
	for rows.Next() {
		var k Key
		if err := rows.Scan(&k.AccountAlias, &k.WorkspaceID, &k.ItemID); err != nil {
			return nil, fmt.Errorf("cache.HotItems: scan: %w", err)
		}
		out = append(out, k)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("cache.HotItems: rows: %w", err)
	}
	return out, nil
}

// Touch bumps the LastAccessed timestamp on the row identified by k to
// the current wall-clock time. Use it on every cache hit to feed the LRU
// eviction policy.
//
// Touch returns a wrapped [os.ErrNotExist] when the row does not exist.
func (c *Cache) Touch(ctx context.Context, k Key) error {
	if err := validateKey(k); err != nil {
		return fmt.Errorf("cache.Touch: %w", err)
	}
	now := time.Now().UTC()

	tx, err := c.db.BeginTx(ctx, nil)
	if err != nil {
		return fmt.Errorf("cache.Touch: begin: %w", err)
	}
	defer func() { _ = tx.Rollback() }()

	res, err := tx.ExecContext(ctx, `
UPDATE path_metadata
SET last_accessed_ns = ?
WHERE account_alias = ? AND workspace_id = ? AND item_id = ? AND path = ?
`,
		timeToNs(now),
		k.AccountAlias, k.WorkspaceID, k.ItemID, k.Path,
	)
	if err != nil {
		return fmt.Errorf("cache.Touch: exec: %w", err)
	}
	n, err := res.RowsAffected()
	if err != nil {
		return fmt.Errorf("cache.Touch: rows affected: %w", err)
	}
	if n == 0 {
		return fmt.Errorf("cache.Touch: %w", os.ErrNotExist)
	}
	if err := tx.Commit(); err != nil {
		return fmt.Errorf("cache.Touch: commit: %w", err)
	}
	return nil
}

// selectColumns lists path_metadata columns in the order scanEntry expects.
const selectColumns = `account_alias, workspace_id, item_id, path,
    parent_path, name, is_dir,
    content_length, etag, last_modified_ns, content_type,
    blob_sha256, blob_size,
    last_accessed_ns, synced_at_ns`

// selectByKeySQL fetches a single row by primary key.
const selectByKeySQL = `SELECT ` + selectColumns + `
FROM path_metadata
WHERE account_alias = ? AND workspace_id = ? AND item_id = ? AND path = ?`

// selectChildrenSQL fetches every direct child of a parent path. The
// idx_pm_children index supports it.
const selectChildrenSQL = `SELECT ` + selectColumns + `
FROM path_metadata
WHERE account_alias = ? AND workspace_id = ? AND item_id = ? AND parent_path = ?
ORDER BY is_dir DESC, name ASC`

// scannable is the subset of *sql.Row and *sql.Rows we need for a single
// row scan. Both types satisfy this interface implicitly.
type scannable interface {
	Scan(dest ...any) error
}

// scanEntry decodes one row into an [Entry]. Time values are read as
// nanosecond Unix timestamps and converted to UTC.
func scanEntry(s scannable) (Entry, error) {
	var (
		e              Entry
		isDir          int64
		lastModifiedNs int64
		lastAccessedNs int64
		syncedAtNs     int64
	)
	err := s.Scan(
		&e.AccountAlias, &e.WorkspaceID, &e.ItemID, &e.Path,
		&e.ParentPath, &e.Name, &isDir,
		&e.ContentLength, &e.Etag, &lastModifiedNs, &e.ContentType,
		&e.BlobSHA256, &e.BlobSize,
		&lastAccessedNs, &syncedAtNs,
	)
	if err != nil {
		return Entry{}, err
	}
	e.IsDir = isDir != 0
	e.LastModified = nsToTime(lastModifiedNs)
	e.LastAccessed = nsToTime(lastAccessedNs)
	e.SyncedAt = nsToTime(syncedAtNs)
	return e, nil
}
