// Package sync wires the local cache (internal/cache) to the OneLake DFS
// client (internal/onelake) and the Fabric REST client (internal/fabric)
// to give the File Provider Extension a single, cohesive API for
// enumerate / open / put / delete / mkdir / list-workspaces /
// list-items operations on OneLake content.
//
// One Engine is intended per OFEM process; it serves every signed-in
// account and every Fabric item the user navigates through. All public
// methods are safe for concurrent use because the underlying clients
// and cache.Cache are.
//
// Design notes:
//
//   - Reads (Enumerate, Open) consult the SQLite metadata cache first.
//     Folder freshness is governed by an adaptive-poll TTL:
//     RecentFolderTTL for recently visited folders (default 5 min). See
//     docs/auth.md for the rationale.
//
//   - Writes (Put, Delete, Mkdir) follow last-write-wins semantics per
//     the agreed conflict policy: we never read-merge-write, we just
//     issue the operation against OneLake and update the local cache
//     with the new state.
//
//   - macOS metadata files (.DS_Store, ._*, Spotlight-V100, Trashes,
//     fseventsd) are silently swallowed on upload paths so they never
//     reach the lake. See docs/file-provider.md.
//
//   - Every public method emits a telemetry event per docs/telemetry.md.
//     The macOS-metadata short-circuit emits no telemetry by design.
//
// # Throttling layers
//
// OFEM gates concurrent traffic at two independent layers and the two
// must be reasoned about separately:
//
//  1. Per-account caps (this package, see concurrency.go). A
//     perAccountSemaphore caps in-flight Put / Open calls per account
//     alias. The slot is held for the entire logical operation —
//     including the chunked PUT/PATCH chain and the partial-download
//     resume retries — and released via deferred `release` exactly once
//     at function exit, even on error paths. This is fairness between
//     accounts: a misbehaving account cannot starve others.
//
//  2. Per-host caps (internal/httpgate, see PR #39). A per-host token
//     bucket caps the raw HTTP requests OFEM emits against a single
//     origin. The bucket is consumed for every chunk PUT / PATCH /
//     GET that goes on the wire and released by the transport when
//     the response completes. This is origin protection: we never
//     hammer onelake.dfs.fabric.microsoft.com beyond what the docs
//     say it tolerates.
//
// The two layers compose: a single Put can hold one per-account
// upload slot AND consume per-host tokens for each chunk in its
// PUT/PATCH chain. They do not double-count or interlock because
// they gate orthogonal resources (logical operation vs HTTP request).
// A 412 storm on one account does not lock per-account slots beyond
// the deferred release scope and never holds per-host tokens (412
// responses release the token on receipt).
package sync

import (
	"errors"
	"log/slog"
	"os"
	"path/filepath"
	"strconv"
	"sync"
	"time"

	"github.com/sdebruyn/onelake-explorer-macos/internal/cache"
	"github.com/sdebruyn/onelake-explorer-macos/internal/fabric"
	"github.com/sdebruyn/onelake-explorer-macos/internal/onelake"
	"github.com/sdebruyn/onelake-explorer-macos/internal/telemetry"
)

// Default TTLs implementing the adaptive-poll schedule from docs/auth.md.
// The engine never goes longer than RecentFolderTTL without revalidating
// a cache entry.
const (
	// DefaultRecentFolderTTL is the freshness window for folders the user
	// visited recently. Per docs/auth.md the adaptive poller refreshes
	// these every 5 min.
	DefaultRecentFolderTTL = 5 * time.Minute
)

// TenantResolver maps an account alias to its Entra tenant GUID. The
// engine consults it when stamping telemetry events that docs/telemetry.md
// requires to carry tenantId. Implementations must be safe for concurrent
// use; [auth.Registry] satisfies the contract.
type TenantResolver interface {
	TenantID(alias string) (string, bool)
}

// Options configures a new Engine. Cache, Fabric, and OneLake are
// required; everything else has a sensible default.
type Options struct {
	// Cache is the SQLite + blob store used for metadata and content.
	// Required.
	Cache *cache.Cache

	// Fabric is the REST client used to discover workspaces and items.
	// Required.
	Fabric *fabric.Client

	// OneLake is the DFS client used for file I/O. Required.
	OneLake *onelake.Client

	// Telemetry receives operation events. Optional; when nil the engine
	// runs without emitting telemetry (the underlying Client.Track
	// already no-ops on nil).
	Telemetry *telemetry.Client

	// Tenants resolves an account alias to its Entra tenant GUID for
	// telemetry tagging. Optional; when nil, sync_pulled and similar
	// events that include tenantId carry an empty tenant string.
	Tenants TenantResolver

	// Logger receives structured logs. Defaults to slog.Default with a
	// "component=sync" attribute when nil.
	Logger *slog.Logger

	// RecentFolderTTL is the refresh interval for folders the user
	// visited recently. Defaults to DefaultRecentFolderTTL.
	RecentFolderTTL time.Duration

	// PausedProbeInterval is the minimum gap between two recovery
	// probes for the same paused workspace. Defaults to
	// DefaultPausedProbeInterval.
	PausedProbeInterval time.Duration

	// MaxConcurrentDownloads caps concurrent Open calls per account.
	// Defaults to DefaultMaxConcurrentDownloads.
	MaxConcurrentDownloads int

	// MaxConcurrentUploads caps concurrent Put calls per account.
	// Defaults to DefaultMaxConcurrentUploads.
	MaxConcurrentUploads int

	// Now overrides time.Now for tests. Production callers leave it nil.
	Now func() time.Time

	// ScratchDir is the directory where in-flight download spill files
	// (and their etag sidecars) are written. It MUST be writable by the
	// process running the engine. The sandboxed File Provider Extension
	// cannot write to the global os.TempDir(), so production callers pass
	// a path inside the App Group container (e.g. <cacheDir>/partials).
	// Defaults to <os.TempDir()>/ofem-download-partials when empty, which
	// suits the unsandboxed CLI, daemon, and tests.
	ScratchDir string
}

// Engine reconciles a remote OneLake item with the local cache. See the
// package doc for the contract.
type Engine struct {
	cache               *cache.Cache
	fabric              *fabric.Client
	onelake             *onelake.Client
	telemetry           *telemetry.Client
	tenants             TenantResolver
	logger              *slog.Logger
	recentFolderTTL     time.Duration
	pausedProbeInterval time.Duration
	pausedTracker       *pausedTracker
	downloadSem         *perAccountSemaphore
	uploadSem           *perAccountSemaphore
	offline             *offlineState
	now                 func() time.Time
	scratchDir          string

	// done is closed by Close to signal background goroutines to unwind.
	// bg tracks those goroutines so Close can wait for them to exit before
	// returning. closeOnce makes Close idempotent.
	done      chan struct{}
	bg        sync.WaitGroup
	closeOnce sync.Once
}

// New constructs an Engine from Options. It returns an error if any of
// the required dependencies (Cache, Fabric, OneLake) is missing so the
// caller fails fast at wiring time rather than at first request.
func New(opts Options) (*Engine, error) {
	switch {
	case opts.Cache == nil:
		return nil, errors.New("sync.New: Cache is required")
	case opts.Fabric == nil:
		return nil, errors.New("sync.New: Fabric is required")
	case opts.OneLake == nil:
		return nil, errors.New("sync.New: OneLake is required")
	}

	logger := opts.Logger
	if logger == nil {
		logger = slog.Default()
	}
	logger = logger.With(slog.String("component", "sync"))

	now := opts.Now
	if now == nil {
		now = func() time.Time { return time.Now().UTC() }
	}

	recentTTL := opts.RecentFolderTTL
	if recentTTL <= 0 {
		recentTTL = DefaultRecentFolderTTL
	}
	probeInterval := opts.PausedProbeInterval
	if probeInterval <= 0 {
		probeInterval = DefaultPausedProbeInterval
	}
	downloads := opts.MaxConcurrentDownloads
	if downloads <= 0 {
		downloads = DefaultMaxConcurrentDownloads
	}
	uploads := opts.MaxConcurrentUploads
	if uploads <= 0 {
		uploads = DefaultMaxConcurrentUploads
	}

	// Download spill files live under a PER-PROCESS subdirectory of the
	// configured scratch dir. The dir is shared cross-process (daemon,
	// CLI, sandboxed extension), but a spill file must never be written
	// by two processes at once: finalisePartial opens it O_RDWR|O_CREATE
	// and, on a fresh download, skips SHA verification (expectedSHA ==
	// ""), so interleaved writes would be content-addressed as a silently
	// corrupt blob. Scoping by PID makes cross-process collisions
	// impossible while keeping in-process resume (the per-account
	// download semaphore still serialises same-key downloads within one
	// process). Spills left behind by a crashed process are reaped here.
	scratchBase := opts.ScratchDir
	if scratchBase == "" {
		scratchBase = filepath.Join(os.TempDir(), partialsDirName)
	}
	reapStalePartialDirs(scratchBase)
	scratchDir := filepath.Join(scratchBase, strconv.Itoa(os.Getpid()))

	return &Engine{
		cache:               opts.Cache,
		fabric:              opts.Fabric,
		onelake:             opts.OneLake,
		telemetry:           opts.Telemetry,
		tenants:             opts.Tenants,
		logger:              logger,
		recentFolderTTL:     recentTTL,
		pausedProbeInterval: probeInterval,
		pausedTracker:       newPausedTracker(),
		downloadSem:         newPerAccountSemaphore(downloads),
		uploadSem:           newPerAccountSemaphore(uploads),
		offline:             newOfflineState(),
		now:                 now,
		scratchDir:          scratchDir,
		done:                make(chan struct{}),
	}, nil
}

// Close stops every background goroutine the engine started during its
// lifetime and waits for them to exit. It is idempotent: a second call
// is a no-op. It does NOT close the cache, the auth registry, or any
// other dependency the engine was wired with — those have their own
// lifecycles owned by the caller (see engine.Components.Close).
//
// The production daemon currently relies on process exit to reap
// goroutines (see internal/daemon/run.go), so calling Close in that
// path is optional. Tests SHOULD call it to avoid goroutine leaks
// that the race detector surfaces under heavy parallelism.
func (e *Engine) Close() error {
	if e == nil {
		return nil
	}
	e.closeOnce.Do(func() {
		if e.done != nil {
			close(e.done)
		}
		e.bg.Wait()
		// Clear per-alias semaphore maps now that all goroutines have
		// exited and no acquire/release calls can be in flight. This
		// reclaims the lazily-allocated channels (one per alias ever
		// seen) that would otherwise remain for the process lifetime.
		e.downloadSem.clear()
		e.uploadSem.clear()
	})
	return nil
}

// tenantFor returns the tenant GUID for alias, or "" if no resolver is
// wired or the alias is unknown. Cheap to call (the Registry-backed
// resolver only reads a config snapshot).
func (e *Engine) tenantFor(alias string) string {
	if e.tenants == nil || alias == "" {
		return ""
	}
	if tid, ok := e.tenants.TenantID(alias); ok {
		return tid
	}
	return ""
}

// RecentFolderTTL returns the configured recent-folder freshness window.
// Exposed primarily for tests and the daemon's adaptive poller.
func (e *Engine) RecentFolderTTL() time.Duration { return e.recentFolderTTL }

// track is the common helper that hands the event to the telemetry
// client. Callers populate Name, TenantID, AccountAliasHash,
// DurationMs, Success, ErrorCode, BytesTransferred, and ItemsChanged as
// relevant; we just centralise the nil-Telemetry no-op.
func (e *Engine) track(ev telemetry.Event) {
	if e.telemetry == nil {
		return
	}
	e.telemetry.Track(ev)
}

// boolPtr is a tiny helper for the *bool Success field in
// telemetry.Event. Saves a one-shot temporary at every call site.
func boolPtr(b bool) *bool { return &b }

// elapsedMs returns the milliseconds elapsed since start, snapped to at
// least 1 so telemetry never records 0 for a "completed" operation
// (which would be indistinguishable from "not applicable").
func elapsedMs(start time.Time, now func() time.Time) int64 {
	d := now().Sub(start) / time.Millisecond
	if d <= 0 {
		return 1
	}
	return int64(d)
}
