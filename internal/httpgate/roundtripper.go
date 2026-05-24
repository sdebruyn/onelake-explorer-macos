package httpgate

import (
	"errors"
	"log/slog"
	"net/http"
	"time"
)

// Transport is an http.RoundTripper that runs every request through the
// per-host gate of the supplied Registry. It is the recommended way to
// plug httpgate into existing *http.Client wiring: callers wrap the
// transport they already use, and gating is applied transparently on
// every attempt — including each retry an inner layer such as
// internal/api.Do issues.
//
// On 429 / 503 responses the round-tripper parses Retry-After and, when
// present, calls Penalty on the matching gate so subsequent attempts
// (from the retry layer or from peer goroutines on other requests)
// share the pause window. When the header is missing, the registry's
// per-host fallback is used.
//
// Transport never reads or alters the response body; it only inspects
// status and headers.
type Transport struct {
	// Inner is the underlying RoundTripper. nil means
	// http.DefaultTransport.
	Inner http.RoundTripper
	// Registry maps host -> *Gate. Required.
	Registry *Registry
	// Now is the clock used to interpret Retry-After. nil means
	// time.Now. Tests inject a deterministic clock.
	Now func() time.Time
}

// NewTransport is a tiny convenience constructor.
func NewTransport(inner http.RoundTripper, registry *Registry) *Transport {
	return &Transport{Inner: inner, Registry: registry}
}

// Wrap returns a shallow copy of client whose Transport gates every
// request through registry. The original client is not mutated; pass
// the result to your API client constructor.
//
// If client is nil, a new *http.Client with the gated transport is
// returned. If registry is nil, Wrap returns client unchanged - the
// caller opted out.
func Wrap(client *http.Client, registry *Registry) *http.Client {
	if registry == nil {
		return client
	}
	var base *http.Client
	if client == nil {
		base = &http.Client{}
	} else {
		copied := *client
		base = &copied
	}
	base.Transport = NewTransport(base.Transport, registry)
	return base
}

// RoundTrip implements http.RoundTripper.
func (t *Transport) RoundTrip(req *http.Request) (*http.Response, error) {
	if t.Registry == nil {
		return nil, errors.New("httpgate: Transport.Registry is nil")
	}
	inner := t.Inner
	if inner == nil {
		inner = http.DefaultTransport
	}
	now := t.Now
	if now == nil {
		now = time.Now
	}

	gate := t.Registry.Gate(req.URL.Host)
	release, err := gate.Acquire(req.Context())
	if err != nil {
		return nil, err
	}
	defer release()

	resp, err := inner.RoundTrip(req)
	if err != nil {
		return nil, err
	}

	if resp.StatusCode == http.StatusTooManyRequests || resp.StatusCode == http.StatusServiceUnavailable {
		until, ok := ParseRetryAfter(resp.Header.Get("Retry-After"), now())
		if !ok {
			if d := t.Registry.Defaults().MissingRetryAfter; d > 0 {
				until = now().Add(d)
				ok = true
			}
		}
		if ok {
			slog.Warn("httpgate: server-side throttle, pausing gate",
				slog.String("host", req.URL.Host),
				slog.Int("status", resp.StatusCode),
				slog.Time("until", until),
			)
			gate.Penalty(until)
		}
	}

	return resp, nil
}
