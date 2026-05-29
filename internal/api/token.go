// Package api holds HTTP-client primitives shared by the Fabric REST and
// OneLake DFS clients: a TokenProvider abstraction, typed errors mapped
// from HTTP status codes, a small retry helper that honors Retry-After,
// and a bearer-injection helper.
package api
