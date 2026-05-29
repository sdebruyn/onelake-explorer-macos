package httpretry

import (
	"context"
	"errors"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"syscall"
	"testing"
	"time"
)

// fastPolicy returns a Policy with tiny backoff windows so the table-
// driven tests don't spend real wall time waiting between attempts.
func fastPolicy(maxAttempts int) Policy {
	return Policy{
		MaxAttempts:    maxAttempts,
		InitialBackoff: 1 * time.Millisecond,
		MaxBackoff:     2 * time.Millisecond,
	}
}

func TestDo_StatusClasses(t *testing.T) {
	cases := []struct {
		name        string
		status      int
		wantRetries int
		wantErrIs   error
	}{
		{"200", 200, 1, nil},
		{"400", 400, 1, nil},
		{"401", 401, 1, ErrUnauthorized},
		{"403", 403, 1, ErrForbidden},
		{"404", 404, 1, ErrNotFound},
		{"408", 408, 3, nil},
		{"409", 409, 1, ErrConflict},
		{"410", 410, 1, ErrGone},
		{"412", 412, 1, ErrPreconditionFailed},
		{"413", 413, 1, ErrPayloadTooLarge},
		{"415", 415, 1, ErrUnsupportedMedia},
		{"416", 416, 1, ErrRangeNotSatisfiable},
		{"422", 422, 1, ErrUnprocessable},
		{"425", 425, 3, nil},
		{"429", 429, 3, ErrThrottled},
		{"500", 500, 3, ErrServerError},
		{"502", 502, 3, ErrServerError},
		{"503", 503, 3, ErrServerError},
		{"504", 504, 3, ErrServerError},
	}
	for _, c := range cases {
		c := c
		t.Run(c.name, func(t *testing.T) {
			var calls int32
			srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
				atomic.AddInt32(&calls, 1)
				// Set Retry-After: 0 so the retry path doesn't wait.
				if c.status == 429 || c.status >= 500 {
					w.Header().Set("Retry-After", "0")
				}
				w.WriteHeader(c.status)
			}))
			defer srv.Close()

			req, _ := http.NewRequest(http.MethodGet, srv.URL, nil)
			resp, err := Do(context.Background(), srv.Client(), req, fastPolicy(3))
			if resp != nil {
				_ = resp.Body.Close()
			}
			if c.status < 300 {
				if err != nil {
					t.Fatalf("unexpected error for %d: %v", c.status, err)
				}
			} else {
				if err == nil {
					t.Fatalf("expected error for %d, got nil", c.status)
				}
				if c.wantErrIs != nil && !errors.Is(err, c.wantErrIs) {
					t.Errorf("status %d: errors.Is(_, %v) = false; got %v", c.status, c.wantErrIs, err)
				}
			}
			if got := int(atomic.LoadInt32(&calls)); got != c.wantRetries {
				t.Errorf("status %d: calls = %d, want %d", c.status, got, c.wantRetries)
			}
		})
	}
}

func TestDo_RetryAfterSeconds(t *testing.T) {
	var calls int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		n := atomic.AddInt32(&calls, 1)
		if n < 2 {
			w.Header().Set("Retry-After", "0")
			w.WriteHeader(429)
			return
		}
		w.WriteHeader(200)
	}))
	defer srv.Close()

	req, _ := http.NewRequest(http.MethodGet, srv.URL, nil)
	resp, err := Do(context.Background(), srv.Client(), req, fastPolicy(3))
	if err != nil {
		t.Fatalf("Do: %v", err)
	}
	_ = resp.Body.Close()
	if got := atomic.LoadInt32(&calls); got != 2 {
		t.Errorf("calls = %d, want 2", got)
	}
}

func TestDo_RetryAfterHTTPDate(t *testing.T) {
	var calls int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		n := atomic.AddInt32(&calls, 1)
		if n < 2 {
			// 1s in the past — parseRetryAfter clamps to 0.
			past := time.Now().Add(-time.Second).UTC().Format(http.TimeFormat)
			w.Header().Set("Retry-After", past)
			w.WriteHeader(503)
			return
		}
		w.WriteHeader(200)
	}))
	defer srv.Close()

	req, _ := http.NewRequest(http.MethodGet, srv.URL, nil)
	resp, err := Do(context.Background(), srv.Client(), req, fastPolicy(3))
	if err != nil {
		t.Fatalf("Do: %v", err)
	}
	_ = resp.Body.Close()
	if got := atomic.LoadInt32(&calls); got != 2 {
		t.Errorf("calls = %d, want 2", got)
	}
}

func TestDo_BodyReplayedOnRetry(t *testing.T) {
	var bodies []string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		b, _ := io.ReadAll(r.Body)
		bodies = append(bodies, string(b))
		if len(bodies) < 2 {
			w.Header().Set("Retry-After", "0")
			w.WriteHeader(429)
			return
		}
		w.WriteHeader(200)
	}))
	defer srv.Close()

	req, _ := http.NewRequest(http.MethodPost, srv.URL, strings.NewReader("payload"))
	resp, err := Do(context.Background(), srv.Client(), req, fastPolicy(3))
	if err != nil {
		t.Fatalf("Do: %v", err)
	}
	_ = resp.Body.Close()
	if len(bodies) != 2 {
		t.Fatalf("got %d calls, want 2", len(bodies))
	}
	for i, b := range bodies {
		if b != "payload" {
			t.Errorf("body[%d] = %q, want %q", i, b, "payload")
		}
	}
}

func TestDo_ContextCanceledDuringBackoff(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Retry-After", "60")
		w.WriteHeader(503)
	}))
	defer srv.Close()

	ctx, cancel := context.WithCancel(context.Background())
	go func() {
		time.Sleep(20 * time.Millisecond)
		cancel()
	}()

	req, _ := http.NewRequest(http.MethodGet, srv.URL, nil)
	_, err := Do(ctx, srv.Client(), req, Policy{MaxAttempts: 5, InitialBackoff: time.Second, MaxBackoff: 30 * time.Second})
	if !errors.Is(err, context.Canceled) {
		t.Fatalf("want context.Canceled, got %v", err)
	}
}

func TestDo_ContextDeadlineTrumpsBudget(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(503)
	}))
	defer srv.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 50*time.Millisecond)
	defer cancel()
	req, _ := http.NewRequest(http.MethodGet, srv.URL, nil)
	_, err := Do(ctx, srv.Client(), req, Policy{MaxAttempts: 50, InitialBackoff: 30 * time.Millisecond, MaxBackoff: 200 * time.Millisecond})
	if !errors.Is(err, context.DeadlineExceeded) {
		t.Fatalf("want DeadlineExceeded, got %v", err)
	}
}

func TestDo_3xxNotSuccess(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Location", "https://elsewhere.example.com/")
		w.WriteHeader(http.StatusTemporaryRedirect)
	}))
	defer srv.Close()

	client := &http.Client{
		CheckRedirect: func(_ *http.Request, _ []*http.Request) error {
			return http.ErrUseLastResponse
		},
	}
	req, _ := http.NewRequest(http.MethodPatch, srv.URL, nil)
	_, err := Do(context.Background(), client, req, fastPolicy(3))
	var ae *APIError
	if !errors.As(err, &ae) {
		t.Fatalf("expected *APIError, got %T: %v", err, err)
	}
	if ae.StatusCode != http.StatusTemporaryRedirect {
		t.Errorf("StatusCode = %d, want 307", ae.StatusCode)
	}
}

func TestDo_AttemptsReportedOnExhaustion(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Retry-After", "0")
		w.WriteHeader(503)
	}))
	defer srv.Close()

	req, _ := http.NewRequest(http.MethodGet, srv.URL, nil)
	_, err := Do(context.Background(), srv.Client(), req, fastPolicy(4))
	if err == nil {
		t.Fatal("want error, got nil")
	}
	if got := Attempts(err); got != 4 {
		t.Errorf("Attempts(err) = %d, want 4", got)
	}
	if !errors.Is(err, ErrServerError) {
		t.Errorf("errors.Is(_, ErrServerError) = false; got %v", err)
	}
}

func TestDo_FullJitter_NeverExceedsCurrentWindow(t *testing.T) {
	// 100 iterations of jitter() must always land in [0, wait). A bug in
	// the schedule (e.g. accidentally returning wait + jitter) would
	// surface within a few iterations.
	const wait = 50 * time.Millisecond
	for i := 0; i < 100; i++ {
		got := jitter(wait)
		if got < 0 || got >= wait {
			t.Fatalf("iter %d: jitter = %v, want in [0, %v)", i, got, wait)
		}
	}
	// jitter(0) must not block or panic.
	if got := jitter(0); got != 0 {
		t.Errorf("jitter(0) = %v, want 0", got)
	}
}

func TestDo_NextBackoff_CapsAtMax(t *testing.T) {
	max := 1 * time.Second
	w := 250 * time.Millisecond
	// 4 doublings: 500ms, 1s, then capped at max.
	steps := []time.Duration{500 * time.Millisecond, 1 * time.Second, 1 * time.Second, 1 * time.Second}
	for i, want := range steps {
		w = nextBackoff(w, max)
		if w != want {
			t.Errorf("step %d: got %v, want %v", i, w, want)
		}
	}
}

func TestDo_NetworkErrorRetried(t *testing.T) {
	var calls int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		n := atomic.AddInt32(&calls, 1)
		if n < 2 {
			hj, _ := w.(http.Hijacker)
			conn, _, _ := hj.Hijack()
			_ = conn.Close()
			return
		}
		w.WriteHeader(200)
	}))
	defer srv.Close()

	req, _ := http.NewRequest(http.MethodGet, srv.URL, nil)
	resp, err := Do(context.Background(), srv.Client(), req, fastPolicy(3))
	if err != nil {
		t.Fatalf("Do: %v", err)
	}
	_ = resp.Body.Close()
	if got := atomic.LoadInt32(&calls); got != 2 {
		t.Errorf("calls = %d, want 2", got)
	}
}

func TestDo_DefaultsApplied(t *testing.T) {
	// Zero Policy => Default* constants. Verify by triggering a single
	// retry on 503 and checking we don't panic / loop forever.
	var calls int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		n := atomic.AddInt32(&calls, 1)
		if n < 2 {
			w.Header().Set("Retry-After", "0")
			w.WriteHeader(503)
			return
		}
		w.WriteHeader(200)
	}))
	defer srv.Close()
	req, _ := http.NewRequest(http.MethodGet, srv.URL, nil)
	resp, err := Do(context.Background(), srv.Client(), req, Policy{})
	if err != nil {
		t.Fatalf("Do: %v", err)
	}
	_ = resp.Body.Close()
}

// closeOnceServer hijacks and drops the connection on the first request
// (a mid-flight transport error) and returns 200 afterwards.
func closeOnceServer(t *testing.T, calls *int32) *httptest.Server {
	t.Helper()
	return httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		if atomic.AddInt32(calls, 1) < 2 {
			hj, _ := w.(http.Hijacker)
			conn, _, _ := hj.Hijack()
			_ = conn.Close()
			return
		}
		w.WriteHeader(200)
	}))
}

// TestDo_NonIdempotentTransportErrorNotRetried covers M-4: a transport
// error on a non-idempotent method (POST/PATCH) must NOT be replayed
// unless the caller asserts Idempotent — replaying could duplicate a
// write the server already applied before the connection dropped.
func TestDo_NonIdempotentTransportErrorNotRetried(t *testing.T) {
	var calls int32
	srv := closeOnceServer(t, &calls)
	defer srv.Close()

	req, _ := http.NewRequest(http.MethodPost, srv.URL, strings.NewReader("x"))
	if _, err := Do(context.Background(), srv.Client(), req, fastPolicy(3)); err == nil {
		t.Fatal("POST transport error: want error (no replay), got nil")
	}
	if got := atomic.LoadInt32(&calls); got != 1 {
		t.Errorf("calls = %d, want 1 (non-idempotent POST must not be replayed)", got)
	}
}

// TestDo_IdempotentFlagAllowsTransportRetry verifies the opt-in: with
// Idempotent set, a POST transport error IS retried.
func TestDo_IdempotentFlagAllowsTransportRetry(t *testing.T) {
	var calls int32
	srv := closeOnceServer(t, &calls)
	defer srv.Close()

	req, _ := http.NewRequest(http.MethodPost, srv.URL, strings.NewReader("x"))
	p := fastPolicy(3)
	p.Idempotent = true
	resp, err := Do(context.Background(), srv.Client(), req, p)
	if err != nil {
		t.Fatalf("Do: %v", err)
	}
	_ = resp.Body.Close()
	if got := atomic.LoadInt32(&calls); got != 2 {
		t.Errorf("calls = %d, want 2 (Idempotent POST should retry)", got)
	}
}

// TestIsRetriableTransport_* cover the typed-error classification
// introduced in Task 2. Tests are unit-level (call isRetriableTransport
// directly) so they don't require a live network.

func wrapOpErr(op string, err error) *net.OpError {
	return &net.OpError{Op: op, Net: "tcp", Err: err}
}

// TestIsRetriableTransport_ECONNREFUSEDNotRetried verifies that a
// connection-refused error is never retried. The remote address is
// wrong or the service is down — retrying burns the full budget for no
// gain.
func TestIsRetriableTransport_ECONNREFUSEDNotRetried(t *testing.T) {
	err := wrapOpErr("connect", syscall.ECONNREFUSED)
	if isRetriableTransport(err) {
		t.Error("ECONNREFUSED should NOT be retriable")
	}
}

// TestIsRetriableTransport_DNSNotFoundNotRetried ensures that a
// permanent NXDOMAIN (IsNotFound=true) is not retried — a bad hostname
// will never resolve on the next attempt.
func TestIsRetriableTransport_DNSNotFoundNotRetried(t *testing.T) {
	err := &net.DNSError{
		Err:         "no such host",
		Name:        "does-not-exist.example.invalid",
		IsNotFound:  true,
		IsTemporary: false,
	}
	if isRetriableTransport(err) {
		t.Error("DNS not-found (NXDOMAIN) should NOT be retriable")
	}
}

// TestIsRetriableTransport_DNSTemporaryRetried verifies that a
// transient DNS failure (e.g. resolver timeout) is still retried.
func TestIsRetriableTransport_DNSTemporaryRetried(t *testing.T) {
	err := &net.DNSError{
		Err:         "temporary failure in name resolution",
		Name:        "onelake.dfs.fabric.microsoft.com",
		IsTemporary: true,
	}
	if !isRetriableTransport(err) {
		t.Error("temporary DNS error SHOULD be retriable")
	}
}

// TestIsRetriableTransport_TimeoutRetried verifies that a net.Error
// with Timeout()=true (covers both read/write deadlines and dial
// timeouts) is retried.
func TestIsRetriableTransport_TimeoutRetried(t *testing.T) {
	err := &net.DNSError{
		Err:       "i/o timeout",
		Name:      "onelake.dfs.fabric.microsoft.com",
		IsTimeout: true,
	}
	if !isRetriableTransport(err) {
		t.Error("timeout error SHOULD be retriable")
	}
}

// TestIsRetriableTransport_ConnectionResetRetried verifies that
// "connection reset by peer" surfaces as retriable via the string
// fallback (ECONNRESET is also caught explicitly by the errno branch).
func TestIsRetriableTransport_ConnectionResetRetried(t *testing.T) {
	err := wrapOpErr("read", syscall.ECONNRESET)
	if !isRetriableTransport(err) {
		t.Error("ECONNRESET SHOULD be retriable")
	}
}

// TestIsRetriableTransport_ContextCanceledNotRetried confirms that a
// context.Canceled error is never retried, regardless of wrapping.
func TestIsRetriableTransport_ContextCanceledNotRetried(t *testing.T) {
	if isRetriableTransport(context.Canceled) {
		t.Error("context.Canceled MUST NOT be retriable")
	}
}

// TestIsRetriableTransport_EPIPERetried verifies that a broken-pipe error
// (e.g. the server closed the write side while we were sending) is
// retriable. The errno branch returns true directly without falling
// through to the string-match path.
func TestIsRetriableTransport_EPIPERetried(t *testing.T) {
	err := wrapOpErr("write", syscall.EPIPE)
	if !isRetriableTransport(err) {
		t.Error("EPIPE SHOULD be retriable")
	}
}

// TestIsRetriableTransport_ENOENTNotRetried verifies that a missing
// unix-socket path (ENOENT) is never retried — the daemon is not
// running, and retrying will not create the socket.
func TestIsRetriableTransport_ENOENTNotRetried(t *testing.T) {
	err := wrapOpErr("dial", syscall.ENOENT)
	if isRetriableTransport(err) {
		t.Error("ENOENT should NOT be retriable")
	}
}

// TestIsRetriableTransport_EACCESNotRetried verifies that a permission
// error on a unix-socket path (EACCES) is never retried — no amount of
// retrying will grant the missing permission.
func TestIsRetriableTransport_EACCESNotRetried(t *testing.T) {
	err := wrapOpErr("dial", syscall.EACCES)
	if isRetriableTransport(err) {
		t.Error("EACCES should NOT be retriable")
	}
}
