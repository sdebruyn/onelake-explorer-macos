package sync

import (
	"context"
	"errors"
	"log/slog"
	"net"
	"os"
	"path/filepath"
	"sync"
	"sync/atomic"
	"time"
)

// offlineCooldown is the maximum time the engine keeps reporting
// itself offline without a successful round-trip. We never auto-
// recover purely on time; the next outbound call's outcome flips the
// flag back. This constant only bounds how stale the "offline" status
// surface can be when no traffic is flowing.
const offlineCooldown = 1 * time.Minute

// IsOfflineError reports whether err matches the kernel- and DNS-class
// failures we treat as "host is offline". The predicate is deliberately
// restrictive: a 503 should NOT promote the engine to offline, otherwise
// paused capacity would appear as an offline condition.
func IsOfflineError(err error) bool {
	if err == nil {
		return false
	}
	if errors.Is(err, context.Canceled) || errors.Is(err, context.DeadlineExceeded) {
		return false
	}
	var dnsErr *net.DNSError
	if errors.As(err, &dnsErr) {
		return true
	}
	var opErr *net.OpError
	if errors.As(err, &opErr) {
		if !opErr.Timeout() {
			return true
		}
	}
	return false
}

// offlineState tracks whether the engine recently observed an offline-
// class failure. A successful outbound call clears the state; otherwise
// the state expires after offlineCooldown.
type offlineState struct {
	mu      sync.Mutex
	since   time.Time
	flagged atomic.Bool
}

func newOfflineState() *offlineState { return &offlineState{} }

func (s *offlineState) markOffline(now time.Time) {
	s.mu.Lock()
	s.since = now
	s.mu.Unlock()
	s.flagged.Store(true)
}

func (s *offlineState) markOnline() {
	s.flagged.Store(false)
	s.mu.Lock()
	s.since = time.Time{}
	s.mu.Unlock()
}

func (s *offlineState) offline(now time.Time) bool {
	if !s.flagged.Load() {
		return false
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if !s.since.IsZero() && now.Sub(s.since) > offlineCooldown {
		s.flagged.Store(false)
		s.since = time.Time{}
		return false
	}
	return true
}

// Offline reports the engine's current best guess about host
// connectivity. The daemon's status handler surfaces this on the IPC
// status response so the host app can render a degraded state.
func (e *Engine) Offline() bool {
	if e == nil || e.offline == nil {
		return false
	}
	return e.offline.offline(e.now())
}

// observeNetworkResult feeds the engine's offline tracker with the
// outcome of a single outbound call. err == nil counts as a successful
// round-trip and clears the offline flag; an IsOfflineError(err) sets it.
func (e *Engine) observeNetworkResult(err error) {
	if e == nil || e.offline == nil {
		return
	}
	if err == nil {
		e.offline.markOnline()
		return
	}
	if IsOfflineError(err) {
		e.offline.markOffline(e.now())
	}
}

// CleanupLegacyOfflineQueue removes the on-disk spool directory left
// behind by the offline upload queue that was removed in this release.
// The removal is idempotent: if the directory does not exist (fresh
// install or already cleaned) the function returns without logging.
// If removal fails — extremely unlikely — the error is logged at Warn
// and the daemon continues booting normally; leftover bytes in that
// directory are harmless. Call once at daemon startup in the code path
// that previously called RecoverOfflineQueue. This helper has a
// time-bounded lifecycle and can be deleted after a few releases once
// no surviving installation still carries the spool directory.
func CleanupLegacyOfflineQueue(cacheRoot string, logger *slog.Logger) {
	dir := filepath.Join(cacheRoot, "offline-queue")
	if err := os.RemoveAll(dir); err != nil {
		if !errors.Is(err, os.ErrNotExist) {
			logger.Warn("could not remove legacy offline-queue directory",
				slog.String("dir", dir),
				slog.Any("err", err),
			)
		}
	}
}
