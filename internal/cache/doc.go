// Package cache stores OneLake file metadata in SQLite and file content
// as sharded blobs on disk. It is the source of truth Finder reads
// through the File Provider Extension; the sync engine reconciles it
// with the remote (see docs/file-provider.md).
//
// Layout under the configured root directory:
//
//	<root>/
//	  cache.sqlite          metadata store (modernc.org/sqlite, pure Go)
//	  cache.sqlite-wal      WAL journal (managed by SQLite)
//	  cache.sqlite-shm      shared-memory file (managed by SQLite)
//	  blobs/
//	    <ab>/<cdef…>        content-addressed blob, sharded by sha256 prefix
//
// Concurrency: a single [Cache] value is safe for concurrent use across
// goroutines. Internally it relies on the database/sql connection pool and
// SQLite WAL mode for read concurrency.
package cache
