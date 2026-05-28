package cache

import "time"

// Key uniquely identifies a metadata row. The four components together
// form the SQLite primary key for path_metadata.
//
// Path is a POSIX-style path relative to the item root, without a leading
// "/". The empty Path identifies the item root itself.
type Key struct {
	// AccountAlias is the user-chosen short name for the signed-in account
	// (for example "work"). See internal/auth.ValidateAlias for the
	// canonical character rules.
	AccountAlias string

	// WorkspaceID is the Fabric workspace GUID owning the item.
	WorkspaceID string

	// ItemID is the Fabric item GUID (lakehouse, warehouse, etc.) the path
	// is rooted in.
	ItemID string

	// Path is the POSIX path relative to the item root. No leading "/".
	// Use "" for the item root itself.
	Path string
}

// Entry is the full metadata row for one path. Time zero-values map to
// "unknown" / "not set" and are encoded as zero nanoseconds in the table.
type Entry struct {
	Key

	// ParentPath is the POSIX path of the directory containing this entry,
	// relative to the item root, with no leading "/". Empty when the entry
	// itself sits at the item root.
	ParentPath string

	// Name is the final segment of Path (or the item alias for roots).
	Name string

	// IsDir is true when the entry represents a directory (or any other
	// non-file container) instead of a regular blob.
	IsDir bool

	// ContentLength is the remote-reported size in bytes. Zero for
	// directories and for files whose size we have not learned yet.
	ContentLength int64

	// Etag is the OneLake / ADLS Gen2 entity tag, when known. Used for
	// conditional GETs and PUTs.
	Etag string

	// LastModified is the remote-reported last-modified timestamp.
	LastModified time.Time

	// ContentType is the MIME type reported by the remote, when known.
	ContentType string

	// BlobSHA256 is the lowercase hex SHA-256 of the locally cached file
	// content, or "" when no blob is cached for this entry.
	BlobSHA256 string

	// BlobSize is the size in bytes of the locally cached blob, or 0 when
	// no blob is cached.
	BlobSize int64

	// LastAccessed is the wall-clock timestamp of the last cache hit
	// against this entry. Used for LRU eviction of blob-bearing rows.
	LastAccessed time.Time

	// SyncedAt is the wall-clock timestamp at which this row's metadata
	// was last reconciled with the remote. It is stamped both when the
	// row is written as a child of its parent's listing AND when the row
	// is the directory whose own contents were just listed, so on its own
	// it cannot tell those two cases apart.
	SyncedAt time.Time

	// ChildrenSyncedAt is the wall-clock timestamp at which this
	// directory's OWN children were last listed from the remote. Unlike
	// SyncedAt it is set ONLY when the directory itself is refreshed, never
	// when it is written as a child of its parent. Zero means "this
	// directory's contents have never been fetched" — which lets the
	// enumerator tell a genuinely empty folder (children fetched, none
	// found) apart from one that was merely seen in its parent's listing
	// but never descended into. Always zero for non-directory rows.
	ChildrenSyncedAt time.Time
}

// Options configures a [Cache] at construction time.
type Options struct {
	// Root is the base directory; cache.sqlite and blobs/ go inside it.
	// It is created with mode 0o700 if missing.
	Root string

	// MaxBlobBytes is the LRU eviction threshold for cached blob bytes
	// (it does NOT count metadata). Zero means "do not evict": [Cache.EvictToLimit]
	// then becomes a no-op.
	MaxBlobBytes int64
}
