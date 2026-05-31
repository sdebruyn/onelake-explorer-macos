package httpgate

import (
	"errors"
	"io"
	"log/slog"
	"net/http"
	"sync/atomic"
	"time"
)

// Transport is an http.RoundTripper that runs every request through the
// per-host gate of the supplied Registry. It is the recommended way to
// plug httpgate into existing *http.Client wiring: callers wrap the
// transport they already use, and gating is applied transparently on
// every attempt — including each retry an outer layer such as
// internal/httpretry.Do issues.
//
// On 429 / 503 responses the round-tripper parses Retry-After and, when
// present, calls Penalty on the matching gate so subsequent attempts
// (from the retry layer or from peer goroutines on other requests)
// share the pause window. When the header is missing, the registry's
// per-host fallback is used.
//
// Transport never reads or alters the response body; it only inspects
// status and headers. The gate slot is held for the entire lifetime of
// the response — from Acquire all the way through to resp.Body.Close —
// so streaming reads (DFS Range GETs) keep the slot reserved while bytes
// are still on the wire, not only while the request headers are being
// exchanged.
type Transport struct {
	// Inner is the underlying RoundTripper. nil means
	// http.DefaultTransport.
	//
	// Footgun: http.DefaultTransport has no timeout, so leaving Inner
	// nil (or wrapping a client whose Transport is nil) yields an
	// un-timeouted transport behind the gate. Always pass an inner
	// Transport with sensible per-request timeouts.
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
//
// Footgun: the returned client uses http.DefaultTransport when no
// inner transport is provided, and http.DefaultTransport has no
// Timeout. Production callers should always pass a *http.Client with
// a configured Timeout (and ideally an explicit Transport with its
// own dial/TLS timeouts) so that a stuck connection cannot pin a
// gate slot indefinitely.
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
//
// The acquired gate slot is released only when resp.Body is closed (or
// immediately on the error / nil-body paths). This keeps the slot held
// for the entire I/O lifetime of the response, which is what matters
// for the OneLake DFS use case where the bulk of the load is the
// streaming body, not the request handshake.
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

	resp, err := inner.RoundTrip(req)
	if err != nil {
		release()
		return nil, err
	}

	// Post any Penalty BEFORE wrapping the body so the in-band retry in
	// internal/httpretry.Do (which only sees status+headers) observes the
	// new pause window the moment it loops back into Acquire.
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

	if resp.Body == nil {
		// HEAD responses and synthetic bodies set Body to nil; nothing
		// to wrap, release the slot now.
		release()
		return resp, nil
	}
	resp.Body = &releasingBody{ReadCloser: resp.Body, release: release}
	return resp, nil
}

// releasingBody wraps the response body so the gate slot is released
// exactly once, on the first Close(). Subsequent Close() calls (or a
// double-defer at the call site) are a no-op for the release function
// but still forward to the wrapped body's Close() so callers see its
// real error.
type releasingBody struct {
	io.ReadCloser
	release  func()
	released atomic.Bool
}

func (b *releasingBody) Close() error {
	if b.released.CompareAndSwap(false, true) {
		defer b.release()
	}
	return b.ReadCloser.Close()
}
