package httpgate

import (
	"net/http"
	"strconv"
	"strings"
	"time"
)

// ParseRetryAfter parses an HTTP Retry-After header value per RFC 7231
// section 7.1.3. The header is either:
//
//   - a non-negative integer of seconds (delta-seconds), or
//   - an HTTP-date (RFC 1123 / RFC 850 / asctime).
//
// On success it returns the wall-clock deadline (now + delta, or the
// parsed timestamp) and true. On an empty, malformed or negative value
// it returns the zero time and false.
//
// The now argument is taken as the reference for delta-seconds parsing
// so callers can pin a deterministic clock in tests. Pass time.Now() in
// production code.
func ParseRetryAfter(v string, now time.Time) (time.Time, bool) {
	v = strings.TrimSpace(v)
	if v == "" {
		return time.Time{}, false
	}
	if secs, err := strconv.Atoi(v); err == nil {
		if secs < 0 {
			return time.Time{}, false
		}
		return now.Add(time.Duration(secs) * time.Second), true
	}
	if t, err := http.ParseTime(v); err == nil {
		if !t.After(now) {
			return time.Time{}, false
		}
		return t, true
	}
	return time.Time{}, false
}
