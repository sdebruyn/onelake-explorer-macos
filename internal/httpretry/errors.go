package httpretry

import (
	"errors"
	"fmt"
	"io"
	"net/http"
	"strings"
	"time"

	"github.com/sdebruyn/onelake-explorer-macos/internal/httpgate"
)

// Sentinel errors mapped from HTTP status codes. Callers use [errors.Is]
// to detect categories without needing to type-assert [APIError]. The
// retry helper unwraps these to decide whether to retry.
var (
	// ErrUnauthorized maps to HTTP 401. It signals that the token is
	// missing, expired, or invalid and surfaces a re-authentication
	// requirement to the caller (e.g. the File Provider re-auth surface).
	// The http retry layer does NOT retry 401 — token refresh and a
	// second attempt are the caller's responsibility.
	ErrUnauthorized = errors.New("httpretry: unauthorized (401)")
	// ErrForbidden maps to HTTP 403.
	ErrForbidden = errors.New("httpretry: forbidden (403)")
	// ErrNotFound maps to HTTP 404.
	ErrNotFound = errors.New("httpretry: not found (404)")
	// ErrConflict maps to HTTP 409.
	ErrConflict = errors.New("httpretry: conflict (409)")
	// ErrGone maps to HTTP 410.
	ErrGone = errors.New("httpretry: gone (410)")
	// ErrPreconditionFailed maps to HTTP 412 (If-Match etag conflict).
	ErrPreconditionFailed = errors.New("httpretry: precondition failed (412)")
	// ErrPayloadTooLarge maps to HTTP 413.
	ErrPayloadTooLarge = errors.New("httpretry: payload too large (413)")
	// ErrUnsupportedMedia maps to HTTP 415.
	ErrUnsupportedMedia = errors.New("httpretry: unsupported media type (415)")
	// ErrRangeNotSatisfiable maps to HTTP 416.
	ErrRangeNotSatisfiable = errors.New("httpretry: range not satisfiable (416)")
	// ErrUnprocessable maps to HTTP 422.
	ErrUnprocessable = errors.New("httpretry: unprocessable entity (422)")
	// ErrThrottled maps to HTTP 429. The retry helper honors Retry-After.
	ErrThrottled = errors.New("httpretry: throttled (429)")
	// ErrServerError maps to any 5xx the helper did not specifically name.
	ErrServerError = errors.New("httpretry: server error (5xx)")
)

// APIError is returned for any non-2xx response. It wraps the matching
// sentinel error (ErrUnauthorized, ErrNotFound, …) so [errors.Is] keeps
// working even when callers receive a generic APIError.
type APIError struct {
	StatusCode int
	Status     string
	Body       []byte
	// RetryAfter is the parsed Retry-After header, zero if absent.
	RetryAfter time.Duration
	// Attempts is the number of attempts made before this error was
	// surfaced; populated by [Do] when it gives up on a retriable status.
	// Single-shot errors (the immediate non-retriable case) carry 1.
	Attempts int
	// sentinel is the typed sentinel this status maps to, for Unwrap.
	sentinel error
}

// Error implements the error interface.
func (e *APIError) Error() string {
	body := strings.TrimSpace(string(e.Body))
	if len(body) > 256 {
		body = body[:256] + "…"
	}
	attemptsSuffix := ""
	if e.Attempts > 1 {
		attemptsSuffix = fmt.Sprintf(" after %d attempts", e.Attempts)
	}
	if body == "" {
		return fmt.Sprintf("httpretry: HTTP %d %s%s", e.StatusCode, e.Status, attemptsSuffix)
	}
	return fmt.Sprintf("httpretry: HTTP %d %s%s: %s", e.StatusCode, e.Status, attemptsSuffix, body)
}

// Unwrap allows [errors.Is] to walk to the sentinel.
func (e *APIError) Unwrap() error { return e.sentinel }

// FromResponse builds an APIError from an HTTP response. It consumes
// (and closes) the response body. Returns nil if the response is 2xx.
//
// The returned APIError wraps the appropriate sentinel error so
// [errors.Is](err, ErrNotFound) etc. works without further plumbing.
func FromResponse(resp *http.Response) error {
	if resp == nil {
		return errors.New("httpretry: nil response")
	}
	if resp.StatusCode >= 200 && resp.StatusCode < 300 {
		return nil
	}

	body, _ := io.ReadAll(resp.Body)
	_ = resp.Body.Close()

	ae := &APIError{
		StatusCode: resp.StatusCode,
		Status:     resp.Status,
		Body:       body,
		Attempts:   1,
	}
	ae.sentinel = sentinelFor(resp.StatusCode)
	if isRetryAfterStatus(resp.StatusCode) {
		ae.RetryAfter = parseRetryAfter(resp.Header.Get("Retry-After"))
	}
	return ae
}

// sentinelFor maps an HTTP status code to its typed sentinel. Statuses
// without a specific sentinel still produce an APIError (no wrapping),
// so callers can match by StatusCode if needed.
func sentinelFor(status int) error {
	switch status {
	case http.StatusUnauthorized:
		return ErrUnauthorized
	case http.StatusForbidden:
		return ErrForbidden
	case http.StatusNotFound:
		return ErrNotFound
	case http.StatusConflict:
		return ErrConflict
	case http.StatusGone:
		return ErrGone
	case http.StatusPreconditionFailed:
		return ErrPreconditionFailed
	case http.StatusRequestEntityTooLarge:
		return ErrPayloadTooLarge
	case http.StatusUnsupportedMediaType:
		return ErrUnsupportedMedia
	case http.StatusRequestedRangeNotSatisfiable:
		return ErrRangeNotSatisfiable
	case http.StatusUnprocessableEntity:
		return ErrUnprocessable
	case http.StatusTooManyRequests:
		return ErrThrottled
	}
	if status >= 500 {
		return ErrServerError
	}
	return nil
}

// isRetryAfterStatus reports whether the server may legitimately send a
// Retry-After header for the given status. Per RFC 9110 it is defined
// for 429 and 503; in practice some intermediates emit it on other 5xx
// responses too, so we accept Retry-After on every 5xx as a defensive
// measure (parseRetryAfter handles garbage by returning zero).
func isRetryAfterStatus(status int) bool {
	return status == http.StatusTooManyRequests || status >= 500
}

// parseRetryAfter parses the Retry-After header into a relative delay,
// returning zero for an empty or unparsable header. It delegates to the
// single RFC 7231 implementation in [httpgate.ParseRetryAfter] (which
// returns an absolute deadline) so the two packages cannot drift.
func parseRetryAfter(v string) time.Duration {
	// Capture now once and reuse it for the delta so an integer
	// delta-seconds value round-trips exactly (a second time.Now() via
	// time.Until would shave off a few microseconds).
	now := time.Now()
	deadline, ok := httpgate.ParseRetryAfter(v, now)
	if !ok {
		return 0
	}
	if d := deadline.Sub(now); d > 0 {
		return d
	}
	return 0
}
