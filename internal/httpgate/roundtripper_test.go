package httpgate

import (
	"context"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

// TestTransport_PenaltyOn429 verifies that a single 429 with a
// Retry-After header installs the parsed deadline on the matching gate.
func TestTransport_PenaltyOn429(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Retry-After", "2")
		w.WriteHeader(http.StatusTooManyRequests)
	}))
	defer srv.Close()
	u, _ := url.Parse(srv.URL)

	reg := NewRegistry(Defaults{Concurrency: 4, QPS: 100, Burst: 100})
	reg.Register(u.Host, 4, 100, 100)

	client := Wrap(&http.Client{Timeout: 5 * time.Second}, reg)

	resp, err := client.Get(srv.URL)
	if err != nil {
		t.Fatalf("Get: %v", err)
	}
	_, _ = io.Copy(io.Discard, resp.Body)
	_ = resp.Body.Close()

	st := reg.Gate(u.Host).State()
	if d := time.Until(st.PauseUntil); d < time.Second || d > 3*time.Second {
		t.Errorf("PauseUntil delta = %s, want ~2s", d)
	}
}

// TestTransport_MissingRetryAfterFallback verifies that when the server
// returns 429/503 without a Retry-After header, the configured default
// pause is applied.
func TestTransport_MissingRetryAfterFallback(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusTooManyRequests)
	}))
	defer srv.Close()
	u, _ := url.Parse(srv.URL)

	reg := NewRegistry(Defaults{
		Concurrency:       4,
		QPS:               100,
		Burst:             100,
		MissingRetryAfter: 5 * time.Second,
	})
	reg.Register(u.Host, 4, 100, 100)
	client := Wrap(nil, reg)

	resp, err := client.Get(srv.URL)
	if err != nil {
		t.Fatalf("Get: %v", err)
	}
	_, _ = io.Copy(io.Discard, resp.Body)
	_ = resp.Body.Close()

	st := reg.Gate(u.Host).State()
	if d := time.Until(st.PauseUntil); d < 4*time.Second || d > 6*time.Second {
		t.Errorf("fallback PauseUntil delta = %s, want ~5s", d)
	}
}

// TestTransport_NilRegistryNoOp confirms that Wrap with a nil registry
// returns the client unchanged.
func TestTransport_NilRegistryNoOp(t *testing.T) {
	c := &http.Client{Timeout: time.Second}
	if got := Wrap(c, nil); got != c {
		t.Errorf("Wrap with nil registry should be a no-op")
	}
}

// TestTransport_SuccessNoPenalty verifies that a 200 response does not
// install any pause window.
func TestTransport_SuccessNoPenalty(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		_, _ = io.WriteString(w, "ok")
	}))
	defer srv.Close()
	u, _ := url.Parse(srv.URL)

	reg := NewRegistry(Defaults{Concurrency: 4, QPS: 100, Burst: 100, MissingRetryAfter: 5 * time.Second})
	reg.Register(u.Host, 4, 100, 100)
	client := Wrap(nil, reg)

	resp, err := client.Get(srv.URL)
	if err != nil {
		t.Fatalf("Get: %v", err)
	}
	b, _ := io.ReadAll(resp.Body)
	_ = resp.Body.Close()
	if !strings.HasPrefix(string(b), "ok") {
		t.Errorf("body = %q", b)
	}

	if !reg.Gate(u.Host).State().PauseUntil.IsZero() {
		t.Errorf("PauseUntil should be zero after 200")
	}
}

// TestTransport_GateConcurrencyApplied verifies that the gate's
// concurrency cap is enforced through the RoundTripper.
func TestTransport_GateConcurrencyApplied(t *testing.T) {
	const cap = 2
	var (
		inflight int32
		peak     int32
	)
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		cur := atomic.AddInt32(&inflight, 1)
		for {
			p := atomic.LoadInt32(&peak)
			if cur <= p || atomic.CompareAndSwapInt32(&peak, p, cur) {
				break
			}
		}
		time.Sleep(50 * time.Millisecond)
		atomic.AddInt32(&inflight, -1)
		w.WriteHeader(200)
	}))
	defer srv.Close()
	u, _ := url.Parse(srv.URL)

	reg := NewRegistry(Defaults{Concurrency: cap, QPS: 100, Burst: 100})
	reg.Register(u.Host, cap, 100, 100)
	client := Wrap(nil, reg)

	const callers = 8
	done := make(chan struct{}, callers)
	for i := 0; i < callers; i++ {
		go func() {
			resp, err := client.Get(srv.URL)
			if err == nil {
				_, _ = io.Copy(io.Discard, resp.Body)
				_ = resp.Body.Close()
			}
			done <- struct{}{}
		}()
	}
	for i := 0; i < callers; i++ {
		<-done
	}
	if got := atomic.LoadInt32(&peak); got > int32(cap) {
		t.Errorf("peak concurrent server-side handlers = %d, want <= %d", got, cap)
	}
}

// TestTransport_SlotHeldUntilBodyClose is the regression test for the
// "release on RoundTrip return" bug. The server writes headers fast,
// then streams the body in slow chunks. While the caller is still
// reading the body, the gate's Inflight count must report 1 — the slot
// must NOT be released the moment RoundTrip returns. Closing the body
// must drop Inflight back to 0.
func TestTransport_SlotHeldUntilBodyClose(t *testing.T) {
	const (
		chunkSize  = 100 * 1024
		chunkCount = 10
		chunkDelay = 50 * time.Millisecond
	)
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/octet-stream")
		w.WriteHeader(http.StatusOK)
		flusher, _ := w.(http.Flusher)
		buf := make([]byte, chunkSize)
		for i := 0; i < chunkCount; i++ {
			_, _ = w.Write(buf)
			if flusher != nil {
				flusher.Flush()
			}
			time.Sleep(chunkDelay)
		}
	}))
	defer srv.Close()
	u, _ := url.Parse(srv.URL)

	reg := NewRegistry(Defaults{Concurrency: 4, QPS: 100, Burst: 100})
	reg.Register(u.Host, 4, 100, 100)
	client := Wrap(&http.Client{Timeout: 30 * time.Second}, reg)

	resp, err := client.Get(srv.URL)
	if err != nil {
		t.Fatalf("Get: %v", err)
	}

	// Mid-stream observation: after the headers are received but
	// before the body is fully drained, the slot must still be held.
	read := make([]byte, chunkSize)
	if _, err := io.ReadFull(resp.Body, read); err != nil {
		t.Fatalf("first chunk read: %v", err)
	}
	if got := reg.Gate(u.Host).State().Inflight; got != 1 {
		t.Errorf("during body stream: Inflight = %d, want 1", got)
	}

	// Drain the rest and verify the slot stays held until Close.
	if _, err := io.Copy(io.Discard, resp.Body); err != nil {
		t.Fatalf("drain body: %v", err)
	}
	if got := reg.Gate(u.Host).State().Inflight; got != 1 {
		t.Errorf("after body drained, before Close: Inflight = %d, want 1", got)
	}

	if err := resp.Body.Close(); err != nil {
		t.Fatalf("Close: %v", err)
	}
	if got := reg.Gate(u.Host).State().Inflight; got != 0 {
		t.Errorf("after Close: Inflight = %d, want 0", got)
	}
}

// TestTransport_DoubleCloseSafe verifies that calling resp.Body.Close
// twice (a common defer pattern) does not double-release the slot.
func TestTransport_DoubleCloseSafe(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		_, _ = io.WriteString(w, "ok")
	}))
	defer srv.Close()
	u, _ := url.Parse(srv.URL)

	reg := NewRegistry(Defaults{Concurrency: 2, QPS: 100, Burst: 100})
	reg.Register(u.Host, 2, 100, 100)
	client := Wrap(nil, reg)

	resp, err := client.Get(srv.URL)
	if err != nil {
		t.Fatalf("Get: %v", err)
	}
	_, _ = io.Copy(io.Discard, resp.Body)
	if err := resp.Body.Close(); err != nil {
		t.Fatalf("first Close: %v", err)
	}
	if err := resp.Body.Close(); err != nil {
		// httptest's response body returns nil on second Close; if a
		// future stdlib change makes that an error, this test still
		// asserts the release accounting is correct.
		t.Logf("second Close returned: %v (acceptable; gate accounting still checked below)", err)
	}
	if got := reg.Gate(u.Host).State().Inflight; got != 0 {
		t.Errorf("after double Close: Inflight = %d, want 0", got)
	}
}

// TestTransport_InnerErrorReleasesSlot verifies that a transport-level
// error (no response, no body) still releases the gate slot.
func TestTransport_InnerErrorReleasesSlot(t *testing.T) {
	reg := NewRegistry(Defaults{Concurrency: 1, QPS: 100, Burst: 100})

	tr := &Transport{
		Inner:    roundTripperFunc(func(*http.Request) (*http.Response, error) { return nil, errors.New("dial fail") }),
		Registry: reg,
	}
	req, _ := http.NewRequestWithContext(context.Background(), http.MethodGet, "http://stuck.example.com/", nil)
	_, err := tr.RoundTrip(req)
	if err == nil {
		t.Fatal("expected error from inner transport")
	}
	if got := reg.Gate("stuck.example.com").State().Inflight; got != 0 {
		t.Errorf("after inner error: Inflight = %d, want 0", got)
	}
}

// TestTransport_NilBodyReleasesSlot verifies that a response with no
// Body (HEAD-style synthetic responses) still releases the slot
// immediately.
func TestTransport_NilBodyReleasesSlot(t *testing.T) {
	reg := NewRegistry(Defaults{Concurrency: 1, QPS: 100, Burst: 100})

	tr := &Transport{
		Inner: roundTripperFunc(func(*http.Request) (*http.Response, error) {
			return &http.Response{StatusCode: http.StatusOK, Header: http.Header{}}, nil
		}),
		Registry: reg,
	}
	req, _ := http.NewRequestWithContext(context.Background(), http.MethodHead, "http://head.example.com/", nil)
	resp, err := tr.RoundTrip(req)
	if err != nil {
		t.Fatalf("RoundTrip: %v", err)
	}
	_ = resp
	if got := reg.Gate("head.example.com").State().Inflight; got != 0 {
		t.Errorf("after nil-body response: Inflight = %d, want 0", got)
	}
}

type roundTripperFunc func(*http.Request) (*http.Response, error)

func (f roundTripperFunc) RoundTrip(r *http.Request) (*http.Response, error) { return f(r) }
