package sync

import (
	"context"
	"net/http"
	"testing"

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
