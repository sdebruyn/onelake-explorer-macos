// Package sync wires the local cache (internal/cache) to the OneLake DFS
// client (internal/onelake) and the Fabric REST client (internal/fabric)
// to give the File Provider Extension and the CLI a single, cohesive
// API for enumerate / open / put / delete / mkdir / list-workspaces /
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
//     Folder freshness is governed by adaptive-poll TTLs: OpenFolderTTL
//     for folders currently visible in Finder (default 30 s) and
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
package sync

import (
	"errors"
	"log/slog"
	"time"

	"github.com/sdebruyn/onelake-explorer-macos/internal/cache"
	"github.com/sdebruyn/onelake-explorer-macos/internal/fabric"
	"github.com/sdebruyn/onelake-explorer-macos/internal/onelake"
	"github.com/sdebruyn/onelake-explorer-macos/internal/telemetry"
)

// Default TTLs implementing the adaptive-poll schedule from docs/auth.md.
// The engine never goes longer than RecentFolderTTL without revalidating
// a cache entry, even when the caller does not pass an explicit context
// flag identifying the folder as "currently open" in Finder.
const (
	// DefaultOpenFolderTTL is the freshness window for folders currently
	// visible in Finder. Per docs/auth.md the daemon's adaptive poller
	// refreshes these every 30 s, and an Enumerate call falls back on a
	// remote fetch once the cached row is older than this.
	DefaultOpenFolderTTL = 30 * time.Second

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

	// OpenFolderTTL is the refresh interval for folders currently
	// visible in Finder. Defaults to DefaultOpenFolderTTL.
	OpenFolderTTL time.Duration

	// RecentFolderTTL is the refresh interval for folders the user
	// visited recently. Defaults to DefaultRecentFolderTTL.
	RecentFolderTTL time.Duration

	// Now overrides time.Now for tests. Production callers leave it nil.
	Now func() time.Time
}

// Engine reconciles a remote OneLake item with the local cache. See the
// package doc for the contract.
type Engine struct {
	cache           *cache.Cache
	fabric          *fabric.Client
	onelake         *onelake.Client
	telemetry       *telemetry.Client
	tenants         TenantResolver
	logger          *slog.Logger
	openFolderTTL   time.Duration
	recentFolderTTL time.Duration
	now             func() time.Time
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

	openTTL := opts.OpenFolderTTL
	if openTTL <= 0 {
		openTTL = DefaultOpenFolderTTL
	}
	recentTTL := opts.RecentFolderTTL
	if recentTTL <= 0 {
		recentTTL = DefaultRecentFolderTTL
	}

	return &Engine{
		cache:           opts.Cache,
		fabric:          opts.Fabric,
		onelake:         opts.OneLake,
		telemetry:       opts.Telemetry,
		tenants:         opts.Tenants,
		logger:          logger,
		openFolderTTL:   openTTL,
		recentFolderTTL: recentTTL,
		now:             now,
	}, nil
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

// OpenFolderTTL returns the configured open-folder freshness window.
// Exposed primarily for tests and the daemon's adaptive poller.
func (e *Engine) OpenFolderTTL() time.Duration { return e.openFolderTTL }

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
