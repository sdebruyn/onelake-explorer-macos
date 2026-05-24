// Resume support for downloads: a per-Open partial-blob spill file in
// the OS tempdir that survives the lifetime of a single Open call and
// lets a transport-level retry pick up where the previous attempt
// stopped.
//
// The partial-blob file lives in os.TempDir() under a deterministic
// name derived from the cache.Key, so a follow-up Open started after a
// kernel hand-off still finds it. On any failure the partial is left
// in place; on completion it is consumed by cache.StoreBlob and
// removed.

package sync

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"os"
	"path/filepath"

	"github.com/sdebruyn/onelake-explorer-macos/internal/cache"
)

// partialsDirName is the leaf directory under os.TempDir() where
// in-flight download spill files live. It is created on demand.
const partialsDirName = "ofem-download-partials"

// partialFor returns the canonical on-disk path for the partial-spill
// of one cache key. Same key -> same path so two Open calls on the same
// file from different processes will rendezvous on the same partial
// (the operations are still serialised through the per-account
// download semaphore, but cross-process callers also benefit).
func partialFor(k cache.Key) string {
	h := sha256.Sum256([]byte(k.AccountAlias + "\x00" + k.WorkspaceID + "\x00" + k.ItemID + "\x00" + k.Path))
	name := hex.EncodeToString(h[:]) + ".partial"
	return filepath.Join(os.TempDir(), partialsDirName, name)
}

// partialRangeStart returns the byte offset Open should pass in a
// Range header to resume an in-flight download, and a boolean
// reporting whether a partial was actually found. When the partial
// would not contribute usable bytes (cache entry has a different
// etag, no etag yet, file gone, …) returns 0, false so the caller
// downloads from the start.
//
// The decision to resume is intentionally conservative: only resume
// when the cache row carries a content-length and the partial size is
// strictly less than that target. Anything else falls back to a fresh
// download which is the safe choice — the partial bytes are still
// there, the new download just writes to a fresh temp.
func (e *Engine) partialRangeStart(_ context.Context, cached cache.Entry) (int64, bool) {
	if cached.ContentLength <= 0 {
		return 0, false
	}
	info, err := os.Stat(partialFor(cached.Key))
	if err != nil {
		return 0, false
	}
	if info.Size() <= 0 || info.Size() >= cached.ContentLength {
		return 0, false
	}
	return info.Size(), true
}

// finalisePartial appends the freshly streamed body to any existing
// partial-spill for k and (on success) hands the combined bytes to
// cache.StoreBlob. The Content-Length the server reported is compared
// against the bytes ultimately stored; a mismatch deletes the partial
// and returns an error so the caller can retry from offset 0.
//
// On any failure (read, write, fsync) the partial-spill is left in
// place so the next attempt can pick up from the same offset. On a
// successful StoreBlob the partial-spill is removed.
func (e *Engine) finalisePartial(ctx context.Context, k cache.Key, body io.Reader, expectedTotal int64, rangeStart int64) (sha string, size int64, err error) {
	partialPath := partialFor(k)
	if err := os.MkdirAll(filepath.Dir(partialPath), 0o700); err != nil {
		return "", 0, fmt.Errorf("sync.finalisePartial: mkdir partials: %w", err)
	}
	// #nosec G304 -- path is derived from a SHA-256 over a key we own.
	f, err := os.OpenFile(partialPath, os.O_RDWR|os.O_CREATE, 0o600)
	if err != nil {
		return "", 0, fmt.Errorf("sync.finalisePartial: open partial: %w", err)
	}
	// Seek to rangeStart (= the existing partial's size) so the bytes
	// the server streams append cleanly. A short partial-on-disk would
	// otherwise corrupt the byte stream.
	if _, err := f.Seek(rangeStart, io.SeekStart); err != nil {
		_ = f.Close()
		return "", 0, fmt.Errorf("sync.finalisePartial: seek: %w", err)
	}

	n, copyErr := io.Copy(f, body)
	if copyErr != nil {
		_ = f.Close()
		// Keep the partial: the next attempt will pick up from the new
		// (= rangeStart + n) offset.
		e.logger.Warn("download interrupted; keeping partial for resume",
			slog.String("path", k.Path),
			slog.Int64("partial_size", rangeStart+n),
			slog.Int64("expected", expectedTotal),
			slog.Any("err", copyErr),
		)
		return "", 0, fmt.Errorf("sync.finalisePartial: copy: %w", copyErr)
	}
	if err := f.Sync(); err != nil {
		_ = f.Close()
		return "", 0, fmt.Errorf("sync.finalisePartial: sync: %w", err)
	}
	totalWritten := rangeStart + n
	if expectedTotal > 0 && totalWritten != expectedTotal {
		_ = f.Close()
		// Sticky partial only when we're short; trash when too long
		// (the server gave us more than the cached Content-Length, so
		// something fundamentally changed and we want to restart clean).
		if totalWritten > expectedTotal {
			_ = os.Remove(partialPath)
		}
		return "", 0, fmt.Errorf("sync.finalisePartial: size mismatch: got %d, want %d", totalWritten, expectedTotal)
	}

	// Rewind so cache.StoreBlob reads from byte 0.
	if _, err := f.Seek(0, io.SeekStart); err != nil {
		_ = f.Close()
		return "", 0, fmt.Errorf("sync.finalisePartial: rewind: %w", err)
	}
	sha, size, err = e.cache.StoreBlob(ctx, f)
	_ = f.Close()
	if err != nil {
		return "", 0, fmt.Errorf("sync.finalisePartial: store: %w", err)
	}
	if expectedTotal > 0 && size != expectedTotal {
		// StoreBlob already deduped or short-circuited; treat as a
		// mismatch and rewind the next attempt.
		_ = os.Remove(partialPath)
		return "", 0, fmt.Errorf("sync.finalisePartial: stored %d bytes, expected %d", size, expectedTotal)
	}
	// Success: drop the partial-spill.
	if err := os.Remove(partialPath); err != nil && !errors.Is(err, os.ErrNotExist) {
		e.logger.Debug("could not remove partial after success",
			slog.String("path", partialPath), slog.Any("err", err))
	}
	return sha, size, nil
}
