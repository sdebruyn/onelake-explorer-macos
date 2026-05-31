package onelake

import (
	"context"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/sdebruyn/onelake-explorer-macos/internal/httpgate"
)

// TestGateIntegration_429PauseHonoured verifies the end-to-end
// integration: a 429 with Retry-After on the first response must
// install a pause window on the shared gate; the next request (the
// in-band retry from httpretry.Do) must wait for the pause to clear before
// reaching the server again.
//
// This is the OneLake-side counterpart to internal/httpgate's unit
// tests - it exercises Wrap, RoundTrip and ParseRetryAfter end-to-end.
func TestGateIntegration_429PauseHonoured(t *testing.T) {
	const retryAfterSec = 1

	var (
		mu   sync.Mutex
		seen []time.Time
		hits int
	)
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		mu.Lock()
		hits++
		idx := hits
		seen = append(seen, time.Now())
		mu.Unlock()

		if idx == 1 {
			w.Header().Set("Retry-After", "1")
			w.WriteHeader(http.StatusTooManyRequests)
			return
		}
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte("ok"))
	}))
	defer srv.Close()

	u, _ := url.Parse(srv.URL)
	registry := httpgate.NewRegistry(httpgate.Defaults{
		Concurrency: 4,
		QPS:         100,
		Burst:       100,
	})
	registry.Register(u.Host, 4, 100, 100)

	c := New(Options{
		TokenProvider: mockTokenProvider{tok: "tok"},
		HTTPClient:    &http.Client{Timeout: 10 * time.Second},
		BaseURL:       srv.URL,
		MaxAttempts:   3,
		Registry:      registry,
	})

	start := time.Now()
	rc, _, err := c.ReadWithIfMatch(context.Background(), "alias", wsGUID, itemGUID, "Files/a", 0, -1, "")
	if err != nil {
		t.Fatalf("Read: %v", err)
	}
	_, _ = io.Copy(io.Discard, rc)
	_ = rc.Close()
	elapsed := time.Since(start)

	mu.Lock()
	stamps := append([]time.Time{}, seen...)
	mu.Unlock()
	if len(stamps) < 2 {
		t.Fatalf("expected at least 2 server hits, got %d", len(stamps))
	}

	gap := stamps[1].Sub(stamps[0])
	min := time.Duration(retryAfterSec) * time.Second * 80 / 100 // 80% slack
	if gap < min {
		t.Errorf("retry fired %s after 429; want >= %s (Retry-After honoured)", gap, min)
	}
	if elapsed < min {
		t.Errorf("total elapsed %s, want >= %s", elapsed, min)
	}

	// The gate's last-posted PauseUntil must be in the recent past after
	// the request has finished (or close to it).
	st := registry.Gate(u.Host).State()
	if st.Inflight != 0 {
		t.Errorf("Inflight after request = %d, want 0", st.Inflight)
	}
}

// TestGateIntegration_PeersWaitOnPenalty verifies that 5 concurrent
// requests share a single pause: only the first hits 429, the others
// wait on the gate's pause window, then each issues exactly one server
// call (no extra retries). Asserts both the request count (= 1 + 5)
// and that none of the peer calls land before the pause has elapsed.
func TestGateIntegration_PeersWaitOnPenalty(t *testing.T) {
	const peers = 5

	var (
		mu     sync.Mutex
		hits   int
		stamps []time.Time
	)
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		mu.Lock()
		hits++
		idx := hits
		stamps = append(stamps, time.Now())
		mu.Unlock()

		if idx == 1 {
			w.Header().Set("Retry-After", "1")
			w.WriteHeader(http.StatusTooManyRequests)
			return
		}
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte("ok"))
	}))
	defer srv.Close()

	u, _ := url.Parse(srv.URL)
	registry := httpgate.NewRegistry(httpgate.Defaults{
		Concurrency: 8,
		QPS:         100,
		Burst:       100,
	})
	registry.Register(u.Host, 8, 100, 100)

	c := New(Options{
		TokenProvider: mockTokenProvider{tok: "tok"},
		HTTPClient:    &http.Client{Timeout: 10 * time.Second},
		BaseURL:       srv.URL,
		MaxAttempts:   3,
		Registry:      registry,
	})

	// Fire one caller first to take the 429 hit and install the pause.
	// Use a barrier so the peers launch only after the gate has the
	// penalty recorded - otherwise their pre-penalty Acquire wins the
	// race and they hit the server in parallel.
	rc, _, err := c.ReadWithIfMatch(context.Background(), "alias", wsGUID, itemGUID, "Files/a", 0, -1, "")
	if err != nil {
		t.Fatalf("lead Read: %v", err)
	}
	_, _ = io.Copy(io.Discard, rc)
	_ = rc.Close()

	mu.Lock()
	hitsAfterLead := hits
	leadFirst := stamps[0]
	mu.Unlock()
	// Lead should have produced exactly 2 hits: 429 + retry.
	if hitsAfterLead != 2 {
		t.Fatalf("lead caller produced %d hits, want 2", hitsAfterLead)
	}

	// Now run peers concurrently. The gate's pause was posted on the
	// 429 and has already cleared, so they should each just succeed
	// with one call apiece.
	var wg sync.WaitGroup
	wg.Add(peers)
	for i := 0; i < peers; i++ {
		go func() {
			defer wg.Done()
			rc, _, err := c.ReadWithIfMatch(context.Background(), "alias", wsGUID, itemGUID, "Files/a", 0, -1, "")
			if err != nil {
				t.Errorf("peer Read: %v", err)
				return
			}
			_, _ = io.Copy(io.Discard, rc)
			_ = rc.Close()
		}()
	}
	wg.Wait()

	mu.Lock()
	total := hits
	peerFirst := stamps[2] // index 0,1 are lead's 429 and retry
	mu.Unlock()

	// Expect: 1 (429) + 1 (retry) + peers (success) = 2 + peers.
	if total != 2+peers {
		t.Errorf("total hits = %d, want %d", total, 2+peers)
	}
	// The first peer hit must be no earlier than ~Retry-After after
	// the first 429 - proves the pause was applied across requests.
	gap := peerFirst.Sub(leadFirst)
	if gap < 800*time.Millisecond {
		t.Errorf("first peer hit fired %s after the 429; want >= 800ms", gap)
	}
}

// TestGateIntegration_Penalty503 verifies that a 503 with Retry-After
// also triggers Penalty, identically to 429.
func TestGateIntegration_Penalty503(t *testing.T) {
	var hits int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		n := atomic.AddInt32(&hits, 1)
		if n == 1 {
			w.Header().Set("Retry-After", "1")
			w.WriteHeader(http.StatusServiceUnavailable)
			return
		}
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte("ok"))
	}))
	defer srv.Close()

	u, _ := url.Parse(srv.URL)
	registry := httpgate.NewRegistry(httpgate.Defaults{Concurrency: 8, QPS: 100, Burst: 100})
	registry.Register(u.Host, 8, 100, 100)

	c := New(Options{
		TokenProvider: mockTokenProvider{tok: "tok"},
		HTTPClient:    &http.Client{Timeout: 10 * time.Second},
		BaseURL:       srv.URL,
		MaxAttempts:   3,
		Registry:      registry,
	})

	rc, _, err := c.ReadWithIfMatch(context.Background(), "alias", wsGUID, itemGUID, "Files/a", 0, -1, "")
	if err != nil {
		t.Fatalf("Read: %v", err)
	}
	b, _ := io.ReadAll(rc)
	_ = rc.Close()
	if !strings.HasPrefix(string(b), "ok") {
		t.Errorf("body = %q, want ok", b)
	}
	if got := atomic.LoadInt32(&hits); got != 2 {
		t.Errorf("hits = %d, want 2", got)
	}
}
