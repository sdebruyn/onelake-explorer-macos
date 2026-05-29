package cache

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"io"
	"os"
	"path/filepath"
	"testing"
)

func TestStoreBlob_ContentAddressedAndIdempotent(t *testing.T) {
	t.Parallel()
	c := newCache(t)
	ctx := context.Background()

	data := []byte("hello, onelake")
	expectedSum := sha256.Sum256(data)
	expectedHex := hex.EncodeToString(expectedSum[:])

	sha1, n1, err := c.StoreBlob(ctx, bytes.NewReader(data))
	if err != nil {
		t.Fatalf("StoreBlob 1: %v", err)
	}
	if sha1 != expectedHex {
		t.Fatalf("sha = %s, want %s", sha1, expectedHex)
	}
	if n1 != int64(len(data)) {
		t.Fatalf("size = %d, want %d", n1, len(data))
	}

	// On-disk file lives at the sharded path.
	_, expectedPath := blobShardPath(c.blobRoot, sha1)
	st1, err := os.Stat(expectedPath)
	if err != nil {
		t.Fatalf("expected blob at %s: %v", expectedPath, err)
	}

	// Second store of the same content must return the same sha and not
	// create a duplicate file.
	sha2, n2, err := c.StoreBlob(ctx, bytes.NewReader(data))
	if err != nil {
		t.Fatalf("StoreBlob 2: %v", err)
	}
	if sha2 != sha1 || n2 != n1 {
		t.Fatalf("idempotency broken: sha2=%s n2=%d, want sha1=%s n1=%d", sha2, n2, sha1, n1)
	}
	st2, err := os.Stat(expectedPath)
	if err != nil {
		t.Fatalf("stat after second store: %v", err)
	}
	if st1.ModTime() != st2.ModTime() {
		t.Errorf("ModTime changed; expected idempotent store")
	}

	// No leftover temp files in the blob root.
	entries, err := os.ReadDir(c.blobRoot)
	if err != nil {
		t.Fatalf("ReadDir blobRoot: %v", err)
	}
	for _, e := range entries {
		if filepath.Ext(e.Name()) == ".tmp" {
			t.Errorf("leftover temp file: %s", e.Name())
		}
	}
}

func TestOpenBlob_RoundTrip(t *testing.T) {
	t.Parallel()
	c := newCache(t)
	ctx := context.Background()

	data := []byte("byte by byte")
	sha, _, err := c.StoreBlob(ctx, bytes.NewReader(data))
	if err != nil {
		t.Fatalf("StoreBlob: %v", err)
	}
	r, err := c.OpenBlob(ctx, sha)
	if err != nil {
		t.Fatalf("OpenBlob: %v", err)
	}
	t.Cleanup(func() { _ = r.Close() })

	got, err := io.ReadAll(r)
	if err != nil {
		t.Fatalf("ReadAll: %v", err)
	}
	if !bytes.Equal(got, data) {
		t.Fatalf("bytes mismatch: got %q want %q", got, data)
	}
}

func TestOpenBlob_NotFound(t *testing.T) {
	t.Parallel()
	c := newCache(t)
	// 64-char valid-shape sha that we never stored.
	fakeSHA := "0000000000000000000000000000000000000000000000000000000000000001"
	_, err := c.OpenBlob(context.Background(), fakeSHA)
	if !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("OpenBlob = %v, want os.ErrNotExist", err)
	}
}

func TestOpenBlob_RejectsBadSHA(t *testing.T) {
	t.Parallel()
	c := newCache(t)
	if _, err := c.OpenBlob(context.Background(), "not-a-sha"); err == nil {
		t.Fatal("expected error for bad sha")
	}
}

func TestDelete_DropsBlobWhenLastReference(t *testing.T) {
	t.Parallel()
	c := newCache(t)
	ctx := context.Background()

	sha, size, err := c.StoreBlob(ctx, bytes.NewReader([]byte("delete-me")))
	if err != nil {
		t.Fatalf("StoreBlob: %v", err)
	}
	e := sampleEntry()
	e.BlobSHA256 = sha
	e.BlobSize = size
	if err := c.Put(ctx, e); err != nil {
		t.Fatalf("Put: %v", err)
	}
	if err := c.Delete(ctx, e.Key); err != nil {
		t.Fatalf("Delete: %v", err)
	}

	_, p := blobShardPath(c.blobRoot, sha)
	if _, err := os.Stat(p); !errors.Is(err, os.ErrNotExist) {
		t.Errorf("blob still on disk after Delete: %v", err)
	}
}

func TestDiskUsage_EmptyCacheIsZero(t *testing.T) {
	t.Parallel()
	c := newCache(t)
	count, n, err := c.DiskUsage(context.Background())
	if err != nil {
		t.Fatalf("DiskUsage: %v", err)
	}
	if count != 0 || n != 0 {
		t.Fatalf("expected (0, 0), got (%d, %d)", count, n)
	}
}

func TestDiskUsage_CountsBlobsOnly(t *testing.T) {
	t.Parallel()
	c := newCache(t)
	ctx := context.Background()

	for i, payload := range [][]byte{[]byte("one"), []byte("two-bytes"), []byte("three-bytes!")} {
		if _, _, err := c.StoreBlob(ctx, bytes.NewReader(payload)); err != nil {
			t.Fatalf("StoreBlob %d: %v", i, err)
		}
	}

	count, n, err := c.DiskUsage(ctx)
	if err != nil {
		t.Fatalf("DiskUsage: %v", err)
	}
	if count != 3 {
		t.Errorf("count = %d, want 3", count)
	}
	want := int64(len("one") + len("two-bytes") + len("three-bytes!"))
	if n != want {
		t.Errorf("bytes = %d, want %d", n, want)
	}
}

func TestWipe_RemovesBlobsAndClearsLinks(t *testing.T) {
	t.Parallel()
	c := newCache(t)
	ctx := context.Background()

	data := []byte("wipe-me")
	sha, size, err := c.StoreBlob(ctx, bytes.NewReader(data))
	if err != nil {
		t.Fatalf("StoreBlob: %v", err)
	}
	e := sampleEntry()
	e.BlobSHA256 = sha
	e.BlobSize = size
	if err := c.Put(ctx, e); err != nil {
		t.Fatalf("Put: %v", err)
	}

	count, n, err := c.Wipe(ctx)
	if err != nil {
		t.Fatalf("Wipe: %v", err)
	}
	if count != 1 {
		t.Errorf("count = %d, want 1", count)
	}
	if n != int64(len(data)) {
		t.Errorf("bytes = %d, want %d", n, len(data))
	}

	// Blob file must be gone.
	_, p := blobShardPath(c.blobRoot, sha)
	if _, err := os.Stat(p); !errors.Is(err, os.ErrNotExist) {
		t.Errorf("blob still on disk after Wipe: %v", err)
	}

	// Metadata row survives but with cleared link.
	got, err := c.Get(ctx, e.Key)
	if err != nil {
		t.Fatalf("Get after Wipe: %v", err)
	}
	if got.BlobSHA256 != "" || got.BlobSize != 0 {
		t.Errorf("blob link still set after Wipe: sha=%q size=%d", got.BlobSHA256, got.BlobSize)
	}
}

func TestWipe_EmptyCacheReturnsZero(t *testing.T) {
	t.Parallel()
	c := newCache(t)
	count, n, err := c.Wipe(context.Background())
	if err != nil {
		t.Fatalf("Wipe: %v", err)
	}
	if count != 0 || n != 0 {
		t.Errorf("expected (0, 0), got (%d, %d)", count, n)
	}
}
