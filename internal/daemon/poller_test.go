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
	sweeps int
}

func (f *fakePollerEngine) RefreshFolder(_ context.Context, k cache.Key) (sync.Diff, error) {
	f.called = append(f.called, k)
	key := k.AccountAlias + "|" + k.WorkspaceID + "|" + k.ItemID
	if err, ok := f.errs[key]; ok {
		return sync.Diff{}, err
	}
	return f.diffs[key], nil
}

func (f *fakePollerEngine) SweepPausedWorkspaces(_ context.Context) { f.sweeps++ }

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

	pollOnce(context.Background(), c, e, discardLogger(), 30*time.Minute)

	if len(e.called) != 2 {
		t.Fatalf("RefreshFolder called %d times, want 2", len(e.called))
	}
	for _, k := range e.called {
		if k.Path != "" {
			t.Errorf("Path = %q, want empty (item root)", k.Path)
		}
	}
}

func TestPollOnce_HotItemsErrorIsLoggedNotFatal(t *testing.T) {
	c := &fakePollerCache{err: errors.New("db down")}
	e := &fakePollerEngine{}

	// Just ensure it returns without panicking; the warn line lands in
	// discardLogger and the engine is never called.
	pollOnce(context.Background(), c, e, discardLogger(), 30*time.Minute)

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

	pollOnce(context.Background(), c, e, discardLogger(), 30*time.Minute)

	if len(e.called) != 2 {
		t.Errorf("RefreshFolder called %d times, want 2 (loop should continue past error)", len(e.called))
	}
}

func TestPollOnce_HotWindowAppliedToCutoff(t *testing.T) {
	c := &fakePollerCache{}
	e := &fakePollerEngine{}

	before := time.Now()
	pollOnce(context.Background(), c, e, discardLogger(), 15*time.Minute)
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

	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() {
		runAdaptivePoller(ctx, c, e, discardLogger(), 50*time.Millisecond, 30*time.Minute)
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
		runAdaptivePoller(context.Background(), &fakePollerCache{}, &fakePollerEngine{}, discardLogger(), 0, 30*time.Minute)
		close(done)
	}()
	select {
	case <-done:
	case <-time.After(1 * time.Second):
		t.Fatalf("runAdaptivePoller with zero period did not return")
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

	pollOnce(ctx, c, e, discardLogger(), 30*time.Minute)

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

func (e *cancelOnFirstEngine) SweepPausedWorkspaces(_ context.Context) {}

// TestPollOnce_SweepsPausedWorkspaces verifies the cold-paused
// recovery hook fires on every sweep, not just on hot items. Without
// this, a workspace that was paused while nobody was looking at it
// would never recover in the IPC status surface.
func TestPollOnce_SweepsPausedWorkspaces(t *testing.T) {
	c := &fakePollerCache{}
	e := &fakePollerEngine{}

	pollOnce(context.Background(), c, e, discardLogger(), 30*time.Minute)

	if e.sweeps != 1 {
		t.Errorf("SweepPausedWorkspaces calls = %d, want 1", e.sweeps)
	}
}
