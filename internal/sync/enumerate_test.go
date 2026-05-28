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

// TestRefreshFolder_EmitsSyncPulledWithTenantID asserts that the engine
// stamps sync_pulled events with the tenant GUID resolved via the
// injected TenantResolver, per docs/telemetry.md.
func TestRefreshFolder_EmitsSyncPulledWithTenantID(t *testing.T) {

	f := newEngine(t, func(o *Options) {
		o.Tenants = stubTenants{testAlias: "tenant-guid-work"}
	})
	ctx := context.Background()

	httpmock.RegisterResponder("GET", "=~^"+testOneLakeBase+"/"+testWorkspaceID+`\?.*$`,
		func(req *http.Request) (*http.Response, error) {
			return httpmock.NewJsonResponse(200, map[string]any{
				"paths": []map[string]any{
					{"name": testItemID + "/Files/new.csv", "etag": "e1"},
				},
			})
		})

	parent := cache.Key{AccountAlias: testAlias, WorkspaceID: testWorkspaceID, ItemID: testItemID, Path: "Files"}
	if _, err := f.engine.RefreshFolder(ctx, parent); err != nil {
		t.Fatalf("RefreshFolder: %v", err)
	}

	events := f.drainEvents(t)
	ev := findEvent(t, events, "sync_pulled")
	if ev.TenantID != "tenant-guid-work" {
		t.Errorf("sync_pulled.TenantID = %q, want tenant-guid-work", ev.TenantID)
	}
	if ev.ItemsChanged <= 0 {
		t.Errorf("sync_pulled.ItemsChanged = %d, want >0", ev.ItemsChanged)
	}
}

// TestRefreshFolder_PreservesParentLastAccessed guards against a
// previous bug where every RefreshFolder bumped the parent row's
// LastAccessed to now, which kept system-polled items perpetually "hot"
// in HotItems and caused endless background refresh traffic.
//
// The parent's LastAccessed must reflect the latest user access (via
// cache.Touch on Enumerate), not the most recent system refresh.
func TestRefreshFolder_PreservesParentLastAccessed(t *testing.T) {

	f := newEngine(t)
	ctx := context.Background()

	httpmock.RegisterResponder("GET", "=~^"+testOneLakeBase+"/"+testWorkspaceID+`\?.*$`,
		httpmock.NewStringResponder(200, `{"paths":[]}`))

	parent := cache.Key{AccountAlias: testAlias, WorkspaceID: testWorkspaceID, ItemID: testItemID, Path: "Files"}

	// Seed the parent row with a known-old LastAccessed.
	oldAccess := f.now.Now().Add(-2 * time.Hour)
	if err := f.cache.Put(ctx, cache.Entry{
		Key:          parent,
		Name:         "Files",
		IsDir:        true,
		LastAccessed: oldAccess,
		SyncedAt:     oldAccess,
	}); err != nil {
		t.Fatalf("seed parent: %v", err)
	}

	// A system-initiated refresh should not bump LastAccessed.
	if _, err := f.engine.RefreshFolder(ctx, parent); err != nil {
		t.Fatalf("RefreshFolder: %v", err)
	}

	got, err := f.cache.Get(ctx, parent)
	if err != nil {
		t.Fatalf("Get parent: %v", err)
	}
	if !got.LastAccessed.Equal(oldAccess) {
		t.Errorf("parent.LastAccessed = %v, want preserved %v (system refresh must not bump LRU)",
			got.LastAccessed, oldAccess)
	}
	// SyncedAt, by contrast, must have advanced.
	if !got.SyncedAt.After(oldAccess) {
		t.Errorf("parent.SyncedAt = %v, want > %v (refresh did stamp freshness)",
			got.SyncedAt, oldAccess)
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

// TestRefreshFolder_DirectoryWithTrailingSlash regresses a bug where a
// DFS row reported as "<itemGUID>/Files/sub/" (note the trailing slash)
// was silently dropped because the post-strip relative path retained
// the trailing slash and failed isDirectChild's "no further '/'" check.
// Both the file and the folder must land in the cache.
func TestRefreshFolder_DirectoryWithTrailingSlash(t *testing.T) {

	f := newEngine(t)
	ctx := context.Background()

	httpmock.RegisterResponder("GET", "=~^"+testOneLakeBase+"/"+testWorkspaceID+`\?.*$`,
		func(req *http.Request) (*http.Response, error) {
			return httpmock.NewJsonResponse(200, map[string]any{
				"paths": []map[string]any{
					{"name": testItemID + "/Files/foo.csv", "contentLength": "10", "etag": "e1"},
					{"name": testItemID + "/Files/sub/", "isDirectory": "true"},
				},
			})
		})

	parent := cache.Key{AccountAlias: testAlias, WorkspaceID: testWorkspaceID, ItemID: testItemID, Path: "Files"}
	if _, err := f.engine.RefreshFolder(ctx, parent); err != nil {
		t.Fatalf("RefreshFolder: %v", err)
	}

	kids, err := f.cache.Children(ctx, parent)
	if err != nil {
		t.Fatalf("Children: %v", err)
	}
	if len(kids) != 2 {
		t.Fatalf("cached children = %d (%+v), want 2", len(kids), kids)
	}

	var sawFile, sawDir bool
	for _, k := range kids {
		switch k.Path {
		case "Files/foo.csv":
			sawFile = true
			if k.IsDir {
				t.Errorf("foo.csv flagged as directory")
			}
		case "Files/sub":
			sawDir = true
			if !k.IsDir {
				t.Errorf("sub not flagged as directory")
			}
		default:
			t.Errorf("unexpected cached child: %q", k.Path)
		}
	}
	if !sawFile || !sawDir {
		t.Errorf("missing children: file=%v dir=%v", sawFile, sawDir)
	}
}

// TestStripItemPrefix covers the directory-trailing-slash bug, the root
// case, and the cross-item defensive guard.
func TestStripItemPrefix(t *testing.T) {

	const itemGUID = "22222222-2222-2222-2222-222222222222"

	cases := []struct {
		name    string
		in      string
		guid    string
		wantRel string
		wantOK  bool
	}{
		{name: "file under item", in: itemGUID + "/Files/foo", guid: itemGUID, wantRel: "Files/foo", wantOK: true},
		{name: "directory with trailing slash", in: itemGUID + "/Files/sub/", guid: itemGUID, wantRel: "Files/sub", wantOK: true},
		{name: "root with trailing slash", in: itemGUID + "/", guid: itemGUID, wantRel: "", wantOK: true},
		{name: "root without trailing slash", in: itemGUID, guid: itemGUID, wantRel: "", wantOK: true},
		{name: "leading slash is tolerated", in: "/" + itemGUID + "/Files/foo", guid: itemGUID, wantRel: "Files/foo", wantOK: true},
		{name: "unrelated GUID is rejected", in: "33333333-3333-3333-3333-333333333333/foo", guid: itemGUID, wantRel: "", wantOK: false},
		{
			name:    "shared GUID prefix does not bleed",
			in:      itemGUID + "abcd/Files/foo",
			guid:    itemGUID,
			wantRel: "",
			wantOK:  false,
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			rel, ok := stripItemPrefix(tc.in, tc.guid)
			if rel != tc.wantRel || ok != tc.wantOK {
				t.Errorf("stripItemPrefix(%q, %q) = (%q, %v), want (%q, %v)",
					tc.in, tc.guid, rel, ok, tc.wantRel, tc.wantOK)
			}
		})
	}
}

// TestIsDirectChild covers the predicate at the heart of the listing
// filter: a remote row must be exactly one segment deeper than the
// requested parent.
func TestIsDirectChild(t *testing.T) {
	cases := []struct {
		parent, child string
		want          bool
	}{
		{parent: "", child: "Files", want: true},
		{parent: "", child: "Files/a", want: false},
		{parent: "", child: "", want: false},
		{parent: "Files", child: "Files/a.csv", want: true},
		{parent: "Files", child: "Files/sub", want: true},
		{parent: "Files", child: "Files/sub/inner.csv", want: false},
		{parent: "Files", child: "Files", want: false},
		{parent: "Files", child: "Tables/a.csv", want: false},
		// Defensive: a child whose path starts with parent's name but is a
		// sibling, not a descendant, must not match.
		{parent: "Files", child: "FilesExtra/a.csv", want: false},
	}
	for _, tc := range cases {
		got := isDirectChild(tc.parent, tc.child)
		if got != tc.want {
			t.Errorf("isDirectChild(%q, %q) = %v, want %v", tc.parent, tc.child, got, tc.want)
		}
	}
}

// TestEnumerate_EmptyFolderCachedAfterRefresh is the regression test for
// the empty-folder enumeration cost: once a genuinely empty folder has
// been listed, a second Enumerate within the TTL must serve the empty
// listing from cache WITHOUT another DFS round-trip. Before the
// ChildrenSyncedAt marker, an empty folder re-listed on every read.
func TestEnumerate_EmptyFolderCachedAfterRefresh(t *testing.T) {
	f := newEngine(t)
	ctx := context.Background()

	httpmock.RegisterResponder("GET", "=~^"+testOneLakeBase+"/"+testWorkspaceID+`\?.*$`,
		httpmock.NewStringResponder(200, `{"paths":[]}`))

	empty := cache.Key{AccountAlias: testAlias, WorkspaceID: testWorkspaceID, ItemID: testItemID, Path: "Files/empty"}

	// First Enumerate lists the (empty) folder and stamps ChildrenSyncedAt.
	if got, err := f.engine.Enumerate(ctx, empty); err != nil {
		t.Fatalf("first Enumerate: %v", err)
	} else if len(got) != 0 {
		t.Fatalf("first Enumerate entries = %d, want 0", len(got))
	}
	afterFirst := httpmock.GetTotalCallCount()
	if afterFirst == 0 {
		t.Fatal("expected the first Enumerate to hit the network")
	}

	// Second Enumerate within the TTL must be served from cache: still
	// empty, and no additional HTTP call.
	got, err := f.engine.Enumerate(ctx, empty)
	if err != nil {
		t.Fatalf("second Enumerate: %v", err)
	}
	if len(got) != 0 {
		t.Errorf("second Enumerate entries = %d, want 0", len(got))
	}
	if now := httpmock.GetTotalCallCount(); now != afterFirst {
		t.Errorf("empty folder re-listed on cache hit: HTTP calls %d -> %d", afterFirst, now)
	}
}

// TestEnumerate_DirSeenViaParentRefreshes verifies a directory that was
// only written as a child of its parent's listing (ChildrenSyncedAt == 0)
// is refreshed when first enumerated, rather than reported as empty from
// a SyncedAt that merely reflects the parent listing.
func TestEnumerate_DirSeenViaParentRefreshes(t *testing.T) {
	f := newEngine(t)
	ctx := context.Background()

	httpmock.RegisterResponder("GET", "=~^"+testOneLakeBase+"/"+testWorkspaceID+`\?.*$`,
		func(_ *http.Request) (*http.Response, error) {
			return httpmock.NewJsonResponse(200, map[string]any{
				"paths": []map[string]any{
					{"name": testItemID + "/Files/sub", "isDirectory": "true"},
				},
			})
		})

	// Refresh the parent: this writes the "Files/sub" row with
	// ChildrenSyncedAt == 0 (seen, but never descended into).
	parent := cache.Key{AccountAlias: testAlias, WorkspaceID: testWorkspaceID, ItemID: testItemID, Path: "Files"}
	if _, err := f.engine.Enumerate(ctx, parent); err != nil {
		t.Fatalf("parent Enumerate: %v", err)
	}
	beforeSub := httpmock.GetTotalCallCount()

	// Enumerating the child must refresh (ChildrenSyncedAt == 0), not serve
	// a stale-empty listing.
	sub := cache.Key{AccountAlias: testAlias, WorkspaceID: testWorkspaceID, ItemID: testItemID, Path: "Files/sub"}
	if _, err := f.engine.Enumerate(ctx, sub); err != nil {
		t.Fatalf("sub Enumerate: %v", err)
	}
	if now := httpmock.GetTotalCallCount(); now == beforeSub {
		t.Errorf("child dir seen via parent was not refreshed on first enumerate (HTTP calls stayed at %d)", beforeSub)
	}
}
