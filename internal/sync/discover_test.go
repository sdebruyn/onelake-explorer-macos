package sync

import (
	"context"
	"net/http"
	"testing"
	"time"

	"github.com/jarcoal/httpmock"

	"github.com/sdebruyn/onelake-explorer-macos/internal/cache"
)

// TestListWorkspaces_FetchesAndCaches verifies the happy path: the
// Fabric REST endpoint is called, the workspaces are returned, and the
// virtual cache rows are upserted for offline use.
func TestListWorkspaces_FetchesAndCaches(t *testing.T) {

	f := newEngine(t)
	ctx := context.Background()

	httpmock.RegisterResponder("GET", testFabricBase+"/v1/workspaces",
		func(req *http.Request) (*http.Response, error) {
			return httpmock.NewJsonResponse(200, map[string]any{
				"value": []map[string]any{
					{"id": testWorkspaceID, "displayName": "Finance", "type": "Workspace"},
					{"id": testWorkspaceID2, "displayName": "Marketing", "type": "Workspace"},
				},
			})
		})

	ws, err := f.engine.ListWorkspaces(ctx, testAlias)
	if err != nil {
		t.Fatalf("ListWorkspaces: %v", err)
	}
	if len(ws) != 2 {
		t.Fatalf("workspaces = %d, want 2", len(ws))
	}

	// Cached row should exist for each workspace.
	for _, w := range ws {
		if _, err := f.cache.Get(ctx, cache.Key{
			AccountAlias: testAlias,
			WorkspaceID:  virtualWorkspaceID,
			ItemID:       virtualWorkspaceID,
			Path:         w.ID,
		}); err != nil {
			t.Errorf("workspace %s not cached: %v", w.ID, err)
		}
	}

	ev := findEvent(t, f.drainEvents(t), "workspace_list")
	if ev.Success == nil || !*ev.Success {
		t.Errorf("workspace_list success = %v", ev.Success)
	}
}

// TestListItems_FetchesAndCaches is the workspace-scoped counterpart.
func TestListItems_FetchesAndCaches(t *testing.T) {

	f := newEngine(t)
	ctx := context.Background()

	httpmock.RegisterResponder("GET", testFabricBase+"/v1/workspaces/"+testWorkspaceID+"/items",
		func(req *http.Request) (*http.Response, error) {
			return httpmock.NewJsonResponse(200, map[string]any{
				"value": []map[string]any{
					{"id": testItemID, "displayName": "MyLakehouse", "type": "Lakehouse", "workspaceId": testWorkspaceID},
				},
			})
		})

	items, err := f.engine.ListItems(ctx, testAlias, testWorkspaceID)
	if err != nil {
		t.Fatalf("ListItems: %v", err)
	}
	if len(items) != 1 || items[0].ID != testItemID {
		t.Errorf("items = %+v", items)
	}

	if _, err := f.cache.Get(ctx, cache.Key{
		AccountAlias: testAlias,
		WorkspaceID:  testWorkspaceID,
		ItemID:       virtualItemID,
		Path:         testItemID,
	}); err != nil {
		t.Errorf("item not cached: %v", err)
	}

	ev := findEvent(t, f.drainEvents(t), "item_list")
	if ev.Success == nil || !*ev.Success {
		t.Errorf("item_list success = %v", ev.Success)
	}
}

// TestListWorkspaces_ErrorEmitsFailureTelemetry asserts that the failure
// path still emits a workspace_list event.
func TestListWorkspaces_ErrorEmitsFailureTelemetry(t *testing.T) {

	f := newEngine(t)
	ctx := context.Background()

	httpmock.RegisterResponder("GET", testFabricBase+"/v1/workspaces",
		httpmock.NewStringResponder(403, "forbidden"))

	if _, err := f.engine.ListWorkspaces(ctx, testAlias); err == nil {
		t.Fatal("expected error")
	}
	ev := findEvent(t, f.drainEvents(t), "workspace_list")
	if ev.Success == nil || *ev.Success {
		t.Errorf("workspace_list success = %v, want false", ev.Success)
	}
}

// TestListWorkspaces_ExpiresStaleRows verifies the TTL-based eviction:
// a workspace cached on the first call but missing from a later call
// is dropped only once the cached row is older than RecentFolderTTL.
// Within the TTL we keep it (eventual consistency tolerance).
func TestListWorkspaces_ExpiresStaleRows(t *testing.T) {

	f := newEngine(t)
	ctx := context.Background()

	calls := 0
	httpmock.RegisterResponder("GET", testFabricBase+"/v1/workspaces",
		func(req *http.Request) (*http.Response, error) {
			calls++
			if calls == 1 {
				return httpmock.NewJsonResponse(200, map[string]any{
					"value": []map[string]any{
						{"id": testWorkspaceID, "displayName": "Finance", "type": "Workspace"},
						{"id": testWorkspaceID2, "displayName": "Marketing", "type": "Workspace"},
					},
				})
			}
			// Subsequent calls report Marketing only.
			return httpmock.NewJsonResponse(200, map[string]any{
				"value": []map[string]any{
					{"id": testWorkspaceID2, "displayName": "Marketing", "type": "Workspace"},
				},
			})
		})

	if _, err := f.engine.ListWorkspaces(ctx, testAlias); err != nil {
		t.Fatalf("first ListWorkspaces: %v", err)
	}

	// Second call within the TTL window: Finance is missing from the
	// response but the cached row must NOT be evicted yet.
	if _, err := f.engine.ListWorkspaces(ctx, testAlias); err != nil {
		t.Fatalf("second ListWorkspaces: %v", err)
	}
	financeKey := cache.Key{
		AccountAlias: testAlias,
		WorkspaceID:  virtualWorkspaceID,
		ItemID:       virtualWorkspaceID,
		Path:         testWorkspaceID,
	}
	if _, err := f.cache.Get(ctx, financeKey); err != nil {
		t.Errorf("Finance row should still be cached within TTL: %v", err)
	}

	// Advance the clock past RecentFolderTTL and call again; now the
	// row must be gone.
	f.now.Add(6 * time.Minute)
	if _, err := f.engine.ListWorkspaces(ctx, testAlias); err != nil {
		t.Fatalf("third ListWorkspaces: %v", err)
	}
	if _, err := f.cache.Get(ctx, financeKey); err == nil {
		t.Error("Finance row should be evicted past RecentFolderTTL")
	}
}
