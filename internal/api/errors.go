package api

import (
	"errors"
	"fmt"
	"io"
	"net/http"
	"strconv"
	"strings"
	"time"
)

// Sentinel errors mapped from HTTP status codes. Callers use errors.Is
// to detect categories without needing to type-assert APIError. The
// retry helper unwraps these to decide whether to retry.
var (
	// ErrUnauthorized maps to HTTP 401. The token expired or is invalid;
	// the caller should refresh the token and retry once.
	ErrUnauthorized = errors.New("api: unauthorized (401)")
	// ErrForbidden maps to HTTP 403. The principal is authenticated but
	// lacks permission. Do not retry.
	ErrForbidden = errors.New("api: forbidden (403)")
	// ErrNotFound maps to HTTP 404.
	ErrNotFound = errors.New("api: not found (404)")
	// ErrConflict maps to HTTP 409 (e.g. directory already exists).
	ErrConflict = errors.New("api: conflict (409)")
	// ErrPreconditionFailed maps to HTTP 412 (e.g. If-Match etag conflict).
	ErrPreconditionFailed = errors.New("api: precondition failed (412)")
	// ErrThrottled maps to HTTP 429. The retry helper honors Retry-After.
	ErrThrottled = errors.New("api: throttled (429)")
	// ErrServerError maps to any 5xx. The retry helper backs off.
	ErrServerError = errors.New("api: server error (5xx)")
)

// APIError is returned for any non-2xx response that the typed sentinels
// do not specifically describe. It carries the status code and the raw
// response body for diagnostics. APIError wraps the matching sentinel
// (ErrUnauthorized, ErrNotFound, …) so errors.Is keeps working.
type APIError struct {
	StatusCode int
	Status     string
	Body       []byte
	// RetryAfter is the parsed Retry-After header, zero if absent.
	RetryAfter time.Duration
	// sentinel is the typed sentinel this status maps to, for Unwrap.
	sentinel error
}

// Error implements the error interface.
func (e *APIError) Error() string {
	body := strings.TrimSpace(string(e.Body))
	if len(body) > 256 {
		body = body[:256] + "…"
	}
	if body == "" {
		return fmt.Sprintf("api: HTTP %d %s", e.StatusCode, e.Status)
	}
	return fmt.Sprintf("api: HTTP %d %s: %s", e.StatusCode, e.Status, body)
}

// Unwrap allows errors.Is to walk to the sentinel.
func (e *APIError) Unwrap() error { return e.sentinel }

// FromResponse builds an APIError from an HTTP response. It consumes
// (and closes) the response body. Returns nil if the response is 2xx.
//
// The returned APIError wraps the appropriate sentinel error so
// errors.Is(err, ErrNotFound) etc. works without further plumbing.
func FromResponse(resp *http.Response) error {
	if resp == nil {
		return errors.New("api: nil response")
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
	}

	switch {
	case resp.StatusCode == http.StatusUnauthorized:
		ae.sentinel = ErrUnauthorized
	case resp.StatusCode == http.StatusForbidden:
		ae.sentinel = ErrForbidden
	case resp.StatusCode == http.StatusNotFound:
		ae.sentinel = ErrNotFound
	case resp.StatusCode == http.StatusConflict:
		ae.sentinel = ErrConflict
	case resp.StatusCode == http.StatusPreconditionFailed:
		ae.sentinel = ErrPreconditionFailed
	case resp.StatusCode == http.StatusTooManyRequests:
		ae.sentinel = ErrThrottled
		ae.RetryAfter = parseRetryAfter(resp.Header.Get("Retry-After"))
	case resp.StatusCode >= 500:
		ae.sentinel = ErrServerError
		ae.RetryAfter = parseRetryAfter(resp.Header.Get("Retry-After"))
	}

	return ae
}

// parseRetryAfter parses the Retry-After header. Per RFC 7231 the value
// is either a non-negative integer of seconds or an HTTP-date. Returns
// zero for an empty or unparsable header.
func parseRetryAfter(v string) time.Duration {
	v = strings.TrimSpace(v)
	if v == "" {
		return 0
	}
	if secs, err := strconv.Atoi(v); err == nil {
		if secs < 0 {
			return 0
		}
		return time.Duration(secs) * time.Second
	}
	if t, err := http.ParseTime(v); err == nil {
		d := time.Until(t)
		if d < 0 {
			return 0
		}
		return d
	}
	return 0
}
