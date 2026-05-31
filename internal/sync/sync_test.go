package sync

import (
	"context"
	"net/http"
	"sync/atomic"
	"testing"
	"time"

	"github.com/jarcoal/httpmock"

	"github.com/sdebruyn/onelake-explorer-macos/internal/cache"
	"github.com/sdebruyn/onelake-explorer-macos/internal/fabric"
	"github.com/sdebruyn/onelake-explorer-macos/internal/onelake"
	"github.com/sdebruyn/onelake-explorer-macos/internal/telemetry"
)

// Shared GUIDs the tests reuse.
const (
	testFabricBase   = "https://api.fabric.microsoft.com"
	testOneLakeBase  = "https://onelake.dfs.fabric.microsoft.com"
	testAlias        = "work"
	testWorkspaceID  = "11111111-1111-1111-1111-111111111111"
	testItemID       = "22222222-2222-2222-2222-222222222222"
	testWorkspaceID2 = "33333333-3333-3333-3333-333333333333"
)

// countingTokenProvider records every Token() call so tests can assert
// "zero HTTP roundtrips" on cache-hit paths. Implements auth.TokenProvider.
type countingTokenProvider struct {
	calls int64
	tok   string
}

func (c *countingTokenProvider) Token(_ context.Context, _ string) (string, error) {
	atomic.AddInt64(&c.calls, 1)
	if c.tok == "" {
		return "test-token", nil
	}
	return c.tok, nil
}

func (c *countingTokenProvider) Calls() int64 { return atomic.LoadInt64(&c.calls) }

// engineFixture bundles the engine and its dependencies for tests so the
// individual cases stay short.
type engineFixture struct {
	engine *Engine
	cache  *cache.Cache
	sink   *telemetry.MemorySink
	tel    *telemetry.Client
	tp     *countingTokenProvider
	now    *fakeClock
}

// fakeClock returns deterministic timestamps so freshness checks have a
// stable answer in tests. The clock starts at a fixed reference moment
// and advances when Add is called. Not safe for concurrent use; tests
// are single-goroutine.
type fakeClock struct {
	t time.Time
}

func newFakeClock(start time.Time) *fakeClock {
	return &fakeClock{t: start.UTC()}
}

func (f *fakeClock) Now() time.Time      { return f.t }
func (f *fakeClock) Add(d time.Duration) { f.t = f.t.Add(d).UTC() }

// stubTenants implements [TenantResolver] from a static map. Used in
// tests that assert sync_pulled carries tenantId.
type stubTenants map[string]string

func (s stubTenants) TenantID(alias string) (string, bool) {
	v, ok := s[alias]
	return v, ok
}

// newEngine builds an engine plumbed through httpmock against both the
// Fabric REST and OneLake DFS endpoints.
func newEngine(t *testing.T, opts ...func(*Options)) *engineFixture {
	return newEngineAt(t, "", opts...)
}

// newEngineAt builds an engine rooted at the given cache directory.
// Pass "" to allocate a fresh t.TempDir(); pass a previously-used path
// to re-open an existing cache (the offline-queue restart tests rely
// on this to model a daemon crash + restart).
func newEngineAt(t *testing.T, cacheRoot string, opts ...func(*Options)) *engineFixture {
	t.Helper()

	httpmock.Activate()
	t.Cleanup(httpmock.DeactivateAndReset)

	httpClient := &http.Client{Timeout: 10 * time.Second}
	httpmock.ActivateNonDefault(httpClient)

	tp := &countingTokenProvider{}
	oc := onelake.New(onelake.Options{
		TokenProvider: tp,
		HTTPClient:    httpClient,
		BaseURL:       testOneLakeBase,
		MaxAttempts:   2,
	})
	fc := fabric.New(fabric.Options{
		TokenProvider: tp,
		HTTPClient:    httpClient,
		BaseURL:       testFabricBase,
		MaxAttempts:   2,
	})

	if cacheRoot == "" {
		cacheRoot = t.TempDir()
	}
	c, err := cache.Open(cache.Options{Root: cacheRoot})
	if err != nil {
		t.Fatalf("cache.Open: %v", err)
	}
	t.Cleanup(func() { _ = c.Close() })

	sink := &telemetry.MemorySink{}
	tel := telemetry.New(telemetry.Options{
		AppVersion:    "test",
		InstallID:     "install-1",
		Sink:          sink,
		FlushInterval: time.Hour, // disable auto-flush; tests use Flush.
	})

	clock := newFakeClock(time.Date(2026, 5, 23, 12, 0, 0, 0, time.UTC))

	o := Options{
		Cache:           c,
		Fabric:          fc,
		OneLake:         oc,
		Telemetry:       tel,
		OpenFolderTTL:   30 * time.Second,
		RecentFolderTTL: 5 * time.Minute,
		Now:             clock.Now,
	}
	for _, mut := range opts {
		mut(&o)
	}
	eng, err := New(o)
	if err != nil {
		t.Fatalf("sync.New: %v", err)
	}
	// Close the engine before the cache: Close waits for the drain
	// goroutine spawned by observeNetworkResult to exit so it can't race
	// the cache shutdown (cache.Close above is registered earlier and
	// therefore runs after this cleanup per t.Cleanup LIFO order).
	t.Cleanup(func() { _ = eng.Close() })

	return &engineFixture{
		engine: eng,
		cache:  c,
		sink:   sink,
		tel:    tel,
		tp:     tp,
		now:    clock,
	}
}

// drainEvents flushes the telemetry buffer to the sink and returns the
// drained events.
func (f *engineFixture) drainEvents(t *testing.T) []telemetry.Event {
	t.Helper()
	if err := f.tel.Flush(context.Background()); err != nil {
		t.Fatalf("telemetry flush: %v", err)
	}
	return f.sink.Drain()
}

// findEvent returns the first event with the given name, or fails the
// test if none matches.
func findEvent(t *testing.T, events []telemetry.Event, name string) telemetry.Event {
	t.Helper()
	for _, ev := range events {
		if ev.Name == name {
			return ev
		}
	}
	t.Fatalf("event %q not found in %+v", name, events)
	return telemetry.Event{}
}
