// Package httpretry is the shared retry primitive for every outbound HTTP
// request OFEM makes. Both internal/fabric and internal/onelake call
// [Do] so the retry policy, backoff schedule, and error classification
// stay in one place.
//
// Retriable conditions:
//
//   - HTTP 408, 425, 429, 500, 502, 503, 504.
//   - Network timeouts.
//   - net.OpError with Op == "dial" or "read" / "write".
//   - io.EOF and io.ErrUnexpectedEOF surfaced from the round-trip.
//   - "connection reset" / "broken pipe" errors from the kernel.
//
// Non-retriable: every other 4xx (400, 401, 403, 404, 409, 410, 412,
// 413, 415, 416, 422, …) is surfaced immediately as an [APIError].
// The deliberate cutoff matches docs/onelake-api.md.
//
// Backoff: exponential full-jitter starting at 250 ms, doubling each
// attempt, capped at 30 s. With the default budget of 6 attempts the
// worst-case wall-clock is roughly 5 minutes. 429 and 503 responses
// honor the server's Retry-After header (seconds or HTTP date) when
// it falls inside the cap.
//
// Cancellation: every wait window selects on the caller's context.
// A context deadline overrides the retry budget — when the deadline
// elapses, Do returns ctx.Err() with the wrapped last response error
// available via [Result.Last].
//
// The package composes with internal/httpgate (a separate
// per-host coordination layer): httpretry decides whether to try
// again, httpgate decides whether the next attempt may actually go
// out. They do not import each other.
package httpretry
