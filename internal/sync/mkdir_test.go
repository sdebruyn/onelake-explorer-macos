package sync

import (
	"context"
	"net/http"
	"testing"

	"github.com/jarcoal/httpmock"

	"github.com/sdebruyn/onelake-explorer-macos/internal/cache"
)

// TestMkdir_CreatesRemoteAndCache asserts the remote directory create
// + cache upsert path.
func TestMkdir_CreatesRemoteAndCache(t *testing.T) {

	f := newEngine(t)
	ctx := context.Background()

	called := false
	httpmock.RegisterResponder("PUT", "=~^"+testOneLakeBase+"/"+testWorkspaceID+"/"+testItemID+`/Files/new\?.*$`,
		func(req *http.Request) (*http.Response, error) {
			called = true
			if req.URL.Query().Get("resource") != "directory" {
				t.Errorf("resource = %q, want directory", req.URL.Query().Get("resource"))
			}
			return httpmock.NewStringResponse(201, ""), nil
		})

	k := cache.Key{AccountAlias: testAlias, WorkspaceID: testWorkspaceID, ItemID: testItemID, Path: "Files/new"}
	if err := f.engine.Mkdir(ctx, k); err != nil {
		t.Fatalf("Mkdir: %v", err)
	}
	if !called {
		t.Error("remote create directory not called")
	}

	got, err := f.cache.Get(ctx, k)
	if err != nil {
		t.Fatalf("Get: %v", err)
	}
	if !got.IsDir {
		t.Error("cache entry is not a directory")
	}

	ev := findEvent(t, f.drainEvents(t), "folder_create")
	if ev.Success == nil || !*ev.Success {
		t.Errorf("folder_create success = %v", ev.Success)
	}
}
