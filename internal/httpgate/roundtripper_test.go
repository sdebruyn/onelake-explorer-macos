package httpgate

import (
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
