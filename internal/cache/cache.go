package cache

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"log/slog"
	"os"
	"path/filepath"

	// Register the pure-Go SQLite driver under the name "sqlite". No cgo.
	_ "modernc.org/sqlite"
)

// driverName is the name modernc.org/sqlite registers itself as. Kept as a
// constant so callers do not depend on the driver package directly.
const driverName = "sqlite"

// blobsSubdir is the leaf-directory name under [Options.Root] where blob
// shards live. Each shard directory holds blobs whose lowercase hex
// SHA-256 starts with the shard's two hex characters.
const blobsSubdir = "blobs"

// sqliteFile is the file name of the metadata store inside [Options.Root].
const sqliteFile = "cache.sqlite"

// Cache combines the SQLite path-metadata store and the sharded on-disk
// blob store. Construct it with [Open] and close it with [Cache.Close].
type Cache struct {
	opts     Options
	db       *sql.DB
	blobRoot string // <Root>/blobs, cached at Open to avoid recomputing
	logger   *slog.Logger
}

// Open creates the directory structure if needed and opens (or creates)
// the SQLite store under opts.Root. The returned [Cache] is safe for
// concurrent use; callers should hold a single instance for the lifetime
// of the process.
//
// Open is idempotent: opening an already-initialised cache simply
// re-runs the IF NOT EXISTS schema and verifies the schema version.
func Open(opts Options) (*Cache, error) {
	if opts.Root == "" {
		return nil, errors.New("cache.Open: Root is required")
	}

	if err := os.MkdirAll(opts.Root, 0o700); err != nil {
		return nil, fmt.Errorf("cache.Open: create root: %w", err)
	}
	blobRoot := filepath.Join(opts.Root, blobsSubdir)
	if err := os.MkdirAll(blobRoot, 0o700); err != nil {
		return nil, fmt.Errorf("cache.Open: create blobs dir: %w", err)
	}

	dbPath := filepath.Join(opts.Root, sqliteFile)
	// _pragma DSN parameters apply to every new connection in the pool,
	// which matters because database/sql may open several connections.
	dsn := "file:" + dbPath +
		"?_pragma=journal_mode(WAL)" +
		"&_pragma=synchronous(NORMAL)" +
		"&_pragma=busy_timeout(5000)" +
		"&_pragma=foreign_keys(ON)"

	db, err := sql.Open(driverName, dsn)
	if err != nil {
		return nil, fmt.Errorf("cache.Open: sql.Open: %w", err)
	}
	db.SetMaxOpenConns(8)

	if err := db.PingContext(context.Background()); err != nil {
		_ = db.Close()
		return nil, fmt.Errorf("cache.Open: ping: %w", err)
	}

	c := &Cache{
		opts:     opts,
		db:       db,
		blobRoot: blobRoot,
		logger:   slog.Default().With(slog.String("component", "cache")),
	}

	if err := c.migrate(context.Background()); err != nil {
		_ = db.Close()
		return nil, fmt.Errorf("cache.Open: migrate: %w", err)
	}
	return c, nil
}

// Close releases the SQLite connection pool. Pending writes are flushed
// because each writer ran inside an explicit transaction.
func (c *Cache) Close() error {
	if c == nil || c.db == nil {
		return nil
	}
	return c.db.Close()
}

// Root returns the configured root directory. Useful for tests and the
// daemon that needs to report disk usage to the host app.
func (c *Cache) Root() string { return c.opts.Root }

// BlobRoot returns the directory under [Cache.Root] that holds the
// sharded blob files. The SQLite metadata (cache.sqlite and its WAL
// sidecars) sit alongside it under Root but are not blobs; callers that
// want to compare against [Options.MaxBlobBytes] should walk BlobRoot
// instead of Root so the metadata DB doesn't inflate the measurement.
func (c *Cache) BlobRoot() string { return c.blobRoot }

// migrate applies the schema and pins the current schemaVersion in the
// schema_version table. The function is safe to run repeatedly: existing
// objects use IF NOT EXISTS, and the version row is INSERT OR REPLACE.
//
// When a future schema bump arrives, branch on the existing version
// before applying the new statements.
func (c *Cache) migrate(ctx context.Context) error {
	tx, err := c.db.BeginTx(ctx, nil)
	if err != nil {
		return fmt.Errorf("begin: %w", err)
	}
	defer func() { _ = tx.Rollback() }()

	if _, err := tx.ExecContext(ctx, schemaSQL); err != nil {
		return fmt.Errorf("apply schema: %w", err)
	}

	var existing sql.NullInt64
	err = tx.QueryRowContext(ctx, `SELECT MAX(version) FROM schema_version`).Scan(&existing)
	if err != nil && !errors.Is(err, sql.ErrNoRows) {
		return fmt.Errorf("read schema_version: %w", err)
	}

	switch {
	case !existing.Valid:
		// Fresh database: claim the current version.
		if _, err := tx.ExecContext(ctx,
			`INSERT INTO schema_version (version) VALUES (?)`,
			schemaVersion,
		); err != nil {
			return fmt.Errorf("insert schema_version: %w", err)
		}
	case existing.Int64 == schemaVersion:
		// Already at the latest version; nothing to do.
	case existing.Int64 < schemaVersion:
		// Placeholder for future numbered migrations. As of v1 nothing
		// to do, but we keep the branch so adding v2 is a one-line
		// change here.
		if _, err := tx.ExecContext(ctx,
			`INSERT OR REPLACE INTO schema_version (version) VALUES (?)`,
			schemaVersion,
		); err != nil {
			return fmt.Errorf("bump schema_version: %w", err)
		}
	default:
		return fmt.Errorf("on-disk schema version %d is newer than supported %d", existing.Int64, schemaVersion)
	}

	if err := tx.Commit(); err != nil {
		return fmt.Errorf("commit: %w", err)
	}
	return nil
}
