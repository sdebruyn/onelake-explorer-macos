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
func (e *Engine) Delete(ctx context.Context, k cache.Key) error {
	start := e.now()

	cached, cachedErr := e.cache.Get(ctx, k)
	if cachedErr != nil && !errors.Is(cachedErr, os.ErrNotExist) {
		return fmt.Errorf("sync.Delete: cache get: %w", cachedErr)
	}
	isDir := cachedErr == nil && cached.IsDir
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

	if err := e.onelake.Delete(ctx, k.AccountAlias, k.WorkspaceID, k.ItemID, k.Path, isDir); err != nil {
		e.track(telemetry.Event{
			Name:             eventName,
			AccountAliasHash: telemetry.HashAlias(k.AccountAlias),
			DurationMs:       elapsedMs(start, e.now),
			Success:          boolPtr(false),
			ErrorCode:        telemetry.SafeErrorCode("delete_failed"),
		})
		return fmt.Errorf("sync.Delete: remote delete: %w", err)
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
