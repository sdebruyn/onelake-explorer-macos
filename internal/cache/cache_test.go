package cache

import (
	"context"
	"os"
	"path/filepath"
	"testing"
)

func TestOpen_CreatesDirectoryStructure(t *testing.T) {
	t.Parallel()
	root := t.TempDir()
	c, err := Open(Options{Root: root})
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	t.Cleanup(func() { _ = c.Close() })

	if _, err := os.Stat(filepath.Join(root, sqliteFile)); err != nil {
		t.Fatalf("sqlite file not created: %v", err)
	}
	if _, err := os.Stat(filepath.Join(root, blobsSubdir)); err != nil {
		t.Fatalf("blobs dir not created: %v", err)
	}
}

func TestOpen_RequiresRoot(t *testing.T) {
	t.Parallel()
	if _, err := Open(Options{}); err == nil {
		t.Fatal("expected error when Root is empty")
	}
}

func TestOpen_ReopenIsNoop(t *testing.T) {
	t.Parallel()
	root := t.TempDir()

	c, err := Open(Options{Root: root})
	if err != nil {
		t.Fatalf("first Open: %v", err)
	}
	// Write a row so we can verify it survives the reopen.
	ctx := context.Background()
	want := sampleEntry()
	if err := c.Put(ctx, want); err != nil {
		t.Fatalf("Put: %v", err)
	}
	if err := c.Close(); err != nil {
		t.Fatalf("Close: %v", err)
	}

	c2, err := Open(Options{Root: root})
	if err != nil {
		t.Fatalf("reopen: %v", err)
	}
	t.Cleanup(func() { _ = c2.Close() })

	got, err := c2.Get(ctx, want.Key)
	if err != nil {
		t.Fatalf("Get after reopen: %v", err)
	}
	if got.Name != want.Name {
		t.Fatalf("Get.Name = %q, want %q", got.Name, want.Name)
	}

	// Re-running migrate on the already-migrated DB must remain a no-op.
	if err := c2.migrate(ctx); err != nil {
		t.Fatalf("migrate idempotent: %v", err)
	}

	// And the schema_version row must still be exactly 1.
	var v int
	if err := c2.db.QueryRowContext(ctx,
		`SELECT version FROM schema_version`,
	).Scan(&v); err != nil {
		t.Fatalf("query schema_version: %v", err)
	}
	if v != schemaVersion {
		t.Fatalf("schema_version = %d, want %d", v, schemaVersion)
	}
}

func TestOpen_RejectsNewerSchema(t *testing.T) {
	t.Parallel()
	root := t.TempDir()
	c, err := Open(Options{Root: root})
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	// Inject a fake "from the future" version.
	if _, err := c.db.Exec(`INSERT OR REPLACE INTO schema_version (version) VALUES (?)`, schemaVersion+1); err != nil {
		t.Fatalf("inject: %v", err)
	}
	if err := c.Close(); err != nil {
		t.Fatalf("Close: %v", err)
	}

	if _, err := Open(Options{Root: root}); err == nil {
		t.Fatal("expected Open to refuse a newer schema version")
	}
}

func TestClose_NilSafe(t *testing.T) {
	t.Parallel()
	var c *Cache
	if err := c.Close(); err != nil {
		t.Fatalf("nil Close: %v", err)
	}
}

// sampleEntry returns a representative Entry. Tests mutate the returned
// value to cover variations.
func sampleEntry() Entry {
	return Entry{
		Key: Key{
			AccountAlias: "work",
			WorkspaceID:  "ws-1",
			ItemID:       "item-1",
			Path:         "Files/raw/2024/sales.csv",
		},
		ParentPath:    "Files/raw/2024",
		Name:          "sales.csv",
		IsDir:         false,
		ContentLength: 2048,
		Etag:          "etag-1",
		ContentType:   "text/csv",
	}
}
