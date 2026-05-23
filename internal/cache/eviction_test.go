package cache

import (
	"bytes"
	"context"
	"fmt"
	"os"
	"testing"
	"time"
)

// TestEvictToLimit_RemovesOldestUntilUnderLimit inserts a known set of
// rows with staggered LastAccessed timestamps and total bytes well above
// the configured limit. The eviction must drop blob links from the
// oldest rows first, preserve newer rows, leave metadata rows in place
// (with cleared blob_sha256 / blob_size), and remove the blob files
// belonging to evicted rows from disk.
func TestEvictToLimit_RemovesOldestUntilUnderLimit(t *testing.T) {
	t.Parallel()

	const (
		// Each blob is 1 KiB. With 6 rows the total is 6 KiB.
		blobSize = 1024
		numRows  = 6
		// Limit at 3 KiB so we expect 3 blobs to be evicted.
		maxBytes    = 3 * 1024
		expectEvict = 3
	)

	c, err := Open(Options{Root: t.TempDir(), MaxBlobBytes: maxBytes})
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	t.Cleanup(func() { _ = c.Close() })
	ctx := context.Background()

	base := Key{AccountAlias: "work", WorkspaceID: "ws", ItemID: "it"}
	keys := make([]Key, 0, numRows)
	// Older rows go first; row 0 is the oldest.
	now := time.Now().UTC()
	for i := 0; i < numRows; i++ {
		k := keyAt(base, fmt.Sprintf("file-%d.bin", i))
		keys = append(keys, k)

		// Each blob has unique content so it has a unique sha and unique
		// on-disk path.
		body := make([]byte, blobSize)
		body[0] = byte(i + 1)
		sha, n, err := c.StoreBlob(ctx, bytes.NewReader(body))
		if err != nil {
			t.Fatalf("StoreBlob %d: %v", i, err)
		}
		if n != int64(blobSize) {
			t.Fatalf("StoreBlob %d: size = %d, want %d", i, n, blobSize)
		}
		e := Entry{
			Key:          k,
			ParentPath:   "",
			Name:         fmt.Sprintf("file-%d.bin", i),
			LastAccessed: now.Add(time.Duration(i) * time.Minute),
			SyncedAt:     now,
			BlobSHA256:   sha,
			BlobSize:     n,
		}
		if err := c.Put(ctx, e); err != nil {
			t.Fatalf("Put %d: %v", i, err)
		}
	}

	total, err := c.BlobBytes(ctx)
	if err != nil {
		t.Fatalf("BlobBytes: %v", err)
	}
	if total != int64(numRows*blobSize) {
		t.Fatalf("BlobBytes before evict = %d, want %d", total, numRows*blobSize)
	}

	evicted, reclaimed, err := c.EvictToLimit(ctx)
	if err != nil {
		t.Fatalf("EvictToLimit: %v", err)
	}
	if evicted != expectEvict {
		t.Errorf("evicted = %d, want %d", evicted, expectEvict)
	}
	if reclaimed != int64(expectEvict*blobSize) {
		t.Errorf("reclaimed = %d, want %d", reclaimed, expectEvict*blobSize)
	}

	after, err := c.BlobBytes(ctx)
	if err != nil {
		t.Fatalf("BlobBytes after: %v", err)
	}
	if after > maxBytes {
		t.Fatalf("BlobBytes after evict = %d, want <= %d", after, maxBytes)
	}

	// Rows 0..2 should have had their blob link cleared but the metadata
	// row itself must survive.
	for i := 0; i < expectEvict; i++ {
		got, err := c.Get(ctx, keys[i])
		if err != nil {
			t.Errorf("Get evicted row %d: %v", i, err)
			continue
		}
		if got.BlobSHA256 != "" || got.BlobSize != 0 {
			t.Errorf("row %d still has blob link: sha=%q size=%d", i, got.BlobSHA256, got.BlobSize)
		}
	}
	// Rows 3..5 must still have their blob link.
	for i := expectEvict; i < numRows; i++ {
		got, err := c.Get(ctx, keys[i])
		if err != nil {
			t.Errorf("Get surviving row %d: %v", i, err)
			continue
		}
		if got.BlobSHA256 == "" {
			t.Errorf("surviving row %d lost its blob link", i)
		}
	}
}

func TestEvictToLimit_NoopWhenUnderLimit(t *testing.T) {
	t.Parallel()
	c, err := Open(Options{Root: t.TempDir(), MaxBlobBytes: 1 << 30})
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	t.Cleanup(func() { _ = c.Close() })
	ctx := context.Background()

	e := sampleEntry()
	sha, n, err := c.StoreBlob(ctx, bytes.NewReader([]byte("tiny")))
	if err != nil {
		t.Fatalf("StoreBlob: %v", err)
	}
	e.BlobSHA256 = sha
	e.BlobSize = n
	if err := c.Put(ctx, e); err != nil {
		t.Fatalf("Put: %v", err)
	}

	evicted, reclaimed, err := c.EvictToLimit(ctx)
	if err != nil {
		t.Fatalf("EvictToLimit: %v", err)
	}
	if evicted != 0 || reclaimed != 0 {
		t.Fatalf("expected no-op, got evicted=%d reclaimed=%d", evicted, reclaimed)
	}
}

func TestEvictToLimit_ZeroLimitIsNoop(t *testing.T) {
	t.Parallel()
	c, err := Open(Options{Root: t.TempDir(), MaxBlobBytes: 0})
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	t.Cleanup(func() { _ = c.Close() })
	evicted, reclaimed, err := c.EvictToLimit(context.Background())
	if err != nil {
		t.Fatalf("EvictToLimit: %v", err)
	}
	if evicted != 0 || reclaimed != 0 {
		t.Fatalf("MaxBlobBytes==0 must be a no-op, got evicted=%d reclaimed=%d", evicted, reclaimed)
	}
}

func TestEvictToLimit_PreservesSharedBlobOnDisk(t *testing.T) {
	t.Parallel()
	c, err := Open(Options{Root: t.TempDir(), MaxBlobBytes: 0})
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	t.Cleanup(func() { _ = c.Close() })
	ctx := context.Background()

	// Two rows share a sha; once we evict one the file must remain
	// because the other still references it.
	base := Key{AccountAlias: "work", WorkspaceID: "ws", ItemID: "it"}
	a := Entry{Key: keyAt(base, "a.bin"), Name: "a.bin", LastAccessed: time.Now().Add(-time.Hour)}
	b := Entry{Key: keyAt(base, "b.bin"), Name: "b.bin", LastAccessed: time.Now()}

	data := make([]byte, 4096)
	sha, n, err := c.StoreBlob(ctx, bytes.NewReader(data))
	if err != nil {
		t.Fatalf("StoreBlob: %v", err)
	}
	a.BlobSHA256, a.BlobSize = sha, n
	b.BlobSHA256, b.BlobSize = sha, n
	if err := c.Put(ctx, a); err != nil {
		t.Fatalf("Put a: %v", err)
	}
	if err := c.Put(ctx, b); err != nil {
		t.Fatalf("Put b: %v", err)
	}

	// Force a single eviction by switching the limit just below the
	// per-row size and re-opening.
	c.opts.MaxBlobBytes = int64(n) // exactly one blob worth → drop one ref
	evicted, _, err := c.EvictToLimit(ctx)
	if err != nil {
		t.Fatalf("EvictToLimit: %v", err)
	}
	if evicted != 1 {
		t.Fatalf("evicted = %d, want 1", evicted)
	}

	// The blob file must still be present because the surviving row
	// keeps a reference.
	_, p := blobShardPath(c.blobRoot, sha)
	if _, err := os.Stat(p); err != nil {
		t.Fatalf("shared blob removed prematurely: %v", err)
	}
}
