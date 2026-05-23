package sync

import (
	"context"
	"errors"
	"net/http"
	"os"
	"testing"

	"github.com/jarcoal/httpmock"

	"github.com/sdebruyn/onelake-explorer-macos/internal/cache"
)

// TestDelete_FileRemovesRemoteAndCache covers the file path: telemetry
// must come out as file_delete (not folder_delete) when the cached row
// says it is a regular file.
func TestDelete_FileRemovesRemoteAndCache(t *testing.T) {

	f := newEngine(t)
	ctx := context.Background()

	k := cache.Key{AccountAlias: testAlias, WorkspaceID: testWorkspaceID, ItemID: testItemID, Path: "Files/del.txt"}
	if err := f.cache.Put(ctx, cache.Entry{Key: k, Name: "del.txt", ParentPath: "Files"}); err != nil {
		t.Fatalf("seed: %v", err)
	}

	called := false
	httpmock.RegisterResponder("DELETE", "=~^"+testOneLakeBase+"/"+testWorkspaceID+"/"+testItemID+`/Files/del\.txt(\?.*)?$`,
		func(req *http.Request) (*http.Response, error) {
			called = true
			if req.URL.Query().Get("recursive") == "true" {
				t.Errorf("non-directory delete should not be recursive")
			}
			return httpmock.NewStringResponse(200, ""), nil
		})

	if err := f.engine.Delete(ctx, k); err != nil {
		t.Fatalf("Delete: %v", err)
	}
	if !called {
		t.Error("remote DELETE not called")
	}

	if _, err := f.cache.Get(ctx, k); !errors.Is(err, os.ErrNotExist) {
		t.Errorf("cache row still present: %v", err)
	}

	ev := findEvent(t, f.drainEvents(t), "file_delete")
	if ev.Success == nil || !*ev.Success {
		t.Errorf("file_delete success = %v", ev.Success)
	}
}

// TestDelete_DirectoryIsRecursive verifies recursive flag and the
// folder_delete telemetry event.
func TestDelete_DirectoryIsRecursive(t *testing.T) {

	f := newEngine(t)
	ctx := context.Background()

	k := cache.Key{AccountAlias: testAlias, WorkspaceID: testWorkspaceID, ItemID: testItemID, Path: "Files/sub"}
	if err := f.cache.Put(ctx, cache.Entry{Key: k, Name: "sub", ParentPath: "Files", IsDir: true}); err != nil {
		t.Fatalf("seed: %v", err)
	}

	httpmock.RegisterResponder("DELETE", "=~^"+testOneLakeBase+`.*`,
		func(req *http.Request) (*http.Response, error) {
			if req.URL.Query().Get("recursive") != "true" {
				t.Errorf("directory delete should be recursive, query = %q", req.URL.RawQuery)
			}
			return httpmock.NewStringResponse(200, ""), nil
		})

	if err := f.engine.Delete(ctx, k); err != nil {
		t.Fatalf("Delete: %v", err)
	}
	ev := findEvent(t, f.drainEvents(t), "folder_delete")
	if ev.Success == nil || !*ev.Success {
		t.Errorf("folder_delete success = %v", ev.Success)
	}
}

// TestDelete_MacOSMetadataLocalOnly verifies that .DS_Store and friends
// never reach OneLake on the delete path either.
func TestDelete_MacOSMetadataLocalOnly(t *testing.T) {

	f := newEngine(t)
	ctx := context.Background()

	httpmock.RegisterResponder("DELETE", "=~^"+testOneLakeBase+`.*`,
		func(req *http.Request) (*http.Response, error) {
			t.Errorf("unexpected remote DELETE for macOS metadata: %s", req.URL.String())
			return httpmock.NewStringResponse(500, ""), nil
		})

	k := cache.Key{AccountAlias: testAlias, WorkspaceID: testWorkspaceID, ItemID: testItemID, Path: "Files/.DS_Store"}
	if err := f.engine.Delete(ctx, k); err != nil {
		t.Fatalf("Delete: %v", err)
	}
}
