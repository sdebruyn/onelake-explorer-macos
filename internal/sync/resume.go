// Resume support for downloads: a per-Open partial-blob spill file in
// the OS tempdir that survives the lifetime of a single Open call and
// lets a transport-level retry pick up where the previous attempt
// stopped.
//
// The partial-blob file lives in os.TempDir() under a deterministic
// name derived from the cache.Key, so a follow-up Open started after a
// kernel hand-off still finds it. Each partial carries a sidecar
// "<partial>.etag" file recording the ETag of the GET it was started
// against; on resume the caller pins the request to that ETag via
// If-Match so a server-side mutation can never cause us to stitch
// incompatible byte ranges. When cached.BlobSHA256 is known, the
// assembled bytes are also SHA-verified before commit.
//
// On any failure the partial is left in place; on completion it is
// consumed by cache.StoreBlob and removed.

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

// partialEtagFor returns the sidecar path that records the ETag the
// partial spill was started against. Same naming convention as
// [partialFor] so a stale partial and its sidecar are easy to spot
// and remove as a pair.
func partialEtagFor(k cache.Key) string { return partialFor(k) + ".etag" }

// loadPartialEtag returns the ETag recorded for the current partial,
// or "" when no sidecar exists or it cannot be read. Treating missing
// or unreadable sidecars as "" is intentional — we then either skip
// the resume entirely (when an etag would have been required) or
// start a fresh download.
func loadPartialEtag(k cache.Key) string {
	bs, err := os.ReadFile(partialEtagFor(k)) // #nosec G304 -- path is SHA over our own key.
	if err != nil {
		return ""
	}
	return string(bs)
}

// storePartialEtag writes the etag sidecar for k. Empty etag deletes
// the sidecar so a follow-up resume that cannot match the etag falls
// through to a fresh download.
func storePartialEtag(k cache.Key, etag string) error {
	if etag == "" {
		err := os.Remove(partialEtagFor(k))
		if err != nil && !errors.Is(err, os.ErrNotExist) {
			return err
		}
		return nil
	}
	if err := os.MkdirAll(filepath.Dir(partialEtagFor(k)), 0o700); err != nil {
		return err
	}
	return os.WriteFile(partialEtagFor(k), []byte(etag), 0o600)
}

// discardPartial removes the spill file and its etag sidecar. Best-
// effort: missing files are ignored.
func discardPartial(k cache.Key) {
	_ = os.Remove(partialFor(k))
	_ = os.Remove(partialEtagFor(k))
}

// partialRangeStart returns the byte offset Open should pass in a
// Range header to resume an in-flight download, the ETag the partial
// is pinned to, and a boolean reporting whether a partial was found.
// When the partial would not contribute usable bytes (cache entry has
// no etag yet, etag sidecar missing or mismatched, file gone, …)
// returns 0, "", false so the caller downloads from the start.
//
// The decision to resume is conservative on purpose: we only resume
// when (a) the cache row has a content-length, (b) a sidecar etag
// exists, AND (c) the cached row's etag still matches the sidecar.
// Anything else falls back to a fresh download which is the safe
// choice — the partial bytes are still on disk and we just discard
// them rather than risk stitching them with newer bytes from a
// changed remote.
func (e *Engine) partialRangeStart(_ context.Context, cached cache.Entry) (int64, string, bool) {
	if cached.ContentLength <= 0 {
		return 0, "", false
	}
	info, err := os.Stat(partialFor(cached.Key))
	if err != nil {
		return 0, "", false
	}
	if info.Size() <= 0 || info.Size() >= cached.ContentLength {
		return 0, "", false
	}
	etag := loadPartialEtag(cached.Key)
	if etag == "" {
		// No etag binding: refuse to resume. Discard now so a follow-
		// up retry doesn't keep trying to seek into the stale partial.
		discardPartial(cached.Key)
		return 0, "", false
	}
	// If we know the cached row's etag, it must match the sidecar —
	// otherwise the remote moved on between the partial download and
	// this attempt.
	if cached.Etag != "" && cached.Etag != etag {
		discardPartial(cached.Key)
		return 0, "", false
	}
	return info.Size(), etag, true
}

// finalisePartial appends the freshly streamed body to any existing
// partial-spill for k and (on success) hands the combined bytes to
// cache.StoreBlob. The Content-Length the server reported is compared
// against the bytes ultimately stored; a mismatch deletes the partial
// and returns an error so the caller can retry from offset 0. When
// expectedSHA is non-empty, the assembled bytes are SHA-verified and
// a mismatch trashes the partial AND its etag sidecar so the next
// attempt restarts clean.
//
// On any failure (read, write, fsync) the partial-spill is left in
// place so the next attempt can pick up from the same offset. On a
// successful StoreBlob the partial-spill and its etag sidecar are
// removed together.
func (e *Engine) finalisePartial(ctx context.Context, k cache.Key, body io.Reader, expectedTotal int64, rangeStart int64, expectedSHA string) (sha string, size int64, err error) {
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
			discardPartial(k)
		}
		return "", 0, fmt.Errorf("sync.finalisePartial: size mismatch: got %d, want %d", totalWritten, expectedTotal)
	}

	// SHA verification before StoreBlob when an expected hash is known.
	// This catches the case where size matches by coincidence but the
	// bytes were stitched from incompatible versions. Discard the
	// partial AND its etag sidecar so the next attempt restarts clean.
	if expectedSHA != "" {
		if _, err := f.Seek(0, io.SeekStart); err != nil {
			_ = f.Close()
			return "", 0, fmt.Errorf("sync.finalisePartial: rewind for sha verify: %w", err)
		}
		h := sha256.New()
		if _, err := io.Copy(h, f); err != nil {
			_ = f.Close()
			return "", 0, fmt.Errorf("sync.finalisePartial: read for sha verify: %w", err)
		}
		got := hex.EncodeToString(h.Sum(nil))
		if got != expectedSHA {
			_ = f.Close()
			discardPartial(k)
			return "", 0, fmt.Errorf("sync.finalisePartial: sha mismatch: got %s, want %s", got, expectedSHA)
		}
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
		discardPartial(k)
		return "", 0, fmt.Errorf("sync.finalisePartial: stored %d bytes, expected %d", size, expectedTotal)
	}
	// Success: drop the partial-spill and its etag sidecar.
	if err := os.Remove(partialPath); err != nil && !errors.Is(err, os.ErrNotExist) {
		e.logger.Debug("could not remove partial after success",
			slog.String("path", partialPath), slog.Any("err", err))
	}
	if err := os.Remove(partialEtagFor(k)); err != nil && !errors.Is(err, os.ErrNotExist) {
		e.logger.Debug("could not remove partial etag after success",
			slog.String("path", partialEtagFor(k)), slog.Any("err", err))
	}
	return sha, size, nil
}
