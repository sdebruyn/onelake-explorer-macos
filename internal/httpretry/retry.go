package httpretry

import (
	"bytes"
	"context"
	"crypto/rand"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"math/big"
	"net"
	"net/http"
	"strings"
	"time"
)

// Defaults match the spec in package doc. Override via [Policy].
const (
	// DefaultMaxAttempts is the total number of attempts including the
	// first one. ~6 attempts at 250ms doubling caps the worst-case
	// wall-clock around 5 minutes.
	DefaultMaxAttempts = 6
	// DefaultInitialBackoff is the first wait window before the second
	// attempt. Full-jitter draws uniformly in [0, current).
	DefaultInitialBackoff = 250 * time.Millisecond
	// DefaultMaxBackoff caps a single wait window. Once the exponential
	// schedule reaches this value further attempts cap here.
	DefaultMaxBackoff = 30 * time.Second
)

// Policy parametrises [Do]. The zero value is valid and uses the
// Default* constants above.
type Policy struct {
	// MaxAttempts is the total number of attempts. Values < 1 are
	// treated as 1 (effectively disabling retry).
	MaxAttempts int
	// InitialBackoff is the first wait window. Values <= 0 use
	// DefaultInitialBackoff.
	InitialBackoff time.Duration
	// MaxBackoff caps a single wait window. Values <= 0 use
	// DefaultMaxBackoff.
	MaxBackoff time.Duration
	// Logger receives one warn line per retry. Defaults to slog.Default
	// with a "component=httpretry" attribute.
	Logger *slog.Logger
}

// defaulted returns a copy of p with zero fields filled in from the
// Default* constants.
func (p Policy) defaulted() Policy {
	if p.MaxAttempts < 1 {
		p.MaxAttempts = DefaultMaxAttempts
	}
	if p.InitialBackoff <= 0 {
		p.InitialBackoff = DefaultInitialBackoff
	}
	if p.MaxBackoff <= 0 {
		p.MaxBackoff = DefaultMaxBackoff
	}
	if p.Logger == nil {
		p.Logger = slog.Default().With(slog.String("component", "httpretry"))
	}
	return p
}

// Do executes req with bounded retries per [Policy]:
//
//   - 2xx returns immediately with the response (caller owns the body).
//   - Retriable conditions (see package doc) retry with full-jitter
//     exponential backoff. 429 and 5xx with a usable Retry-After honor
//     the header (capped at MaxBackoff).
//   - Non-retriable 4xx returns immediately as an [APIError].
//   - 3xx is treated as an error so a stray redirect on PATCH/PUT/DELETE
//     never looks like success.
//
// The request body, when present, is buffered once on the first call so
// subsequent retries can replay it. Callers that already supply
// req.GetBody bypass the in-memory buffer.
//
// The returned error from a retriable failure carries the attempt
// count (see [APIError.Attempts]). A context deadline / cancellation
// surfaces as ctx.Err() and trumps the retry budget.
func Do(ctx context.Context, client *http.Client, req *http.Request, p Policy) (*http.Response, error) {
	if client == nil {
		client = http.DefaultClient
	}
	p = p.defaulted()

	if err := ensureReplayableBody(req); err != nil {
		return nil, err
	}

	wait := p.InitialBackoff
	var lastErr error
	for attempt := 1; attempt <= p.MaxAttempts; attempt++ {
		if err := ctx.Err(); err != nil {
			return nil, err
		}

		if attempt > 1 && req.GetBody != nil {
			body, err := req.GetBody()
			if err != nil {
				return nil, fmt.Errorf("httpretry: rewind request body: %w", err)
			}
			req.Body = body
		}

		// #nosec G107 G704 -- URL is composed by trusted callers
		// (internal/fabric, internal/onelake) from a fixed base + typed
		// identifiers; this is not user-controlled input.
		resp, err := client.Do(req.WithContext(ctx))

		switch {
		case err != nil:
			if !isRetriableTransport(err) {
				return nil, err
			}
			lastErr = err
			p.Logger.Warn("transport error; will retry",
				slog.String("method", req.Method),
				slog.String("url", req.URL.Redacted()),
				slog.Int("attempt", attempt),
				slog.Int("max_attempts", p.MaxAttempts),
				slog.Any("err", err),
			)
		case resp.StatusCode < 300:
			return resp, nil
		case resp.StatusCode < 400:
			// Treat 3xx the stdlib didn't auto-follow as an error so a
			// proxy-injected redirect on PATCH/PUT/DELETE doesn't
			// silently masquerade as a 2xx.
			return nil, FromResponse(resp)
		case !isRetriableStatus(resp.StatusCode):
			return nil, FromResponse(resp)
		default:
			respErr := FromResponse(resp)
			var apiErr *APIError
			if !errors.As(respErr, &apiErr) {
				// Defensive: FromResponse always returns *APIError for
				// non-2xx; this branch keeps us from nil-derefing if
				// that contract ever changes.
				return nil, respErr
			}
			lastErr = apiErr
			if attempt == p.MaxAttempts {
				apiErr.Attempts = attempt
				return nil, &attemptedError{wrapped: apiErr, attempts: attempt}
			}
			waitOverride := time.Duration(0)
			if apiErr.RetryAfter > 0 {
				waitOverride = apiErr.RetryAfter
				if waitOverride > p.MaxBackoff {
					waitOverride = p.MaxBackoff
				}
			}
			if waitOverride > 0 {
				p.Logger.Warn("retriable response; will retry",
					slog.String("method", req.Method),
					slog.String("url", req.URL.Redacted()),
					slog.Int("attempt", attempt),
					slog.Int("max_attempts", p.MaxAttempts),
					slog.Int("status", resp.StatusCode),
					slog.Duration("wait", waitOverride),
					slog.Bool("retry_after_honored", true),
				)
				if err := sleepCtx(ctx, waitOverride); err != nil {
					return nil, err
				}
				wait = nextBackoff(wait, p.MaxBackoff)
				continue
			}
		}

		if attempt == p.MaxAttempts {
			break
		}

		jittered := jitter(wait)
		p.Logger.Warn("retriable failure; will retry after jittered backoff",
			slog.String("method", req.Method),
			slog.String("url", req.URL.Redacted()),
			slog.Int("attempt", attempt),
			slog.Int("max_attempts", p.MaxAttempts),
			slog.Duration("wait", jittered),
		)
		if err := sleepCtx(ctx, jittered); err != nil {
			return nil, err
		}
		wait = nextBackoff(wait, p.MaxBackoff)
	}

	return nil, &attemptedError{wrapped: lastErr, attempts: p.MaxAttempts}
}

// attemptedError wraps the final error returned by [Do] with the number
// of attempts that were made. It preserves [errors.Is] / [errors.As]
// traversal to the underlying error (including any [APIError] sentinel).
type attemptedError struct {
	wrapped  error
	attempts int
}

func (e *attemptedError) Error() string {
	if e.wrapped == nil {
		return fmt.Sprintf("httpretry: failed after %d attempts", e.attempts)
	}
	return fmt.Sprintf("httpretry: %v (after %d attempts)", e.wrapped, e.attempts)
}

func (e *attemptedError) Unwrap() error { return e.wrapped }

// Attempts returns the number of attempts a [Do] call made before
// surfacing this error. Useful for telemetry without type-asserting.
func (e *attemptedError) Attempts() int { return e.attempts }

// Attempts walks the error chain for an *attemptedError and returns its
// recorded count, or 1 if none is present.
func Attempts(err error) int {
	var ae *attemptedError
	if errors.As(err, &ae) {
		return ae.attempts
	}
	var apiErr *APIError
	if errors.As(err, &apiErr) && apiErr.Attempts > 0 {
		return apiErr.Attempts
	}
	if err != nil {
		return 1
	}
	return 0
}

// nextBackoff doubles wait, clamping to maxBackoff. Operates on the
// pre-jitter window so the schedule is independent of the realised
// random wait the caller actually slept for.
func nextBackoff(wait, maxBackoff time.Duration) time.Duration {
	next := wait * 2
	if next > maxBackoff || next <= 0 {
		return maxBackoff
	}
	return next
}

// jitter returns a uniformly distributed value in [0, wait). When wait
// is non-positive it returns zero so the caller does not sleep at all.
// Falls back to math/big's Int(rand.Reader, n) for cryptographic
// quality; the cost is negligible on the retry path.
func jitter(wait time.Duration) time.Duration {
	if wait <= 0 {
		return 0
	}
	n, err := rand.Int(rand.Reader, big.NewInt(int64(wait)))
	if err != nil {
		// Fallback: degrade to deterministic half-window rather than
		// blocking on entropy. Highly unlikely to ever fire.
		return wait / 2
	}
	return time.Duration(n.Int64())
}

// sleepCtx blocks for d unless ctx fires first. Returns ctx.Err() on
// cancellation, nil otherwise.
func sleepCtx(ctx context.Context, d time.Duration) error {
	if d <= 0 {
		return nil
	}
	t := time.NewTimer(d)
	defer t.Stop()
	select {
	case <-ctx.Done():
		return ctx.Err()
	case <-t.C:
		return nil
	}
}

// isRetriableStatus reports whether an HTTP status warrants a retry.
// 408 (Request Timeout), 425 (Too Early), 429, and 500-504 fall in this
// set; everything else 4xx is treated as terminal (the caller's request
// is wrong; retrying won't help).
func isRetriableStatus(status int) bool {
	switch status {
	case http.StatusRequestTimeout,
		http.StatusTooEarly,
		http.StatusTooManyRequests,
		http.StatusInternalServerError,
		http.StatusBadGateway,
		http.StatusServiceUnavailable,
		http.StatusGatewayTimeout:
		return true
	}
	return false
}

// isRetriableTransport reports whether a transport-layer error is
// worth retrying. We retry on the kernel- and DNS-class failures that
// typically resolve themselves on the next attempt:
//
//   - net.Error.Timeout()
//   - net.DNSError
//   - net.OpError with a generic syscall failure
//   - io.EOF and io.ErrUnexpectedEOF surfacing mid-body
//   - "connection reset" / "broken pipe" (substring match — the stdlib
//     does not export a stable error sentinel for these on every OS).
//
// We deliberately do NOT retry on context cancellation: that's a
// caller-driven stop signal and must propagate immediately.
func isRetriableTransport(err error) bool {
	if err == nil {
		return false
	}
	if errors.Is(err, context.Canceled) || errors.Is(err, context.DeadlineExceeded) {
		return false
	}
	var netErr net.Error
	if errors.As(err, &netErr) && netErr.Timeout() {
		return true
	}
	var dnsErr *net.DNSError
	if errors.As(err, &dnsErr) {
		return true
	}
	var opErr *net.OpError
	if errors.As(err, &opErr) {
		return true
	}
	if errors.Is(err, io.EOF) || errors.Is(err, io.ErrUnexpectedEOF) {
		return true
	}
	msg := err.Error()
	if strings.Contains(msg, "connection reset") ||
		strings.Contains(msg, "broken pipe") ||
		strings.Contains(msg, "connection refused") ||
		strings.Contains(msg, "no such host") {
		return true
	}
	return false
}

// ensureReplayableBody buffers req.Body into memory and sets GetBody so
// later attempts can rewind. No-op when the body is nil, http.NoBody, or
// the caller already supplied GetBody.
//
// The buffered slice is also exposed via GetBody for two reasons:
//   - rewinding without re-reading the original (often a one-shot)
//     reader.
//   - keeping Content-Length consistent across attempts so the
//     transport sets the right Content-Length header on every retry.
func ensureReplayableBody(req *http.Request) error {
	if req.Body == nil || req.Body == http.NoBody {
		return nil
	}
	if req.GetBody != nil {
		return nil
	}
	buf, err := io.ReadAll(req.Body)
	if err != nil {
		return fmt.Errorf("httpretry: buffer request body: %w", err)
	}
	_ = req.Body.Close()
	req.Body = io.NopCloser(bytes.NewReader(buf))
	req.ContentLength = int64(len(buf))
	req.GetBody = func() (io.ReadCloser, error) {
		return io.NopCloser(bytes.NewReader(buf)), nil
	}
	return nil
}

