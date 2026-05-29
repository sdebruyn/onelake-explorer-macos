package sync

import (
	"context"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"os"

	"github.com/sdebruyn/onelake-explorer-macos/internal/cache"
	"github.com/sdebruyn/onelake-explorer-macos/internal/httpretry"
	"github.com/sdebruyn/onelake-explorer-macos/internal/onelake"
	"github.com/sdebruyn/onelake-explorer-macos/internal/telemetry"
)

// Open returns a reader for a file's bytes. The data comes from the
// local cache whenever the cache holds a blob whose linked metadata row
// matches the remote's etag; otherwise the file is fetched from
// OneLake, stored in the cache, linked to the metadata row (including
// the etag DFS returned on the GET response), and the freshly cached
// blob is returned to the caller.
//
// Open issues a HEAD to OneLake to validate freshness before serving a
// cached blob. The adaptive-poll schedule covers folders, not individual
// files, so we revalidate per Open rather than trusting the SyncedAt
// timestamp alone. On a cache miss we skip the HEAD and read the etag
// straight off the GET response, so the row is fully populated and a
// follow-up Open hits the cache-fresh fast path.
//
// Offline semantics: when the freshness HEAD fails with an
// IsOfflineError AND the cache row carries a fully stored blob
// (BlobSHA256 non-empty), Open returns the cached bytes tagged
// `served_stale_offline` rather than failing. This mirrors how
// OneDrive/Dropbox behave offline: a cached file the user already
// downloaded yesterday must keep opening from a coffee shop with no
// Wi-Fi. When the cache only holds a partial-spill (no BlobSHA256),
// or holds nothing at all, the offline error stays — we won't fake
// data that was never fully cached.
//
// Telemetry: emits file_download with durationMs, success, and
// bytesTransferred. Pure cache-hit emits the event with
// bytesTransferred = 0; an offline cache-hit emits with
// ErrorCode = "served_stale_offline" and Success = true.
func (e *Engine) Open(ctx context.Context, k cache.Key) (io.ReadCloser, error) {
	start := e.now()

	if err := e.guardPausedWorkspace(ctx, k.AccountAlias, k.WorkspaceID); err != nil {
		return nil, err
	}
	if err := e.downloadSem.acquire(ctx, k.AccountAlias); err != nil {
		return nil, err
	}
	defer e.downloadSem.release(k.AccountAlias)

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
			// Offline fallback: when the freshness HEAD failed because
			// the host is offline AND we have a fully stored blob,
			// serve the stale bytes rather than refusing. This matches
			// OneDrive/Dropbox behaviour and is the asymmetric mirror
			// of the offline upload queue: we won't lose the user's
			// edits, we also won't gate their reads on connectivity.
			e.observeNetworkResult(err)
			if IsOfflineError(err) {
				rc, oerr := e.cache.OpenBlob(ctx, cached.BlobSHA256)
				if oerr == nil {
					_ = e.cache.Touch(ctx, k)
					e.logger.Debug("offline; serving stale cached blob",
						slog.String("alias", k.AccountAlias),
						slog.String("path", k.Path))
					e.track(telemetry.Event{
						Name:             "file_download",
						AccountAliasHash: telemetry.HashAlias(k.AccountAlias),
						DurationMs:       elapsedMs(start, e.now),
						Success:          boolPtr(true),
						ErrorCode:        telemetry.SafeErrorCode("served_stale_offline"),
					})
					return rc, nil
				}
				// Blob row says we have it but the file is gone; fall
				// through to surface the original offline error.
				e.logger.Warn("offline and cached blob missing; surfacing original error",
					slog.String("path", k.Path), slog.Any("err", oerr))
			}
			return nil, err
		case fresh:
			e.observeNetworkResult(nil) // successful HEAD cleared the offline flag
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
			e.observeNetworkResult(nil) // successful HEAD (etag mismatch → stale, but still a round-trip)
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

	// Cache miss or staleness: stream from OneLake. Read returns the
	// response-header metadata (etag, content-length, last-modified,
	// content-type) alongside the body so we can populate the cache row
	// without a follow-up HEAD.
	//
	// When a partial-spill is present and pinned to an etag, send the
	// request with If-Match. If the server signals 412 the partial is
	// no longer compatible with the live resource — discard everything
	// and retry once from offset 0.
	rangeStart, pinnedEtag, partial := e.partialRangeStart(ctx, cached)
	ifMatch := pinnedEtag
	body, props, err := e.onelake.ReadWithIfMatch(ctx, k.AccountAlias, k.WorkspaceID, k.ItemID, k.Path, rangeStart, -1, ifMatch)
	if err != nil {
		if partial && errors.Is(err, httpretry.ErrPreconditionFailed) {
			// Remote etag changed between the original GET and this
			// resume attempt. Trash the partial spill + sidecar and
			// retry once from scratch.
			e.logger.Info("resume etag changed; discarding partial and restarting",
				slog.String("path", k.Path),
				slog.String("pinned_etag", pinnedEtag))
			e.discardPartial(k)
			rangeStart = 0
			partial = false
			body, props, err = e.onelake.ReadWithIfMatch(ctx, k.AccountAlias, k.WorkspaceID, k.ItemID, k.Path, 0, -1, "")
		}
	}
	if err != nil {
		e.observeNetworkResult(err)
		if e.markPausedIfNeeded(ctx, k.AccountAlias, k.WorkspaceID, err) {
			e.track(telemetry.Event{
				Name:             "file_download",
				AccountAliasHash: telemetry.HashAlias(k.AccountAlias),
				DurationMs:       elapsedMs(start, e.now),
				Success:          boolPtr(false),
				ErrorCode:        telemetry.SafeErrorCode("capacity_paused"),
			})
			return nil, fmt.Errorf("sync.Open: %w", ErrWorkspacePaused)
		}
		e.track(telemetry.Event{
			Name:             "file_download",
			AccountAliasHash: telemetry.HashAlias(k.AccountAlias),
			DurationMs:       elapsedMs(start, e.now),
			Success:          boolPtr(false),
			ErrorCode:        telemetry.SafeErrorCode("read_failed"),
		})
		return nil, fmt.Errorf("sync.Open: remote read: %w", err)
	}
	e.observeNetworkResult(nil) // successful GET
	defer func() { _ = body.Close() }()

	// Pin the partial to the response etag so a follow-up resume can
	// detect remote mutation via If-Match. Best-effort: if the sidecar
	// write fails, partialRangeStart will refuse the next resume and we
	// just re-download from offset 0 — safer than a silent stitch.
	if !partial && props != nil && props.ETag != "" {
		if serr := e.storePartialEtag(k, props.ETag); serr != nil {
			e.logger.Debug("could not write partial etag sidecar",
				slog.String("path", k.Path), slog.Any("err", serr))
		}
	}

	// Pick the expected total from the server-side response when
	// available (most reliable), falling back to the cached value used
	// to decide on the Range. The expectedTotal is what finalisePartial
	// verifies the on-disk byte count against before committing.
	expectedTotal := cached.ContentLength
	if props != nil && props.ContentLength > 0 {
		// For a 206 Partial Content response, ContentLength reflects
		// only the requested range. Reconstruct the full size by adding
		// the offset we asked to resume from.
		if partial {
			expectedTotal = rangeStart + props.ContentLength
		} else {
			expectedTotal = props.ContentLength
		}
	}

	// When the cache row carries a known SHA, ask finalisePartial to
	// SHA-verify the assembled bytes — this catches the rare case where
	// size matches by coincidence but the bytes were stitched from
	// incompatible versions (which If-Match should prevent, but defense
	// in depth: a server that ignores If-Match on GET would otherwise
	// silently corrupt the cache).
	expectedSHA := ""
	if partial {
		expectedSHA = cached.BlobSHA256
	}
	sha, size, err := e.finalisePartial(ctx, k, body, expectedTotal, rangeStart, expectedSHA)
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
	// we already learned via HEAD or a previous list and folding in the
	// fresh response-header metadata. Reading the etag here is what makes
	// the next Open hit the cache-fresh fast path instead of re-downloading.
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
	if props != nil {
		if props.ETag != "" {
			row.Etag = props.ETag
		}
		if props.ContentLength != 0 {
			row.ContentLength = props.ContentLength
		}
		if !props.LastModified.IsZero() {
			row.LastModified = props.LastModified
		}
		if props.ContentType != "" {
			row.ContentType = props.ContentType
		}
	}
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
