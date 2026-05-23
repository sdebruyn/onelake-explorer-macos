// Package api holds HTTP-client primitives shared by the Fabric REST and
// OneLake DFS clients: a TokenProvider abstraction, typed errors mapped
// from HTTP status codes, a small retry helper that honors Retry-After,
// and a bearer-injection helper.
//
// The TokenProvider interface defined here is a temporary shim. A
// parallel PR introduces internal/auth.TokenProvider with the same
// shape; once that lands, callers should depend on it directly and this
// shim can be removed.
package api

import "context"

// TokenProvider yields a Microsoft Entra access token (audience
// https://storage.azure.com/) for a given account alias. The auth
// package implements this; tests use a mock.
type TokenProvider interface {
	Token(ctx context.Context, alias string) (string, error)
}
