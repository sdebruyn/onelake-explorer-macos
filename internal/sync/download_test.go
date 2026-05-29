package sync

import (
	"context"
	"io"
	"net"
	"net/http"
	"strings"
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
// caching. Crucially, the etag must be captured from the initial GET
// response so the second Open hits the HEAD-only fast path without us
// having to manually back-fill the row.
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

	// After the cache-miss path, the row MUST carry the etag harvested
	// from the GET response. Without it the next Open would fall back to
	// the re-download branch every single time.
	entry, err := f.cache.Get(ctx, k)
	if err != nil {
		t.Fatalf("Get: %v", err)
	}
	if entry.Etag != "e1" {
		t.Fatalf("cache row etag = %q after cache-miss download, want %q", entry.Etag, "e1")
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

// TestOpen_CacheMissCapturesEtag is the focused regression for the bug
// where cache-miss never learnt the etag, causing every subsequent Open
// to re-download. The two-Open shape mirrors the user's read pattern in
// Finder: open file once, open again moments later.
func TestOpen_CacheMissCapturesEtag(t *testing.T) {

	f := newEngine(t)
	ctx := context.Background()

	getCount := 0
	httpmock.RegisterResponder("GET", testOneLakeBase+"/"+testWorkspaceID+"/"+testItemID+"/Files/a.csv",
		func(req *http.Request) (*http.Response, error) {
			getCount++
			resp := httpmock.NewStringResponse(200, "blob")
			resp.Header.Set("ETag", "etag-1")
			resp.Header.Set("Content-Type", "text/csv")
			return resp, nil
		})
	httpmock.RegisterResponder("HEAD", testOneLakeBase+"/"+testWorkspaceID+"/"+testItemID+"/Files/a.csv",
		func(req *http.Request) (*http.Response, error) {
			resp := httpmock.NewStringResponse(200, "")
			resp.Header.Set("ETag", "etag-1")
			return resp, nil
		})

	k := cache.Key{AccountAlias: testAlias, WorkspaceID: testWorkspaceID, ItemID: testItemID, Path: "Files/a.csv"}

	rc, err := f.engine.Open(ctx, k)
	if err != nil {
		t.Fatalf("first Open: %v", err)
	}
	_, _ = io.ReadAll(rc)
	_ = rc.Close()
	if getCount != 1 {
		t.Fatalf("first Open GETs = %d, want 1", getCount)
	}

	entry, err := f.cache.Get(ctx, k)
	if err != nil {
		t.Fatalf("Get: %v", err)
	}
	if entry.Etag != "etag-1" {
		t.Errorf("etag captured on cache miss = %q, want etag-1", entry.Etag)
	}
	if entry.ContentType != "text/csv" {
		t.Errorf("content-type captured = %q, want text/csv", entry.ContentType)
	}

	rc2, err := f.engine.Open(ctx, k)
	if err != nil {
		t.Fatalf("second Open: %v", err)
	}
	_, _ = io.ReadAll(rc2)
	_ = rc2.Close()
	if getCount != 1 {
		t.Errorf("second Open re-downloaded; GETs = %d, want still 1", getCount)
	}
}

// TestOpen_RemoteReadError tags the failure path so the telemetry event
// is emitted and the cache stays clean.
func TestOpen_RemoteReadError(t *testing.T) {

	f := newEngine(t)
	ctx := context.Background()

	httpmock.RegisterResponder("GET", testOneLakeBase+"/"+testWorkspaceID+"/"+testItemID+"/Files/oops.csv",
		httpmock.NewStringResponder(403, "forbidden"))

	k := cache.Key{AccountAlias: testAlias, WorkspaceID: testWorkspaceID, ItemID: testItemID, Path: "Files/oops.csv"}
	if _, err := f.engine.Open(ctx, k); err == nil {
		t.Fatal("expected error from forbidden response")
	}
	if _, err := f.cache.Get(ctx, k); err == nil {
		t.Error("cache row should not exist after a failed Open")
	}

	ev := findEvent(t, f.drainEvents(t), "file_download")
	if ev.Success == nil || *ev.Success {
		t.Errorf("Success = %v, want false", ev.Success)
	}
	if ev.ErrorCode == "" {
		t.Error("ErrorCode empty on failure")
	}
}

// TestOpen_StoreBlobError simulates a body that fails partway through so
// StoreBlob bubbles an error out of Open. We arrange this via a
// responder whose ReadCloser errors on the first Read call.
func TestOpen_StoreBlobError(t *testing.T) {

	f := newEngine(t)
	ctx := context.Background()

	httpmock.RegisterResponder("GET", testOneLakeBase+"/"+testWorkspaceID+"/"+testItemID+"/Files/broken.csv",
		func(req *http.Request) (*http.Response, error) {
			resp := &http.Response{
				StatusCode:    200,
				Body:          io.NopCloser(&erroringReader{err: io.ErrUnexpectedEOF}),
				Header:        http.Header{"ETag": []string{"e1"}},
				ContentLength: -1,
			}
			return resp, nil
		})

	k := cache.Key{AccountAlias: testAlias, WorkspaceID: testWorkspaceID, ItemID: testItemID, Path: "Files/broken.csv"}
	if _, err := f.engine.Open(ctx, k); err == nil {
		t.Fatal("expected error from StoreBlob")
	}

	ev := findEvent(t, f.drainEvents(t), "file_download")
	if ev.Success == nil || *ev.Success {
		t.Errorf("Success = %v, want false", ev.Success)
	}
	if ev.ErrorCode == "" {
		t.Error("ErrorCode empty on failure")
	}
}

// erroringReader always returns the configured error on Read; used to
// force a StoreBlob failure in Open's tests.
type erroringReader struct{ err error }

func (e *erroringReader) Read([]byte) (int, error) { return 0, e.err }

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

	// Store a fake blob and seed the cache row with blob link inline.
	sha, _, err := f.cache.StoreBlob(ctx, stringReader("v1"))
	if err != nil {
		t.Fatalf("StoreBlob: %v", err)
	}
	if err := f.cache.Put(ctx, cache.Entry{
		Key: k, Name: "a.csv", ParentPath: "Files", ContentLength: 2,
		Etag: "old-etag", BlobSHA256: sha, BlobSize: 2,
	}); err != nil {
		t.Fatalf("seed Put: %v", err)
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

// TestOpen_OfflineServesStaleBlob covers the MEDIUM-4 fix: when the
// freshness HEAD fails with an offline-class error (DNS, network
// unreachable, …) AND the cache has a fully stored blob, Open serves
// the cached bytes tagged `served_stale_offline` instead of refusing.
// Consistent with how OneDrive/Dropbox behave offline — a file the
// user already downloaded yesterday must keep opening with no Wi-Fi.
func TestOpen_OfflineServesStaleBlob(t *testing.T) {
	f := newEngine(t)
	ctx := context.Background()

	const body = "cached bytes"
	k := cache.Key{AccountAlias: testAlias, WorkspaceID: testWorkspaceID, ItemID: testItemID, Path: "Files/offline.txt"}

	// Stage the blob in the cache then link a metadata row to it.
	sha, _, err := f.cache.StoreBlob(ctx, strings.NewReader(body))
	if err != nil {
		t.Fatalf("StoreBlob: %v", err)
	}
	if err := f.cache.Put(ctx, cache.Entry{
		Key: k, Name: "offline.txt", ParentPath: "Files",
		ContentLength: int64(len(body)), Etag: "etag-cached",
		BlobSHA256: sha, BlobSize: int64(len(body)),
	}); err != nil {
		t.Fatalf("seed Put: %v", err)
	}

	// HEAD fails with a DNS error (the offline classifier recognises this).
	httpmock.RegisterResponder("HEAD", "=~^"+testOneLakeBase+`.*`,
		func(_ *http.Request) (*http.Response, error) {
			return nil, &net.DNSError{Err: "no such host", IsNotFound: true}
		})
	// GET must NOT be called — we should serve the cached blob without it.
	httpmock.RegisterResponder("GET", "=~^"+testOneLakeBase+`.*`,
		func(req *http.Request) (*http.Response, error) {
			t.Errorf("unexpected GET while offline: %s", req.URL)
			return httpmock.NewStringResponse(500, ""), nil
		})

	rc, err := f.engine.Open(ctx, k)
	if err != nil {
		t.Fatalf("Open offline with cached blob: want nil, got %v", err)
	}
	got, _ := io.ReadAll(rc)
	_ = rc.Close()
	if string(got) != body {
		t.Errorf("body = %q, want %q", got, body)
	}
	if !f.engine.Offline() {
		t.Error("engine should report Offline()=true after the failed HEAD")
	}

	events := f.drainEvents(t)
	ev := findEvent(t, events, "file_download")
	if ev.ErrorCode != "served_stale_offline" {
		t.Errorf("errorCode = %q, want served_stale_offline", ev.ErrorCode)
	}
	if ev.Success == nil || !*ev.Success {
		t.Errorf("event success = %v, want true", ev.Success)
	}
}

// TestOpen_OfflineWithoutCachedBlob confirms the asymmetric guard:
// when offline AND no cached blob exists, Open surfaces the offline
// error rather than fabricating a response.
func TestOpen_OfflineWithoutCachedBlob(t *testing.T) {
	f := newEngine(t)
	ctx := context.Background()

	k := cache.Key{AccountAlias: testAlias, WorkspaceID: testWorkspaceID, ItemID: testItemID, Path: "Files/missing.txt"}

	httpmock.RegisterResponder("GET", "=~^"+testOneLakeBase+`.*`,
		func(_ *http.Request) (*http.Response, error) {
			return nil, &net.DNSError{Err: "no such host", IsNotFound: true}
		})

	_, err := f.engine.Open(ctx, k)
	if err == nil {
		t.Fatal("Open offline with no cache: want error, got nil")
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
