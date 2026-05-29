package cache

// BlobBytes is defined on *Cache in blob.go. It returns the deduped
// on-disk byte total for all linked blobs by summing DISTINCT blob_size
// values from path_metadata (GROUP BY blob_sha256). This is O(1) in SQL
// and avoids a full filesystem walk on every status call.
//
// The daemon status handler calls it via (*Cache).BlobBytes to report
// CacheBytes without the per-call I/O overhead of filepath.WalkDir.
// See internal/daemon/handlers.go: cacheBlobSize.
