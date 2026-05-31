package sync

import (
	"context"
	"fmt"
	"time"

	"github.com/sdebruyn/onelake-explorer-macos/internal/cache"
	"github.com/sdebruyn/onelake-explorer-macos/internal/fabric"
	"github.com/sdebruyn/onelake-explorer-macos/internal/telemetry"
)

// VirtualWorkspaceID is the placeholder used as workspace_id when
// caching the top-level "list of workspaces" for an account. The cache
// schema requires every key to have a non-empty workspace_id; this
// constant keeps that invariant satisfied while staying obviously
// distinct from a real GUID.
//
// Exported so the fp package (and any future consumer) can reference
// the same value without duplicating the string literal.
const VirtualWorkspaceID = "__workspaces__"

// VirtualItemID mirrors VirtualWorkspaceID for the cache rows backing
// per-workspace item listings. Same reasoning.
//
// Exported for the same reason as VirtualWorkspaceID.
const VirtualItemID = "__items__"

// ListWorkspaces returns the workspaces visible to the given account.
// The result is also written to the cache so offline enumeration of
// the top-level OneLake folder works.
//
// Cached rows whose SyncedAt is older than RecentFolderTTL and that no
// longer appear in the freshly fetched list are removed — that way a
// workspace the user has lost access to (or a tenant the user revoked)
// stops surfacing in the local view once the daemon's next discovery
// pass runs. The reconciliation is best-effort; cache write errors are
// logged and do not fail the call.
//
// Telemetry: emits workspace_list with durationMs and success.
func (e *Engine) ListWorkspaces(ctx context.Context, alias string) ([]fabric.Workspace, error) {
	start := e.now()

	ws, err := e.fabric.ListWorkspaces(ctx, alias)
	e.observeNetworkResult(err)
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
	parentKey := cache.Key{
		AccountAlias: alias,
		WorkspaceID:  VirtualWorkspaceID,
		ItemID:       VirtualWorkspaceID,
		Path:         "",
	}
	root := cache.Entry{
		Key:          parentKey,
		IsDir:        true,
		Name:         alias,
		SyncedAt:     now,
		LastAccessed: now,
	}
	if perr := e.cache.Put(ctx, root); perr != nil {
		e.logger.Warn("workspace_list cache stamp parent failed", "alias", alias, "err", perr)
	}
	seen := make(map[string]struct{}, len(ws))
	for _, w := range ws {
		seen[w.ID] = struct{}{}
		row := cache.Entry{
			Key: cache.Key{
				AccountAlias: alias,
				WorkspaceID:  VirtualWorkspaceID,
				ItemID:       VirtualWorkspaceID,
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

	e.expireDiscoveryRows(ctx, parentKey, seen, now)

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
// As with ListWorkspaces, cached item rows whose SyncedAt is older than
// RecentFolderTTL and that are no longer reported by Fabric are dropped
// so deleted or access-revoked items eventually disappear from the
// local view.
//
// Telemetry: emits item_list with durationMs and success.
func (e *Engine) ListItems(ctx context.Context, alias, workspaceID string) ([]fabric.Item, error) {
	start := e.now()

	items, err := e.fabric.ListItems(ctx, alias, workspaceID)
	e.observeNetworkResult(err)
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
	parentKey := cache.Key{
		AccountAlias: alias,
		WorkspaceID:  workspaceID,
		ItemID:       VirtualItemID,
		Path:         "",
	}
	root := cache.Entry{
		Key:          parentKey,
		IsDir:        true,
		Name:         workspaceID,
		SyncedAt:     now,
		LastAccessed: now,
	}
	if perr := e.cache.Put(ctx, root); perr != nil {
		e.logger.Warn("item_list cache stamp parent failed", "workspace", workspaceID, "err", perr)
	}
	seen := make(map[string]struct{}, len(items))
	for _, it := range items {
		seen[it.ID] = struct{}{}
		row := cache.Entry{
			Key: cache.Key{
				AccountAlias: alias,
				WorkspaceID:  workspaceID,
				ItemID:       VirtualItemID,
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

	e.expireDiscoveryRows(ctx, parentKey, seen, now)

	e.track(telemetry.Event{
		Name:             "item_list",
		AccountAliasHash: telemetry.HashAlias(alias),
		DurationMs:       elapsedMs(start, e.now),
		Success:          boolPtr(true),
	})
	return items, nil
}

// expireDiscoveryRows removes children of parent whose ID is not in seen
// and whose SyncedAt is older than RecentFolderTTL. The TTL guard exists
// so that a workspace which was momentarily missing from a single 200
// (eventual consistency on the Fabric side) does not get evicted on the
// very next call — it has to be absent for at least RecentFolderTTL.
// Errors are logged at warn level; reconciliation never fails the call.
func (e *Engine) expireDiscoveryRows(ctx context.Context, parent cache.Key, seen map[string]struct{}, now time.Time) {
	kids, err := e.cache.Children(ctx, parent)
	if err != nil {
		e.logger.Warn("discovery cache reconciliation: read children failed",
			"workspace", parent.WorkspaceID, "err", err)
		return
	}
	for _, k := range kids {
		if _, ok := seen[k.Path]; ok {
			continue
		}
		if !k.SyncedAt.IsZero() && now.Sub(k.SyncedAt) < e.recentFolderTTL {
			continue
		}
		if err := e.cache.Delete(ctx, k.Key); err != nil {
			e.logger.Warn("discovery cache reconciliation: delete failed",
				"path", k.Path, "err", err)
		}
	}
}
