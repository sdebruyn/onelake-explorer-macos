package sync

import (
	"context"
	"fmt"

	"github.com/sdebruyn/onelake-explorer-macos/internal/cache"
	"github.com/sdebruyn/onelake-explorer-macos/internal/fabric"
	"github.com/sdebruyn/onelake-explorer-macos/internal/telemetry"
)

// virtualWorkspaceID is the placeholder used as workspace_id when
// caching the top-level "list of workspaces" for an account. The cache
// schema requires every key to have a non-empty workspace_id; this
// constant keeps that invariant satisfied while staying obviously
// distinct from a real GUID.
const virtualWorkspaceID = "__workspaces__"

// virtualItemID mirrors virtualWorkspaceID for the cache rows backing
// per-workspace item listings. Same reasoning.
const virtualItemID = "__items__"

// ListWorkspaces returns the workspaces visible to the given account.
// The result is also written to the cache so offline enumeration of
// the top-level OneLake folder works.
//
// Telemetry: emits workspace_list with durationMs and success.
func (e *Engine) ListWorkspaces(ctx context.Context, alias string) ([]fabric.Workspace, error) {
	start := e.now()

	ws, err := e.fabric.ListWorkspaces(ctx, alias)
	if err != nil {
		e.track(telemetry.Event{
			Name:             "workspace_list",
			AccountAliasHash: telemetry.HashAlias(alias),
			DurationMs:       elapsedMs(start, e.now),
			Success:          boolPtr(false),
			ErrorCode:        telemetry.SafeErrorCode("list_failed"),
		})
		return nil, fmt.Errorf("sync.ListWorkspaces: %w", err)
	}

	// Stamp the virtual parent and one row per workspace.
	now := e.now()
	root := cache.Entry{
		Key: cache.Key{
			AccountAlias: alias,
			WorkspaceID:  virtualWorkspaceID,
			ItemID:       virtualWorkspaceID,
			Path:         "",
		},
		IsDir:        true,
		Name:         alias,
		SyncedAt:     now,
		LastAccessed: now,
	}
	if perr := e.cache.Put(ctx, root); perr != nil {
		e.logger.Warn("workspace_list cache stamp parent failed", "alias", alias, "err", perr)
	}
	for _, w := range ws {
		row := cache.Entry{
			Key: cache.Key{
				AccountAlias: alias,
				WorkspaceID:  virtualWorkspaceID,
				ItemID:       virtualWorkspaceID,
				Path:         w.ID,
			},
			ParentPath:   "",
			Name:         w.DisplayName,
			IsDir:        true,
			SyncedAt:     now,
			LastAccessed: now,
		}
		if perr := e.cache.Put(ctx, row); perr != nil {
			e.logger.Warn("workspace_list cache put failed", "workspace", w.ID, "err", perr)
		}
	}

	e.track(telemetry.Event{
		Name:             "workspace_list",
		AccountAliasHash: telemetry.HashAlias(alias),
		DurationMs:       elapsedMs(start, e.now),
		Success:          boolPtr(true),
	})
	return ws, nil
}

// ListItems returns the items inside a workspace. The result is also
// written to the cache so offline enumeration works.
//
// Telemetry: emits item_list with durationMs and success.
func (e *Engine) ListItems(ctx context.Context, alias, workspaceID string) ([]fabric.Item, error) {
	start := e.now()

	items, err := e.fabric.ListItems(ctx, alias, workspaceID)
	if err != nil {
		e.track(telemetry.Event{
			Name:             "item_list",
			AccountAliasHash: telemetry.HashAlias(alias),
			DurationMs:       elapsedMs(start, e.now),
			Success:          boolPtr(false),
			ErrorCode:        telemetry.SafeErrorCode("list_failed"),
		})
		return nil, fmt.Errorf("sync.ListItems: %w", err)
	}

	now := e.now()
	root := cache.Entry{
		Key: cache.Key{
			AccountAlias: alias,
			WorkspaceID:  workspaceID,
			ItemID:       virtualItemID,
			Path:         "",
		},
		IsDir:        true,
		Name:         workspaceID,
		SyncedAt:     now,
		LastAccessed: now,
	}
	if perr := e.cache.Put(ctx, root); perr != nil {
		e.logger.Warn("item_list cache stamp parent failed", "workspace", workspaceID, "err", perr)
	}
	for _, it := range items {
		row := cache.Entry{
			Key: cache.Key{
				AccountAlias: alias,
				WorkspaceID:  workspaceID,
				ItemID:       virtualItemID,
				Path:         it.ID,
			},
			ParentPath:   "",
			Name:         it.DisplayName,
			IsDir:        true,
			SyncedAt:     now,
			LastAccessed: now,
		}
		if perr := e.cache.Put(ctx, row); perr != nil {
			e.logger.Warn("item_list cache put failed", "item", it.ID, "err", perr)
		}
	}

	e.track(telemetry.Event{
		Name:             "item_list",
		AccountAliasHash: telemetry.HashAlias(alias),
		DurationMs:       elapsedMs(start, e.now),
		Success:          boolPtr(true),
	})
	return items, nil
}
