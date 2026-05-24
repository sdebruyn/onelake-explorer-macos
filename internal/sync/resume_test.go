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
	"strings"
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

	// Pre-stage a partial-spill on disk equal to the first half, plus
	// an etag sidecar pinning it to the same etag the cache row has.
	// Without the sidecar, partialRangeStart would refuse to resume.
	partialPath := partialFor(k)
	if err := os.MkdirAll(filepath.Dir(partialPath), 0o700); err != nil {
		t.Fatalf("mkdir partials: %v", err)
	}
	if err := os.WriteFile(partialPath, full[:half], 0o600); err != nil {
		t.Fatalf("write partial: %v", err)
	}
	if err := storePartialEtag(k, "etag-1"); err != nil {
		t.Fatalf("store partial etag: %v", err)
	}
	t.Cleanup(func() {
		_ = os.Remove(partialPath)
		_ = os.Remove(partialEtagFor(k))
	})

	// HEAD: return the same etag so the engine falls into the cache-
	// hit fast path; we then need the blob to be missing so we still
	// fall through to GET. The blob has not been stored yet (we only
	// seeded the metadata row), so OpenBlob will fail and the engine
	// loops down to the resume GET.
	httpmock.RegisterResponder("HEAD", "=~^"+testOneLakeBase+`.*`,
		func(_ *http.Request) (*http.Response, error) {
			resp := httpmock.NewStringResponse(200, "")
			resp.Header.Set("ETag", "etag-1")
			resp.Header.Set("Content-Length", strconv.FormatInt(int64(len(full)), 10))
			return resp, nil
		})

	var rangeRequested string
	var ifMatchHdr string
	httpmock.RegisterResponder("GET", "=~^"+testOneLakeBase+`.*`,
		func(req *http.Request) (*http.Response, error) {
			rangeRequested = req.Header.Get("Range")
			ifMatchHdr = req.Header.Get("If-Match")
			body := full[half:]
			resp := httpmock.NewBytesResponse(206, body)
			resp.Header.Set("ETag", "etag-1")
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
	if ifMatchHdr != "etag-1" {
		t.Errorf("If-Match header = %q, want etag-1", ifMatchHdr)
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

// TestOpen_PartialResume_EtagChanged covers the HIGH-2 data-integrity
// scenario: a partial-spill exists pinned to etag-1, but the remote
// moved to etag-2 between the original GET and the resumed request.
// The server enforces If-Match by returning 412; the engine must
// trash the partial AND its sidecar, then re-download the full
// resource from offset 0. Without this guard the engine would stitch
// old (etag-1) bytes onto new (etag-2) bytes and store a hybrid blob
// whose Content-Length matches but whose SHA is meaningless.
func TestOpen_PartialResume_EtagChanged(t *testing.T) {
	f := newEngine(t)
	ctx := context.Background()

	full := bytes.Repeat([]byte("ABCDEFGH"), 16) // 128 bytes, all "new"
	half := int64(len(full) / 2)

	k := cache.Key{
		AccountAlias: testAlias,
		WorkspaceID:  testWorkspaceID,
		ItemID:       testItemID,
		Path:         "Files/changed.bin",
	}

	// Seed cache row with the old etag and content length.
	if err := f.cache.Put(ctx, cache.Entry{
		Key: k, Name: "changed.bin", ParentPath: "Files",
		ContentLength: int64(len(full)), Etag: "etag-1",
	}); err != nil {
		t.Fatalf("seed cache: %v", err)
	}

	// Stage a partial pinned to etag-1 with the OLD bytes (zeros).
	old := bytes.Repeat([]byte{0xAA}, int(half))
	partialPath := partialFor(k)
	if err := os.MkdirAll(filepath.Dir(partialPath), 0o700); err != nil {
		t.Fatalf("mkdir partials: %v", err)
	}
	if err := os.WriteFile(partialPath, old, 0o600); err != nil {
		t.Fatalf("write partial: %v", err)
	}
	if err := storePartialEtag(k, "etag-1"); err != nil {
		t.Fatalf("store partial etag: %v", err)
	}
	t.Cleanup(func() {
		_ = os.Remove(partialPath)
		_ = os.Remove(partialEtagFor(k))
	})

	httpmock.RegisterResponder("HEAD", "=~^"+testOneLakeBase+`.*`,
		func(_ *http.Request) (*http.Response, error) {
			resp := httpmock.NewStringResponse(200, "")
			resp.Header.Set("ETag", "etag-2")
			resp.Header.Set("Content-Length", strconv.FormatInt(int64(len(full)), 10))
			return resp, nil
		})

	var (
		gets               atomic.Int32
		sawIfMatchOnFirst  string
		sawRangeOnFirst    string
		sawIfMatchOnSecond string
		sawRangeOnSecond   string
	)
	httpmock.RegisterResponder("GET", "=~^"+testOneLakeBase+`.*`,
		func(req *http.Request) (*http.Response, error) {
			n := gets.Add(1)
			if n == 1 {
				sawIfMatchOnFirst = req.Header.Get("If-Match")
				sawRangeOnFirst = req.Header.Get("Range")
				// Reject the resume because the etag changed.
				resp := httpmock.NewStringResponse(412, "etag changed")
				return resp, nil
			}
			sawIfMatchOnSecond = req.Header.Get("If-Match")
			sawRangeOnSecond = req.Header.Get("Range")
			resp := httpmock.NewBytesResponse(200, full)
			resp.Header.Set("ETag", "etag-2")
			resp.Header.Set("Content-Length", strconv.FormatInt(int64(len(full)), 10))
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
	if sawIfMatchOnFirst != "etag-1" {
		t.Errorf("first GET If-Match = %q, want etag-1", sawIfMatchOnFirst)
	}
	if sawRangeOnFirst == "" {
		t.Error("first GET should have carried a Range header (resume)")
	}
	if sawIfMatchOnSecond != "" {
		t.Errorf("second GET If-Match = %q, want empty (full re-download)", sawIfMatchOnSecond)
	}
	if sawRangeOnSecond != "" {
		t.Errorf("second GET Range = %q, want empty (full re-download)", sawRangeOnSecond)
	}
	if gets.Load() != 2 {
		t.Errorf("GET calls = %d, want 2 (412 then 200)", gets.Load())
	}

	// The old partial must be gone: a successful full-download cleans
	// up after itself.
	if _, err := os.Stat(partialPath); !os.IsNotExist(err) {
		t.Errorf("partial-spill survived: stat err = %v", err)
	}
	if _, err := os.Stat(partialEtagFor(k)); !os.IsNotExist(err) {
		t.Errorf("partial-spill etag survived: stat err = %v", err)
	}
}

// TestFinalisePartial_SHAMismatchDiscardsAll verifies the
// belt-and-suspenders SHA check inside finalisePartial. If the
// assembled bytes do not hash to the expected SHA, the spill AND its
// etag sidecar are discarded — so the next attempt does not pick up
// where the bogus partial left off. This is the second line of
// defence behind If-Match in case a server ignores If-Match on GET.
func TestFinalisePartial_SHAMismatchDiscardsAll(t *testing.T) {
	f := newEngine(t)
	ctx := context.Background()
	k := cache.Key{AccountAlias: "a", WorkspaceID: "w", ItemID: "i", Path: "Files/sha.bin"}

	// Stage spill + etag sidecar so we can assert they get cleaned up.
	if err := os.MkdirAll(filepath.Dir(partialFor(k)), 0o700); err != nil {
		t.Fatalf("mkdir partials: %v", err)
	}
	if err := os.WriteFile(partialFor(k), []byte("HALF"), 0o600); err != nil {
		t.Fatalf("write spill: %v", err)
	}
	if err := storePartialEtag(k, "etag-x"); err != nil {
		t.Fatalf("store etag: %v", err)
	}
	t.Cleanup(func() { discardPartial(k) })

	// We tell finalisePartial to append "rest" (4 bytes) so the total
	// matches expectedTotal=8. expectedSHA is a wrong hash → must fail.
	_, _, err := f.engine.finalisePartial(ctx, k, strings.NewReader("rest"), 8, 4, "0000000000000000000000000000000000000000000000000000000000000000")
	if err == nil {
		t.Fatal("finalisePartial: want SHA mismatch error, got nil")
	}
	if !strings.Contains(err.Error(), "sha mismatch") {
		t.Errorf("err = %v, want sha mismatch", err)
	}
	if _, serr := os.Stat(partialFor(k)); !os.IsNotExist(serr) {
		t.Errorf("partial spill survived SHA mismatch: stat err = %v", serr)
	}
	if _, serr := os.Stat(partialEtagFor(k)); !os.IsNotExist(serr) {
		t.Errorf("partial etag sidecar survived SHA mismatch: stat err = %v", serr)
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
