package sync

import (
	"context"
	"errors"
	"fmt"
	"os"

	"github.com/sdebruyn/onelake-explorer-macos/internal/cache"
	"github.com/sdebruyn/onelake-explorer-macos/internal/telemetry"
)

// Delete removes a file or directory from OneLake, then drops the
// matching cache rows and blobs (cache.Delete cascades). Directories
// are deleted recursively to match Finder's "Move to Bin" semantics.
//
// macOS metadata files are silently swallowed on the OneLake side
// (we still drop the cache row so Finder sees the delete reflected
// locally), per docs/file-provider.md.
//
// Telemetry: emits file_delete or folder_delete depending on whether
// the cached row says it is a directory. When the cache has never seen
// the entry we default to file_delete (the common case).
//
// The recursive flag sent to OneLake also defaults to true on a cache
// miss. The cached IsDir hint is the only way we know whether the
// path is a folder before issuing the call, and a stale or absent
// cache row would otherwise produce a non-recursive DELETE that fails
// with 409 on a populated directory (a folder created out-of-band, or
// a row evicted/rebuilt since the last visit). DFS treats a recursive
// flag on a file delete as a no-op, so always-recursive on a miss is
// safe.
func (e *Engine) Delete(ctx context.Context, k cache.Key) error {
	start := e.now()

	cached, cachedErr := e.cache.Get(ctx, k)
	if cachedErr != nil && !errors.Is(cachedErr, os.ErrNotExist) {
		return fmt.Errorf("sync.Delete: cache get: %w", cachedErr)
	}
	cacheHit := cachedErr == nil
	isDir := cacheHit && cached.IsDir
	eventName := "file_delete"
	if isDir {
		eventName = "folder_delete"
	}

	if IsMacOSMetadata(k.Path) {
		// Local-only file; the lake never knew about it. Drop the cache
		// row (if any) and return success without emitting telemetry,
		// matching the upload-path behaviour.
		if err := e.cache.Delete(ctx, k); err != nil {
			return fmt.Errorf("sync.Delete: cache delete: %w", err)
		}
		return nil
	}

	// On a cache miss we cannot tell file from directory; ask DFS to
	// recurse so a stale/missing cache does not produce a 409 on
	// populated directories.
	recursive := isDir || !cacheHit
	if err := e.guardPausedWorkspace(ctx, k.AccountAlias, k.WorkspaceID); err != nil {
		return err
	}
	remoteErr := e.onelake.Delete(ctx, k.AccountAlias, k.WorkspaceID, k.ItemID, k.Path, recursive)
	e.observeNetworkResult(remoteErr)
	if remoteErr != nil {
		if e.markPausedIfNeeded(ctx, k.AccountAlias, k.WorkspaceID, remoteErr) {
			e.track(telemetry.Event{
				Name:             eventName,
				AccountAliasHash: telemetry.HashAlias(k.AccountAlias),
				DurationMs:       elapsedMs(start, e.now),
				Success:          boolPtr(false),
				ErrorCode:        telemetry.SafeErrorCode("capacity_paused"),
			})
			return fmt.Errorf("sync.Delete: %w", ErrWorkspacePaused)
		}
		e.track(telemetry.Event{
			Name:             eventName,
			AccountAliasHash: telemetry.HashAlias(k.AccountAlias),
			DurationMs:       elapsedMs(start, e.now),
			Success:          boolPtr(false),
			ErrorCode:        telemetry.SafeErrorCode("delete_failed"),
		})
		return fmt.Errorf("sync.Delete: remote delete: %w", remoteErr)
	}

	if err := e.cache.Delete(ctx, k); err != nil {
		return fmt.Errorf("sync.Delete: cache delete: %w", err)
	}

	e.track(telemetry.Event{
		Name:             eventName,
		AccountAliasHash: telemetry.HashAlias(k.AccountAlias),
		DurationMs:       elapsedMs(start, e.now),
		Success:          boolPtr(true),
	})
	return nil
}
