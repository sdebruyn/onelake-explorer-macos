package daemon

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"path/filepath"
	"time"

	"github.com/sdebruyn/onelake-explorer-macos/internal/auth"
	"github.com/sdebruyn/onelake-explorer-macos/internal/buildinfo"
	"github.com/sdebruyn/onelake-explorer-macos/internal/cache"
	"github.com/sdebruyn/onelake-explorer-macos/internal/config"
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

// Handlers bundles the dependencies every IPC handler needs and exposes
// a Register method that binds all of OFE's methods on a [ipc.Server].
//
// Handlers is constructed by [Run] (or by tests via [NewHandlers]) and
// has no public mutator methods — its state is read-only after wiring.
type Handlers struct {
	store     *config.Store
	registry  *auth.Registry
	cache     *cache.Cache
	engine    syncRefresher
	startedAt time.Time
	version   string
}

// NewHandlers builds a Handlers wired to the given dependencies. All of
// store, registry and cache are required; engine may be nil for tests
// that don't exercise sync.refresh, in which case the method returns an
// error indicating the engine is not wired.
func NewHandlers(store *config.Store, registry *auth.Registry, cache *cache.Cache, engine syncRefresher) *Handlers {
	return &Handlers{
		store:     store,
		registry:  registry,
		cache:     cache,
		engine:    engine,
		startedAt: time.Now().UTC(),
		version:   buildinfo.Version,
	}
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
	srv.Register("mount.list", h.handleMountList)
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
}

func (h *Handlers) handleStatus(_ context.Context, _ json.RawMessage) (any, error) {
	snap := h.store.Snapshot()
	aliases := make([]string, 0, len(snap.Accounts))
	for alias := range snap.Accounts {
		aliases = append(aliases, alias)
	}
	sortStrings(aliases)

	cacheBytes := int64(-1)
	if du, err := h.cacheBlobSize(); err == nil {
		cacheBytes = du
	}

	return StatusResponse{
		DaemonVersion: h.version,
		StartedAt:     h.startedAt,
		Accounts:      aliases,
		CacheBytes:    cacheBytes,
		CacheMaxBytes: snap.Cache.MaxSizeBytes,
	}, nil
}

// cacheBlobSize walks the cache blob root and returns the total bytes
// occupied. We do this rather than maintaining a counter because the
// cache package owns its own eviction bookkeeping and we don't want to
// duplicate state.
//
// The walk is scoped to [cache.Cache.BlobRoot] — never the full
// [cache.Cache.Root] — so the SQLite metadata file and its WAL sidecars
// don't inflate the figure we compare against
// [config.CacheConfig.MaxSizeBytes], which counts blob bytes only.
func (h *Handlers) cacheBlobSize() (int64, error) {
	if h.cache == nil {
		return 0, fmt.Errorf("cache not initialised")
	}
	return walkBlobBytes(h.cache.BlobRoot())
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
// pseudonymisation off the wire.
type ConfigSnapshotResponse struct {
	Telemetry      bool                      `json:"telemetry"`
	DefaultAccount string                    `json:"defaultAccount"`
	Cache          config.CacheConfig        `json:"cache"`
	Net            config.NetConfig          `json:"net"`
	Log            config.LogConfig          `json:"log"`
	Accounts       map[string]config.Account `json:"accounts"`
}

func (h *Handlers) handleConfigSnapshot(_ context.Context, _ json.RawMessage) (any, error) {
	snap := h.store.Snapshot()
	return ConfigSnapshotResponse{
		Telemetry:      snap.Telemetry,
		DefaultAccount: snap.DefaultAccount,
		Cache:          snap.Cache,
		Net:            snap.Net,
		Log:            snap.Log,
		Accounts:       snap.Accounts,
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

// MountListResponse is the payload returned by "mount.list".
type MountListResponse struct {
	// Domains is the list of registered File Provider domains. Returned
	// empty until the File Provider Extension lands in Phase 1.
	Domains []MountDomain `json:"domains"`
}

// MountDomain describes one File Provider domain as the host app will
// register it. The fields mirror NSFileProviderDomain.
type MountDomain struct {
	Identifier  string `json:"identifier"`
	DisplayName string `json:"displayName"`
}

func (h *Handlers) handleMountList(_ context.Context, _ json.RawMessage) (any, error) {
	return MountListResponse{Domains: []MountDomain{}}, nil
}

// --- small helpers kept private so they don't pollute the package API.

// walkBlobBytes sums the sizes of every regular file under root using
// [filepath.WalkDir] (cheaper than [filepath.Walk] because it works on
// lazy [fs.DirEntry] values and avoids one stat per entry). Files that
// vanish mid-walk are skipped silently because the cache eviction logic
// can race with us.
func walkBlobBytes(root string) (int64, error) {
	var total int64
	err := filepath.WalkDir(root, func(_ string, d fs.DirEntry, err error) error {
		if err != nil {
			if errors.Is(err, fs.ErrNotExist) {
				return nil
			}
			return err
		}
		if d.IsDir() {
			return nil
		}
		info, infoErr := d.Info()
		if infoErr != nil {
			if errors.Is(infoErr, fs.ErrNotExist) {
				return nil
			}
			return infoErr
		}
		total += info.Size()
		return nil
	})
	if err != nil && errors.Is(err, fs.ErrNotExist) {
		return 0, nil
	}
	return total, err
}
