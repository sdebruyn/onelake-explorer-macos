// Package api holds HTTP-client primitives shared by the Fabric REST and
// OneLake DFS clients: a TokenProvider abstraction, typed errors mapped
// from HTTP status codes, a small retry helper that honors Retry-After,
// and a bearer-injection helper.
package api

import "github.com/sdebruyn/onelake-explorer-macos/internal/auth"

// TokenProvider yields a Microsoft Entra access token (audience
// https://storage.azure.com/) for a given account alias.
//
// Deprecated: use [github.com/sdebruyn/onelake-explorer-macos/internal/auth.TokenProvider]
// instead. This alias keeps existing call sites compiling for one
// release while they migrate; new code should import the canonical
// interface from internal/auth directly. The alias will be removed in
// a future release.
type TokenProvider = auth.TokenProvider
