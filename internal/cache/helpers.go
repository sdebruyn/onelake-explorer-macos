package cache

import (
	"errors"
	"path/filepath"
	"strings"
	"time"
)

// boolToInt translates a Go bool into the integer SQLite stores.
func boolToInt(b bool) int64 {
	if b {
		return 1
	}
	return 0
}

// timeToNs serialises t as Unix nanoseconds. The zero time encodes as 0
// so callers can distinguish "unset" from "set to 1970-01-01".
func timeToNs(t time.Time) int64 {
	if t.IsZero() {
		return 0
	}
	return t.UTC().UnixNano()
}

// nsToTime is the inverse of timeToNs.
func nsToTime(ns int64) time.Time {
	if ns == 0 {
		return time.Time{}
	}
	return time.Unix(0, ns).UTC()
}

// validateKey rejects keys that are missing required components. A key
// with an empty Path is valid: it denotes the item root.
func validateKey(k Key) error {
	if k.AccountAlias == "" {
		return errors.New("AccountAlias is required")
	}
	if k.WorkspaceID == "" {
		return errors.New("WorkspaceID is required")
	}
	if k.ItemID == "" {
		return errors.New("ItemID is required")
	}
	return nil
}

// validateChildrenKey reuses [validateKey]: Children may be called with
// any parent path, including "" to list the item's top-level entries.
func validateChildrenKey(k Key) error { return validateKey(k) }

// escapeLike escapes the three SQL LIKE wildcard characters using `\` as
// the escape character. Callers must use ESCAPE '\' in the LIKE clause.
func escapeLike(s string) string {
	replacer := strings.NewReplacer(
		`\`, `\\`,
		`%`, `\%`,
		`_`, `\_`,
	)
	return replacer.Replace(s)
}

// dedupe returns a copy of in with duplicate strings removed, preserving
// first-seen order. Used to collapse the blob-sha list collected during a
// cascading delete.
func dedupe(in []string) []string {
	if len(in) <= 1 {
		return in
	}
	seen := make(map[string]struct{}, len(in))
	out := make([]string, 0, len(in))
	for _, s := range in {
		if _, ok := seen[s]; ok {
			continue
		}
		seen[s] = struct{}{}
		out = append(out, s)
	}
	return out
}

// blobShardPath returns <blobRoot>/<sha[:2]>/<sha[2:]>. sha is expected
// to be a 64-character lowercase hex string; callers normalise before
// calling.
func blobShardPath(blobRoot, sha string) (dir, file string) {
	dir = filepath.Join(blobRoot, sha[:2])
	file = filepath.Join(dir, sha[2:])
	return dir, file
}
