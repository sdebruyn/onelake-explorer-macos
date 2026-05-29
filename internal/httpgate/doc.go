// Package httpgate is a central per-host coordination layer that sits in
// front of every HTTP round trip to Fabric and OneLake.
//
// It composes with — but does not replace — the per-call retry layer in
// internal/api and internal/httpretry. The retry layer
// decides whether to retry a single in-flight call after it returns.
// httpgate decides whether the call is allowed to leave the local
// process at all, given:
//
//   - a per-host inflight cap (semaphore-style limit on concurrent calls),
//   - a per-host steady-state QPS budget (token bucket with burst), and
//   - a per-host "global pause" window applied when the server hands us
//     a Retry-After header on 429 or 503.
//
// The pause window is the load-bearing piece for the OFEM use case. When
// 50 sync tasks share a host and all 50 hit 429 within the same second,
// they all read the same Retry-After: 30 and all wake at t+30
// simultaneously — guaranteeing exactly one succeeds and the other 49
// re-trigger the throttle. With this package, every retry first has to
// go back through the host's gate; the token bucket smears the wave of
// retries over (N / qps) seconds instead of releasing them at once.
//
// Public surface is intentionally tiny:
//
//   - [Gate] is a single-host coordinator.
//   - [Registry] holds the per-host gates and is wired once at process
//     start by cmd/ofem, then passed into the Fabric and OneLake clients.
//   - [ParseRetryAfter] turns an HTTP Retry-After header into a wall-clock
//     deadline using the same rules as RFC 7231.
//
// Concurrency safety: every exported method on [Gate] and [Registry] is
// safe for concurrent use.
//
// # Package dependency
//
// internal/httpretry imports internal/httpgate (for [ParseRetryAfter] —
// single source of truth for Retry-After parsing). internal/httpgate does
// NOT import internal/httpretry. The dependency is one-way:
// httpretry → httpgate.
//
// # Interaction with internal/api.Do
//
// The retry layer in internal/api.Do composes with — and does not
// replace — the gate's pause window. When a 5xx response carries no
// Retry-After header, api.Do sleeps its own initialBackoff (~500ms)
// before retrying; the retry's Acquire then waits for the gate's
// [Defaults.MissingRetryAfter] window to elapse. These waits are
// additive: the effective delay before the next attempt actually
// leaves the local process is api.Do's backoff PLUS the gate's pause.
//
// In practice that means an unmarked 5xx on the Fabric host costs
// ~500ms (api.Do) + ~30s (Fabric MissingRetryAfter); on the OneLake
// host ~500ms + ~10s. This is intentional — the doubled wait costs
// half a second over either bound alone but guarantees that peer
// goroutines on the same host also observe the pause through the
// shared gate, not just the goroutine that received the 5xx.
package httpgate
