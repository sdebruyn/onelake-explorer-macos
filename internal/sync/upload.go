package sync

import (
	"context"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"os"
	"regexp"
	"strings"

	"github.com/sdebruyn/onelake-explorer-macos/internal/cache"
	"github.com/sdebruyn/onelake-explorer-macos/internal/telemetry"
)

// macOSMetadataRE matches the macOS metadata suffixes documented in
// docs/file-provider.md:
//
//	\.(DS_Store|Spotlight-V100|Trashes|fseventsd)$
//
// AppleDouble files start with "._" and are matched separately.
var macOSMetadataRE = regexp.MustCompile(`\.(DS_Store|Spotlight-V100|Trashes|fseventsd)$`)

// IsMacOSMetadata reports whether p denotes a macOS metadata file we
// must never push to OneLake. Exposed for tests and for any external
// caller that wants to short-circuit before invoking Put.
func IsMacOSMetadata(p string) bool {
	name := baseName(p)
	if name == "" {
		return false
	}
	if strings.HasPrefix(name, "._") {
		return true
	}
	return macOSMetadataRE.MatchString(name)
}

// Put uploads content to OneLake (chunked) and mirrors the result in the
// cache: the metadata row gets the post-upload size/etag, and the bytes
// we just sent are also stored in the local blob store so the next Open
// is a cache hit without round-tripping the lake again.
//
// Last-write-wins: even if the cache's etag is older than the remote's
// we still issue the PUT/PATCH chain. This matches docs/auth.md and
// docs/file-provider.md — no conflict copies, no client-side merge.
//
// macOS metadata filter: when k.Path matches the macOS-metadata pattern
// (e.g. ".DS_Store", "._foo", "Spotlight-V100"), Put returns nil
// success without contacting OneLake and without emitting telemetry.
// This keeps the lake namespace clean and keeps event counts honest.
// See docs/file-provider.md.
//
// Telemetry: emits file_upload with durationMs, success, and
// bytesTransferred.
func (e *Engine) Put(ctx context.Context, k cache.Key, content io.Reader, size int64) error {
	if IsMacOSMetadata(k.Path) {
		e.logger.Debug("ignoring macOS metadata upload",
			slog.String("account", k.AccountAlias),
			slog.String("path", k.Path),
		)
		// Drain (but discard) the reader so the caller's I/O accounting
		// stays consistent — File Provider can hand us a temp file
		// handle whose lifecycle expects the bytes to be consumed.
		_, _ = io.Copy(io.Discard, content)
		return nil
	}

	if err := e.guardPausedWorkspace(ctx, k.AccountAlias, k.WorkspaceID); err != nil {
		return err
	}
	if err := e.uploadSem.acquire(ctx, k.AccountAlias); err != nil {
		return err
	}
	defer e.uploadSem.release(k.AccountAlias)

	start := e.now()

	// Buffer the upload bytes into a spill file so the last-write-wins
	// retry loop can replay them on a 412 without re-reading the
	// (often one-shot) caller-provided reader. The spill lives in the
	// OS tempdir; on success it is consumed by StoreBlob, on failure
	// it is cleaned up by the deferred call.
	tmp, err := newSpillFile()
	if err != nil {
		return fmt.Errorf("sync.Put: spill temp: %w", err)
	}
	defer tmp.cleanup()

	if _, err := io.Copy(tmp.file, content); err != nil {
		return fmt.Errorf("sync.Put: spill copy: %w", err)
	}
	if err := tmp.rewind(); err != nil {
		return fmt.Errorf("sync.Put: spill rewind: %w", err)
	}

	if err := e.uploadWithLastWriteWins(ctx, k, tmp.file, size, tmp.rewind); err != nil {
		if e.markPausedIfNeeded(ctx, k.AccountAlias, k.WorkspaceID, err) {
			e.track(telemetry.Event{
				Name:             "file_upload",
				AccountAliasHash: telemetry.HashAlias(k.AccountAlias),
				DurationMs:       elapsedMs(start, e.now),
				Success:          boolPtr(false),
				ErrorCode:        telemetry.SafeErrorCode("capacity_paused"),
			})
			return fmt.Errorf("sync.Put: %w", ErrWorkspacePaused)
		}
		errCode := "write_failed"
		if errors.Is(err, ErrLastWriteWinsExhausted) {
			errCode = "lww_exhausted"
		}
		e.track(telemetry.Event{
			Name:             "file_upload",
			AccountAliasHash: telemetry.HashAlias(k.AccountAlias),
			DurationMs:       elapsedMs(start, e.now),
			Success:          boolPtr(false),
			ErrorCode:        telemetry.SafeErrorCode(errCode),
		})
		return fmt.Errorf("sync.Put: write: %w", err)
	}

	// Persist the local copy. The same bytes the lake just received now
	// land in the blob store so a subsequent Open is a guaranteed cache
	// hit.
	if err := tmp.rewind(); err != nil {
		return fmt.Errorf("sync.Put: rewind spill: %w", err)
	}
	sha, storedSize, err := e.cache.StoreBlob(ctx, tmp.file)
	if err != nil {
		// Upload succeeded; failing to mirror locally is recoverable.
		e.logger.Warn("upload mirrored to lake but local cache write failed",
			slog.String("path", k.Path), slog.Any("err", err))
	}

	// Best-effort HEAD to learn the server-assigned etag/lastmod. Most
	// callers expect them on the next list, but caching them now means
	// the next Open is a true hit (no HEAD needed).
	now := e.now()
	row := cache.Entry{
		Key:           k,
		ParentPath:    parentPath(k.Path),
		Name:          baseName(k.Path),
		IsDir:         false,
		ContentLength: size,
		LastAccessed:  now,
		SyncedAt:      now,
	}
	if sha != "" {
		row.BlobSHA256 = sha
		row.BlobSize = storedSize
	}
	if props, perr := e.onelake.GetProperties(ctx, k.AccountAlias, k.WorkspaceID, k.ItemID, k.Path); perr == nil {
		row.Etag = props.ETag
		if props.ContentLength != 0 {
			row.ContentLength = props.ContentLength
		}
		row.LastModified = props.LastModified
		row.ContentType = props.ContentType
	} else {
		e.logger.Debug("post-upload HEAD failed; metadata will catch up on next list",
			slog.String("path", k.Path), slog.Any("err", perr))
	}

	if err := e.cache.Put(ctx, row); err != nil {
		return fmt.Errorf("sync.Put: cache put: %w", err)
	}

	e.track(telemetry.Event{
		Name:             "file_upload",
		AccountAliasHash: telemetry.HashAlias(k.AccountAlias),
		DurationMs:       elapsedMs(start, e.now),
		Success:          boolPtr(true),
		BytesTransferred: size,
	})
	return nil
}

// spillFile is a single-writer-then-rewindable temp file the engine uses
// to keep a copy of the bytes flowing to OneLake. Caller must call
// cleanup() exactly once.
type spillFile struct {
	file *os.File
	path string
}

// newSpillFile creates an empty temp file with permissions 0o600.
func newSpillFile() (*spillFile, error) {
	f, err := os.CreateTemp("", "ofem-sync-spill-*")
	if err != nil {
		return nil, fmt.Errorf("sync: create spill: %w", err)
	}
	return &spillFile{file: f, path: f.Name()}, nil
}

func (s *spillFile) rewind() error {
	if s == nil || s.file == nil {
		return errors.New("sync: nil spill")
	}
	_, err := s.file.Seek(0, io.SeekStart)
	return err
}

func (s *spillFile) cleanup() {
	if s == nil || s.file == nil {
		return
	}
	_ = s.file.Close()
	_ = os.Remove(s.path)
}
