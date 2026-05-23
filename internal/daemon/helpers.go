package daemon

import (
	"encoding/base64"
	"sort"
)

// decodeBase64 accepts either standard or raw (no-padding) base64. The
// host app and CLI may produce either, so the daemon is lenient on the
// input side.
func decodeBase64(s string) ([]byte, error) {
	if s == "" {
		return nil, nil
	}
	if b, err := base64.StdEncoding.DecodeString(s); err == nil {
		return b, nil
	}
	return base64.RawStdEncoding.DecodeString(s)
}

// sortStrings is a tiny wrapper around sort.Strings so handlers.go
// doesn't need to import sort at the top alongside several other names
// (keeps the import block compact).
func sortStrings(s []string) { sort.Strings(s) }
