package sync

import (
	"context"
	"errors"
	"net/http"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/jarcoal/httpmock"

	"github.com/sdebruyn/onelake-explorer-macos/internal/cache"
	"github.com/sdebruyn/onelake-explorer-macos/internal/httpretry"
)

// Paused-capacity body payloads the detector should recognise. The
// table covers both Fabric REST's `errorCode`-style JSON and OneLake
// DFS's free-text message.
func TestIsPausedCapacityError(t *testing.T) {
	cases := []struct {
		name string
		body string
		want bool
	}{
		{"fabric_errorCode_paused", `{"errorCode":"CapacityPaused","message":"X"}`, true},
		{"fabric_errorCode_suspended", `{"errorCode":"CapacitySuspended"}`, true},
		{"fabric_errorCode_notactive", `{"errorCode":"CapacityNotActive"}`, true},
		{"dfs_phrase_paused", `Unable to complete the action because this Fabric capacity is currently paused.`, true},
		{"dfs_phrase_notactive", `The capacity is not active.`, true},
		{"benign_403", `{"errorCode":"InsufficientPrivileges","message":"You do not have permission"}`, false},
		{"empty", "", false},
	}
	for _, c := range cases {
		c := c
		t.Run(c.name, func(t *testing.T) {
			ae := &httpretry.APIError{StatusCode: 503, Status: "Service Unavailable", Body: []byte(c.body)}
			if got := IsPausedCapacityError(ae); got != c.want {
				t.Errorf("body=%q: IsPausedCapacityError = %v, want %v", c.body, got, c.want)
			}
		})
	}

	if IsPausedCapacityError(nil) {
		t.Error("nil error must not be paused")
	}
	if IsPausedCapacityError(errors.New("transport boom")) {
		t.Error("non-APIError must not be paused")
	}
}

// TestRefreshFolder_MarksPausedAndShortCircuits verifies the end-to-end
// flow: a 503 with the paused-capacity message marks the workspace and
// causes the next call to short-circuit without a network round trip.
func TestRefreshFolder_MarksPausedAndShortCircuits(t *testing.T) {
	f := newEngine(t)
	ctx := context.Background()

	var listCalls int32
	httpmock.RegisterResponder("GET", "=~^"+testOneLakeBase+`.*`,
		func(req *http.Request) (*http.Response, error) {
			atomic.AddInt32(&listCalls, 1)
			resp := httpmock.NewStringResponse(503,
				`{"errorCode":"CapacityPaused","message":"Unable to complete the action because this Fabric capacity is currently paused."}`)
			resp.Header.Set("Retry-After", "0")
			return resp, nil
		})

	k := cache.Key{AccountAlias: testAlias, WorkspaceID: testWorkspaceID, ItemID: testItemID}
	_, err := f.engine.RefreshFolder(ctx, k)
	if !errors.Is(err, ErrWorkspacePaused) {
		t.Fatalf("first call: want ErrWorkspacePaused, got %v", err)
	}
	if got := atomic.LoadInt32(&listCalls); got == 0 {
		t.Errorf("first call: expected at least one network request")
	}

	// Verify workspace_status row is persisted as paused.
	st, gerr := f.cache.GetWorkspaceStatus(ctx, testAlias, testWorkspaceID)
	if gerr != nil {
		t.Fatalf("workspace_status: %v", gerr)
	}
	if st.State != cache.WorkspaceStatePaused {
		t.Errorf("state = %q, want paused", st.State)
	}

	// Second call within the probe interval must short-circuit (zero
	// new HTTP calls beyond what happened during the probe attempt).
	before := atomic.LoadInt32(&listCalls)
	_, err = f.engine.RefreshFolder(ctx, k)
	if !errors.Is(err, ErrWorkspacePaused) {
		t.Fatalf("second call: want ErrWorkspacePaused, got %v", err)
	}
	after := atomic.LoadInt32(&listCalls)
	if after != before {
		t.Errorf("second call hit network %d times, want 0 (should be probe-throttled)", after-before)
	}
}

// TestProbe_Recovers verifies that once the server stops returning
// paused, the probe flips the workspace back to active.
func TestProbe_Recovers(t *testing.T) {
	f := newEngine(t)
	ctx := context.Background()

	// Make the probe interval tiny so the test runs quickly.
	f.engine.pausedProbeInterval = 1 * time.Millisecond

	// Seed paused state in the cache.
	if err := f.cache.SetWorkspaceStatus(ctx, cache.WorkspaceStatus{
		AccountAlias: testAlias, WorkspaceID: testWorkspaceID,
		State: cache.WorkspaceStatePaused, Reason: "capacity_paused",
		DetectedAt: f.now.Now().Add(-1 * time.Hour),
		ProbedAt:   f.now.Now().Add(-1 * time.Hour),
	}); err != nil {
		t.Fatalf("seed: %v", err)
	}

	httpmock.RegisterResponder("HEAD", "=~^"+testOneLakeBase+`.*`,
		httpmock.NewStringResponder(200, ""))

	if !f.engine.probePausedWorkspace(ctx, testAlias, testWorkspaceID) {
		t.Fatal("probe should report reachable")
	}
	st, _ := f.cache.GetWorkspaceStatus(ctx, testAlias, testWorkspaceID)
	if st.State != cache.WorkspaceStateActive {
		t.Errorf("state after recovery = %q, want active", st.State)
	}
}

// TestProbe_ThrottlesByInterval ensures probes do not stampede.
func TestProbe_ThrottlesByInterval(t *testing.T) {
	f := newEngine(t)
	ctx := context.Background()

	f.engine.pausedProbeInterval = 1 * time.Hour

	if err := f.cache.SetWorkspaceStatus(ctx, cache.WorkspaceStatus{
		AccountAlias: testAlias, WorkspaceID: testWorkspaceID,
		State: cache.WorkspaceStatePaused, Reason: "capacity_paused",
		DetectedAt: f.now.Now(),
		ProbedAt:   f.now.Now(), // just probed
	}); err != nil {
		t.Fatalf("seed: %v", err)
	}

	var probes int32
	httpmock.RegisterResponder("HEAD", "=~^"+testOneLakeBase+`.*`,
		func(_ *http.Request) (*http.Response, error) {
			atomic.AddInt32(&probes, 1)
			return httpmock.NewStringResponse(200, ""), nil
		})

	// Multiple guard calls must not trigger more than zero probes,
	// since we are inside the cooldown window.
	for i := 0; i < 5; i++ {
		if err := f.engine.guardPausedWorkspace(ctx, testAlias, testWorkspaceID); !errors.Is(err, ErrWorkspacePaused) {
			t.Fatalf("guard %d: want ErrWorkspacePaused, got %v", i, err)
		}
	}
	if got := atomic.LoadInt32(&probes); got != 0 {
		t.Errorf("probes = %d, want 0 inside cooldown", got)
	}
}

// TestProbe_NonSuccessStaysPaused covers the sad path: a non-2xx
// probe response keeps the workspace flagged paused and refreshes
// ProbedAt so the next probe respects the minimum interval.
func TestProbe_NonSuccessStaysPaused(t *testing.T) {
	f := newEngine(t)
	ctx := context.Background()

	f.engine.pausedProbeInterval = 1 * time.Millisecond

	seedTime := f.now.Now().Add(-1 * time.Hour)
	if err := f.cache.SetWorkspaceStatus(ctx, cache.WorkspaceStatus{
		AccountAlias: testAlias, WorkspaceID: testWorkspaceID,
		State: cache.WorkspaceStatePaused, Reason: "capacity_paused",
		DetectedAt: seedTime,
		ProbedAt:   seedTime,
	}); err != nil {
		t.Fatalf("seed: %v", err)
	}

	httpmock.RegisterResponder("HEAD", "=~^"+testOneLakeBase+`.*`,
		httpmock.NewStringResponder(403, "still paused"))

	if f.engine.probePausedWorkspace(ctx, testAlias, testWorkspaceID) {
		t.Fatal("probe on non-2xx must report not-recovered")
	}
	st, _ := f.cache.GetWorkspaceStatus(ctx, testAlias, testWorkspaceID)
	if st.State != cache.WorkspaceStatePaused {
		t.Errorf("state after non-2xx probe = %q, want paused", st.State)
	}
	if !st.ProbedAt.After(seedTime) {
		t.Errorf("ProbedAt = %v, want > %v (refreshed by probe attempt)", st.ProbedAt, seedTime)
	}
	if st.DetectedAt != seedTime {
		t.Errorf("DetectedAt = %v, want preserved %v", st.DetectedAt, seedTime)
	}
}

// TestSweepPausedWorkspaces_ProbesEachPausedRow verifies the cold
// recovery sweep iterates every paused row and skips active ones.
// Without the cold sweep, a workspace that was once active and then
// went paused while nobody was looking at it would stay paused
// forever in the IPC status surface.
func TestSweepPausedWorkspaces_ProbesEachPausedRow(t *testing.T) {
	f := newEngine(t)
	ctx := context.Background()
	f.engine.pausedProbeInterval = 1 * time.Millisecond

	// Three rows: two paused (one will recover, one stays paused), one
	// active (must not be touched).
	seedTime := f.now.Now().Add(-1 * time.Hour)
	_ = f.cache.SetWorkspaceStatus(ctx, cache.WorkspaceStatus{
		AccountAlias: testAlias, WorkspaceID: "ws-recover",
		State: cache.WorkspaceStatePaused, Reason: "capacity_paused",
		DetectedAt: seedTime, ProbedAt: seedTime,
	})
	_ = f.cache.SetWorkspaceStatus(ctx, cache.WorkspaceStatus{
		AccountAlias: testAlias, WorkspaceID: "ws-stuck",
		State: cache.WorkspaceStatePaused, Reason: "capacity_paused",
		DetectedAt: seedTime, ProbedAt: seedTime,
	})
	_ = f.cache.SetWorkspaceStatus(ctx, cache.WorkspaceStatus{
		AccountAlias: testAlias, WorkspaceID: "ws-active",
		State: cache.WorkspaceStateActive,
		DetectedAt: seedTime,
	})

	var probes atomic.Int32
	httpmock.RegisterResponder("HEAD", "=~^"+testOneLakeBase+`.*`,
		func(req *http.Request) (*http.Response, error) {
			probes.Add(1)
			if strings.Contains(req.URL.Path, "ws-recover") {
				return httpmock.NewStringResponse(200, ""), nil
			}
			// 403 is non-retriable so httpretry doesn't multiply our count.
			return httpmock.NewStringResponse(403, "forbidden"), nil
		})

	f.engine.SweepPausedWorkspaces(ctx)

	if got := probes.Load(); got != 2 {
		t.Errorf("HEAD probes = %d, want 2 (one per paused row, active row skipped)", got)
	}
	if st, _ := f.cache.GetWorkspaceStatus(ctx, testAlias, "ws-recover"); st.State != cache.WorkspaceStateActive {
		t.Errorf("ws-recover state = %q, want active", st.State)
	}
	if st, _ := f.cache.GetWorkspaceStatus(ctx, testAlias, "ws-stuck"); st.State != cache.WorkspaceStatePaused {
		t.Errorf("ws-stuck state = %q, want paused", st.State)
	}
	if st, _ := f.cache.GetWorkspaceStatus(ctx, testAlias, "ws-active"); st.State != cache.WorkspaceStateActive {
		t.Errorf("ws-active state = %q, want active", st.State)
	}
}

// TestExtractErrorCode covers the JSON helper in isolation.
func TestExtractErrorCode(t *testing.T) {
	cases := []struct {
		in, want string
	}{
		{`{"errorcode":"CapacityPaused"}`, "CapacityPaused"},
		{`{ "errorcode" :  "X" }`, "X"},
		{`{"errorcode":  "spaces"}`, "spaces"},
		{`{"message":"no code"}`, ""},
		{``, ""},
	}
	for _, c := range cases {
		got := extractErrorCode(strings.ToLower(c.in))
		if got != strings.ToLower(c.want) {
			t.Errorf("extractErrorCode(%q) = %q, want %q", c.in, got, c.want)
		}
	}
}
