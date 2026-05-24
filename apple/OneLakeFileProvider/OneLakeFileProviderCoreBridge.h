// OneLakeFileProviderCoreBridge.h
//
// Swift bridging header for the OneLake File Provider Extension.
// Re-exports the auto-generated libofemcore.h so Swift can call the
// cgo-exported `ofem_core_*` C functions directly.
//
// The libofemcore.{a,h} pair is produced by `make cgo-build` and
// lives in `apple/build/cgo/`; that directory is on this target's
// HEADER_SEARCH_PATHS / LIBRARY_SEARCH_PATHS (see apple/project.yml).

#ifndef ONELAKE_FILE_PROVIDER_CORE_BRIDGE_H
#define ONELAKE_FILE_PROVIDER_CORE_BRIDGE_H

#import "libofemcore.h"

#endif /* ONELAKE_FILE_PROVIDER_CORE_BRIDGE_H */
