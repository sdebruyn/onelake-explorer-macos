package sync

import (
	"context"
	"encoding/base32"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net"
	"os"
	"path/filepath"
	"sort"
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
// under <cacheRoot>/offline-queue/ whose filename deterministically
// encodes the cache.Key so a daemon restart can rebuild the queue
// from disk without any side-channel state.
type queuedUpload struct {
	key    cache.Key
	body   string
	size   int64
	queued time.Time
}

// offlineQueueDirName is the leaf directory under the cache root used
// to hold spool bytes for queued uploads.
const offlineQueueDirName = "offline-queue"

// queueSuffix is the file extension appended to the encoded-key
// filename so the directory walker can distinguish queue files from
// stray temp files that may end up alongside them.
const queueSuffix = ".queued"

// fieldSep separates the cache.Key fields inside a queue filename. A
// NUL byte is the safest separator because none of the four fields can
// legitimately contain it; we base32-encode the concatenation so the
// resulting name is portable across filesystems.
const fieldSep = "\x00"

// spoolNameForKey produces a deterministic, filesystem-safe filename
// that encodes k so a restart-time walker can decode it back. Using a
// lossless base32 (no padding) keeps the result alphanumeric and
// constant-width per input — equal Keys map to equal filenames so
// multiple offline Put attempts on the same path collapse to one entry.
func spoolNameForKey(k cache.Key) string {
	raw := k.AccountAlias + fieldSep + k.WorkspaceID + fieldSep + k.ItemID + fieldSep + k.Path
	enc := base32.StdEncoding.WithPadding(base32.NoPadding).EncodeToString([]byte(raw))
	return enc + queueSuffix
}

// keyFromSpoolName is the inverse of spoolNameForKey. Returns ok=false
// when name is not a valid queue file (wrong suffix, wrong number of
// fields, non-base32 body) so the walker can skip stray files instead
// of crashing.
func keyFromSpoolName(name string) (cache.Key, bool) {
	if !strings.HasSuffix(name, queueSuffix) {
		return cache.Key{}, false
	}
	body := strings.TrimSuffix(name, queueSuffix)
	dec, err := base32.StdEncoding.WithPadding(base32.NoPadding).DecodeString(body)
	if err != nil {
		return cache.Key{}, false
	}
	parts := strings.SplitN(string(dec), fieldSep, 4)
	if len(parts) != 4 {
		return cache.Key{}, false
	}
	return cache.Key{
		AccountAlias: parts[0],
		WorkspaceID:  parts[1],
		ItemID:       parts[2],
		Path:         parts[3],
	}, true
}

// enqueueOfflineUpload writes content to a spool file under the cache
// root and records the upload in the in-memory FIFO queue. The spool
// file is fsync'd before this returns nil so a power-cut between
// enqueue and drain does not lose the user's bytes.
func (e *Engine) enqueueOfflineUpload(_ context.Context, k cache.Key, content io.Reader, _ int64) error {
	if e.cache == nil {
		return errors.New("sync: nil cache for offline queue")
	}
	dir := filepath.Join(e.cache.Root(), offlineQueueDirName)
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return err
	}
	final := filepath.Join(dir, spoolNameForKey(k))
	// Write to a sibling temp first then atomically rename, so a crash
	// mid-write never leaves a half-baked spool file the recovery
	// walker would try to replay.
	tmp, err := os.CreateTemp(dir, "spool-*.tmp")
	if err != nil {
		return err
	}
	written, err := io.Copy(tmp, content)
	if err != nil {
		_ = tmp.Close()
		_ = os.Remove(tmp.Name())
		return err
	}
	// fsync the bytes to disk before declaring success; without this
	// the OS may lose the write on power-cut between enqueue and
	// drain, and the caller already saw a nil-success from Put.
	if err := tmp.Sync(); err != nil {
		_ = tmp.Close()
		_ = os.Remove(tmp.Name())
		return err
	}
	if err := tmp.Close(); err != nil {
		_ = os.Remove(tmp.Name())
		return err
	}
	if err := os.Rename(tmp.Name(), final); err != nil {
		_ = os.Remove(tmp.Name())
		return err
	}
	// fsync the directory entry so the rename is durable too. Best-
	// effort: not every filesystem requires it and the failure case
	// (rare) is still an enqueue-as-best-we-can.
	if dh, derr := os.Open(dir); derr == nil {
		_ = dh.Sync()
		_ = dh.Close()
	}
	q := queuedUpload{key: k, body: final, size: written, queued: e.now()}
	e.queueMu.Lock()
	// Coalesce: if an entry for the same final path already sits in
	// the queue, drop the old entry — the new spool file replaced its
	// bytes on disk and the file rename is atomic.
	for i, q0 := range e.queue {
		if q0.body == final {
			e.queue = append(e.queue[:i], e.queue[i+1:]...)
			break
		}
	}
	e.queue = append(e.queue, q)
	e.queueMu.Unlock()
	e.logger.Info("queued upload during offline window",
		slog.String("alias", k.AccountAlias),
		slog.String("path", k.Path),
		slog.Int64("size", written),
	)
	return nil
}

// recoverOfflineQueue walks <cacheRoot>/offline-queue/ on daemon
// startup and rebuilds the in-memory queue from any spool files it
// finds. Files whose names cannot be decoded back to a cache.Key are
// left in place and logged at debug — they will not block drain.
//
// Ordering: entries are sorted by mtime so the FIFO invariant of
// "earlier writes drain first" survives a restart. Within the same
// mtime, filename (= encoded key) acts as a stable tiebreaker.
//
// Called from daemon.run before the IPC listener accepts requests so
// the queue is never empty between "Put returns nil" and "drain on
// network recovery". Safe to call multiple times: any entries already
// in memory under matching paths are coalesced, not duplicated.
func (e *Engine) recoverOfflineQueue() error {
	if e == nil || e.cache == nil {
		return nil
	}
	dir := filepath.Join(e.cache.Root(), offlineQueueDirName)
	ents, err := os.ReadDir(dir)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return nil
		}
		return fmt.Errorf("sync: recover offline queue: %w", err)
	}
	type pending struct {
		path  string
		key   cache.Key
		size  int64
		mtime time.Time
	}
	pendings := make([]pending, 0, len(ents))
	for _, ent := range ents {
		if ent.IsDir() {
			continue
		}
		name := ent.Name()
		k, ok := keyFromSpoolName(name)
		if !ok {
			// Stray file (likely a half-written ".tmp" from a previous
			// crash). Best to leave it alone so a future operator can
			// inspect; the walker's job is rebuild, not cleanup.
			e.logger.Debug("offline queue: skipping unrecognised file",
				slog.String("name", name))
			continue
		}
		info, err := ent.Info()
		if err != nil {
			continue
		}
		pendings = append(pendings, pending{
			path:  filepath.Join(dir, name),
			key:   k,
			size:  info.Size(),
			mtime: info.ModTime(),
		})
	}
	sort.Slice(pendings, func(i, j int) bool {
		if !pendings[i].mtime.Equal(pendings[j].mtime) {
			return pendings[i].mtime.Before(pendings[j].mtime)
		}
		return pendings[i].path < pendings[j].path
	})

	e.queueMu.Lock()
	defer e.queueMu.Unlock()
	for _, p := range pendings {
		seen := false
		for _, q := range e.queue {
			if q.body == p.path {
				seen = true
				break
			}
		}
		if seen {
			continue
		}
		e.queue = append(e.queue, queuedUpload{
			key:    p.key,
			body:   p.path,
			size:   p.size,
			queued: p.mtime,
		})
	}
	if len(pendings) > 0 {
		e.logger.Info("offline queue: recovered from disk",
			slog.Int("entries", len(pendings)))
	}
	return nil
}

// RecoverOfflineQueue is the exported entry point the daemon calls at
// startup before opening the IPC socket. See [Engine.recoverOfflineQueue].
func (e *Engine) RecoverOfflineQueue() error { return e.recoverOfflineQueue() }

// drainingCtxKey marks a context as belonging to an offline-queue drain.
// [Engine.Put] consults it via [isDraining] so a replay that hits offline
// again surfaces the error instead of re-spooling the bytes. Without this,
// the replay would rewrite the very spool file the drain is about to
// unlink (the spool path is deterministic per key) and coalesce the queue
// head away — losing the upload under flapping connectivity.
type drainingCtxKey struct{}

func withDraining(ctx context.Context) context.Context {
	return context.WithValue(ctx, drainingCtxKey{}, true)
}

func isDraining(ctx context.Context) bool {
	v, _ := ctx.Value(drainingCtxKey{}).(bool)
	return v
}

// drainOfflineQueue replays every queued upload in FIFO order using
// the standard Put path (in draining mode, so a replay that hits offline
// surfaces the error rather than re-queueing). Stops on the first failure
// so the queue stays ordered and the engine backs off naturally if the
// network is still flaky. Successful items are removed from the queue and
// their spool file is unlinked.
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
		if err := e.Put(withDraining(ctx), q.key, f, q.size); err != nil {
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
