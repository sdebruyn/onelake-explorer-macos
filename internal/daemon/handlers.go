package daemon

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"time"

	"github.com/sdebruyn/onelake-explorer-macos/internal/auth"
	"github.com/sdebruyn/onelake-explorer-macos/internal/buildinfo"
	"github.com/sdebruyn/onelake-explorer-macos/internal/cache"
	"github.com/sdebruyn/onelake-explorer-macos/internal/config"
	"github.com/sdebruyn/onelake-explorer-macos/internal/fp"
	"github.com/sdebruyn/onelake-explorer-macos/internal/httpgate"
	"github.com/sdebruyn/onelake-explorer-macos/internal/ipc"
	"github.com/sdebruyn/onelake-explorer-macos/internal/sync"
)

// ErrEngineNotWired is returned by sync.refresh when the daemon was
// constructed without a sync engine (for example in unit tests). Callers
// can use [errors.Is] to detect it rather than string-matching the
// formatted error.
var ErrEngineNotWired = errors.New("sync engine not wired")

// syncRefresher is the subset of [sync.Engine] the IPC handlers need.
// Defining it as an interface lets the handler tests inject a stub that
// records calls without spinning up a real engine + token provider +
// HTTP mock stack.
type syncRefresher interface {
	RefreshFolder(ctx context.Context, k cache.Key) (sync.Diff, error)
}

// offlineReporter is the subset of [sync.Engine] the status handler
// uses to surface "is the host offline" to the IPC client. Defined as
// an interface so tests can stub it without spinning up the engine.
type offlineReporter interface {
	Offline() bool
}

// Handlers bundles the dependencies every IPC handler needs and exposes
// a Register method that binds all of OFEM's methods on a [ipc.Server].
//
// Handlers is constructed by [Run] (or by tests via [NewHandlers]) and
// has no public mutator methods — its state is read-only after wiring.
type Handlers struct {
	store     *config.Store
	registry  *auth.Registry
	cache     *cache.Cache
	engine    syncRefresher
	offline   offlineReporter
	gates     *httpgate.Registry
	feed      *Changefeed
	startedAt time.Time
	version   string

	// fp serves the File Provider Extension's enumerate / item / fetch /
	// create / modify / delete over IPC. nil when the daemon was built
	// without a full *sync.Engine (e.g. unit tests with a stub refresher);
	// the fp.* handlers then return ErrEngineNotWired.
	fp   *fp.Service
	fpOK bool
}

// NewHandlers builds a Handlers wired to the given dependencies. All of
// store, registry and cache are required; engine may be nil for tests
// that don't exercise sync.refresh, in which case the method returns an
// error indicating the engine is not wired. gates may be nil for tests;
// when nil, status returns an empty Gates list. feed may be nil for tests;
// when nil, sync.pollChanges returns an empty result.
func NewHandlers(store *config.Store, registry *auth.Registry, cache *cache.Cache, engine syncRefresher, gates *httpgate.Registry, feed *Changefeed) *Handlers {
	off, _ := engine.(offlineReporter)
	h := &Handlers{
		store:     store,
		registry:  registry,
		cache:     cache,
		engine:    engine,
		offline:   off,
		gates:     gates,
		feed:      feed,
		startedAt: time.Now().UTC(),
		version:   buildinfo.Version,
	}
	// Wire the File Provider service only when the daemon owns a full
	// engine (production). The narrow syncRefresher stub used in tests does
	// not satisfy fp.Engine, leaving fp nil so the handlers fail cleanly.
	if fpEng, ok := engine.(fp.Engine); ok && cache != nil {
		h.fp = &fp.Service{Engine: fpEng, Cache: cache}
		h.fpOK = true
	}
	return h
}

// Register installs every IPC method this daemon exposes on srv. Calls
// after the server has started accepting are allowed but ill-advised.
func (h *Handlers) Register(srv *ipc.Server) {
	srv.Register("status", h.handleStatus)
	srv.Register("account.list", h.handleAccountList)
	srv.Register("account.add", h.handleAccountAdd)
	srv.Register("account.remove", h.handleAccountRemove)
	srv.Register("config.snapshot", h.handleConfigSnapshot)
	srv.Register("sync.refresh", h.handleSyncRefresh)
	srv.Register("sync.pollChanges", h.handleSyncPollChanges)
	srv.Register("mount.list", h.handleMountList)

	// File Provider Extension surface (replaces the cgo bridge).
	srv.Register("fp.enumerate", h.handleFPEnumerate)
	srv.Register("fp.item", h.handleFPItem)
	srv.Register("fp.fetchContents", h.handleFPFetchContents)
	srv.Register("fp.createItem", h.handleFPCreateItem)
	srv.Register("fp.modifyItem", h.handleFPModifyItem)
	srv.Register("fp.deleteItem", h.handleFPDeleteItem)
}

// StatusResponse is the payload returned by the "status" method.
type StatusResponse struct {
	// DaemonVersion is the buildinfo.Version baked into the daemon
	// binary at link time.
	DaemonVersion string `json:"daemonVersion"`
	// StartedAt is the wall-clock time the daemon process began
	// accepting IPC requests, in UTC RFC 3339.
	StartedAt time.Time `json:"startedAt"`
	// Accounts is the list of account aliases the daemon knows about.
	Accounts []string `json:"accounts"`
	// CacheBytes is the current on-disk size of cached blobs, or -1 if
	// the cache has not been measured yet.
	CacheBytes int64 `json:"cacheBytes"`
	// CacheMaxBytes is the configured upper bound for cached blob
	// bytes; zero means "no eviction limit".
	CacheMaxBytes int64 `json:"cacheMaxBytes"`
	// Gates is a per-host snapshot of the request-gate state. Empty
	// when the daemon was built without a gate registry (tests). See
	// internal/httpgate for the meaning of each field.
	Gates []httpgate.State `json:"gates"`
	// PausedWorkspaces lists every workspace the sync engine currently
	// considers unreachable due to a paused / suspended Fabric
	// capacity. Empty when no workspace is paused.
	PausedWorkspaces []PausedWorkspace `json:"pausedWorkspaces"`
	// Offline reports whether the daemon believes the host is offline
	// (DNS / network-unreachable on the last outbound attempt). When
	// true, writes are queued locally for later drain.
	Offline bool `json:"offline"`
}

// PausedWorkspace is the JSON-friendly view of one paused workspace.
// Times are emitted as RFC 3339.
type PausedWorkspace struct {
	AccountAlias string    `json:"accountAlias"`
	WorkspaceID  string    `json:"workspaceId"`
	Reason       string    `json:"reason"`
	DetectedAt   time.Time `json:"detectedAt"`
	ProbedAt     time.Time `json:"probedAt,omitempty"`
}

func (h *Handlers) handleStatus(ctx context.Context, _ json.RawMessage) (any, error) {
	snap := h.store.Snapshot()
	aliases := make([]string, 0, len(snap.Accounts))
	for alias := range snap.Accounts {
		aliases = append(aliases, alias)
	}
	sortStrings(aliases)

	cacheBytes := int64(-1)
	if du, err := h.cacheBlobSize(ctx); err == nil {
		cacheBytes = du
	}

	var gates []httpgate.State
	if h.gates != nil {
		gates = h.gates.States()
	}

	paused := make([]PausedWorkspace, 0)
	if h.cache != nil {
		statuses, err := h.cache.ListWorkspaceStatuses(ctx)
		if err == nil {
			for _, s := range statuses {
				if s.State != cache.WorkspaceStatePaused {
					continue
				}
				paused = append(paused, PausedWorkspace{
					AccountAlias: s.AccountAlias,
					WorkspaceID:  s.WorkspaceID,
					Reason:       s.Reason,
					DetectedAt:   s.DetectedAt,
					ProbedAt:     s.ProbedAt,
				})
			}
		}
	}

	offline := false
	if h.offline != nil {
		offline = h.offline.Offline()
	}

	return StatusResponse{
		DaemonVersion:    h.version,
		StartedAt:        h.startedAt,
		Accounts:         aliases,
		CacheBytes:       cacheBytes,
		CacheMaxBytes:    snap.Cache.MaxSizeBytes,
		Gates:            gates,
		PausedWorkspaces: paused,
		Offline:          offline,
	}, nil
}

// cacheBlobSize returns the deduped byte total for linked blobs by
// delegating to cache.BlobBytes, which performs a SQL SUM(DISTINCT blob_size)
// rather than a filesystem walk. This avoids per-call I/O on every status
// request; see internal/cache/size.go for rationale.
func (h *Handlers) cacheBlobSize(ctx context.Context) (int64, error) {
	if h.cache == nil {
		return 0, fmt.Errorf("cache not initialised")
	}
	return h.cache.BlobBytes(ctx)
}

// AccountListResponse is the payload returned by "account.list".
type AccountListResponse struct {
	// Accounts is the registry's view, sorted by alias.
	Accounts []AccountSummary `json:"accounts"`
	// DefaultAccount is the configured default alias, empty when unset.
	DefaultAccount string `json:"defaultAccount"`
}

// AccountSummary is the display-safe subset of [auth.Account] sent over
// the wire. It deliberately omits HomeAccountID because that string
// embeds the per-user objectId and docs/telemetry.md keeps it out of
// any logged channel.
type AccountSummary struct {
	Alias      string    `json:"alias"`
	Username   string    `json:"username"`
	TenantID   string    `json:"tenantId"`
	TenantName string    `json:"tenantName,omitempty"`
	AddedAt    time.Time `json:"addedAt"`
}

func (h *Handlers) handleAccountList(_ context.Context, _ json.RawMessage) (any, error) {
	accounts := h.registry.List()
	out := AccountListResponse{
		Accounts: make([]AccountSummary, 0, len(accounts)),
	}
	for _, a := range accounts {
		out.Accounts = append(out.Accounts, AccountSummary{
			Alias:      a.Alias,
			Username:   a.Username,
			TenantID:   a.TenantID,
			TenantName: a.TenantName,
			AddedAt:    a.AddedAt,
		})
	}
	if def, ok := h.registry.Default(); ok {
		out.DefaultAccount = def
	}
	return out, nil
}

// AccountAddRequest is the payload accepted by "account.add". The
// secret is base64-encoded so JSON can carry arbitrary bytes.
type AccountAddRequest struct {
	Alias     string         `json:"alias"`
	SecretB64 string         `json:"secretB64"`
	Account   AccountPayload `json:"account"`
}

// AccountPayload mirrors [auth.Account] for wire transport.
type AccountPayload struct {
	Alias         string    `json:"alias"`
	HomeAccountID string    `json:"homeAccountId"`
	Username      string    `json:"username"`
	TenantID      string    `json:"tenantId"`
	TenantName    string    `json:"tenantName,omitempty"`
	AddedAt       time.Time `json:"addedAt,omitempty"`
}

// AccountAddResponse confirms the alias that was persisted.
type AccountAddResponse struct {
	Alias string `json:"alias"`
}

func (h *Handlers) handleAccountAdd(_ context.Context, params json.RawMessage) (any, error) {
	var req AccountAddRequest
	if err := json.Unmarshal(params, &req); err != nil {
		return nil, fmt.Errorf("decode params: %w", err)
	}
	if req.Alias == "" {
		req.Alias = req.Account.Alias
	}
	secret, err := decodeBase64(req.SecretB64)
	if err != nil {
		return nil, fmt.Errorf("decode secret: %w", err)
	}
	account := auth.Account{
		Alias:         req.Alias,
		HomeAccountID: req.Account.HomeAccountID,
		Username:      req.Account.Username,
		TenantID:      req.Account.TenantID,
		TenantName:    req.Account.TenantName,
		AddedAt:       req.Account.AddedAt,
	}
	if account.AddedAt.IsZero() {
		account.AddedAt = time.Now().UTC()
	}
	if err := h.registry.Add(account, secret); err != nil {
		return nil, err
	}
	return AccountAddResponse{Alias: req.Alias}, nil
}

// AccountRemoveRequest is the payload accepted by "account.remove".
type AccountRemoveRequest struct {
	Alias string `json:"alias"`
}

// AccountRemoveResponse confirms the alias that was removed.
type AccountRemoveResponse struct {
	Alias string `json:"alias"`
}

func (h *Handlers) handleAccountRemove(_ context.Context, params json.RawMessage) (any, error) {
	var req AccountRemoveRequest
	if err := json.Unmarshal(params, &req); err != nil {
		return nil, fmt.Errorf("decode params: %w", err)
	}
	if req.Alias == "" {
		return nil, fmt.Errorf("alias is required")
	}
	if err := h.registry.Remove(req.Alias); err != nil {
		return nil, err
	}
	return AccountRemoveResponse(req), nil
}

// ConfigSnapshotResponse is the payload returned by "config.snapshot".
// It mirrors [config.File] but omits InstallID to keep telemetry
// pseudonymisation off the wire. The Accounts map is scrubbed to remove
// HomeAccountID and Username (UPN) for the same reason account.list uses
// AccountSummary: docs/telemetry.md explicitly prohibits UPNs from being
// sent over any logged channel, and the IPC socket is accessible to any
// process the user runs.
type ConfigSnapshotResponse struct {
	Telemetry      bool                         `json:"telemetry"`
	DefaultAccount string                       `json:"defaultAccount"`
	Cache          config.CacheConfig           `json:"cache"`
	Net            config.NetConfig             `json:"net"`
	Log            config.LogConfig             `json:"log"`
	Accounts       map[string]configAccountSafe `json:"accounts"`
}

// configAccountSafe is the subset of [config.Account] safe to expose over
// IPC. It omits HomeAccountID (AAD objectId) and Username (UPN) for
// consistency with AccountSummary in account.list.
type configAccountSafe struct {
	Alias      string `json:"alias"`
	TenantID   string `json:"tenantId"`
	TenantName string `json:"tenantName,omitempty"`
	AddedAt    string `json:"addedAt,omitempty"`
}

func (h *Handlers) handleConfigSnapshot(_ context.Context, _ json.RawMessage) (any, error) {
	snap := h.store.Snapshot()
	accounts := make(map[string]configAccountSafe, len(snap.Accounts))
	for k, a := range snap.Accounts {
		accounts[k] = configAccountSafe{
			Alias:      a.Alias,
			TenantID:   a.TenantID,
			TenantName: a.TenantName,
			AddedAt:    a.AddedAt,
		}
	}
	return ConfigSnapshotResponse{
		Telemetry:      snap.Telemetry,
		DefaultAccount: snap.DefaultAccount,
		Cache:          snap.Cache,
		Net:            snap.Net,
		Log:            snap.Log,
		Accounts:       accounts,
	}, nil
}

// SyncRefreshRequest is the payload accepted by "sync.refresh". Path
// may be empty to refresh the item root.
type SyncRefreshRequest struct {
	Alias       string `json:"alias"`
	WorkspaceID string `json:"workspaceId"`
	ItemID      string `json:"itemId"`
	Path        string `json:"path"`
}

// SyncRefreshResponse mirrors [sync.Diff] for the wire.
type SyncRefreshResponse struct {
	Added   int `json:"added"`
	Updated int `json:"updated"`
	Removed int `json:"removed"`
}

func (h *Handlers) handleSyncRefresh(ctx context.Context, params json.RawMessage) (any, error) {
	var req SyncRefreshRequest
	if len(params) > 0 {
		if err := json.Unmarshal(params, &req); err != nil {
			return nil, fmt.Errorf("decode params: %w", err)
		}
	}
	if req.Alias == "" || req.WorkspaceID == "" || req.ItemID == "" {
		return nil, errors.New("alias, workspaceId and itemId are required")
	}
	if h.engine == nil {
		return nil, ErrEngineNotWired
	}
	diff, err := h.engine.RefreshFolder(ctx, cache.Key{
		AccountAlias: req.Alias,
		WorkspaceID:  req.WorkspaceID,
		ItemID:       req.ItemID,
		Path:         req.Path,
	})
	if err != nil {
		return nil, err
	}
	return SyncRefreshResponse{
		Added:   diff.Added,
		Updated: diff.Updated,
		Removed: diff.Removed,
	}, nil
}

// PollChangesRequest is the payload accepted by "sync.pollChanges".
// Anchor is the watermark returned by the previous call; pass the zero
// value on the first call to receive all events in the feed.
type PollChangesRequest struct {
	// Anchor is the opaque timestamp watermark from the previous call.
	// Zero time means "start from the beginning of the feed".
	Anchor time.Time `json:"anchor"`
}

func (h *Handlers) handleSyncPollChanges(_ context.Context, params json.RawMessage) (any, error) {
	var req PollChangesRequest
	if len(params) > 0 {
		if err := json.Unmarshal(params, &req); err != nil {
			return nil, fmt.Errorf("decode params: %w", err)
		}
	}
	if h.feed == nil {
		// No feed wired (test path or early startup). Return an empty
		// result with the current time as the anchor so the caller
		// advances its watermark and does not spin.
		return PollChangesResult{
			Events:     []ChangeEvent{},
			Anchor:     time.Now().UTC(),
			FullResync: false,
		}, nil
	}
	res := h.feed.Since(req.Anchor)
	if res.Events == nil {
		res.Events = []ChangeEvent{}
	}
	return res, nil
}

// MountListResponse is the payload returned by "mount.list".
type MountListResponse struct {
	// Domains is the list of registered File Provider domains, derived
	// from the accounts in config.toml. Each account maps to one domain
	// with the mount path the macOS File Provider framework assigns under
	// ~/Library/CloudStorage/. The daemon cannot query NSFileProviderManager
	// from Go; the host app is the authoritative source for the actual domain
	// registration state. This list reflects config.toml, not live domain state.
	//
	// TODO(phase-2): replace with a real NSFileProviderDomain query once the
	// host app exposes domain registration state over IPC.
	Domains []MountDomain `json:"domains"`
}

// MountDomain describes one File Provider domain as the host app will
// register it. The fields mirror NSFileProviderDomain.
type MountDomain struct {
	Identifier  string `json:"identifier"`
	DisplayName string `json:"displayName"`
	// MountPath is the expected on-disk location under ~/Library/CloudStorage/.
	// It is constructed from the alias; the actual directory only appears once
	// the File Provider Extension registers and macOS creates it.
	MountPath string `json:"mountPath,omitempty"`
}

func (h *Handlers) handleMountList(_ context.Context, _ json.RawMessage) (any, error) {
	snap := h.store.Snapshot()
	domains := make([]MountDomain, 0, len(snap.Accounts))
	for alias := range snap.Accounts {
		domains = append(domains, MountDomain{
			Identifier:  alias,
			DisplayName: "OneLake — " + alias, // em-dash, matching Finder sidebar label
			MountPath:   "~/Library/CloudStorage/OneLake-" + alias,
		})
	}
	sortDomains(domains)
	return MountListResponse{Domains: domains}, nil
}

// --- small helpers kept private so they don't pollute the package API.
