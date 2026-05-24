package sync

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"sync/atomic"
	"testing"

	"github.com/jarcoal/httpmock"

	"github.com/sdebruyn/onelake-explorer-macos/internal/cache"
)

// TestOpen_PartialDownloadResume verifies the Range-header resume
// flow. We pre-populate a partial-spill file with the first half of
// the file's bytes, then issue Open. The mock server checks the
// Range header and serves only the missing tail; the engine must
// stitch the two halves and verify the final size matches the cached
// Content-Length.
func TestOpen_PartialDownloadResume(t *testing.T) {
	f := newEngine(t)
	ctx := context.Background()

	full := bytes.Repeat([]byte("abcdefgh"), 16) // 128 bytes
	hash := sha256.Sum256(full)
	wantSha := hex.EncodeToString(hash[:])
	half := int64(len(full) / 2)

	k := cache.Key{
		AccountAlias: testAlias,
		WorkspaceID:  testWorkspaceID,
		ItemID:       testItemID,
		Path:         "Files/resume.bin",
	}

	// Seed the cache row with the expected Content-Length so the
	// resume decision has a target to compare against.
	if err := f.cache.Put(ctx, cache.Entry{
		Key: k, Name: "resume.bin", ParentPath: "Files",
		ContentLength: int64(len(full)), Etag: "etag-1",
	}); err != nil {
		t.Fatalf("seed cache: %v", err)
	}

	// Pre-stage a partial-spill on disk equal to the first half.
	partialPath := partialFor(k)
	if err := os.MkdirAll(filepath.Dir(partialPath), 0o700); err != nil {
		t.Fatalf("mkdir partials: %v", err)
	}
	if err := os.WriteFile(partialPath, full[:half], 0o600); err != nil {
		t.Fatalf("write partial: %v", err)
	}
	t.Cleanup(func() { _ = os.Remove(partialPath) })

	// HEAD: report etag != cached so the cache-hit branch falls through.
	httpmock.RegisterResponder("HEAD", "=~^"+testOneLakeBase+`.*`,
		func(_ *http.Request) (*http.Response, error) {
			resp := httpmock.NewStringResponse(200, "")
			resp.Header.Set("ETag", "etag-2")
			resp.Header.Set("Content-Length", strconv.FormatInt(int64(len(full)), 10))
			return resp, nil
		})

	var rangeRequested string
	httpmock.RegisterResponder("GET", "=~^"+testOneLakeBase+`.*`,
		func(req *http.Request) (*http.Response, error) {
			rangeRequested = req.Header.Get("Range")
			body := full[half:]
			resp := httpmock.NewBytesResponse(206, body)
			resp.Header.Set("ETag", "etag-2")
			resp.Header.Set("Content-Length", strconv.FormatInt(int64(len(body)), 10))
			return resp, nil
		})

	rc, err := f.engine.Open(ctx, k)
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	defer func() { _ = rc.Close() }()
	got, err := io.ReadAll(rc)
	if err != nil {
		t.Fatalf("ReadAll: %v", err)
	}
	if !bytes.Equal(got, full) {
		t.Errorf("body mismatch:\n got %x\nwant %x", got, full)
	}
	if rangeRequested == "" || rangeRequested != "bytes=64-" {
		t.Errorf("Range header = %q, want bytes=64-", rangeRequested)
	}

	row, _ := f.cache.Get(ctx, k)
	if row.BlobSHA256 != wantSha {
		t.Errorf("sha = %q, want %q", row.BlobSHA256, wantSha)
	}
	if row.BlobSize != int64(len(full)) {
		t.Errorf("blob size = %d, want %d", row.BlobSize, len(full))
	}

	// Partial-spill must be cleaned up on success.
	if _, err := os.Stat(partialPath); !os.IsNotExist(err) {
		t.Errorf("partial-spill survived a successful Open: stat err = %v", err)
	}
}

// TestOpen_PartialDownloadFreshStart confirms that when no partial is
// on disk, Open does NOT send a Range header and downloads from
// offset 0.
func TestOpen_PartialDownloadFreshStart(t *testing.T) {
	f := newEngine(t)
	ctx := context.Background()

	k := cache.Key{
		AccountAlias: testAlias, WorkspaceID: testWorkspaceID, ItemID: testItemID,
		Path: "Files/fresh.bin",
	}

	var rangeHdr string
	var gets int32
	httpmock.RegisterResponder("GET", "=~^"+testOneLakeBase+`.*`,
		func(req *http.Request) (*http.Response, error) {
			atomic.AddInt32(&gets, 1)
			rangeHdr = req.Header.Get("Range")
			resp := httpmock.NewStringResponse(200, "hello")
			resp.Header.Set("ETag", "e1")
			resp.Header.Set("Content-Length", "5")
			return resp, nil
		})

	rc, err := f.engine.Open(ctx, k)
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	_ = rc.Close()
	if rangeHdr != "" {
		t.Errorf("unexpected Range header for fresh download: %q", rangeHdr)
	}
	if got := atomic.LoadInt32(&gets); got != 1 {
		t.Errorf("GET calls = %d, want 1", got)
	}
}
