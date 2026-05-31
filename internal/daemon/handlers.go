package daemon

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
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

// ErrEngineNotWired is returned by the fp.* handlers when the daemon
// was constructed without a sync engine (for example in unit tests).
// Callers can use [errors.Is] to detect it rather than string-matching
// the formatted error.
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
	store    *config.Store
	registry *auth.Registry
	// kc is the keychain used by the registry. Needed by auth.login to
	// pass the same keychain instance to LoginInteractive without
	// opening a second file-backed store.
	kc        auth.Keychain
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
// store, registry and cache are required; kc may be nil for tests that
// don't exercise auth.login (the handler returns an error when kc is nil).
// engine may be nil for tests that don't exercise the fp.* handlers;
// gates may be nil for tests (status returns an empty Gates list); feed
// may be nil for tests (sync.pollChanges returns an empty result).
func NewHandlers(store *config.Store, registry *auth.Registry, kc auth.Keychain, cache *cache.Cache, engine syncRefresher, gates *httpgate.Registry, feed *Changefeed) *Handlers {
	off, _ := engine.(offlineReporter)
	h := &Handlers{
		store:     store,
		registry:  registry,
		kc:        kc,
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
	srv.Register("account.remove", h.handleAccountRemove)
	srv.Register("account.setDefault", h.handleAccountSetDefault)
	srv.Register("config.snapshot", h.handleConfigSnapshot)
	srv.Register("config.set", h.handleConfigSet)
	srv.Register("cache.evict", h.handleCacheEvict)
	srv.Register("cache.clear", h.handleCacheClear)
	srv.Register("auth.login", h.handleAuthLogin)
	srv.Register("sync.pollChanges", h.handleSyncPollChanges)

	// File Provider Extension surface (replaces the cgo bridge).
	srv.Register("fp.enumerate", h.handleFPEnumerate)
	srv.Register("fp.item", h.handleFPItem)
	srv.Register("fp.fetchContents", h.handleFPFetchContents)
	srv.Register("fp.createItem", h.handleFPCreateItem)
	srv.Register("fp.modifyItem", h.handleFPModifyItem)
	srv.Register("fp.deleteItem", h.handleFPDeleteItem)
}

// StatusPaths contains the canonical on-disk locations the menu-bar app
// can surface to the user via "Reveal in Finder" actions.
type StatusPaths struct {
	LogDir string `json:"logDir"`
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
	// Paths contains the canonical file-system locations the menu-bar
	// app can expose via "Reveal in Finder" actions.
	Paths StatusPaths `json:"paths"`
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

	p := h.store.Paths()
	return StatusResponse{
		DaemonVersion: h.version,
		StartedAt:     h.startedAt,
		Accounts:      aliases,
		CacheBytes:    cacheBytes,
		// CacheMaxBytes is the byte-precision conversion of the user's
		// GB-precision limit (see config.CacheConfig.MaxBytes). The Swift
		// menubar formats this against the live cacheBytes to render the
		// "X used of Y GB" label.
		CacheMaxBytes:    snap.Cache.MaxBytes(),
		Gates:            gates,
		PausedWorkspaces: paused,
		Offline:          offline,
		Paths: StatusPaths{
			LogDir: p.LogDir,
		},
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

// AccountSetDefaultRequest is the payload accepted by "account.setDefault".
type AccountSetDefaultRequest struct {
	Alias string `json:"alias"`
}

// AccountSetDefaultResponse is the payload returned by "account.setDefault".
type AccountSetDefaultResponse struct {
	DefaultAccount string `json:"defaultAccount"`
}

func (h *Handlers) handleAccountSetDefault(_ context.Context, params json.RawMessage) (any, error) {
	var req AccountSetDefaultRequest
	if err := json.Unmarshal(params, &req); err != nil {
		return nil, fmt.Errorf("decode params: %w", err)
	}
	if req.Alias == "" {
		return nil, fmt.Errorf("alias is required")
	}
	if err := h.registry.SetDefault(req.Alias); err != nil {
		return nil, err
	}
	return AccountSetDefaultResponse{DefaultAccount: req.Alias}, nil
}

// CacheEvictRequest is the (empty) payload accepted by "cache.evict".
type CacheEvictRequest struct{}

// CacheEvictResponse is the payload returned by "cache.evict".
type CacheEvictResponse struct {
	// CacheBytes is the deduped blob byte total AFTER eviction.
	CacheBytes int64 `json:"cacheBytes"`
}

func (h *Handlers) handleCacheEvict(ctx context.Context, _ json.RawMessage) (any, error) {
	if h.cache == nil {
		return nil, fmt.Errorf("cache not initialised")
	}
	if _, _, err := h.cache.EvictToLimit(ctx); err != nil {
		return nil, fmt.Errorf("evict: %w", err)
	}
	remaining, err := h.cache.BlobBytes(ctx)
	if err != nil {
		return nil, fmt.Errorf("measure cache: %w", err)
	}
	slog.Info("cache.evict via IPC", slog.Int64("bytes_after", remaining))
	return CacheEvictResponse{CacheBytes: remaining}, nil
}

// CacheClearRequest is the (empty) payload accepted by "cache.clear".
type CacheClearRequest struct{}

// CacheClearResponse is the payload returned by "cache.clear".
// CacheBytes will be 0 after a successful clear.
type CacheClearResponse struct {
	CacheBytes int64 `json:"cacheBytes"`
}

func (h *Handlers) handleCacheClear(ctx context.Context, _ json.RawMessage) (any, error) {
	if h.cache == nil {
		return nil, fmt.Errorf("cache not initialised")
	}
	if _, _, err := h.cache.Wipe(ctx); err != nil {
		return nil, fmt.Errorf("clear cache: %w", err)
	}
	slog.Info("cache.clear via IPC")
	return CacheClearResponse{CacheBytes: 0}, nil
}

// ConfigSetRequest is the payload accepted by "config.set".
type ConfigSetRequest struct {
	Key   string `json:"key"`
	Value string `json:"value"`
}

// ConfigSetResponse echoes back the normalised key and value that was persisted.
type ConfigSetResponse struct {
	Key   string `json:"key"`
	Value string `json:"value"`
}

func (h *Handlers) handleConfigSet(_ context.Context, params json.RawMessage) (any, error) {
	var req ConfigSetRequest
	if err := json.Unmarshal(params, &req); err != nil {
		return nil, fmt.Errorf("decode params: %w", err)
	}
	if req.Key == "" {
		return nil, fmt.Errorf("key is required")
	}
	var applyErr error
	saveErr := h.store.UpdateAndSave(func(f *config.File) {
		applyErr = config.ApplyConfig(f, req.Key, req.Value)
	})
	if applyErr != nil {
		return nil, applyErr
	}
	if saveErr != nil {
		return nil, fmt.Errorf("save config: %w", saveErr)
	}
	return ConfigSetResponse{
		Key:   config.NormalizeConfigKey(req.Key),
		Value: req.Value,
	}, nil
}

// AuthLoginRequest is the payload accepted by "auth.login".
type AuthLoginRequest struct {
	// Alias is the user-chosen short name for the new account (required).
	Alias string `json:"alias"`
	// Tenant is an optional tenant GUID or domain hint. When empty, MSAL
	// picks the tenant from the user's home directory at sign-in time.
	Tenant string `json:"tenant,omitempty"`
	// ClientID is an optional override for the Entra App Registration
	// client ID. When empty (the common case), the built-in OFEM
	// registration ([auth.EntraClientID]) is used. Non-empty: caller
	// brings their own registration — see docs/custom-app-registration.md.
	ClientID string `json:"clientId,omitempty"`
}

// AuthLoginResponse is the payload returned by "auth.login".
type AuthLoginResponse struct {
	Alias      string `json:"alias"`
	Username   string `json:"username"`
	TenantID   string `json:"tenantId"`
	TenantName string `json:"tenantName,omitempty"`
}

// handleAuthLogin runs the MSAL interactive-browser login flow
// in-process and persists the account via the registry.
//
// This handler is long-running (the user interacts with a browser).
// Context cancellation is forwarded all the way into the MSAL library
// so the server can abort a pending login (e.g. on daemon shutdown).
// Note: the IPC server dispatches requests sequentially per connection,
// so a client that sends auth.login must wait for it to return before
// sending further requests on the same connection; other connections
// (e.g. a "status" call from a second client) proceed concurrently.
//
// NOTE for packaging: the interactive (loopback redirect) flow binds a
// temporary localhost HTTP server. The daemon binary therefore needs the
// com.apple.security.network.server entitlement — handled in the sibling
// Swift/signing PR, not here.
func (h *Handlers) handleAuthLogin(ctx context.Context, params json.RawMessage) (any, error) {
	var req AuthLoginRequest
	if err := json.Unmarshal(params, &req); err != nil {
		return nil, fmt.Errorf("decode params: %w", err)
	}
	if req.Alias == "" {
		return nil, fmt.Errorf("alias is required")
	}
	if err := auth.ValidateAlias(req.Alias); err != nil {
		return nil, err
	}
	if h.kc == nil {
		return nil, fmt.Errorf("keychain not wired (daemon built without full engine)")
	}

	var (
		account    auth.Account
		cacheBytes []byte
		err        error
	)
	// Resolve which Entra App Registration to authenticate against: the
	// caller's override if supplied (Bring Your Own App Registration —
	// see docs/custom-app-registration.md), otherwise the built-in
	// multi-tenant OFEM registration.
	clientID := req.ClientID
	if clientID == "" {
		clientID = auth.EntraClientID
	}
	account, _, cacheBytes, err = auth.LoginInteractive(ctx, clientID, req.Tenant, h.kc)
	if err != nil {
		return nil, fmt.Errorf("sign in: %w", err)
	}

	account.Alias = req.Alias
	// Persist the caller's client-ID override so silent refresh on a
	// later daemon start reaches for the same App Registration. Empty
	// stays empty — the registry falls back to the built-in OFEM
	// client ID transparently.
	account.ClientID = req.ClientID
	if err := h.registry.Add(account, cacheBytes); err != nil {
		return nil, fmt.Errorf("register account: %w", err)
	}

	return AuthLoginResponse{
		Alias:      account.Alias,
		Username:   account.Username,
		TenantID:   account.TenantID,
		TenantName: account.TenantName,
	}, nil
}

// --- small helpers kept private so they don't pollute the package API.
