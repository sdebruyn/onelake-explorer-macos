package fabric

import (
	"context"
	"net/http"
	"net/http/httptest"
	"net/url"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/sdebruyn/onelake-explorer-macos/internal/httpgate"
)

// TestGateIntegration_429PauseHonoured is the Fabric-side equivalent of
// the OneLake gate-integration test: it asserts that the per-host gate
// installed by the Registry wrap delays the retry by at least the
// Retry-After value the server returned.
func TestGateIntegration_429PauseHonoured(t *testing.T) {
	var (
		mu     sync.Mutex
		stamps []time.Time
		hits   int
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
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte(`{"value":[]}`))
	}))
	defer srv.Close()

	u, _ := url.Parse(srv.URL)
	registry := httpgate.NewRegistry(httpgate.Defaults{Concurrency: 4, QPS: 100, Burst: 100})
	registry.Register(u.Host, 4, 100, 100)

	c := New(Options{
		TokenProvider: mockTokenProvider{tok: "tok"},
		HTTPClient:    &http.Client{Timeout: 10 * time.Second},
		BaseURL:       srv.URL,
		MaxAttempts:   3,
		Registry:      registry,
	})

	if _, err := c.ListWorkspaces(context.Background(), "alias"); err != nil {
		t.Fatalf("ListWorkspaces: %v", err)
	}

	mu.Lock()
	defer mu.Unlock()
	if len(stamps) < 2 {
		t.Fatalf("expected at least 2 hits, got %d", len(stamps))
	}
	gap := stamps[1].Sub(stamps[0])
	if gap < 800*time.Millisecond {
		t.Errorf("retry fired %s after 429; want >= 800ms", gap)
	}
}

// TestGateIntegration_PeersWaitOnPenalty: 5 concurrent peer calls
// after the gate has been hit with a Retry-After must each issue
// exactly one server call and none of them may land before the pause
// has elapsed.
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
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte(`{"value":[]}`))
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

	// Lead call to install the penalty.
	if _, err := c.ListWorkspaces(context.Background(), "alias"); err != nil {
		t.Fatalf("lead ListWorkspaces: %v", err)
	}
	mu.Lock()
	leadFirst := stamps[0]
	hitsAfterLead := hits
	mu.Unlock()
	if hitsAfterLead != 2 {
		t.Fatalf("lead caller produced %d hits, want 2", hitsAfterLead)
	}

	var wg sync.WaitGroup
	wg.Add(peers)
	for i := 0; i < peers; i++ {
		go func() {
			defer wg.Done()
			if _, err := c.ListWorkspaces(context.Background(), "alias"); err != nil {
				t.Errorf("peer ListWorkspaces: %v", err)
			}
		}()
	}
	wg.Wait()

	mu.Lock()
	total := hits
	peerFirst := stamps[2]
	mu.Unlock()

	if total != 2+peers {
		t.Errorf("total hits = %d, want %d", total, 2+peers)
	}
	if gap := peerFirst.Sub(leadFirst); gap < 800*time.Millisecond {
		t.Errorf("first peer hit fired %s after 429; want >= 800ms", gap)
	}
}

// TestGateIntegration_Penalty503 covers the 503 status code path.
func TestGateIntegration_Penalty503(t *testing.T) {
	var hits int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		n := atomic.AddInt32(&hits, 1)
		if n == 1 {
			w.Header().Set("Retry-After", "1")
			w.WriteHeader(http.StatusServiceUnavailable)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte(`{"value":[]}`))
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

	if _, err := c.ListWorkspaces(context.Background(), "alias"); err != nil {
		t.Fatalf("ListWorkspaces: %v", err)
	}
	if got := atomic.LoadInt32(&hits); got != 2 {
		t.Errorf("hits = %d, want 2", got)
	}
	if registry.Gate(u.Host).State().PauseUntil.IsZero() {
		t.Error("expected non-zero PauseUntil after 503+Retry-After")
	}
}
