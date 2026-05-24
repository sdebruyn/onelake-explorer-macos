package cache

import (
	"context"
	"errors"
	"os"
	"testing"
	"time"
)

func openTestCache(t *testing.T) *Cache {
	t.Helper()
	c, err := Open(Options{Root: t.TempDir()})
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	t.Cleanup(func() { _ = c.Close() })
	return c
}

func TestWorkspaceStatus_MissingIsNotFound(t *testing.T) {
	c := openTestCache(t)
	_, err := c.GetWorkspaceStatus(context.Background(), "work", "ws-1")
	if !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("want ErrNotExist, got %v", err)
	}
}

func TestWorkspaceStatus_RoundTrip(t *testing.T) {
	c := openTestCache(t)
	ctx := context.Background()
	now := time.Date(2026, 5, 24, 10, 0, 0, 0, time.UTC)

	in := WorkspaceStatus{
		AccountAlias: "work",
		WorkspaceID:  "ws-1",
		State:        WorkspaceStatePaused,
		Reason:       "capacity_paused",
		DetectedAt:   now,
		ProbedAt:     now.Add(5 * time.Minute),
	}
	if err := c.SetWorkspaceStatus(ctx, in); err != nil {
		t.Fatalf("Set: %v", err)
	}

	got, err := c.GetWorkspaceStatus(ctx, "work", "ws-1")
	if err != nil {
		t.Fatalf("Get: %v", err)
	}
	if got.State != WorkspaceStatePaused {
		t.Errorf("state = %q, want paused", got.State)
	}
	if got.Reason != "capacity_paused" {
		t.Errorf("reason = %q, want capacity_paused", got.Reason)
	}
	if !got.DetectedAt.Equal(now) {
		t.Errorf("detectedAt = %v, want %v", got.DetectedAt, now)
	}
	if !got.ProbedAt.Equal(now.Add(5 * time.Minute)) {
		t.Errorf("probedAt = %v, want %v", got.ProbedAt, now.Add(5*time.Minute))
	}
}

func TestWorkspaceStatus_DetectedAtPreservedOnSameState(t *testing.T) {
	c := openTestCache(t)
	ctx := context.Background()
	first := time.Date(2026, 5, 24, 10, 0, 0, 0, time.UTC)

	_ = c.SetWorkspaceStatus(ctx, WorkspaceStatus{
		AccountAlias: "work", WorkspaceID: "ws-1",
		State: WorkspaceStatePaused, Reason: "capacity_paused",
		DetectedAt: first,
	})

	// Re-mark paused later: DetectedAt must stick (workspace has been
	// continuously paused).
	later := first.Add(1 * time.Hour)
	_ = c.SetWorkspaceStatus(ctx, WorkspaceStatus{
		AccountAlias: "work", WorkspaceID: "ws-1",
		State: WorkspaceStatePaused, Reason: "capacity_paused",
		DetectedAt: later,
	})

	got, _ := c.GetWorkspaceStatus(ctx, "work", "ws-1")
	if !got.DetectedAt.Equal(first) {
		t.Errorf("detectedAt = %v, want %v (must preserve original)", got.DetectedAt, first)
	}
}

func TestWorkspaceStatus_DetectedAtResetOnStateChange(t *testing.T) {
	c := openTestCache(t)
	ctx := context.Background()
	first := time.Date(2026, 5, 24, 10, 0, 0, 0, time.UTC)
	_ = c.SetWorkspaceStatus(ctx, WorkspaceStatus{
		AccountAlias: "work", WorkspaceID: "ws-1",
		State: WorkspaceStatePaused, Reason: "capacity_paused",
		DetectedAt: first,
	})

	resumed := first.Add(2 * time.Hour)
	_ = c.SetWorkspaceStatus(ctx, WorkspaceStatus{
		AccountAlias: "work", WorkspaceID: "ws-1",
		State: WorkspaceStateActive, DetectedAt: resumed,
	})

	got, _ := c.GetWorkspaceStatus(ctx, "work", "ws-1")
	if !got.DetectedAt.Equal(resumed) {
		t.Errorf("detectedAt = %v, want %v (must reset on transition)", got.DetectedAt, resumed)
	}
}

func TestListWorkspaceStatuses_Ordering(t *testing.T) {
	c := openTestCache(t)
	ctx := context.Background()
	for _, p := range []struct{ alias, ws string }{
		{"zeta", "b"}, {"alpha", "z"}, {"alpha", "a"},
	} {
		_ = c.SetWorkspaceStatus(ctx, WorkspaceStatus{
			AccountAlias: p.alias, WorkspaceID: p.ws, State: WorkspaceStatePaused,
		})
	}
	got, err := c.ListWorkspaceStatuses(ctx)
	if err != nil {
		t.Fatalf("List: %v", err)
	}
	want := [][2]string{{"alpha", "a"}, {"alpha", "z"}, {"zeta", "b"}}
	if len(got) != len(want) {
		t.Fatalf("len = %d, want %d", len(got), len(want))
	}
	for i, w := range want {
		if got[i].AccountAlias != w[0] || got[i].WorkspaceID != w[1] {
			t.Errorf("row %d = (%q,%q), want (%q,%q)", i, got[i].AccountAlias, got[i].WorkspaceID, w[0], w[1])
		}
	}
}
