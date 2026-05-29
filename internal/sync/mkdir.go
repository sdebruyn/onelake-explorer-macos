package sync

import (
	"context"
	"fmt"

	"github.com/sdebruyn/onelake-explorer-macos/internal/cache"
	"github.com/sdebruyn/onelake-explorer-macos/internal/telemetry"
)

// Mkdir creates a directory inside the OneLake item and upserts the
// matching cache row so the directory shows up immediately on the next
// Enumerate without waiting for the parent's TTL to elapse.
//
// Telemetry: emits folder_create with durationMs and success.
func (e *Engine) Mkdir(ctx context.Context, k cache.Key) error {
	start := e.now()

	if err := e.guardPausedWorkspace(ctx, k.AccountAlias, k.WorkspaceID); err != nil {
		return err
	}

	mkdirErr := e.onelake.CreateDirectory(ctx, k.AccountAlias, k.WorkspaceID, k.ItemID, k.Path)
	e.observeNetworkResult(mkdirErr)
	if mkdirErr != nil {
		if e.markPausedIfNeeded(ctx, k.AccountAlias, k.WorkspaceID, mkdirErr) {
			e.track(telemetry.Event{
				Name:             "folder_create",
				AccountAliasHash: telemetry.HashAlias(k.AccountAlias),
				DurationMs:       elapsedMs(start, e.now),
				Success:          boolPtr(false),
				ErrorCode:        telemetry.SafeErrorCode("capacity_paused"),
			})
			return fmt.Errorf("sync.Mkdir: %w", ErrWorkspacePaused)
		}
		e.track(telemetry.Event{
			Name:             "folder_create",
			AccountAliasHash: telemetry.HashAlias(k.AccountAlias),
			DurationMs:       elapsedMs(start, e.now),
			Success:          boolPtr(false),
			ErrorCode:        telemetry.SafeErrorCode("mkdir_failed"),
		})
		return fmt.Errorf("sync.Mkdir: remote: %w", mkdirErr)
	}

	now := e.now()
	row := cache.Entry{
		Key:          k,
		ParentPath:   parentPath(k.Path),
		Name:         baseName(k.Path),
		IsDir:        true,
		LastAccessed: now,
		SyncedAt:     now,
	}
	if err := e.cache.Put(ctx, row); err != nil {
		return fmt.Errorf("sync.Mkdir: cache put: %w", err)
	}

	e.track(telemetry.Event{
		Name:             "folder_create",
		AccountAliasHash: telemetry.HashAlias(k.AccountAlias),
		DurationMs:       elapsedMs(start, e.now),
		Success:          boolPtr(true),
	})
	return nil
}
