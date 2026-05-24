package sync

import (
	"context"
	"errors"
	"net/http"
	"strings"
	"sync/atomic"
	"testing"

	"github.com/jarcoal/httpmock"

	"github.com/sdebruyn/onelake-explorer-macos/internal/cache"
)

// TestPut_412RetriesUpToCapAndDrops models the livelock case: the
// remote keeps returning 412 on the create-file step. After
// maxLastWriteWinsCycles cycles we drop the local change and surface
// ErrLastWriteWinsExhausted. There must be NO conflict copy on disk
// or in the lake (no extra PUT to a sibling path).
func TestPut_412RetriesUpToCapAndDrops(t *testing.T) {
	f := newEngine(t)
	ctx := context.Background()

	var putCalls int32
	httpmock.RegisterResponder("PUT", "=~^"+testOneLakeBase+`.*`,
		func(req *http.Request) (*http.Response, error) {
			atomic.AddInt32(&putCalls, 1)
			return httpmock.NewStringResponse(412, "precondition failed"), nil
		})
	// HEAD is what uploadWithLastWriteWins issues between cycles to
	// resync the cache row with the freshest etag.
	httpmock.RegisterResponder("HEAD", "=~^"+testOneLakeBase+`.*`,
		func(_ *http.Request) (*http.Response, error) {
			resp := httpmock.NewStringResponse(200, "")
			resp.Header.Set("ETag", "remote-etag-new")
			return resp, nil
		})
	// PATCH responders so the append/flush chain does not 404 if it
	// ever reaches that point (it should not for the 412-on-create case).
	httpmock.RegisterResponder("PATCH", "=~^"+testOneLakeBase+`.*`,
		httpmock.NewStringResponder(202, ""))

	k := cache.Key{AccountAlias: testAlias, WorkspaceID: testWorkspaceID, ItemID: testItemID, Path: "Files/race.txt"}
	err := f.engine.Put(ctx, k, strings.NewReader("payload"), 7)
	if err == nil {
		t.Fatal("Put: want error, got nil")
	}
	if !errors.Is(err, ErrLastWriteWinsExhausted) {
		t.Fatalf("want ErrLastWriteWinsExhausted, got %v", err)
	}
	want := int32(maxLastWriteWinsCycles + 1)
	if got := atomic.LoadInt32(&putCalls); got != want {
		t.Errorf("PUT calls = %d, want %d", got, want)
	}
}

// TestPut_412ResolvesWithinCap verifies the happy path: 412 on the
// first attempt, success on the second, no exhaustion error.
func TestPut_412ResolvesWithinCap(t *testing.T) {
	f := newEngine(t)
	ctx := context.Background()

	var putCalls int32
	httpmock.RegisterResponder("PUT", "=~^"+testOneLakeBase+`.*`,
		func(_ *http.Request) (*http.Response, error) {
			n := atomic.AddInt32(&putCalls, 1)
			if n == 1 {
				return httpmock.NewStringResponse(412, "precondition failed"), nil
			}
			return httpmock.NewStringResponse(201, ""), nil
		})
	httpmock.RegisterResponder("PATCH", "=~^"+testOneLakeBase+`.*`,
		httpmock.NewStringResponder(202, ""))
	httpmock.RegisterResponder("HEAD", "=~^"+testOneLakeBase+`.*`,
		func(_ *http.Request) (*http.Response, error) {
			resp := httpmock.NewStringResponse(200, "")
			resp.Header.Set("ETag", "remote-etag-new")
			return resp, nil
		})

	k := cache.Key{AccountAlias: testAlias, WorkspaceID: testWorkspaceID, ItemID: testItemID, Path: "Files/happy.txt"}
	if err := f.engine.Put(ctx, k, strings.NewReader("data"), 4); err != nil {
		t.Fatalf("Put: %v", err)
	}
	if got := atomic.LoadInt32(&putCalls); got != 2 {
		t.Errorf("PUT calls = %d, want 2 (one 412, one 201)", got)
	}

	row, err := f.cache.Get(ctx, k)
	if err != nil {
		t.Fatalf("Get: %v", err)
	}
	if row.Etag != "remote-etag-new" {
		t.Errorf("etag = %q, want remote-etag-new", row.Etag)
	}
}
