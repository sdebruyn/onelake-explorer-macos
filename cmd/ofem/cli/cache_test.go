package cli

import (
	"bytes"
	"context"
	"io"
	"strings"
	"testing"

	"github.com/sdebruyn/onelake-explorer-macos/internal/cache"
	"github.com/sdebruyn/onelake-explorer-macos/internal/config"
)

// setupTempHome rewires $HOME to a fresh tempdir so config.ResolvePaths
// points the cache at a sandbox we own. Returns the resolved Paths.
func setupTempHome(t *testing.T) config.Paths {
	t.Helper()
	home := t.TempDir()
	t.Setenv("HOME", home)
	paths, err := config.ResolvePaths()
	if err != nil {
		t.Fatalf("ResolvePaths: %v", err)
	}
	return paths
}

// seedCache opens the cache under paths.CacheDir, stores n blobs of the
// given size, and returns the total bytes written so tests can assert
// against it. Each blob has unique content so dedupe doesn't collapse
// them into one file.
func seedCache(t *testing.T, paths config.Paths, n, blobSize int) int64 {
	t.Helper()
	c, err := cache.Open(cache.Options{Root: paths.CacheDir})
	if err != nil {
		t.Fatalf("cache.Open: %v", err)
	}
	t.Cleanup(func() { _ = c.Close() })

	var total int64
	for i := 0; i < n; i++ {
		body := make([]byte, blobSize)
		body[0] = byte(i + 1) // unique first byte → unique sha
		_, written, err := c.StoreBlob(context.Background(), bytes.NewReader(body))
		if err != nil {
			t.Fatalf("StoreBlob %d: %v", i, err)
		}
		total += written
	}
	return total
}

func runCache(t *testing.T, in io.Reader, args ...string) (string, error) {
	t.Helper()
	root := NewRoot()
	var buf bytes.Buffer
	root.SetOut(&buf)
	root.SetErr(&buf)
	if in != nil {
		root.SetIn(in)
	}
	root.SetArgs(args)
	err := root.Execute()
	return buf.String(), err
}

func TestCacheSize_EmptyCachePrintsZeros(t *testing.T) {
	paths := setupTempHome(t)

	out, err := runCache(t, nil, "cache", "size")
	if err != nil {
		t.Fatalf("cache size: %v\n%s", err, out)
	}
	for _, want := range []string{
		"Cache:     " + paths.CacheDir,
		"Used:      0 B",
		"Blobs:     0",
	} {
		if !strings.Contains(out, want) {
			t.Errorf("output missing %q\nfull:\n%s", want, out)
		}
	}
}

func TestCacheSize_ReportsBlobs(t *testing.T) {
	paths := setupTempHome(t)
	total := seedCache(t, paths, 3, 1024)

	out, err := runCache(t, nil, "cache", "size")
	if err != nil {
		t.Fatalf("cache size: %v\n%s", err, out)
	}
	if !strings.Contains(out, "Blobs:     3") {
		t.Errorf("expected 3 blobs in output, got:\n%s", out)
	}
	// total is 3 KiB → humanBytes renders as "3.0 KiB"
	if !strings.Contains(out, "Used:      3.0 KiB") {
		t.Errorf("expected used = 3.0 KiB, got:\n%s", out)
	}
	// Default config has cache.max_size_bytes = 10 GiB.
	if !strings.Contains(out, "Limit:     10.0 GiB") {
		t.Errorf("expected limit = 10.0 GiB, got:\n%s", out)
	}
	_ = total
}

func TestCacheClear_YesFlagSkipsConfirmation(t *testing.T) {
	paths := setupTempHome(t)
	seedCache(t, paths, 2, 512)

	out, err := runCache(t, nil, "cache", "clear", "--yes")
	if err != nil {
		t.Fatalf("cache clear --yes: %v\n%s", err, out)
	}
	if !strings.Contains(out, "Cleared 2 blob(s)") {
		t.Errorf("expected clear summary, got:\n%s", out)
	}
	if !strings.Contains(out, "reclaimed 1.0 KiB") {
		t.Errorf("expected reclaimed bytes, got:\n%s", out)
	}

	// Re-running size must now report zero.
	out, err = runCache(t, nil, "cache", "size")
	if err != nil {
		t.Fatalf("cache size after clear: %v\n%s", err, out)
	}
	if !strings.Contains(out, "Blobs:     0") || !strings.Contains(out, "Used:      0 B") {
		t.Errorf("cache not empty after clear:\n%s", out)
	}
}

func TestCacheClear_PromptAcceptsYes(t *testing.T) {
	paths := setupTempHome(t)
	seedCache(t, paths, 1, 256)

	out, err := runCache(t, strings.NewReader("y\n"), "cache", "clear")
	if err != nil {
		t.Fatalf("cache clear (prompt y): %v\n%s", err, out)
	}
	if !strings.Contains(out, "Clear every cached blob") {
		t.Errorf("expected confirmation prompt, got:\n%s", out)
	}
	if !strings.Contains(out, "Cleared 1 blob(s)") {
		t.Errorf("expected clear summary, got:\n%s", out)
	}
}

func TestCacheClear_PromptAborts(t *testing.T) {
	paths := setupTempHome(t)
	seedCache(t, paths, 1, 128)

	out, err := runCache(t, strings.NewReader("n\n"), "cache", "clear")
	if err != nil {
		t.Fatalf("cache clear (prompt n): %v\n%s", err, out)
	}
	if !strings.Contains(out, "Aborted") {
		t.Errorf("expected abort message, got:\n%s", out)
	}

	// Blob still there.
	c, err := cache.Open(cache.Options{Root: paths.CacheDir})
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	t.Cleanup(func() { _ = c.Close() })
	count, _, err := c.DiskUsage(context.Background())
	if err != nil {
		t.Fatalf("DiskUsage: %v", err)
	}
	if count != 1 {
		t.Errorf("blob disappeared despite abort: count=%d", count)
	}
}

func TestCacheEvict_TrimsToLimit(t *testing.T) {
	paths := setupTempHome(t)

	// Seed 4 blobs of 1 KiB each.
	c, err := cache.Open(cache.Options{Root: paths.CacheDir})
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	ctx := context.Background()
	for i := 0; i < 4; i++ {
		body := make([]byte, 1024)
		body[0] = byte(i + 1)
		sha, n, err := c.StoreBlob(ctx, bytes.NewReader(body))
		if err != nil {
			t.Fatalf("StoreBlob %d: %v", i, err)
		}
		// Link to a metadata row so EvictToLimit has something to walk.
		k := cache.Key{
			AccountAlias: "work",
			WorkspaceID:  "ws",
			ItemID:       "it",
			Path:         string(rune('a' + i)),
		}
		if err := c.Put(ctx, cache.Entry{Key: k, Name: string(rune('a' + i))}); err != nil {
			t.Fatalf("Put %d: %v", i, err)
		}
		if err := c.LinkBlob(ctx, k, sha, n); err != nil {
			t.Fatalf("LinkBlob %d: %v", i, err)
		}
	}
	_ = c.Close()

	// Lower the configured limit to 2 KiB so eviction should drop 2 blobs.
	store, err := config.Load()
	if err != nil {
		t.Fatalf("config.Load: %v", err)
	}
	store.Update(func(f *config.File) { f.Cache.MaxSizeBytes = 2 * 1024 })
	if err := store.Save(); err != nil {
		t.Fatalf("Save: %v", err)
	}

	out, err := runCache(t, nil, "cache", "evict")
	if err != nil {
		t.Fatalf("cache evict: %v\n%s", err, out)
	}
	if !strings.Contains(out, "Evicted 2 blob(s)") {
		t.Errorf("expected 2 evictions, got:\n%s", out)
	}
}

func TestCacheEvict_NoopWhenUnderLimit(t *testing.T) {
	setupTempHome(t)
	// Default limit is 10 GiB; an empty cache has nothing to evict.
	out, err := runCache(t, nil, "cache", "evict")
	if err != nil {
		t.Fatalf("cache evict: %v\n%s", err, out)
	}
	if !strings.Contains(out, "Evicted 0 blob(s)") {
		t.Errorf("expected no-op eviction, got:\n%s", out)
	}
}
