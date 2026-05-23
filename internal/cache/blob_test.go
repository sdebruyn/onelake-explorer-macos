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

func TestLinkBlob_AttachesAndSurvivesReopen(t *testing.T) {
	t.Parallel()
	root := t.TempDir()
	c, err := Open(Options{Root: root})
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	ctx := context.Background()

	e := sampleEntry()
	if err := c.Put(ctx, e); err != nil {
		t.Fatalf("Put: %v", err)
	}
	sha, size, err := c.StoreBlob(ctx, bytes.NewReader([]byte("123456")))
	if err != nil {
		t.Fatalf("StoreBlob: %v", err)
	}
	if err := c.LinkBlob(ctx, e.Key, sha, size); err != nil {
		t.Fatalf("LinkBlob: %v", err)
	}
	if err := c.Close(); err != nil {
		t.Fatalf("Close: %v", err)
	}

	c2, err := Open(Options{Root: root})
	if err != nil {
		t.Fatalf("reopen: %v", err)
	}
	t.Cleanup(func() { _ = c2.Close() })

	got, err := c2.Get(ctx, e.Key)
	if err != nil {
		t.Fatalf("Get: %v", err)
	}
	if got.BlobSHA256 != sha {
		t.Errorf("BlobSHA256 = %q, want %q", got.BlobSHA256, sha)
	}
	if got.BlobSize != size {
		t.Errorf("BlobSize = %d, want %d", got.BlobSize, size)
	}
}

func TestLinkBlob_NoRow(t *testing.T) {
	t.Parallel()
	c := newCache(t)
	ctx := context.Background()
	sha, _, err := c.StoreBlob(ctx, bytes.NewReader([]byte("data")))
	if err != nil {
		t.Fatalf("StoreBlob: %v", err)
	}
	err = c.LinkBlob(ctx, Key{
		AccountAlias: "work",
		WorkspaceID:  "ws",
		ItemID:       "it",
		Path:         "missing",
	}, sha, 4)
	if !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("LinkBlob with no row = %v, want os.ErrNotExist", err)
	}
}

func TestUnlinkBlob_RemovesFileWhenLastReference(t *testing.T) {
	t.Parallel()
	c := newCache(t)
	ctx := context.Background()

	e := sampleEntry()
	if err := c.Put(ctx, e); err != nil {
		t.Fatalf("Put: %v", err)
	}
	data := []byte("only-ref")
	sha, size, err := c.StoreBlob(ctx, bytes.NewReader(data))
	if err != nil {
		t.Fatalf("StoreBlob: %v", err)
	}
	if err := c.LinkBlob(ctx, e.Key, sha, size); err != nil {
		t.Fatalf("LinkBlob: %v", err)
	}

	_, p := blobShardPath(c.blobRoot, sha)
	if _, err := os.Stat(p); err != nil {
		t.Fatalf("blob not on disk: %v", err)
	}

	if err := c.UnlinkBlob(ctx, e.Key); err != nil {
		t.Fatalf("UnlinkBlob: %v", err)
	}

	got, err := c.Get(ctx, e.Key)
	if err != nil {
		t.Fatalf("Get: %v", err)
	}
	if got.BlobSHA256 != "" || got.BlobSize != 0 {
		t.Errorf("blob link still set: sha=%q size=%d", got.BlobSHA256, got.BlobSize)
	}
	if _, err := os.Stat(p); !errors.Is(err, os.ErrNotExist) {
		t.Errorf("blob file still on disk: %v", err)
	}
}

func TestUnlinkBlob_PreservesFileWhenOtherRowReferences(t *testing.T) {
	t.Parallel()
	c := newCache(t)
	ctx := context.Background()

	base := Key{AccountAlias: "work", WorkspaceID: "ws", ItemID: "it"}
	a := Entry{Key: keyAt(base, "a.csv"), ParentPath: "", Name: "a.csv"}
	b := Entry{Key: keyAt(base, "b.csv"), ParentPath: "", Name: "b.csv"}
	mustPut(t, c, ctx, a)
	mustPut(t, c, ctx, b)

	data := []byte("shared content")
	sha, size, err := c.StoreBlob(ctx, bytes.NewReader(data))
	if err != nil {
		t.Fatalf("StoreBlob: %v", err)
	}
	if err := c.LinkBlob(ctx, a.Key, sha, size); err != nil {
		t.Fatalf("LinkBlob a: %v", err)
	}
	if err := c.LinkBlob(ctx, b.Key, sha, size); err != nil {
		t.Fatalf("LinkBlob b: %v", err)
	}

	if err := c.UnlinkBlob(ctx, a.Key); err != nil {
		t.Fatalf("UnlinkBlob a: %v", err)
	}

	_, p := blobShardPath(c.blobRoot, sha)
	if _, err := os.Stat(p); err != nil {
		t.Errorf("blob file removed despite surviving ref from b: %v", err)
	}

	// b's link is still in place.
	gotB, err := c.Get(ctx, b.Key)
	if err != nil {
		t.Fatalf("Get b: %v", err)
	}
	if gotB.BlobSHA256 != sha {
		t.Errorf("b.BlobSHA256 = %q, want %q", gotB.BlobSHA256, sha)
	}

	// Now unlink the last ref; file should disappear.
	if err := c.UnlinkBlob(ctx, b.Key); err != nil {
		t.Fatalf("UnlinkBlob b: %v", err)
	}
	if _, err := os.Stat(p); !errors.Is(err, os.ErrNotExist) {
		t.Errorf("blob file should have been removed after last unlink: %v", err)
	}
}

func TestUnlinkBlob_NoRowOrNoBlob(t *testing.T) {
	t.Parallel()
	c := newCache(t)
	ctx := context.Background()

	// No row at all → no error.
	if err := c.UnlinkBlob(ctx, Key{
		AccountAlias: "work", WorkspaceID: "ws", ItemID: "it", Path: "missing",
	}); err != nil {
		t.Fatalf("UnlinkBlob no row: %v", err)
	}

	// Row exists but no blob attached → no error.
	e := sampleEntry()
	if err := c.Put(ctx, e); err != nil {
		t.Fatalf("Put: %v", err)
	}
	if err := c.UnlinkBlob(ctx, e.Key); err != nil {
		t.Fatalf("UnlinkBlob no blob: %v", err)
	}
}

func TestDelete_DropsBlobWhenLastReference(t *testing.T) {
	t.Parallel()
	c := newCache(t)
	ctx := context.Background()

	e := sampleEntry()
	if err := c.Put(ctx, e); err != nil {
		t.Fatalf("Put: %v", err)
	}
	sha, size, err := c.StoreBlob(ctx, bytes.NewReader([]byte("delete-me")))
	if err != nil {
		t.Fatalf("StoreBlob: %v", err)
	}
	if err := c.LinkBlob(ctx, e.Key, sha, size); err != nil {
		t.Fatalf("LinkBlob: %v", err)
	}
	if err := c.Delete(ctx, e.Key); err != nil {
		t.Fatalf("Delete: %v", err)
	}

	_, p := blobShardPath(c.blobRoot, sha)
	if _, err := os.Stat(p); !errors.Is(err, os.ErrNotExist) {
		t.Errorf("blob still on disk after Delete: %v", err)
	}
}
