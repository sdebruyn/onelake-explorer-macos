package sync

import (
	"context"
	"errors"
	"io"
	"log/slog"
	"net"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/sdebruyn/onelake-explorer-macos/internal/cache"
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
// paused capacity would queue uploads forever.
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
	msg := err.Error()
	return strings.Contains(msg, "no such host") ||
		strings.Contains(msg, "network is unreachable") ||
		strings.Contains(msg, "no route to host") ||
		strings.Contains(msg, "connection refused")
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
// status response so the host app and CLI render a banner.
func (e *Engine) Offline() bool {
	if e == nil || e.offline == nil {
		return false
	}
	return e.offline.offline(e.now())
}

// observeNetworkResult feeds the engine's offline tracker with the
// outcome of a single outbound call. err == nil counts as a successful
// round-trip; an IsOfflineError(err) flips the offline flag.
//
// On the offline → online transition the offline queue is drained in
// a fresh goroutine so any uploads we couldn't push during the offline
// window go out FIFO. A no-op transition (already online) does not
// trigger a drain — otherwise every successful call within an active
// drain spawns another drain and we recurse.
func (e *Engine) observeNetworkResult(err error) {
	if e == nil || e.offline == nil {
		return
	}
	if err == nil {
		wasOffline := e.offline.flagged.Load()
		e.offline.markOnline()
		if wasOffline && e.queueDepth() > 0 {
			go e.drainOfflineQueue(context.Background())
		}
		return
	}
	if IsOfflineError(err) {
		e.offline.markOffline(e.now())
	}
}

// queuedUpload represents an upload deferred because the host was
// offline at the time of the call. The bytes live in a spool file
// under <cacheRoot>/offline-queue/ so they survive a daemon restart;
// the in-memory entry records the cache key and the spool path.
type queuedUpload struct {
	key    cache.Key
	body   string
	size   int64
	queued time.Time
}

// offlineQueueDirName is the leaf directory under the cache root used
// to hold spool bytes for queued uploads.
const offlineQueueDirName = "offline-queue"

// enqueueOfflineUpload writes content to a spool file under the cache
// root and records the upload in the in-memory FIFO queue.
func (e *Engine) enqueueOfflineUpload(_ context.Context, k cache.Key, content io.Reader, size int64) error {
	if e.cache == nil {
		return errors.New("sync: nil cache for offline queue")
	}
	dir := filepath.Join(e.cache.Root(), offlineQueueDirName)
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return err
	}
	tmp, err := os.CreateTemp(dir, "queued-*.bin")
	if err != nil {
		return err
	}
	written, err := io.Copy(tmp, content)
	if err != nil {
		_ = tmp.Close()
		_ = os.Remove(tmp.Name())
		return err
	}
	if err := tmp.Close(); err != nil {
		_ = os.Remove(tmp.Name())
		return err
	}
	q := queuedUpload{key: k, body: tmp.Name(), size: written, queued: e.now()}
	e.queueMu.Lock()
	e.queue = append(e.queue, q)
	e.queueMu.Unlock()
	e.logger.Info("queued upload during offline window",
		slog.String("alias", k.AccountAlias),
		slog.String("path", k.Path),
		slog.Int64("size", written),
	)
	return nil
}

// drainOfflineQueue replays every queued upload in FIFO order using
// the standard Put path. Stops on the first failure so the queue
// stays ordered and the engine backs off naturally if the network is
// still flaky. Successful items are removed from the queue and their
// spool file is unlinked.
//
// Drains are serialised: a second caller that arrives while a drain
// is in progress returns immediately. The in-progress drain already
// sees the up-to-date queue because items are appended under the
// shared queueMu lock.
func (e *Engine) drainOfflineQueue(ctx context.Context) {
	if !e.drainMu.TryLock() {
		return
	}
	defer e.drainMu.Unlock()

	for {
		e.queueMu.Lock()
		if len(e.queue) == 0 {
			e.queueMu.Unlock()
			return
		}
		q := e.queue[0]
		e.queueMu.Unlock()

		f, err := os.Open(q.body) // #nosec G304 -- path constrained to <cacheRoot>/offline-queue/
		if err != nil {
			e.logger.Warn("drain queue: cannot open spool; dropping entry",
				slog.String("path", q.body), slog.Any("err", err))
			e.dropQueueHead(q.body)
			continue
		}
		if err := e.Put(ctx, q.key, f, q.size); err != nil {
			_ = f.Close()
			e.logger.Warn("drain queue: replay failed; keeping rest in queue",
				slog.String("path", q.key.Path), slog.Any("err", err))
			return
		}
		_ = f.Close()
		e.logger.Info("drain queue: replayed upload",
			slog.String("alias", q.key.AccountAlias),
			slog.String("path", q.key.Path),
		)
		_ = os.Remove(q.body)
		e.dropQueueHead(q.body)
	}
}

// dropQueueHead removes the FIFO head when its spool path matches the
// expected one. The path check guards against a concurrent drain
// having already removed the entry.
func (e *Engine) dropQueueHead(expected string) {
	e.queueMu.Lock()
	defer e.queueMu.Unlock()
	if len(e.queue) > 0 && e.queue[0].body == expected {
		e.queue = e.queue[1:]
	}
}

// queueDepth reports the number of uploads currently queued. Exposed
// for tests and for the IPC status surface (future work).
func (e *Engine) queueDepth() int {
	e.queueMu.Lock()
	defer e.queueMu.Unlock()
	return len(e.queue)
}
