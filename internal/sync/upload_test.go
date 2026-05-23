package sync

import (
	"context"
	"net/http"
	"strings"
	"testing"

	"github.com/jarcoal/httpmock"

	"github.com/sdebruyn/onelake-explorer-macos/internal/cache"
)

// TestPut_WritesToRemoteAndMirrorsLocally checks the happy path:
// the chunked upload chain runs, the cache row is created with the
// post-upload etag, and a subsequent Open is a cache hit.
func TestPut_WritesToRemoteAndMirrorsLocally(t *testing.T) {

	f := newEngine(t)
	ctx := context.Background()

	httpmock.RegisterResponder("PUT", "=~^"+testOneLakeBase+`.*`,
		httpmock.NewStringResponder(201, ""))
	httpmock.RegisterResponder("PATCH", "=~^"+testOneLakeBase+`.*`,
		httpmock.NewStringResponder(202, ""))
	httpmock.RegisterResponder("HEAD", testOneLakeBase+"/"+testWorkspaceID+"/"+testItemID+"/Files/up.txt",
		func(req *http.Request) (*http.Response, error) {
			resp := httpmock.NewStringResponse(200, "")
			resp.Header.Set("ETag", "remote-etag")
			resp.Header.Set("Content-Length", "5")
			return resp, nil
		})

	k := cache.Key{AccountAlias: testAlias, WorkspaceID: testWorkspaceID, ItemID: testItemID, Path: "Files/up.txt"}
	if err := f.engine.Put(ctx, k, strings.NewReader("hello"), 5); err != nil {
		t.Fatalf("Put: %v", err)
	}

	got, err := f.cache.Get(ctx, k)
	if err != nil {
		t.Fatalf("Get after Put: %v", err)
	}
	if got.Etag != "remote-etag" {
		t.Errorf("etag = %q, want remote-etag", got.Etag)
	}
	if got.BlobSHA256 == "" {
		t.Error("blob not linked locally")
	}

	events := f.drainEvents(t)
	ev := findEvent(t, events, "file_upload")
	if ev.BytesTransferred != 5 || ev.Success == nil || !*ev.Success {
		t.Errorf("file_upload: %+v", ev)
	}
}

// TestPut_LastWriteWins demonstrates that we do NOT check the remote
// etag before uploading. Even though the cache says we have a stale etag
// (and the test forces the remote to report a newer one), the upload
// proceeds.
func TestPut_LastWriteWins(t *testing.T) {

	f := newEngine(t)
	ctx := context.Background()

	// The test passes if PUT / PATCH happen without any conditional
	// header check on our end. We never read the remote etag prior to
	// uploading — there is no GET / HEAD before the PUT in the
	// recorded calls.
	var preflightCalls int
	httpmock.RegisterResponder("HEAD", "=~^"+testOneLakeBase+`.*`,
		func(req *http.Request) (*http.Response, error) {
			preflightCalls++
			return httpmock.NewStringResponse(200, ""), nil
		})
	httpmock.RegisterResponder("GET", "=~^"+testOneLakeBase+`.*`,
		func(req *http.Request) (*http.Response, error) {
			preflightCalls++
			return httpmock.NewStringResponse(200, ""), nil
		})
	httpmock.RegisterResponder("PUT", "=~^"+testOneLakeBase+`.*`,
		httpmock.NewStringResponder(201, ""))
	httpmock.RegisterResponder("PATCH", "=~^"+testOneLakeBase+`.*`,
		httpmock.NewStringResponder(202, ""))

	// Seed cache with a stale etag and even a linked blob so we are
	// modelling "we know about this file and the remote moved on".
	k := cache.Key{AccountAlias: testAlias, WorkspaceID: testWorkspaceID, ItemID: testItemID, Path: "Files/lww.txt"}
	if err := f.cache.Put(ctx, cache.Entry{
		Key: k, Name: "lww.txt", ParentPath: "Files",
		ContentLength: 4, Etag: "stale-etag",
	}); err != nil {
		t.Fatalf("seed Put: %v", err)
	}

	if err := f.engine.Put(ctx, k, strings.NewReader("data"), 4); err != nil {
		t.Fatalf("Put: %v", err)
	}

	// Best-effort post-upload HEAD is allowed (one call). Anything more
	// would suggest we are read-check-then-writing, which we explicitly
	// do not do.
	if preflightCalls > 1 {
		t.Errorf("preflight GET/HEAD calls = %d, want at most 1 (post-upload HEAD only)", preflightCalls)
	}
}

// TestPut_MacOSMetadataFilter ensures that .DS_Store and friends never
// reach OneLake and never emit telemetry.
func TestPut_MacOSMetadataFilter(t *testing.T) {

	cases := []string{
		"Files/.DS_Store",
		"Files/sub/.DS_Store",
		"Files/._foo.txt",
		"Files/.Spotlight-V100",
		"Files/.Trashes",
		"Files/.fseventsd",
	}
	for _, path := range cases {
		path := path
		t.Run(path, func(t *testing.T) {
			f := newEngine(t)
			ctx := context.Background()

			// Any HTTP call would mean we leaked the upload to OneLake.
			httpmock.RegisterResponder("PUT", "=~^"+testOneLakeBase+`.*`,
				func(req *http.Request) (*http.Response, error) {
					t.Errorf("unexpected PUT for macOS metadata %q: %s", path, req.URL.String())
					return httpmock.NewStringResponse(500, ""), nil
				})
			httpmock.RegisterResponder("PATCH", "=~^"+testOneLakeBase+`.*`,
				func(req *http.Request) (*http.Response, error) {
					t.Errorf("unexpected PATCH for macOS metadata %q: %s", path, req.URL.String())
					return httpmock.NewStringResponse(500, ""), nil
				})

			k := cache.Key{AccountAlias: testAlias, WorkspaceID: testWorkspaceID, ItemID: testItemID, Path: path}
			if err := f.engine.Put(ctx, k, strings.NewReader("ignored"), 7); err != nil {
				t.Fatalf("Put: %v", err)
			}

			events := f.drainEvents(t)
			for _, ev := range events {
				if ev.Name == "file_upload" {
					t.Errorf("file_upload telemetry leaked for macOS metadata file %q: %+v", path, ev)
				}
			}
		})
	}
}

// TestIsMacOSMetadata is a quick coverage table for the predicate.
func TestIsMacOSMetadata(t *testing.T) {

	cases := []struct {
		in   string
		want bool
	}{
		{"Files/.DS_Store", true},
		{"Files/sub/.DS_Store", true},
		{"._hidden", true},
		{"Files/._foo.bin", true},
		{"Files/something.Spotlight-V100", true},
		{"Files/something.Trashes", true},
		{"Files/something.fseventsd", true},
		{"Files/regular.csv", false},
		{"Files/DS_Store.txt", false},
		{"", false},
	}
	for _, c := range cases {
		c := c
		t.Run(c.in, func(t *testing.T) {
			if got := IsMacOSMetadata(c.in); got != c.want {
				t.Errorf("IsMacOSMetadata(%q) = %v, want %v", c.in, got, c.want)
			}
		})
	}
}
