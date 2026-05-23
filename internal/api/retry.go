package api

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"time"
)

// maxBackoff caps the exponential backoff used for 5xx retries. Once
// the backoff reaches this value, further retries wait this same
// interval rather than continuing to double.
const maxBackoff = 30 * time.Second

// initialBackoff is the first backoff interval for 5xx retries.
const initialBackoff = 500 * time.Millisecond

// Do executes req with bounded retries:
//
//   - 2xx and most 4xx responses return immediately.
//   - 429 retries waiting for Retry-After (or initialBackoff if absent).
//   - 5xx retries with exponential backoff capped at maxBackoff.
//   - The context is checked between attempts.
//
// maxAttempts includes the initial attempt; a value < 1 is treated as 1.
// The caller owns the request body buffering: if req.GetBody is set Do
// will rewind on each retry; otherwise the body is read once into memory
// on the first call so subsequent attempts can replay it.
func Do(ctx context.Context, client *http.Client, req *http.Request, maxAttempts int) (*http.Response, error) {
	if client == nil {
		client = http.DefaultClient
	}
	if maxAttempts < 1 {
		maxAttempts = 1
	}

	// Buffer the body once so it can be replayed on retry. Skip if the
	// caller already provided GetBody or the body is nil / no-op.
	if req.Body != nil && req.Body != http.NoBody && req.GetBody == nil {
		buf, err := io.ReadAll(req.Body)
		if err != nil {
			return nil, fmt.Errorf("api: buffer request body: %w", err)
		}
		_ = req.Body.Close()
		req.Body = io.NopCloser(bytes.NewReader(buf))
		req.ContentLength = int64(len(buf))
		req.GetBody = func() (io.ReadCloser, error) {
			return io.NopCloser(bytes.NewReader(buf)), nil
		}
	}

	backoff := initialBackoff
	var lastErr error
	for attempt := 1; attempt <= maxAttempts; attempt++ {
		if err := ctx.Err(); err != nil {
			return nil, err
		}

		// Rewind body for the second and later attempts.
		if attempt > 1 && req.GetBody != nil {
			body, err := req.GetBody()
			if err != nil {
				return nil, fmt.Errorf("api: rewind request body: %w", err)
			}
			req.Body = body
		}

		// Generic retry helper; the URL is set by the caller. The gosec
		// G107/G704 SSRF taint heuristic does not apply here because the
		// callers (internal/fabric, internal/onelake) build URLs from a
		// trusted base + typed identifiers.
		resp, err := client.Do(req.WithContext(ctx)) // #nosec G107 G704

		if err != nil {
			// Network-level error. Don't retry blindly — surface it.
			return nil, err
		}

		// Success: hand the response straight back; the caller owns the body.
		if resp.StatusCode < 400 {
			return resp, nil
		}

		// Non-retriable 4xx (anything except 429): convert and return.
		if resp.StatusCode < 500 && resp.StatusCode != http.StatusTooManyRequests {
			return nil, FromResponse(resp)
		}

		// Retriable: 429 or 5xx. Decide wait and continue.
		apiErr := FromResponse(resp)
		lastErr = apiErr

		if attempt == maxAttempts {
			break
		}

		wait := backoff
		var ae *APIError
		if errors.As(apiErr, &ae) {
			if errors.Is(ae, ErrThrottled) && ae.RetryAfter > 0 {
				wait = ae.RetryAfter
			} else if errors.Is(ae, ErrServerError) && ae.RetryAfter > 0 {
				// 5xx may also carry Retry-After; honor when present.
				wait = ae.RetryAfter
			}
		}
		if wait > maxBackoff {
			wait = maxBackoff
		}

		slog.Warn("api: retrying request",
			"method", req.Method,
			"url", req.URL.Redacted(),
			"attempt", attempt,
			"max_attempts", maxAttempts,
			"status", resp.StatusCode,
			"wait", wait,
		)

		// Exponential backoff for the next iteration's default wait.
		backoff *= 2
		if backoff > maxBackoff {
			backoff = maxBackoff
		}

		t := time.NewTimer(wait)
		select {
		case <-ctx.Done():
			t.Stop()
			return nil, ctx.Err()
		case <-t.C:
		}
	}

	return nil, lastErr
}
