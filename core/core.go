// Package main is the cgo entry point: it exposes a tiny C ABI to the
// Swift host app and the File Provider Extension so they can call into
// the Go core library without depending on a long-running daemon
// process. Functions here are kept minimal and stateless; richer
// integration happens via subsequent C exports as the bridge grows.
//
// Build it as a static C archive (consumed by Xcode) with:
//
//	CGO_ENABLED=1 go build -buildmode=c-archive -o libofemcore.a ./core
//
// which also writes the matching libofemcore.h header next to the .a.
//
// Swift consumes the header via the bridging header
// apple/OneLake/OneLakeCoreBridge.h. All cross-boundary calls use C
// primitives (NUL-terminated char* in particular); Go owns the strings
// it returns and the caller MUST free them with ofem_core_string_free.
package main

// #include <stdlib.h>
import "C"

import (
	"log"
	"unsafe"

	"github.com/sdebruyn/onelake-explorer-macos/internal/buildinfo"
)

// ofem_core_version returns the OFEM build version as a NUL-terminated
// C string. The caller MUST free the returned pointer with
// ofem_core_string_free; calling free() directly works too because Go's
// C.CString allocates with the C malloc, but routing through
// ofem_core_string_free keeps the ownership contract symmetric.
//
//export ofem_core_version
func ofem_core_version() *C.char { //nolint:revive // C-ABI symbol name
	return C.CString(buildinfo.Version)
}

// ofem_core_string_free releases a C string previously returned by an
// ofem_core_* function. Safe to call with a NULL pointer.
//
//export ofem_core_string_free
func ofem_core_string_free(p *C.char) { //nolint:revive // C-ABI symbol name
	if p != nil {
		C.free(unsafe.Pointer(p))
	}
}

// ofem_core_log_message logs an informational message through the Go
// stdlib logger. It is the second smoke API of the bridge — used by
// the Swift File Provider Extension to prove that string round-trips
// from Swift into Go work end-to-end.
//
// We deliberately use the stdlib log package rather than slog: a
// c-archive does not run the daemon's slog setup, and the Swift hosts
// (host app and .appex) already have their own os.log channels. The
// stdlib logger is enough to surface the message in Console.app under
// the host process's stderr.
//
//export ofem_core_log_message
func ofem_core_log_message(msg *C.char) { //nolint:revive // C-ABI symbol name
	if msg == nil {
		return
	}
	log.Printf("[ofem_core] %s", C.GoString(msg))
}

// main is required for -buildmode=c-archive but is never invoked.
func main() {}
