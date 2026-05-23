package daemon

import (
	"context"
	"errors"
	"io"
	"log/slog"
	"testing"
	"time"

	"github.com/sdebruyn/onelake-explorer-macos/internal/cache"
	"github.com/sdebruyn/onelake-explorer-macos/internal/sync"
	"github.com/sdebruyn/onelake-explorer-macos/internal/telemetry"
)

// fakePollerCache implements pollerCache. It returns canned items and
// records the cutoff timestamp the poller passed in.
type fakePollerCache struct {
	items []cache.Key
	err   error
	since time.Time
}

func (f *fakePollerCache) HotItems(_ context.Context, since time.Time) ([]cache.Key, error) {
	f.since = since
	if f.err != nil {
		return nil, f.err
	}
	return f.items, nil
}

// fakePollerEngine implements pollerEngine. It returns one diff per
// (alias, item) bucket so tests can assert per-item dispatch.
type fakePollerEngine struct {
	diffs  map[string]sync.Diff
	errs   map[string]error
	called []cache.Key
}

func (f *fakePollerEngine) RefreshFolder(_ context.Context, k cache.Key) (sync.Diff, error) {
	f.called = append(f.called, k)
	key := k.AccountAlias + "|" + k.WorkspaceID + "|" + k.ItemID
	if err, ok := f.errs[key]; ok {
		return sync.Diff{}, err
	}
	return f.diffs[key], nil
}

// memoryTracker records every event the poller emits.
type memoryTracker struct {
	events []telemetry.Event
}

func (m *memoryTracker) Track(ev telemetry.Event) { m.events = append(m.events, ev) }

func discardLogger() *slog.Logger {
	return slog.New(slog.NewTextHandler(io.Discard, nil))
}

func TestPollOnce_RefreshesEachHotItemRoot(t *testing.T) {
	c := &fakePollerCache{
		items: []cache.Key{
			{AccountAlias: "work", WorkspaceID: "ws-1", ItemID: "item-A"},
			{AccountAlias: "work", WorkspaceID: "ws-2", ItemID: "item-B"},
		},
	}
	e := &fakePollerEngine{
		diffs: map[string]sync.Diff{
			"work|ws-1|item-A": {Added: 2},
			"work|ws-2|item-B": {Updated: 1, Removed: 1},
		},
	}
	tr := &memoryTracker{}

	pollOnce(context.Background(), c, e, tr, nil, discardLogger(), 30*time.Minute)

	if len(e.called) != 2 {
		t.Fatalf("RefreshFolder called %d times, want 2", len(e.called))
	}
	for _, k := range e.called {
		if k.Path != "" {
			t.Errorf("Path = %q, want empty (item root)", k.Path)
		}
	}
	if len(tr.events) != 2 {
		t.Fatalf("emitted %d telemetry events, want 2", len(tr.events))
	}
	for _, ev := range tr.events {
		if ev.Name != "sync_pulled" {
			t.Errorf("event name = %q, want sync_pulled", ev.Name)
		}
		if ev.ItemsChanged <= 0 {
			t.Errorf("ItemsChanged = %d, want >0", ev.ItemsChanged)
		}
	}
}

func TestPollOnce_NoEventWhenDiffEmpty(t *testing.T) {
	c := &fakePollerCache{
		items: []cache.Key{
			{AccountAlias: "work", WorkspaceID: "ws-1", ItemID: "item-A"},
		},
	}
	e := &fakePollerEngine{} // no entries → zero diff
	tr := &memoryTracker{}

	pollOnce(context.Background(), c, e, tr, nil, discardLogger(), 30*time.Minute)

	if len(tr.events) != 0 {
		t.Errorf("emitted %d events for empty diffs, want 0 (%+v)", len(tr.events), tr.events)
	}
}

func TestPollOnce_HotItemsErrorIsLoggedNotFatal(t *testing.T) {
	c := &fakePollerCache{err: errors.New("db down")}
	e := &fakePollerEngine{}
	tr := &memoryTracker{}

	// Just ensure it returns without panicking; the warn line lands in
	// discardLogger and the engine is never called.
	pollOnce(context.Background(), c, e, tr, nil, discardLogger(), 30*time.Minute)

	if len(e.called) != 0 {
		t.Errorf("engine called %d times after HotItems error, want 0", len(e.called))
	}
}

func TestPollOnce_RefreshErrorIsLoggedAndLoopContinues(t *testing.T) {
	c := &fakePollerCache{
		items: []cache.Key{
			{AccountAlias: "work", WorkspaceID: "ws-1", ItemID: "item-A"},
			{AccountAlias: "work", WorkspaceID: "ws-2", ItemID: "item-B"},
		},
	}
	e := &fakePollerEngine{
		errs:  map[string]error{"work|ws-1|item-A": errors.New("transient")},
		diffs: map[string]sync.Diff{"work|ws-2|item-B": {Added: 1}},
	}
	tr := &memoryTracker{}

	pollOnce(context.Background(), c, e, tr, nil, discardLogger(), 30*time.Minute)

	if len(e.called) != 2 {
		t.Errorf("RefreshFolder called %d times, want 2 (loop should continue past error)", len(e.called))
	}
	if len(tr.events) != 1 {
		t.Errorf("emitted %d events, want 1 (success only)", len(tr.events))
	}
}

func TestPollOnce_HotWindowAppliedToCutoff(t *testing.T) {
	c := &fakePollerCache{}
	e := &fakePollerEngine{}
	tr := &memoryTracker{}

	before := time.Now()
	pollOnce(context.Background(), c, e, tr, nil, discardLogger(), 15*time.Minute)
	after := time.Now()

	// The cutoff should be roughly 15 minutes before now.
	expectedMin := before.Add(-15 * time.Minute).Add(-time.Second)
	expectedMax := after.Add(-15 * time.Minute).Add(time.Second)
	if c.since.Before(expectedMin) || c.since.After(expectedMax) {
		t.Errorf("HotItems(since=%v); want between %v and %v",
			c.since, expectedMin, expectedMax)
	}
}

func TestRunAdaptivePoller_StopsOnContextCancel(t *testing.T) {
	c := &fakePollerCache{}
	e := &fakePollerEngine{}
	tr := &memoryTracker{}

	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() {
		runAdaptivePoller(ctx, c, e, tr, nil, discardLogger(), 50*time.Millisecond, 30*time.Minute)
		close(done)
	}()

	cancel()
	select {
	case <-done:
	case <-time.After(2 * time.Second):
		t.Fatalf("runAdaptivePoller did not return after ctx cancel")
	}
}

func TestRunAdaptivePoller_ZeroPeriodReturnsImmediately(t *testing.T) {
	done := make(chan struct{})
	go func() {
		runAdaptivePoller(context.Background(), &fakePollerCache{}, &fakePollerEngine{}, &memoryTracker{}, nil, discardLogger(), 0, 30*time.Minute)
		close(done)
	}()
	select {
	case <-done:
	case <-time.After(1 * time.Second):
		t.Fatalf("runAdaptivePoller with zero period did not return")
	}
}

// fakeTenantResolver records every lookup so a test can assert the
// per-sweep cache collapsed repeat lookups for the same alias.
type fakeTenantResolver struct {
	tenants map[string]string
	calls   []string
}

func (f *fakeTenantResolver) TenantID(alias string) (string, bool) {
	f.calls = append(f.calls, alias)
	v, ok := f.tenants[alias]
	return v, ok
}

func TestPollOnce_TagsSyncPulledWithTenantID(t *testing.T) {
	c := &fakePollerCache{
		items: []cache.Key{
			{AccountAlias: "work", WorkspaceID: "ws-1", ItemID: "item-A"},
			{AccountAlias: "work", WorkspaceID: "ws-2", ItemID: "item-B"},
			{AccountAlias: "client", WorkspaceID: "ws-3", ItemID: "item-C"},
		},
	}
	e := &fakePollerEngine{
		diffs: map[string]sync.Diff{
			"work|ws-1|item-A":   {Added: 1},
			"work|ws-2|item-B":   {Updated: 2},
			"client|ws-3|item-C": {Removed: 1},
		},
	}
	tr := &memoryTracker{}
	resolver := &fakeTenantResolver{
		tenants: map[string]string{
			"work":   "tenant-work",
			"client": "tenant-client",
		},
	}

	pollOnce(context.Background(), c, e, tr, resolver, discardLogger(), 30*time.Minute)

	if len(tr.events) != 3 {
		t.Fatalf("emitted %d events, want 3", len(tr.events))
	}
	allowed := map[string]bool{"tenant-work": true, "tenant-client": true}
	for _, ev := range tr.events {
		// We don't know the alias from the event (only its hash) but we
		// can verify TenantID is non-empty and matches one of the
		// expected tenants.
		if ev.TenantID == "" {
			t.Errorf("sync_pulled emitted with empty TenantID: %+v", ev)
		}
		if !allowed[ev.TenantID] {
			t.Errorf("TenantID = %q, not in expected set %v", ev.TenantID, allowed)
		}
	}

	// The per-sweep cache should collapse the two "work" lookups into one.
	workLookups := 0
	for _, a := range resolver.calls {
		if a == "work" {
			workLookups++
		}
	}
	if workLookups != 1 {
		t.Errorf("tenant resolver called %d times for 'work'; want 1 (cache miss only)", workLookups)
	}
}

func TestPollOnce_UnknownAliasYieldsEmptyTenantID(t *testing.T) {
	c := &fakePollerCache{
		items: []cache.Key{
			{AccountAlias: "ghost", WorkspaceID: "ws-1", ItemID: "item-A"},
		},
	}
	e := &fakePollerEngine{
		diffs: map[string]sync.Diff{"ghost|ws-1|item-A": {Added: 1}},
	}
	tr := &memoryTracker{}
	resolver := &fakeTenantResolver{tenants: map[string]string{}}

	pollOnce(context.Background(), c, e, tr, resolver, discardLogger(), 30*time.Minute)

	if len(tr.events) != 1 {
		t.Fatalf("emitted %d events, want 1", len(tr.events))
	}
	if tr.events[0].TenantID != "" {
		t.Errorf("TenantID = %q, want empty for unknown alias", tr.events[0].TenantID)
	}
}

// TestPollOnce_StopsAtContextCancelBetweenItems verifies that ctx
// cancellation observed mid-sweep (between items, not just between
// cycles) shortcuts the rest of the sweep so daemon shutdown is bounded
// by a single item's RefreshFolder call.
func TestPollOnce_StopsAtContextCancelBetweenItems(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	c := &fakePollerCache{
		items: []cache.Key{
			{AccountAlias: "work", WorkspaceID: "ws-1", ItemID: "item-A"},
			{AccountAlias: "work", WorkspaceID: "ws-2", ItemID: "item-B"},
			{AccountAlias: "work", WorkspaceID: "ws-3", ItemID: "item-C"},
		},
	}
	// Cancel after the first RefreshFolder so the second iteration
	// must observe ctx.Err and bail out.
	e := &cancelOnFirstEngine{cancel: cancel, diff: sync.Diff{Added: 1}}
	tr := &memoryTracker{}

	pollOnce(ctx, c, e, tr, nil, discardLogger(), 30*time.Minute)

	if e.calls > 1 {
		t.Errorf("RefreshFolder called %d times after ctx cancel; want at most 1", e.calls)
	}
}

// cancelOnFirstEngine cancels its captured context the first time
// RefreshFolder is called and otherwise returns its canned diff.
type cancelOnFirstEngine struct {
	cancel context.CancelFunc
	diff   sync.Diff
	calls  int
}

func (e *cancelOnFirstEngine) RefreshFolder(_ context.Context, _ cache.Key) (sync.Diff, error) {
	e.calls++
	e.cancel()
	return e.diff, nil
}
