package daemon

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"path/filepath"
	"strings"
	"testing"

	"github.com/sdebruyn/onelake-explorer-macos/internal/auth"
	"github.com/sdebruyn/onelake-explorer-macos/internal/cache"
	"github.com/sdebruyn/onelake-explorer-macos/internal/config"
	"github.com/sdebruyn/onelake-explorer-macos/internal/httpgate"
	"github.com/sdebruyn/onelake-explorer-macos/internal/sync"
)

// stubEngine records the last RefreshFolder call and returns a canned
// diff/error. Implements syncRefresher.
type stubEngine struct {
	calls []cache.Key
	diff  sync.Diff
	err   error
}

func (s *stubEngine) RefreshFolder(_ context.Context, k cache.Key) (sync.Diff, error) {
	s.calls = append(s.calls, k)
	if s.err != nil {
		return sync.Diff{}, s.err
	}
	return s.diff, nil
}

// newTestHandlers wires a Handlers instance over an in-memory keychain
// and a fresh on-disk cache rooted in t.TempDir(). It points HOME at the
// temp dir so config.Load reads and writes into a sandboxed location and
// the test never touches the user's real ~/Library. The engine is left
// nil; tests that exercise sync.refresh set h.engine themselves.
func newTestHandlers(t *testing.T) *Handlers {
	t.Helper()

	dir := t.TempDir()
	t.Setenv("HOME", dir)

	store, err := config.Load()
	if err != nil {
		t.Fatalf("config.Load: %v", err)
	}
	if err := store.Save(); err != nil {
		t.Fatalf("config.Save: %v", err)
	}

	kc := auth.NewMemoryKeychain()
	reg := auth.NewRegistry(store, kc, auth.EntraClientID, nil)

	cacheRoot := filepath.Join(dir, "cache")
	c, err := cache.Open(cache.Options{Root: cacheRoot, MaxBlobBytes: 1024})
	if err != nil {
		t.Fatalf("cache.Open: %v", err)
	}
	t.Cleanup(func() { _ = c.Close() })

	return NewHandlers(store, reg, c, nil, nil)
}

func TestHandleStatus(t *testing.T) {
	h := newTestHandlers(t)
	got, err := h.handleStatus(context.Background(), nil)
	if err != nil {
		t.Fatalf("handleStatus: %v", err)
	}
	resp, ok := got.(StatusResponse)
	if !ok {
		t.Fatalf("type: got %T", got)
	}
	if resp.StartedAt.IsZero() {
		t.Errorf("StartedAt should be set")
	}
	if resp.CacheMaxBytes <= 0 {
		// We seeded MaxBlobBytes=1024 in the cache but the config's
		// MaxSizeBytes default is 10 GiB; ensure non-zero is returned.
		t.Errorf("CacheMaxBytes should be > 0, got %d", resp.CacheMaxBytes)
	}
	if resp.CacheBytes < 0 {
		t.Errorf("CacheBytes should be measured (>=0), got %d", resp.CacheBytes)
	}
}

// TestHandleStatusIncludesGates verifies the IPC status payload carries
// the per-host gate snapshots when the daemon is wired with a registry.
func TestHandleStatusIncludesGates(t *testing.T) {
	h := newTestHandlers(t)
	h.gates = httpgate.DefaultRegistry()

	got, err := h.handleStatus(context.Background(), nil)
	if err != nil {
		t.Fatalf("handleStatus: %v", err)
	}
	resp := got.(StatusResponse)
	if len(resp.Gates) != 2 {
		t.Fatalf("Gates = %d entries, want 2", len(resp.Gates))
	}
	hosts := map[string]bool{}
	for _, g := range resp.Gates {
		hosts[g.Host] = true
	}
	for _, want := range []string{httpgate.HostFabric, httpgate.HostOneLake} {
		if !hosts[want] {
			t.Errorf("missing host %q in gates output", want)
		}
	}
}

// TestHandleStatusEmptyGatesWhenUnwired confirms the no-registry path
// returns an empty Gates list (not nil-vs-empty panic, etc).
func TestHandleStatusEmptyGatesWhenUnwired(t *testing.T) {
	h := newTestHandlers(t)
	got, err := h.handleStatus(context.Background(), nil)
	if err != nil {
		t.Fatalf("handleStatus: %v", err)
	}
	resp := got.(StatusResponse)
	if len(resp.Gates) != 0 {
		t.Errorf("Gates = %d, want 0 (no registry wired)", len(resp.Gates))
	}
}

func TestHandleAccountListEmpty(t *testing.T) {
	h := newTestHandlers(t)
	got, err := h.handleAccountList(context.Background(), nil)
	if err != nil {
		t.Fatalf("handleAccountList: %v", err)
	}
	resp, ok := got.(AccountListResponse)
	if !ok {
		t.Fatalf("type: got %T", got)
	}
	if len(resp.Accounts) != 0 {
		t.Errorf("expected zero accounts, got %d", len(resp.Accounts))
	}
}

func TestHandleAccountAddAndList(t *testing.T) {
	h := newTestHandlers(t)
	secret := []byte("opaque-msal-cache")
	params, _ := json.Marshal(AccountAddRequest{
		Alias:     "work",
		SecretB64: base64.StdEncoding.EncodeToString(secret),
		Account: AccountPayload{
			Alias:         "work",
			HomeAccountID: "oid.tid",
			Username:      "sam@contoso.com",
			TenantID:      "11111111-1111-1111-1111-111111111111",
			TenantName:    "Contoso",
		},
	})
	res, err := h.handleAccountAdd(context.Background(), params)
	if err != nil {
		t.Fatalf("handleAccountAdd: %v", err)
	}
	addResp, ok := res.(AccountAddResponse)
	if !ok || addResp.Alias != "work" {
		t.Fatalf("add response: %+v", res)
	}

	listed, err := h.handleAccountList(context.Background(), nil)
	if err != nil {
		t.Fatalf("list: %v", err)
	}
	lr := listed.(AccountListResponse)
	if len(lr.Accounts) != 1 || lr.Accounts[0].Alias != "work" {
		t.Fatalf("unexpected list: %+v", lr)
	}
	if lr.Accounts[0].Username != "sam@contoso.com" {
		t.Errorf("username not propagated: %+v", lr.Accounts[0])
	}
}

func TestHandleAccountRemove(t *testing.T) {
	h := newTestHandlers(t)
	if _, err := h.handleAccountAdd(context.Background(), mustJSON(t, AccountAddRequest{
		Alias:     "work",
		SecretB64: base64.StdEncoding.EncodeToString([]byte("x")),
		Account:   AccountPayload{Alias: "work", HomeAccountID: "h", Username: "u", TenantID: "t"},
	})); err != nil {
		t.Fatalf("add: %v", err)
	}
	if _, err := h.handleAccountRemove(context.Background(), mustJSON(t, AccountRemoveRequest{Alias: "work"})); err != nil {
		t.Fatalf("remove: %v", err)
	}
	res, err := h.handleAccountList(context.Background(), nil)
	if err != nil {
		t.Fatalf("list: %v", err)
	}
	if got := res.(AccountListResponse).Accounts; len(got) != 0 {
		t.Errorf("expected empty after remove, got %+v", got)
	}
}

func TestHandleAccountRemoveMissingAliasErrors(t *testing.T) {
	h := newTestHandlers(t)
	_, err := h.handleAccountRemove(context.Background(), mustJSON(t, AccountRemoveRequest{}))
	if err == nil {
		t.Fatalf("expected error for empty alias")
	}
}

func TestHandleConfigSnapshotOmitsInstallID(t *testing.T) {
	h := newTestHandlers(t)
	// Set an install ID via the store so we know it's set.
	h.store.Update(func(f *config.File) { f.InstallID = "should-not-appear" })
	res, err := h.handleConfigSnapshot(context.Background(), nil)
	if err != nil {
		t.Fatalf("snapshot: %v", err)
	}
	out, _ := json.Marshal(res)
	if got := string(out); strings.Contains(got, "should-not-appear") || strings.Contains(got, "install_id") {
		t.Errorf("config.snapshot leaked InstallID: %s", got)
	}
}

func TestHandleSyncRefreshReturnsDiff(t *testing.T) {
	h := newTestHandlers(t)
	stub := &stubEngine{diff: sync.Diff{Added: 2, Updated: 1, Removed: 3}}
	h.engine = stub

	res, err := h.handleSyncRefresh(context.Background(), mustJSON(t, SyncRefreshRequest{
		Alias:       "work",
		WorkspaceID: "11111111-1111-1111-1111-111111111111",
		ItemID:      "22222222-2222-2222-2222-222222222222",
		Path:        "Files",
	}))
	if err != nil {
		t.Fatalf("sync.refresh: %v", err)
	}
	r, ok := res.(SyncRefreshResponse)
	if !ok {
		t.Fatalf("type: got %T", res)
	}
	if r.Added != 2 || r.Updated != 1 || r.Removed != 3 {
		t.Errorf("diff = %+v, want {2 1 3}", r)
	}
	if len(stub.calls) != 1 {
		t.Fatalf("RefreshFolder calls = %d, want 1", len(stub.calls))
	}
	if stub.calls[0].AccountAlias != "work" || stub.calls[0].Path != "Files" {
		t.Errorf("RefreshFolder called with %+v", stub.calls[0])
	}
}

func TestHandleSyncRefreshMissingFieldsErrors(t *testing.T) {
	h := newTestHandlers(t)
	h.engine = &stubEngine{}

	cases := []SyncRefreshRequest{
		{WorkspaceID: "w", ItemID: "i"},
		{Alias: "a", ItemID: "i"},
		{Alias: "a", WorkspaceID: "w"},
		{},
	}
	for _, req := range cases {
		_, err := h.handleSyncRefresh(context.Background(), mustJSON(t, req))
		if err == nil {
			t.Errorf("expected error for %+v", req)
		}
	}
}

func TestHandleSyncRefreshEngineErrorPropagates(t *testing.T) {
	h := newTestHandlers(t)
	want := errors.New("boom")
	h.engine = &stubEngine{err: want}

	_, err := h.handleSyncRefresh(context.Background(), mustJSON(t, SyncRefreshRequest{
		Alias: "work", WorkspaceID: "w", ItemID: "i",
	}))
	if !errors.Is(err, want) {
		t.Fatalf("err = %v, want %v", err, want)
	}
}

func TestHandleSyncRefreshNilEngineErrors(t *testing.T) {
	h := newTestHandlers(t)
	// h.engine deliberately nil.

	_, err := h.handleSyncRefresh(context.Background(), mustJSON(t, SyncRefreshRequest{
		Alias: "work", WorkspaceID: "w", ItemID: "i",
	}))
	if !errors.Is(err, ErrEngineNotWired) {
		t.Fatalf("err = %v, want ErrEngineNotWired", err)
	}
}

func TestHandleMountListStub(t *testing.T) {
	h := newTestHandlers(t)
	res, err := h.handleMountList(context.Background(), nil)
	if err != nil {
		t.Fatalf("mount.list: %v", err)
	}
	r := res.(MountListResponse)
	if r.Domains == nil {
		t.Errorf("Domains should be non-nil empty slice for stable JSON, got nil")
	}
	if len(r.Domains) != 0 {
		t.Errorf("expected empty domains, got %+v", r.Domains)
	}
}

func mustJSON(t *testing.T, v any) json.RawMessage {
	t.Helper()
	b, err := json.Marshal(v)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	return b
}
