package cache

import (
	"context"
	"errors"
	"os"
	"sort"
	"testing"
	"time"
)

func newCache(t *testing.T) *Cache {
	t.Helper()
	c, err := Open(Options{Root: t.TempDir()})
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	t.Cleanup(func() { _ = c.Close() })
	return c
}

func TestPutGet_RoundTrip(t *testing.T) {
	t.Parallel()
	c := newCache(t)
	ctx := context.Background()

	in := sampleEntry()
	in.LastModified = time.Date(2026, 5, 1, 10, 30, 0, 0, time.UTC)

	if err := c.Put(ctx, in); err != nil {
		t.Fatalf("Put: %v", err)
	}
	got, err := c.Get(ctx, in.Key)
	if err != nil {
		t.Fatalf("Get: %v", err)
	}
	if got.Name != in.Name {
		t.Errorf("Name = %q, want %q", got.Name, in.Name)
	}
	if got.ContentLength != in.ContentLength {
		t.Errorf("ContentLength = %d, want %d", got.ContentLength, in.ContentLength)
	}
	if got.Etag != in.Etag {
		t.Errorf("Etag = %q, want %q", got.Etag, in.Etag)
	}
	if got.ContentType != in.ContentType {
		t.Errorf("ContentType = %q, want %q", got.ContentType, in.ContentType)
	}
	if !got.LastModified.Equal(in.LastModified) {
		t.Errorf("LastModified = %v, want %v", got.LastModified, in.LastModified)
	}
	if got.LastAccessed.IsZero() {
		t.Error("LastAccessed should be auto-populated")
	}
	if got.SyncedAt.IsZero() {
		t.Error("SyncedAt should be auto-populated")
	}
}

func TestPut_Upsert(t *testing.T) {
	t.Parallel()
	c := newCache(t)
	ctx := context.Background()

	in := sampleEntry()
	if err := c.Put(ctx, in); err != nil {
		t.Fatalf("Put 1: %v", err)
	}
	in.ContentLength = 9999
	in.Etag = "etag-2"
	if err := c.Put(ctx, in); err != nil {
		t.Fatalf("Put 2: %v", err)
	}
	got, err := c.Get(ctx, in.Key)
	if err != nil {
		t.Fatalf("Get: %v", err)
	}
	if got.ContentLength != 9999 {
		t.Errorf("ContentLength = %d, want 9999", got.ContentLength)
	}
	if got.Etag != "etag-2" {
		t.Errorf("Etag = %q, want etag-2", got.Etag)
	}
}

func TestGet_NotFound(t *testing.T) {
	t.Parallel()
	c := newCache(t)
	ctx := context.Background()

	_, err := c.Get(ctx, Key{
		AccountAlias: "work",
		WorkspaceID:  "ws-1",
		ItemID:       "item-1",
		Path:         "missing",
	})
	if !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("Get on missing key = %v, want os.ErrNotExist", err)
	}
}

func TestDelete_File(t *testing.T) {
	t.Parallel()
	c := newCache(t)
	ctx := context.Background()

	in := sampleEntry()
	if err := c.Put(ctx, in); err != nil {
		t.Fatalf("Put: %v", err)
	}
	if err := c.Delete(ctx, in.Key); err != nil {
		t.Fatalf("Delete: %v", err)
	}
	if _, err := c.Get(ctx, in.Key); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("Get after Delete = %v, want os.ErrNotExist", err)
	}
}

func TestDelete_NonExistentNoop(t *testing.T) {
	t.Parallel()
	c := newCache(t)
	ctx := context.Background()

	err := c.Delete(ctx, Key{AccountAlias: "work", WorkspaceID: "ws", ItemID: "it", Path: "nope"})
	if err != nil {
		t.Fatalf("Delete non-existent: %v", err)
	}
}

func TestDelete_DirectoryCascades(t *testing.T) {
	t.Parallel()
	c := newCache(t)
	ctx := context.Background()

	// Build a small tree:
	//   Files/                 (dir)
	//   Files/a.csv            (file)
	//   Files/sub/             (dir)
	//   Files/sub/b.csv        (file)
	//   Other/c.csv            (file, must survive)
	base := Key{AccountAlias: "work", WorkspaceID: "ws", ItemID: "it"}

	mustPut(t, c, ctx, Entry{Key: keyAt(base, "Files"), ParentPath: "", Name: "Files", IsDir: true})
	mustPut(t, c, ctx, Entry{Key: keyAt(base, "Files/a.csv"), ParentPath: "Files", Name: "a.csv"})
	mustPut(t, c, ctx, Entry{Key: keyAt(base, "Files/sub"), ParentPath: "Files", Name: "sub", IsDir: true})
	mustPut(t, c, ctx, Entry{Key: keyAt(base, "Files/sub/b.csv"), ParentPath: "Files/sub", Name: "b.csv"})
	mustPut(t, c, ctx, Entry{Key: keyAt(base, "Other/c.csv"), ParentPath: "Other", Name: "c.csv"})

	if err := c.Delete(ctx, keyAt(base, "Files")); err != nil {
		t.Fatalf("Delete Files: %v", err)
	}

	for _, p := range []string{"Files", "Files/a.csv", "Files/sub", "Files/sub/b.csv"} {
		if _, err := c.Get(ctx, keyAt(base, p)); !errors.Is(err, os.ErrNotExist) {
			t.Errorf("Get(%q) = %v, want os.ErrNotExist", p, err)
		}
	}
	if _, err := c.Get(ctx, keyAt(base, "Other/c.csv")); err != nil {
		t.Errorf("sibling row Other/c.csv was unexpectedly deleted: %v", err)
	}
}

func TestDelete_PrefixOnlyMatchesPathBoundary(t *testing.T) {
	t.Parallel()
	c := newCache(t)
	ctx := context.Background()

	base := Key{AccountAlias: "work", WorkspaceID: "ws", ItemID: "it"}
	mustPut(t, c, ctx, Entry{Key: keyAt(base, "Files"), ParentPath: "", Name: "Files", IsDir: true})
	mustPut(t, c, ctx, Entry{Key: keyAt(base, "FilesBackup"), ParentPath: "", Name: "FilesBackup", IsDir: true})
	mustPut(t, c, ctx, Entry{Key: keyAt(base, "FilesBackup/x.csv"), ParentPath: "FilesBackup", Name: "x.csv"})

	if err := c.Delete(ctx, keyAt(base, "Files")); err != nil {
		t.Fatalf("Delete: %v", err)
	}
	// "FilesBackup/x.csv" must survive because "FilesBackup" is not a
	// path-segment descendant of "Files".
	if _, err := c.Get(ctx, keyAt(base, "FilesBackup/x.csv")); err != nil {
		t.Errorf("FilesBackup/x.csv was wrongly deleted: %v", err)
	}
}

func TestChildren_DirectOnly(t *testing.T) {
	t.Parallel()
	c := newCache(t)
	ctx := context.Background()

	base := Key{AccountAlias: "work", WorkspaceID: "ws", ItemID: "it"}
	mustPut(t, c, ctx, Entry{Key: keyAt(base, "Files"), ParentPath: "", Name: "Files", IsDir: true})
	mustPut(t, c, ctx, Entry{Key: keyAt(base, "Tables"), ParentPath: "", Name: "Tables", IsDir: true})
	mustPut(t, c, ctx, Entry{Key: keyAt(base, "Files/a.csv"), ParentPath: "Files", Name: "a.csv"})
	mustPut(t, c, ctx, Entry{Key: keyAt(base, "Files/b.csv"), ParentPath: "Files", Name: "b.csv"})
	mustPut(t, c, ctx, Entry{Key: keyAt(base, "Files/sub/c.csv"), ParentPath: "Files/sub", Name: "c.csv"})

	// Direct children of "Files" — must be a.csv and b.csv only, NOT c.csv.
	got, err := c.Children(ctx, keyAt(base, "Files"))
	if err != nil {
		t.Fatalf("Children: %v", err)
	}
	names := make([]string, 0, len(got))
	for _, e := range got {
		names = append(names, e.Name)
	}
	sort.Strings(names)
	if len(names) != 2 || names[0] != "a.csv" || names[1] != "b.csv" {
		t.Fatalf("Children = %v, want [a.csv b.csv]", names)
	}

	// Direct children of the root (parent_path = "") — Files and Tables.
	rootChildren, err := c.Children(ctx, Key{AccountAlias: "work", WorkspaceID: "ws", ItemID: "it"})
	if err != nil {
		t.Fatalf("Children root: %v", err)
	}
	if len(rootChildren) != 2 {
		t.Fatalf("root children = %d, want 2", len(rootChildren))
	}
}

func TestTouch_BumpsLastAccessed(t *testing.T) {
	t.Parallel()
	c := newCache(t)
	ctx := context.Background()

	in := sampleEntry()
	in.LastAccessed = time.Date(2020, 1, 1, 0, 0, 0, 0, time.UTC)
	if err := c.Put(ctx, in); err != nil {
		t.Fatalf("Put: %v", err)
	}
	before, err := c.Get(ctx, in.Key)
	if err != nil {
		t.Fatalf("Get before: %v", err)
	}

	// Sleep a touch so the timestamp advances on every supported clock
	// resolution.
	time.Sleep(2 * time.Millisecond)

	if err := c.Touch(ctx, in.Key); err != nil {
		t.Fatalf("Touch: %v", err)
	}
	after, err := c.Get(ctx, in.Key)
	if err != nil {
		t.Fatalf("Get after: %v", err)
	}
	if !after.LastAccessed.After(before.LastAccessed) {
		t.Fatalf("LastAccessed not bumped: before=%v after=%v", before.LastAccessed, after.LastAccessed)
	}
}

func TestTouch_NotFound(t *testing.T) {
	t.Parallel()
	c := newCache(t)
	err := c.Touch(context.Background(), Key{
		AccountAlias: "work",
		WorkspaceID:  "ws",
		ItemID:       "it",
		Path:         "nope",
	})
	if !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("Touch on missing key = %v, want os.ErrNotExist", err)
	}
}

func TestHotItems(t *testing.T) {
	t.Parallel()
	c := newCache(t)
	ctx := context.Background()

	cutoff := time.Date(2026, 5, 23, 12, 0, 0, 0, time.UTC)

	// Three items in two workspaces under one alias; one of them is
	// "cold" (LastAccessed before cutoff) and must not appear in the
	// result. A second alias is added to confirm the DISTINCT grouping
	// is per (alias, workspace, item) and that hot rows from any path
	// inside the item collapse to a single row.
	hot1 := Entry{
		Key: Key{
			AccountAlias: "work",
			WorkspaceID:  "ws-1",
			ItemID:       "item-A",
			Path:         "Files/a.csv",
		},
		ParentPath:   "Files",
		Name:         "a.csv",
		LastAccessed: cutoff.Add(1 * time.Minute),
		SyncedAt:     cutoff,
	}
	hot1Sibling := Entry{
		Key: Key{
			AccountAlias: "work",
			WorkspaceID:  "ws-1",
			ItemID:       "item-A",
			Path:         "Files/b.csv",
		},
		ParentPath:   "Files",
		Name:         "b.csv",
		LastAccessed: cutoff.Add(2 * time.Minute),
		SyncedAt:     cutoff,
	}
	hot2 := Entry{
		Key: Key{
			AccountAlias: "work",
			WorkspaceID:  "ws-2",
			ItemID:       "item-B",
			Path:         "Tables/t.parquet",
		},
		ParentPath:   "Tables",
		Name:         "t.parquet",
		LastAccessed: cutoff.Add(10 * time.Second),
		SyncedAt:     cutoff,
	}
	cold := Entry{
		Key: Key{
			AccountAlias: "work",
			WorkspaceID:  "ws-3",
			ItemID:       "item-C",
			Path:         "Files/old.csv",
		},
		ParentPath:   "Files",
		Name:         "old.csv",
		LastAccessed: cutoff.Add(-10 * time.Minute),
		SyncedAt:     cutoff,
	}
	hot3 := Entry{
		Key: Key{
			AccountAlias: "client-a",
			WorkspaceID:  "ws-1",
			ItemID:       "item-A",
			Path:         "Files/x.csv",
		},
		ParentPath:   "Files",
		Name:         "x.csv",
		LastAccessed: cutoff.Add(5 * time.Minute),
		SyncedAt:     cutoff,
	}

	for _, e := range []Entry{hot1, hot1Sibling, hot2, cold, hot3} {
		mustPut(t, c, ctx, e)
	}

	got, err := c.HotItems(ctx, cutoff)
	if err != nil {
		t.Fatalf("HotItems: %v", err)
	}
	want := []Key{
		{AccountAlias: "client-a", WorkspaceID: "ws-1", ItemID: "item-A"},
		{AccountAlias: "work", WorkspaceID: "ws-1", ItemID: "item-A"},
		{AccountAlias: "work", WorkspaceID: "ws-2", ItemID: "item-B"},
	}
	if len(got) != len(want) {
		t.Fatalf("HotItems len = %d, want %d (%+v)", len(got), len(want), got)
	}
	for i, k := range want {
		if got[i] != k {
			t.Errorf("HotItems[%d] = %+v, want %+v", i, got[i], k)
		}
	}
}

func TestHotItems_EmptyWhenNothingFresh(t *testing.T) {
	t.Parallel()
	c := newCache(t)
	ctx := context.Background()

	cutoff := time.Date(2026, 5, 23, 12, 0, 0, 0, time.UTC)
	cold := Entry{
		Key: Key{
			AccountAlias: "work",
			WorkspaceID:  "ws-1",
			ItemID:       "item-A",
			Path:         "Files/a.csv",
		},
		Name:         "a.csv",
		LastAccessed: cutoff.Add(-1 * time.Hour),
		SyncedAt:     cutoff,
	}
	mustPut(t, c, ctx, cold)

	got, err := c.HotItems(ctx, cutoff)
	if err != nil {
		t.Fatalf("HotItems: %v", err)
	}
	if len(got) != 0 {
		t.Errorf("HotItems = %+v, want empty", got)
	}
}

// mustPut wraps Put with a fatal-failure helper for table-style tests.
func mustPut(t *testing.T, c *Cache, ctx context.Context, e Entry) {
	t.Helper()
	if err := c.Put(ctx, e); err != nil {
		t.Fatalf("Put(%q): %v", e.Path, err)
	}
}

// keyAt builds a Key by overriding only the Path component of base.
func keyAt(base Key, path string) Key {
	base.Path = path
	return base
}
