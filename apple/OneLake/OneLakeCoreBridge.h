// OneLakeCoreBridge.h
//
// Swift bridging header for the OneLake host app. Re-exports the
// auto-generated libofemcore.h so Swift can call the cgo-exported
// `ofem_core_*` C functions directly.
//
// The libofemcore.{a,h} pair is produced by `make cgo-build` and
// lives in `apple/build/cgo/`; that directory is on this target's
// HEADER_SEARCH_PATHS / LIBRARY_SEARCH_PATHS (see apple/project.yml).

#ifndef ONELAKE_CORE_BRIDGE_H
#define ONELAKE_CORE_BRIDGE_H

#import "libofemcore.h"

#endif /* ONELAKE_CORE_BRIDGE_H */
