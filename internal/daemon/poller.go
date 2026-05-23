package daemon

import (
	"context"
	"log/slog"
	"time"

	"github.com/sdebruyn/onelake-explorer-macos/internal/cache"
	"github.com/sdebruyn/onelake-explorer-macos/internal/sync"
	"github.com/sdebruyn/onelake-explorer-macos/internal/telemetry"
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
}

// telemetryTracker is the subset of [telemetry.Client] the poller uses.
// Accepting an interface keeps the runOnce helper trivially mockable.
type telemetryTracker interface {
	Track(ev telemetry.Event)
}

// runAdaptivePoller refreshes the root of every recently-accessed item
// on a ticker. The blocking loop honors ctx for shutdown.
//
// Per docs/auth.md the adaptive poller refreshes "recent" folders every
// 5 minutes. The full notion of "recent" requires interaction with the
// File Provider Extension (Phase 1); until then we approximate it from
// the cache's LastAccessed timestamps via [cache.Cache.HotItems].
func runAdaptivePoller(
	ctx context.Context,
	c pollerCache,
	engine pollerEngine,
	tel telemetryTracker,
	logger *slog.Logger,
	period time.Duration,
	hotWindow time.Duration,
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
			pollOnce(ctx, c, engine, tel, logger, hotWindow)
		}
	}
}

// pollOnce performs a single sweep: load hot items, refresh each one's
// root, and emit a sync_pulled event per touched item that had at least
// one change. Errors from individual refreshes are logged and swallowed
// so a transient failure on one item does not stall the rest of the
// sweep.
func pollOnce(
	ctx context.Context,
	c pollerCache,
	engine pollerEngine,
	tel telemetryTracker,
	logger *slog.Logger,
	hotWindow time.Duration,
) {
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
		if diff.Total() == 0 {
			continue
		}
		if tel != nil {
			tel.Track(telemetry.Event{
				Name:             "sync_pulled",
				AccountAliasHash: telemetry.HashAlias(k.AccountAlias),
				ItemsChanged:     diff.Total(),
			})
		}
	}
}
