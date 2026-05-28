package sync

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"os"
	"path"
	"strings"
	"time"

	"github.com/sdebruyn/onelake-explorer-macos/internal/cache"
	"github.com/sdebruyn/onelake-explorer-macos/internal/onelake"
	"github.com/sdebruyn/onelake-explorer-macos/internal/telemetry"
)

// Diff summarises what RefreshFolder changed locally.
type Diff struct {
	// Added is the number of new entries inserted into the cache.
	Added int
	// Updated is the number of existing entries whose metadata changed.
	Updated int
	// Removed is the number of cache entries deleted because they were
	// no longer present on the remote.
	Removed int
}

// Total returns Added + Updated + Removed. Convenient for telemetry.
func (d Diff) Total() int { return d.Added + d.Updated + d.Removed }

// Enumerate returns the children of a OneLake folder.
//
// When the folder's own children were last listed (ChildrenSyncedAt)
// within RecentFolderTTL, the cached rows are returned without contacting
// OneLake — including an empty listing for a genuinely empty folder.
// Otherwise the folder is refreshed via RefreshFolder first.
//
// Telemetry: emits folder_list with success and durationMs.
func (e *Engine) Enumerate(ctx context.Context, k cache.Key) ([]cache.Entry, error) {
	start := e.now()

	if fresh, entries, err := e.enumerateFromCache(ctx, k); err != nil {
		return nil, err
	} else if fresh {
		e.track(telemetry.Event{
			Name:             "folder_list",
			AccountAliasHash: telemetry.HashAlias(k.AccountAlias),
			DurationMs:       elapsedMs(start, e.now),
			Success:          boolPtr(true),
		})
		return entries, nil
	}

	if _, err := e.RefreshFolder(ctx, k); err != nil {
		e.track(telemetry.Event{
			Name:             "folder_list",
			AccountAliasHash: telemetry.HashAlias(k.AccountAlias),
			DurationMs:       elapsedMs(start, e.now),
			Success:          boolPtr(false),
			ErrorCode:        telemetry.SafeErrorCode("list_failed"),
		})
		return nil, err
	}

	entries, err := e.cache.Children(ctx, k)
	if err != nil {
		return nil, fmt.Errorf("sync.Enumerate: read cache after refresh: %w", err)
	}
	e.track(telemetry.Event{
		Name:             "folder_list",
		AccountAliasHash: telemetry.HashAlias(k.AccountAlias),
		DurationMs:       elapsedMs(start, e.now),
		Success:          boolPtr(true),
	})
	return entries, nil
}

// enumerateFromCache returns the cached children if the parent's metadata
// row indicates the listing is still within RecentFolderTTL. The boolean
// return signals whether the cache hit was usable.
func (e *Engine) enumerateFromCache(ctx context.Context, k cache.Key) (bool, []cache.Entry, error) {
	parent, err := e.cache.Get(ctx, k)
	if err != nil {
		// Cache miss on the parent itself: signal "not fresh" to the
		// caller without surfacing the miss as an error. Other cache.Get
		// errors are equally non-fatal here; the caller falls back to a
		// remote refresh which will produce a clear error if the cache
		// is truly broken.
		if errors.Is(err, os.ErrNotExist) {
			return false, nil, nil
		}
		e.logger.Warn("cache.Get failed; falling back to remote refresh",
			"path", k.Path, "err", err)
		return false, nil, nil //nolint:nilerr // intentional fallback to remote refresh
	}
	if !parent.IsDir {
		return false, nil, fmt.Errorf("sync.Enumerate: %s is not a directory", k.Path)
	}
	// Freshness is governed by ChildrenSyncedAt — when THIS directory's
	// own children were last listed — not SyncedAt, which is also stamped
	// when the row is written as a child of its parent and so cannot tell
	// "children fetched" from "merely seen in the parent's listing". A
	// directory whose children were fetched within the TTL serves its
	// cached listing even when empty, so a genuinely empty folder no
	// longer triggers a redundant DFS round-trip on every read. When
	// ChildrenSyncedAt is zero (never descended into, e.g. a folder only
	// seen via its parent, or a row migrated from an older schema) we
	// refresh to fetch the real contents.
	age := e.now().Sub(parent.ChildrenSyncedAt)
	if parent.ChildrenSyncedAt.IsZero() || age > e.recentFolderTTL {
		return false, nil, nil
	}
	entries, err := e.cache.Children(ctx, k)
	if err != nil {
		return false, nil, fmt.Errorf("sync.Enumerate: read cache: %w", err)
	}
	return true, entries, nil
}

// RefreshFolder unconditionally fetches the folder from OneLake and
// reconciles cache rows. Rows that are new or whose metadata changed are
// upserted; rows that no longer exist remotely are deleted (cascading
// to blobs). The directory row itself is also upserted so subsequent
// freshness checks (Enumerate) see a current SyncedAt.
//
// Note: the cache update is intentionally non-atomic. We upsert and
// delete row-by-row and stamp the parent only at the end, so a mid-loop
// failure (e.g. disk full, SQLite transient error) leaves the cache in
// a partially refreshed state — some children carry the new SyncedAt,
// others still carry the previous one, and the parent's SyncedAt has
// not advanced. That is intentional: the parent row remains "stale",
// so the very next Enumerate triggers another RefreshFolder which is
// idempotent and converges the cache. Wrapping the whole loop in a
// single SQLite transaction would defeat the LRU bookkeeping the
// individual cache.Put / cache.Delete calls perform.
//
// Telemetry: emits sync_pulled with itemsChanged when the diff is
// non-zero. Callers (Enumerate) emit folder_list themselves.
func (e *Engine) RefreshFolder(ctx context.Context, k cache.Key) (Diff, error) {
	if err := e.guardPausedWorkspace(ctx, k.AccountAlias, k.WorkspaceID); err != nil {
		return Diff{}, err
	}
	result, err := e.onelake.ListPath(ctx, k.AccountAlias, k.WorkspaceID, k.ItemID, k.Path, false)
	if err != nil {
		if e.markPausedIfNeeded(ctx, k.AccountAlias, k.WorkspaceID, err) {
			return Diff{}, fmt.Errorf("sync.RefreshFolder: %w", ErrWorkspacePaused)
		}
		return Diff{}, fmt.Errorf("sync.RefreshFolder: list: %w", err)
	}

	now := e.now()

	// Build a set of remote child paths so we can detect deletions.
	remoteChildren := make(map[string]onelake.PathEntry, len(result.Entries))
	for _, entry := range result.Entries {
		rel, ok := stripItemPrefix(entry.Name, k.ItemID)
		if !ok || rel == "" {
			// Either the server echoed the directory itself or a row that
			// does not belong to this item — skip defensively.
			continue
		}
		// Ensure the entry is a direct child of k.Path (the DFS recursive
		// flag is false but a defensive filter does not hurt).
		if !isDirectChild(k.Path, rel) {
			continue
		}
		remoteChildren[rel] = entry
	}

	// Load currently cached children so we can compute the diff.
	cachedChildren, err := e.cache.Children(ctx, k)
	if err != nil {
		return Diff{}, fmt.Errorf("sync.RefreshFolder: read cache: %w", err)
	}
	cachedByPath := make(map[string]cache.Entry, len(cachedChildren))
	for _, c := range cachedChildren {
		cachedByPath[c.Path] = c
	}

	var diff Diff
	for relPath, entry := range remoteChildren {
		name := path.Base(relPath)
		cur, ok := cachedByPath[relPath]
		next := cache.Entry{
			Key: cache.Key{
				AccountAlias: k.AccountAlias,
				WorkspaceID:  k.WorkspaceID,
				ItemID:       k.ItemID,
				Path:         relPath,
			},
			ParentPath:    k.Path,
			Name:          name,
			IsDir:         entry.IsDirectory,
			ContentLength: entry.ContentLength,
			Etag:          entry.ETag,
			LastModified:  entry.LastModified,
			SyncedAt:      now,
			// Preserve the child's own children-fetched marker: writing it
			// as a child of this listing must NOT look like its contents
			// were just fetched. Zero for a brand-new child (never
			// descended into), unchanged for one we have descended into.
			ChildrenSyncedAt: cur.ChildrenSyncedAt,
			LastAccessed:     cur.LastAccessed, // preserve LRU history
		}
		// Carry over blob linkage when the etag still matches; otherwise
		// drop it so the next Open re-downloads.
		if ok && cur.Etag != "" && cur.Etag == entry.ETag {
			next.BlobSHA256 = cur.BlobSHA256
			next.BlobSize = cur.BlobSize
			next.ContentType = cur.ContentType
		}
		if next.LastAccessed.IsZero() {
			next.LastAccessed = now
		}

		switch {
		case !ok:
			diff.Added++
		case entryChanged(cur, next):
			diff.Updated++
		default:
			// No change; still upsert so SyncedAt advances.
		}
		if err := e.cache.Put(ctx, next); err != nil {
			return Diff{}, fmt.Errorf("sync.RefreshFolder: cache put %q: %w", relPath, err)
		}
	}

	// Drop cached children that disappeared remotely. Delete cascades
	// through directories thanks to cache.Delete's LIKE clause and
	// reclaims any orphan blobs along the way.
	for relPath := range cachedByPath {
		if _, stillThere := remoteChildren[relPath]; stillThere {
			continue
		}
		victim := cache.Key{
			AccountAlias: k.AccountAlias,
			WorkspaceID:  k.WorkspaceID,
			ItemID:       k.ItemID,
			Path:         relPath,
		}
		if err := e.cache.Delete(ctx, victim); err != nil {
			return Diff{}, fmt.Errorf("sync.RefreshFolder: cache delete %q: %w", relPath, err)
		}
		diff.Removed++
	}

	// Stamp the parent row so freshness checks see a current SyncedAt.
	// We upsert (rather than only Touch) so a missing-parent case from
	// the very first Enumerate gets a row in place.
	//
	// Preserve the parent's existing LastAccessed when it has one. A
	// system-initiated refresh (e.g. the adaptive poller) should NOT
	// look like a user access — otherwise polled items stay perpetually
	// "hot" and HotItems re-selects them every sweep, defeating the
	// inactivity window. The user-facing read path (Enumerate) bumps
	// LastAccessed via cache.Touch separately.
	parentLastAccessed := time.Time{}
	if existing, gerr := e.cache.Get(ctx, k); gerr == nil {
		parentLastAccessed = existing.LastAccessed
	}
	if parentLastAccessed.IsZero() {
		parentLastAccessed = now
	}
	parent := cache.Entry{
		Key:        k,
		ParentPath: parentPath(k.Path),
		Name:       baseName(k.Path),
		IsDir:      true,
		SyncedAt:   now,
		// This is the one place ChildrenSyncedAt is advanced: we have just
		// listed k's own children, so future enumerations can trust the
		// cached listing (even an empty one) until the TTL lapses.
		ChildrenSyncedAt: now,
		LastAccessed:     parentLastAccessed,
	}
	if err := e.cache.Put(ctx, parent); err != nil {
		return Diff{}, fmt.Errorf("sync.RefreshFolder: stamp parent: %w", err)
	}

	if diff.Total() > 0 {
		e.track(telemetry.Event{
			Name:             "sync_pulled",
			TenantID:         e.tenantFor(k.AccountAlias),
			AccountAliasHash: telemetry.HashAlias(k.AccountAlias),
			ItemsChanged:     diff.Total(),
		})
	}

	e.logger.Debug("folder refreshed",
		slog.String("account", k.AccountAlias),
		slog.String("workspace", k.WorkspaceID),
		slog.String("item", k.ItemID),
		slog.String("path", k.Path),
		slog.Int("added", diff.Added),
		slog.Int("updated", diff.Updated),
		slog.Int("removed", diff.Removed),
	)
	return diff, nil
}

// stripItemPrefix removes the leading "<itemGUID>/" so the cache stores
// item-relative paths exactly as the OneLake client expects them as
// inputs. Trailing slashes that DFS occasionally returns on directory
// rows are trimmed too so downstream callers (isDirectChild,
// path.Base, …) see a canonical "Files/sub" form rather than
// "Files/sub/", which would otherwise look like an indirect child.
//
// The second return value is false when name does not belong to the
// given itemGUID — a defensive guard against the server echoing a
// cross-item row. Callers should drop such entries silently.
func stripItemPrefix(name, itemGUID string) (string, bool) {
	name = strings.TrimPrefix(name, "/")
	switch {
	case name == itemGUID, name == itemGUID+"/":
		// The directory itself.
		return "", true
	case strings.HasPrefix(name, itemGUID+"/"):
		rel := strings.TrimPrefix(name, itemGUID+"/")
		return strings.TrimRight(rel, "/"), true
	default:
		return "", false
	}
}

// isDirectChild reports whether child is exactly one segment deeper than
// parent (an empty parent means "the item root").
func isDirectChild(parent, child string) bool {
	if child == "" {
		return false
	}
	if parent == "" {
		return !strings.Contains(child, "/")
	}
	if !strings.HasPrefix(child, parent+"/") {
		return false
	}
	tail := strings.TrimPrefix(child, parent+"/")
	return tail != "" && !strings.Contains(tail, "/")
}

// parentPath returns the parent directory of p, or "" when p has no
// parent (i.e. is at the item root).
func parentPath(p string) string {
	p = strings.TrimSuffix(p, "/")
	idx := strings.LastIndex(p, "/")
	if idx < 0 {
		return ""
	}
	return p[:idx]
}

// entryChanged compares the fields that the remote can change between
// calls. LastAccessed and SyncedAt are bookkeeping and intentionally
// ignored.
func entryChanged(a, b cache.Entry) bool {
	switch {
	case a.IsDir != b.IsDir:
		return true
	case a.ContentLength != b.ContentLength:
		return true
	case a.Etag != b.Etag:
		return true
	case !a.LastModified.Equal(b.LastModified):
		return true
	case a.Name != b.Name:
		return true
	case a.ParentPath != b.ParentPath:
		return true
	}
	return false
}
