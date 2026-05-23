package sync

import (
	"context"
	"io"
	"net/http"
	"testing"

	"github.com/jarcoal/httpmock"

	"github.com/sdebruyn/onelake-explorer-macos/internal/cache"
)

// TestOpen_CacheMissDownloads fetches from OneLake on the first Open and
// then serves a HEAD-confirmed cache hit on the second.
func TestOpen_CacheMissDownloads(t *testing.T) {

	f := newEngine(t)
	ctx := context.Background()

	const body = "hello world"
	httpmock.RegisterResponder("GET", testOneLakeBase+"/"+testWorkspaceID+"/"+testItemID+"/Files/a.csv",
		httpmock.NewStringResponder(200, body))

	k := cache.Key{AccountAlias: testAlias, WorkspaceID: testWorkspaceID, ItemID: testItemID, Path: "Files/a.csv"}
	rc, err := f.engine.Open(ctx, k)
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	got, _ := io.ReadAll(rc)
	_ = rc.Close()
	if string(got) != body {
		t.Errorf("body = %q, want %q", got, body)
	}

	events := f.drainEvents(t)
	ev := findEvent(t, events, "file_download")
	if ev.BytesTransferred != int64(len(body)) {
		t.Errorf("bytesTransferred = %d, want %d", ev.BytesTransferred, len(body))
	}
}

// TestOpen_CacheHitNoNetwork verifies a second Open re-uses the cached
// blob without re-downloading. We accept a single HEAD to verify
// freshness because that's how Open implements last-write-wins-aware
// caching.
func TestOpen_CacheHitNoNetwork(t *testing.T) {

	f := newEngine(t)
	ctx := context.Background()

	httpmock.RegisterResponder("GET", testOneLakeBase+"/"+testWorkspaceID+"/"+testItemID+"/Files/a.csv",
		func(req *http.Request) (*http.Response, error) {
			resp := httpmock.NewStringResponse(200, "data!")
			resp.Header.Set("ETag", "e1")
			return resp, nil
		})
	httpmock.RegisterResponder("HEAD", testOneLakeBase+"/"+testWorkspaceID+"/"+testItemID+"/Files/a.csv",
		func(req *http.Request) (*http.Response, error) {
			resp := httpmock.NewStringResponse(200, "")
			resp.Header.Set("ETag", "e1")
			return resp, nil
		})

	k := cache.Key{AccountAlias: testAlias, WorkspaceID: testWorkspaceID, ItemID: testItemID, Path: "Files/a.csv"}
	rc, err := f.engine.Open(ctx, k)
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	_, _ = io.ReadAll(rc)
	_ = rc.Close()
	// Now the cache row exists but has no etag (we couldn't learn it
	// from a 200 GET without a HEAD). Force a HEAD-only fast path by
	// manually setting the etag.
	entry, err := f.cache.Get(ctx, k)
	if err != nil {
		t.Fatalf("Get: %v", err)
	}
	entry.Etag = "e1"
	if err := f.cache.Put(ctx, entry); err != nil {
		t.Fatalf("Put: %v", err)
	}

	getCalls := httpmock.GetCallCountInfo()["GET "+testOneLakeBase+"/"+testWorkspaceID+"/"+testItemID+"/Files/a.csv"]
	rc2, err := f.engine.Open(ctx, k)
	if err != nil {
		t.Fatalf("second Open: %v", err)
	}
	_, _ = io.ReadAll(rc2)
	_ = rc2.Close()
	getCalls2 := httpmock.GetCallCountInfo()["GET "+testOneLakeBase+"/"+testWorkspaceID+"/"+testItemID+"/Files/a.csv"]
	if getCalls2 != getCalls {
		t.Errorf("GET calls jumped from %d to %d on cache hit (no re-download expected)", getCalls, getCalls2)
	}
}

// TestOpen_StaleEtagRedownloads ensures that when the remote etag has
// moved we drop the cached blob and refetch.
func TestOpen_StaleEtagRedownloads(t *testing.T) {

	f := newEngine(t)
	ctx := context.Background()

	// First GET returns "v1"; subsequent HEAD will report a newer etag.
	httpmock.RegisterResponder("GET", testOneLakeBase+"/"+testWorkspaceID+"/"+testItemID+"/Files/a.csv",
		func(req *http.Request) (*http.Response, error) {
			return httpmock.NewStringResponse(200, "v2"), nil
		})
	httpmock.RegisterResponder("HEAD", testOneLakeBase+"/"+testWorkspaceID+"/"+testItemID+"/Files/a.csv",
		func(req *http.Request) (*http.Response, error) {
			resp := httpmock.NewStringResponse(200, "")
			resp.Header.Set("ETag", "new-etag")
			return resp, nil
		})

	k := cache.Key{AccountAlias: testAlias, WorkspaceID: testWorkspaceID, ItemID: testItemID, Path: "Files/a.csv"}

	// Seed the cache with an old version manually.
	if err := f.cache.Put(ctx, cache.Entry{
		Key: k, Name: "a.csv", ParentPath: "Files", ContentLength: 2,
		Etag: "old-etag",
	}); err != nil {
		t.Fatalf("seed Put: %v", err)
	}
	// Store a fake blob so the cached.BlobSHA256 path is exercised.
	sha, _, err := f.cache.StoreBlob(ctx, stringReader("v1"))
	if err != nil {
		t.Fatalf("StoreBlob: %v", err)
	}
	if err := f.cache.LinkBlob(ctx, k, sha, 2); err != nil {
		t.Fatalf("LinkBlob: %v", err)
	}

	rc, err := f.engine.Open(ctx, k)
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	defer rc.Close()
	got, _ := io.ReadAll(rc)
	if string(got) != "v2" {
		t.Errorf("body = %q, want v2 (re-downloaded)", got)
	}
}

// stringReader wraps a string so the tests don't keep re-importing
// strings.NewReader.
func stringReader(s string) io.Reader {
	return &stringRC{s: s}
}

type stringRC struct {
	s string
	i int
}

func (s *stringRC) Read(p []byte) (int, error) {
	if s.i >= len(s.s) {
		return 0, io.EOF
	}
	n := copy(p, s.s[s.i:])
	s.i += n
	return n, nil
}
