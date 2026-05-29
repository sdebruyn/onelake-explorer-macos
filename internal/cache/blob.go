package cache

import (
	"context"
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"log/slog"
	"os"
	"path/filepath"
)

// shaLength is the hex length of a SHA-256: 64 lowercase characters.
const shaLength = 64

// StoreBlob writes content from r into the sharded blob directory under
// <root>/blobs/<sha[:2]>/<sha[2:]>, computing the SHA-256 as it streams.
// Returns the lowercase hex digest and the number of bytes written.
//
// The write is atomic: bytes go to os.CreateTemp first and are renamed
// into place only after the body finishes successfully. A crash mid-write
// therefore never leaves a partial file at the canonical name.
//
// StoreBlob is idempotent: if the blob already exists on disk the
// temporary file is discarded and the existing path is reported as-is.
func (c *Cache) StoreBlob(ctx context.Context, content io.Reader) (sha string, size int64, err error) {
	if err := ctx.Err(); err != nil {
		return "", 0, err
	}
	tmp, err := os.CreateTemp(c.blobRoot, "blob-*.tmp")
	if err != nil {
		return "", 0, fmt.Errorf("cache.StoreBlob: create temp: %w", err)
	}
	tmpName := tmp.Name()
	cleanup := func() {
		_ = tmp.Close()
		_ = os.Remove(tmpName)
	}

	h := sha256.New()
	n, copyErr := io.Copy(io.MultiWriter(tmp, h), content)
	if copyErr != nil {
		cleanup()
		return "", 0, fmt.Errorf("cache.StoreBlob: copy: %w", copyErr)
	}
	if err := tmp.Sync(); err != nil {
		cleanup()
		return "", 0, fmt.Errorf("cache.StoreBlob: sync: %w", err)
	}
	if err := tmp.Close(); err != nil {
		_ = os.Remove(tmpName)
		return "", 0, fmt.Errorf("cache.StoreBlob: close: %w", err)
	}

	sha = hex.EncodeToString(h.Sum(nil))
	dir, dst := blobShardPath(c.blobRoot, sha)
	if err := os.MkdirAll(dir, 0o700); err != nil {
		_ = os.Remove(tmpName)
		return "", 0, fmt.Errorf("cache.StoreBlob: mkdir shard: %w", err)
	}

	// Idempotency: if a blob with this sha already exists, drop the
	// temp file and report the existing one. SHA-256 collisions are
	// negligible at our scale, so the existing bytes are the same as
	// the new ones.
	if st, statErr := os.Stat(dst); statErr == nil {
		_ = os.Remove(tmpName)
		c.logger.Debug("blob already present",
			slog.String("event", "blob.store.dedupe"),
			slog.String("sha256", sha),
			slog.Int64("bytes", st.Size()),
		)
		return sha, st.Size(), nil
	} else if !errors.Is(statErr, os.ErrNotExist) {
		_ = os.Remove(tmpName)
		return "", 0, fmt.Errorf("cache.StoreBlob: stat dst: %w", statErr)
	}

	if err := os.Rename(tmpName, dst); err != nil {
		_ = os.Remove(tmpName)
		return "", 0, fmt.Errorf("cache.StoreBlob: rename: %w", err)
	}
	c.logger.Debug("blob stored",
		slog.String("event", "blob.store.write"),
		slog.String("sha256", sha),
		slog.Int64("bytes", n),
	)
	return sha, n, nil
}

// OpenBlob returns a read-only handle to the named blob. The caller is
// responsible for closing it. Returns a wrapped [os.ErrNotExist] when
// the blob is not on disk.
func (c *Cache) OpenBlob(ctx context.Context, sha string) (io.ReadCloser, error) {
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	if err := validateSHA(sha); err != nil {
		return nil, fmt.Errorf("cache.OpenBlob: %w", err)
	}
	_, path := blobShardPath(c.blobRoot, sha)
	f, err := os.Open(path) // #nosec G304 -- path constrained to <blobRoot>/<2hex>/<62hex>
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return nil, fmt.Errorf("cache.OpenBlob: %w", os.ErrNotExist)
		}
		return nil, fmt.Errorf("cache.OpenBlob: open: %w", err)
	}
	return f, nil
}

// DiskUsage walks the on-disk blob root and returns the number of blob
// files present and the sum of their sizes in bytes. Unlike [Cache.BlobBytes]
// it sees orphaned blobs (files on disk with no surviving metadata link),
// which is what the CLI wants when reporting "what's on the user's disk".
//
// Files that vanish mid-walk are skipped silently because eviction can
// race with the call. A missing blob root (cache not yet opened by any
// process) reports (0, 0, nil).
func (c *Cache) DiskUsage(ctx context.Context) (count int, bytes int64, err error) {
	if err := ctx.Err(); err != nil {
		return 0, 0, err
	}
	walkErr := filepath.WalkDir(c.blobRoot, func(_ string, d fs.DirEntry, walkErr error) error {
		if walkErr != nil {
			if errors.Is(walkErr, fs.ErrNotExist) {
				return nil
			}
			return walkErr
		}
		if d.IsDir() {
			return nil
		}
		info, infoErr := d.Info()
		if infoErr != nil {
			if errors.Is(infoErr, fs.ErrNotExist) {
				return nil
			}
			return infoErr
		}
		// Skip the leftover temp files [StoreBlob] uses for atomic writes.
		// They are not "blobs" yet and reporting them inflates the figure
		// shown to the user.
		if filepath.Ext(d.Name()) == ".tmp" {
			return nil
		}
		count++
		bytes += info.Size()
		return nil
	})
	if walkErr != nil {
		if errors.Is(walkErr, fs.ErrNotExist) {
			return 0, 0, nil
		}
		return 0, 0, fmt.Errorf("cache.DiskUsage: %w", walkErr)
	}
	return count, bytes, nil
}

// Wipe deletes every blob file under the blob root and clears the
// blob_sha256 / blob_size columns on every metadata row in a single
// transaction. Metadata rows themselves survive — the sync engine still
// needs them to know what exists remotely; on the next access the row
// simply behaves as "not cached" and the blob is re-downloaded.
//
// The reported counts come from the disk walk before deletion so callers
// can tell the user exactly how much was reclaimed. Wipe is safe to call
// on an empty cache and returns (0, 0, nil) in that case.
func (c *Cache) Wipe(ctx context.Context) (count int, bytes int64, err error) {
	if err := ctx.Err(); err != nil {
		return 0, 0, err
	}

	count, bytes, err = c.DiskUsage(ctx)
	if err != nil {
		return 0, 0, fmt.Errorf("cache.Wipe: %w", err)
	}

	// 1. Clear blob links across the metadata table inside one transaction
	//    so observers see an atomic switch from "cached" to "not cached".
	tx, err := c.db.BeginTx(ctx, nil)
	if err != nil {
		return 0, 0, fmt.Errorf("cache.Wipe: begin: %w", err)
	}
	defer func() { _ = tx.Rollback() }()
	if _, err := tx.ExecContext(ctx, `
UPDATE path_metadata
SET blob_sha256 = '', blob_size = 0
WHERE blob_sha256 != ''
`); err != nil {
		return 0, 0, fmt.Errorf("cache.Wipe: clear links: %w", err)
	}
	if err := tx.Commit(); err != nil {
		return 0, 0, fmt.Errorf("cache.Wipe: commit: %w", err)
	}

	// 2. Drop every blob shard directory from disk. We remove the shard
	//    directories rather than walking individual files because it's
	//    cheaper and avoids leaving behind empty <ab>/ subdirs.
	entries, err := os.ReadDir(c.blobRoot)
	if err != nil {
		if errors.Is(err, fs.ErrNotExist) {
			return count, bytes, nil
		}
		return 0, 0, fmt.Errorf("cache.Wipe: read blob root: %w", err)
	}
	for _, e := range entries {
		path := filepath.Join(c.blobRoot, e.Name())
		if err := os.RemoveAll(path); err != nil {
			c.logger.Warn("wipe entry failed",
				slog.String("event", "blob.wipe.entry_failed"),
				slog.String("path", path),
				slog.Any("err", err),
			)
		}
	}
	c.logger.Info("cache wiped",
		slog.String("event", "blob.wipe"),
		slog.Int("blobs", count),
		slog.Int64("bytes", bytes),
	)
	return count, bytes, nil
}

// BlobBytes returns the on-disk size, in bytes, of the blobs currently
// linked to metadata rows. It does NOT walk the filesystem; it sums
// blob_size in the database, but over DISTINCT blob_sha256 so a blob
// shared by N metadata rows (one physical file, N links) counts once.
// Summing per-row would report N×size against a disk holding 1×size and
// make [EvictToLimit] over-evict. Use it with [Options.MaxBlobBytes] to
// decide whether eviction is needed.
func (c *Cache) BlobBytes(ctx context.Context) (int64, error) {
	var total sql.NullInt64
	if err := c.db.QueryRowContext(ctx, `
SELECT COALESCE(SUM(blob_size), 0) FROM (
    SELECT blob_size FROM path_metadata
    WHERE blob_sha256 != ''
    GROUP BY blob_sha256
)
`).Scan(&total); err != nil {
		return 0, fmt.Errorf("cache.BlobBytes: %w", err)
	}
	if total.Valid {
		return total.Int64, nil
	}
	return 0, nil
}

// maybeDeleteBlob removes the blob file for sha when no metadata row
// references it any longer. Logs but does not return errors: the caller
// has already committed the metadata change and a leaked blob is
// recoverable by a later eviction pass.
func (c *Cache) maybeDeleteBlob(ctx context.Context, sha string) {
	if err := validateSHA(sha); err != nil {
		// Bad input: nothing to delete safely.
		c.logger.Warn("invalid sha during blob cleanup",
			slog.String("event", "blob.cleanup.invalid"),
			slog.String("sha256", sha),
			slog.Any("err", err),
		)
		return
	}

	var n int64
	if err := c.db.QueryRowContext(ctx, `
SELECT COUNT(*) FROM path_metadata WHERE blob_sha256 = ?
`, sha).Scan(&n); err != nil {
		c.logger.Warn("count refs failed during blob cleanup",
			slog.String("event", "blob.cleanup.count_failed"),
			slog.String("sha256", sha),
			slog.Any("err", err),
		)
		return
	}
	if n > 0 {
		return
	}

	_, path := blobShardPath(c.blobRoot, sha)
	if err := os.Remove(path); err != nil && !errors.Is(err, os.ErrNotExist) {
		c.logger.Warn("blob unlink failed",
			slog.String("event", "blob.cleanup.unlink_failed"),
			slog.String("sha256", sha),
			slog.Any("err", err),
		)
		return
	}
	// Try to remove the shard directory if it is now empty. Ignore
	// errors: a non-empty directory is fine.
	dir := filepath.Dir(path)
	_ = os.Remove(dir)

	c.logger.Debug("blob removed",
		slog.String("event", "blob.cleanup.removed"),
		slog.String("sha256", sha),
	)
}

// validateSHA enforces the lowercase 64-hex-char shape of every SHA the
// blob store accepts. Anything else is a programmer error.
func validateSHA(sha string) error {
	if len(sha) != shaLength {
		return fmt.Errorf("sha must be %d hex chars, got %d", shaLength, len(sha))
	}
	for i := 0; i < len(sha); i++ {
		c := sha[i]
		switch {
		case c >= '0' && c <= '9':
		case c >= 'a' && c <= 'f':
		default:
			return fmt.Errorf("sha must be lowercase hex; bad byte at offset %d", i)
		}
	}
	return nil
}
