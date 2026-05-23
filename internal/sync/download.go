package sync

import (
	"context"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"os"

	"github.com/sdebruyn/onelake-explorer-macos/internal/cache"
	"github.com/sdebruyn/onelake-explorer-macos/internal/onelake"
	"github.com/sdebruyn/onelake-explorer-macos/internal/telemetry"
)

// Open returns a reader for a file's bytes. The data comes from the
// local cache whenever the cache holds a blob whose linked metadata row
// matches the remote's etag; otherwise the file is fetched from
// OneLake, stored in the cache, linked to the metadata row, and the
// freshly cached blob is returned to the caller.
//
// Open issues a HEAD to OneLake to validate freshness before serving a
// cached blob. The adaptive-poll schedule covers folders, not individual
// files, so we revalidate per Open rather than trusting the SyncedAt
// timestamp alone.
//
// Telemetry: emits file_download with durationMs, success, and
// bytesTransferred. Pure cache-hit emits the event with
// bytesTransferred = 0.
func (e *Engine) Open(ctx context.Context, k cache.Key) (io.ReadCloser, error) {
	start := e.now()

	cached, cachedErr := e.cache.Get(ctx, k)
	if cachedErr != nil && !errors.Is(cachedErr, os.ErrNotExist) {
		return nil, fmt.Errorf("sync.Open: cache get: %w", cachedErr)
	}

	if cachedErr == nil && cached.IsDir {
		return nil, fmt.Errorf("sync.Open: %s is a directory", k.Path)
	}

	// Cache hit path: when we have a blob and the etag still matches the
	// remote, return the blob.
	if cachedErr == nil && cached.BlobSHA256 != "" {
		fresh, props, err := e.isBlobFresh(ctx, k, cached)
		switch {
		case err != nil:
			return nil, err
		case fresh:
			rc, err := e.cache.OpenBlob(ctx, cached.BlobSHA256)
			if err != nil {
				// Blob row says we have it but the file is gone; fall
				// through to a fresh download.
				e.logger.Warn("cache blob missing despite linked row; refetching",
					slog.String("path", k.Path), slog.Any("err", err))
			} else {
				_ = e.cache.Touch(ctx, k)
				e.track(telemetry.Event{
					Name:             "file_download",
					AccountAliasHash: telemetry.HashAlias(k.AccountAlias),
					DurationMs:       elapsedMs(start, e.now),
					Success:          boolPtr(true),
				})
				return rc, nil
			}
		default:
			// Remote moved on: prep cached entry with the new metadata so
			// the post-download upsert lands on the latest values.
			if props != nil {
				cached.Etag = props.ETag
				cached.ContentLength = props.ContentLength
				cached.LastModified = props.LastModified
				cached.ContentType = props.ContentType
			}
		}
	}

	// Cache miss or staleness: stream from OneLake.
	body, err := e.onelake.Read(ctx, k.AccountAlias, k.WorkspaceID, k.ItemID, k.Path, 0, -1)
	if err != nil {
		e.track(telemetry.Event{
			Name:             "file_download",
			AccountAliasHash: telemetry.HashAlias(k.AccountAlias),
			DurationMs:       elapsedMs(start, e.now),
			Success:          boolPtr(false),
			ErrorCode:        telemetry.SafeErrorCode("read_failed"),
		})
		return nil, fmt.Errorf("sync.Open: remote read: %w", err)
	}
	defer func() { _ = body.Close() }()

	sha, size, err := e.cache.StoreBlob(ctx, body)
	if err != nil {
		e.track(telemetry.Event{
			Name:             "file_download",
			AccountAliasHash: telemetry.HashAlias(k.AccountAlias),
			DurationMs:       elapsedMs(start, e.now),
			Success:          boolPtr(false),
			ErrorCode:        telemetry.SafeErrorCode("blob_store_failed"),
		})
		return nil, fmt.Errorf("sync.Open: store blob: %w", err)
	}

	// Upsert the metadata row, preserving any existing remote attributes
	// we already learned via HEAD or a previous list.
	row := cached
	row.Key = k
	if row.Name == "" {
		row.Name = baseName(k.Path)
	}
	if row.ParentPath == "" {
		row.ParentPath = parentPath(k.Path)
	}
	row.BlobSHA256 = sha
	row.BlobSize = size
	if row.ContentLength == 0 {
		row.ContentLength = size
	}
	now := e.now()
	row.LastAccessed = now
	row.SyncedAt = now
	if err := e.cache.Put(ctx, row); err != nil {
		return nil, fmt.Errorf("sync.Open: cache put: %w", err)
	}

	rc, err := e.cache.OpenBlob(ctx, sha)
	if err != nil {
		return nil, fmt.Errorf("sync.Open: open freshly stored blob: %w", err)
	}
	e.track(telemetry.Event{
		Name:             "file_download",
		AccountAliasHash: telemetry.HashAlias(k.AccountAlias),
		DurationMs:       elapsedMs(start, e.now),
		Success:          boolPtr(true),
		BytesTransferred: size,
	})
	return rc, nil
}

// isBlobFresh returns whether the cached blob still matches the remote.
// On staleness it returns the parsed PathProperties so the caller can
// reuse them for the post-download upsert. When the cache entry has no
// etag we treat it as stale (forces a re-validate).
func (e *Engine) isBlobFresh(ctx context.Context, k cache.Key, cached cache.Entry) (bool, *onelake.PathProperties, error) {
	props, err := e.onelake.GetProperties(ctx, k.AccountAlias, k.WorkspaceID, k.ItemID, k.Path)
	if err != nil {
		return false, nil, fmt.Errorf("sync.Open: head: %w", err)
	}
	if cached.Etag == "" {
		return false, props, nil
	}
	if props.ETag != "" && props.ETag == cached.Etag {
		return true, props, nil
	}
	return false, props, nil
}

// baseName returns the last path segment, defaulting to "" for an empty
// path. We do not import path/filepath here because cache paths are
// always POSIX-style regardless of host OS.
func baseName(p string) string {
	if p == "" {
		return ""
	}
	for i := len(p) - 1; i >= 0; i-- {
		if p[i] == '/' {
			return p[i+1:]
		}
	}
	return p
}
