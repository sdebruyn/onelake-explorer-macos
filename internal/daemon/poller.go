package daemon

import (
	"context"
	"log/slog"
	"time"

	"github.com/sdebruyn/onelake-explorer-macos/internal/cache"
	"github.com/sdebruyn/onelake-explorer-macos/internal/sync"
)

// pollerCache is the subset of [cache.Cache] the adaptive poller needs.
// Defined as an interface so the helper can be unit-tested without
// touching SQLite.
type pollerCache interface {
	HotItems(ctx context.Context, since time.Time) ([]cache.Key, error)
}

// pollerEngine is the subset of [sync.Engine] the adaptive poller needs.
type pollerEngine interface {
	RefreshFolder(ctx context.Context, k cache.Key) (sync.Diff, error)
	SweepPausedWorkspaces(ctx context.Context)
}

// runAdaptivePoller refreshes the root of every recently-accessed item
// on a ticker. The blocking loop honors ctx for shutdown.
//
// Per docs/auth.md the adaptive poller refreshes "recent" folders every
// 5 minutes. The full notion of "recent" requires interaction with the
// File Provider Extension (Phase 1); until then we approximate it from
// the cache's LastAccessed timestamps via [cache.Cache.HotItems].
//
// Telemetry: sync_pulled events are emitted by [sync.Engine.RefreshFolder]
// itself (the engine is the single source of truth and already tags them
// with the resolved tenantId). The poller deliberately does NOT emit a
// second event per refresh — that would double-count every sweep.
//
// feed may be nil; when non-nil, detected changes are published so the
// host app can call signalEnumerator via the sync.pollChanges RPC.
func runAdaptivePoller(
	ctx context.Context,
	c pollerCache,
	engine pollerEngine,
	logger *slog.Logger,
	period time.Duration,
	hotWindow time.Duration,
	feed *Changefeed,
) {
	if period <= 0 {
		// Defensive: New always picks a positive default, but a future
		// caller passing zero should not turn into a tight loop.
		return
	}
	ticker := time.NewTicker(period)
	defer ticker.Stop()

	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			pollOnce(ctx, c, engine, logger, hotWindow, feed)
		}
	}
}

// pollOnce performs a single sweep: load hot items and refresh each
// one's root, then probe any paused workspaces so the IPC status
// surface recovers without requiring user interaction. Errors from
// individual refreshes are logged and swallowed so a transient failure
// on one item does not stall the rest of the sweep.
//
// feed may be nil. When non-nil, any item whose refresh produces a
// non-zero Diff has a ChangeEvent published so the host app can call
// signalEnumerator on the affected container.
func pollOnce(
	ctx context.Context,
	c pollerCache,
	engine pollerEngine,
	logger *slog.Logger,
	hotWindow time.Duration,
	feed *Changefeed,
) {
	// Cold-paused recovery probe: one cheap HEAD per paused workspace,
	// regardless of whether the workspace is in HotItems. Without this,
	// a workspace that goes paused while nobody is looking at it never
	// flips back to active in the IPC status response until the next
	// user click. The sweep runs in line with the same ticker so we
	// don't add a second goroutine; pacing is bounded by the per-
	// workspace pausedProbeInterval inside the engine.
	engine.SweepPausedWorkspaces(ctx)

	since := time.Now().Add(-hotWindow)
	items, err := c.HotItems(ctx, since)
	if err != nil {
		logger.Warn("adaptive poller: load hot items failed", slog.Any("err", err))
		return
	}
	if len(items) == 0 {
		return
	}

	logger.Debug("adaptive poller: sweep", slog.Int("items", len(items)))
	for _, k := range items {
		// Sweep the item root; descendants get refreshed by the
		// existing Enumerate path the next time Finder touches them.
		k.Path = ""

		// Honor cancellation between every item, not just between
		// cycles: a sweep over a long hot-list shouldn't block daemon
		// shutdown for the duration of a slow refresh.
		if ctx.Err() != nil {
			return
		}
		diff, rerr := engine.RefreshFolder(ctx, k)
		if rerr != nil {
			logger.Debug("adaptive poller: refresh failed",
				slog.String("alias", k.AccountAlias),
				slog.String("workspace", k.WorkspaceID),
				slog.String("item", k.ItemID),
				slog.Any("err", rerr),
			)
			continue
		}
		logger.Debug("adaptive poller: refreshed",
			slog.String("alias", k.AccountAlias),
			slog.String("workspace", k.WorkspaceID),
			slog.String("item", k.ItemID),
			slog.Int("added", diff.Added),
			slog.Int("updated", diff.Updated),
			slog.Int("removed", diff.Removed),
		)

		// Publish a change event when the diff is non-zero so the host
		// app can call signalEnumerator on the affected container.
		if feed != nil && diff.Total() > 0 {
			domain := "ofem." + k.AccountAlias
			// The container is the item root (k.Path is cleared above).
			containerID := k.AccountAlias + "/" + k.WorkspaceID + "/" + k.ItemID
			feed.Publish(domain, containerID, time.Now().UTC())
		}
	}
}
