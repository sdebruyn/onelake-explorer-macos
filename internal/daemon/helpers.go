package daemon

import "sort"

// sortStrings is a tiny wrapper around sort.Strings so handlers.go
// doesn't need to import sort at the top alongside several other names
// (keeps the import block compact).
func sortStrings(s []string) { sort.Strings(s) }
