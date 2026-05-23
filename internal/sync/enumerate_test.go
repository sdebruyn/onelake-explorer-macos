package sync

import (
	"context"
	"net/http"
	"testing"
	"time"

	"github.com/jarcoal/httpmock"

	"github.com/sdebruyn/onelake-explorer-macos/internal/cache"
)

// TestEnumerate_CacheHit verifies that a freshly populated cache returns
// without contacting OneLake. We assert zero token requests after the
// initial RefreshFolder.
func TestEnumerate_CacheHit(t *testing.T) {

	f := newEngine(t)
	ctx := context.Background()

	// One responder for the initial refresh.
	httpmock.RegisterResponder("GET", "=~^"+testOneLakeBase+"/"+testWorkspaceID+`\?.*$`,
		func(req *http.Request) (*http.Response, error) {
			return httpmock.NewJsonResponse(200, map[string]any{
				"paths": []map[string]any{
					{"name": testItemID + "/Files/a.csv", "contentLength": "12", "etag": "e1"},
					{"name": testItemID + "/Files/sub", "isDirectory": "true"},
				},
			})
		})

	parent := cache.Key{AccountAlias: testAlias, WorkspaceID: testWorkspaceID, ItemID: testItemID, Path: "Files"}
	if _, err := f.engine.Enumerate(ctx, parent); err != nil {
		t.Fatalf("first Enumerate (refresh): %v", err)
	}
	initialTokenCalls := f.tp.Calls()
	initialHTTPCalls := httpmock.GetTotalCallCount()

	// Second Enumerate within the TTL window must not touch the network.
	entries, err := f.engine.Enumerate(ctx, parent)
	if err != nil {
		t.Fatalf("cache-hit Enumerate: %v", err)
	}
	if got := f.tp.Calls(); got != initialTokenCalls {
		t.Errorf("token calls jumped to %d (was %d) on cache hit", got, initialTokenCalls)
	}
	if got := httpmock.GetTotalCallCount(); got != initialHTTPCalls {
		t.Errorf("HTTP calls jumped to %d (was %d) on cache hit", got, initialHTTPCalls)
	}
	if len(entries) != 2 {
		t.Errorf("entries = %d, want 2", len(entries))
	}

	events := f.drainEvents(t)
	found := 0
	for _, ev := range events {
		if ev.Name == "folder_list" {
			found++
		}
	}
	if found != 2 {
		t.Errorf("folder_list emitted %d times, want 2", found)
	}
}

// TestEnumerate_CacheMissCallsRemote verifies the first call lists from
// OneLake and writes the cache rows.
func TestEnumerate_CacheMissCallsRemote(t *testing.T) {

	f := newEngine(t)
	ctx := context.Background()

	httpmock.RegisterResponder("GET", "=~^"+testOneLakeBase+"/"+testWorkspaceID+`\?.*$`,
		func(req *http.Request) (*http.Response, error) {
			return httpmock.NewJsonResponse(200, map[string]any{
				"paths": []map[string]any{
					{"name": testItemID + "/Files/a.csv", "contentLength": "12", "etag": "e1"},
				},
			})
		})

	parent := cache.Key{AccountAlias: testAlias, WorkspaceID: testWorkspaceID, ItemID: testItemID, Path: "Files"}
	entries, err := f.engine.Enumerate(ctx, parent)
	if err != nil {
		t.Fatalf("Enumerate: %v", err)
	}
	if len(entries) != 1 || entries[0].Name != "a.csv" || entries[0].ContentLength != 12 {
		t.Errorf("unexpected entries: %+v", entries)
	}

	got, err := f.cache.Get(ctx, cache.Key{
		AccountAlias: testAlias, WorkspaceID: testWorkspaceID, ItemID: testItemID,
		Path: "Files/a.csv",
	})
	if err != nil {
		t.Fatalf("cache.Get: %v", err)
	}
	if got.Etag != "e1" {
		t.Errorf("cached etag = %q, want e1", got.Etag)
	}
}

// TestEnumerate_StaleRefreshes verifies that aging the clock past the
// RecentFolderTTL forces a remote refresh.
func TestEnumerate_StaleRefreshes(t *testing.T) {

	f := newEngine(t)
	ctx := context.Background()

	calls := 0
	httpmock.RegisterResponder("GET", "=~^"+testOneLakeBase+"/"+testWorkspaceID+`\?.*$`,
		func(req *http.Request) (*http.Response, error) {
			calls++
			return httpmock.NewJsonResponse(200, map[string]any{
				"paths": []map[string]any{
					{"name": testItemID + "/Files/a.csv"},
				},
			})
		})

	parent := cache.Key{AccountAlias: testAlias, WorkspaceID: testWorkspaceID, ItemID: testItemID, Path: "Files"}
	if _, err := f.engine.Enumerate(ctx, parent); err != nil {
		t.Fatalf("first Enumerate: %v", err)
	}
	if _, err := f.engine.Enumerate(ctx, parent); err != nil {
		t.Fatalf("second Enumerate: %v", err)
	}
	if calls != 1 {
		t.Errorf("HTTP calls after warm cache = %d, want 1", calls)
	}

	f.now.Add(6 * time.Minute) // past RecentFolderTTL.
	if _, err := f.engine.Enumerate(ctx, parent); err != nil {
		t.Fatalf("post-expiry Enumerate: %v", err)
	}
	if calls != 2 {
		t.Errorf("HTTP calls after expiry = %d, want 2", calls)
	}
}

// TestRefreshFolder_DropsLocallyCachedEntriesGoneRemotely covers the
// reconciliation: a row that the cache has but the remote no longer
// reports must be removed.
func TestRefreshFolder_DropsLocallyCachedEntriesGoneRemotely(t *testing.T) {

	f := newEngine(t)
	ctx := context.Background()

	// First response has two files; later response only one.
	listResponses := [][]map[string]any{
		{
			{"name": testItemID + "/Files/keep.csv", "etag": "k1"},
			{"name": testItemID + "/Files/gone.csv", "etag": "g1"},
		},
		{
			{"name": testItemID + "/Files/keep.csv", "etag": "k2"},
		},
	}
	idx := 0
	httpmock.RegisterResponder("GET", "=~^"+testOneLakeBase+"/"+testWorkspaceID+`\?.*$`,
		func(req *http.Request) (*http.Response, error) {
			resp, err := httpmock.NewJsonResponse(200, map[string]any{
				"paths": listResponses[idx],
			})
			idx++
			return resp, err
		})

	parent := cache.Key{AccountAlias: testAlias, WorkspaceID: testWorkspaceID, ItemID: testItemID, Path: "Files"}
	if _, err := f.engine.RefreshFolder(ctx, parent); err != nil {
		t.Fatalf("first RefreshFolder: %v", err)
	}

	// Sanity: both files should be in the cache after first refresh.
	kids, err := f.cache.Children(ctx, parent)
	if err != nil {
		t.Fatalf("Children: %v", err)
	}
	if len(kids) != 2 {
		t.Fatalf("cached children after first refresh = %d, want 2", len(kids))
	}

	diff, err := f.engine.RefreshFolder(ctx, parent)
	if err != nil {
		t.Fatalf("second RefreshFolder: %v", err)
	}
	if diff.Removed != 1 {
		t.Errorf("diff.Removed = %d, want 1", diff.Removed)
	}
	if diff.Updated != 1 {
		t.Errorf("diff.Updated = %d, want 1 (keep.csv etag changed)", diff.Updated)
	}

	if _, err := f.cache.Get(ctx, cache.Key{
		AccountAlias: testAlias, WorkspaceID: testWorkspaceID, ItemID: testItemID,
		Path: "Files/gone.csv",
	}); err == nil {
		t.Error("gone.csv should be deleted from cache")
	}
}

// TestEnumerate_TelemetryEmitted asserts the folder_list event lands in
// the sink with the expected properties.
func TestEnumerate_TelemetryEmitted(t *testing.T) {

	f := newEngine(t)
	ctx := context.Background()

	httpmock.RegisterResponder("GET", "=~^"+testOneLakeBase+"/"+testWorkspaceID+`\?.*$`,
		httpmock.NewStringResponder(200, `{"paths":[]}`))

	parent := cache.Key{AccountAlias: testAlias, WorkspaceID: testWorkspaceID, ItemID: testItemID, Path: "Files"}
	if _, err := f.engine.Enumerate(ctx, parent); err != nil {
		t.Fatalf("Enumerate: %v", err)
	}
	events := f.drainEvents(t)
	ev := findEvent(t, events, "folder_list")
	if ev.Success == nil || !*ev.Success {
		t.Errorf("folder_list.success = %v, want true", ev.Success)
	}
	if ev.AccountAliasHash == "" {
		t.Error("AccountAliasHash empty")
	}
}
