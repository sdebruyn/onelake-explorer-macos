package daemon

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"path/filepath"
	"testing"

	"github.com/sdebruyn/onelake-explorer-macos/internal/auth"
	"github.com/sdebruyn/onelake-explorer-macos/internal/cache"
	"github.com/sdebruyn/onelake-explorer-macos/internal/config"
)

// newTestHandlers wires a Handlers instance over an in-memory keychain
// and a fresh on-disk cache rooted in t.TempDir(). It points HOME at the
// temp dir so config.Load reads and writes into a sandboxed location and
// the test never touches the user's real ~/Library.
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
	reg := auth.NewRegistry(store, kc)

	cacheRoot := filepath.Join(dir, "cache")
	c, err := cache.Open(cache.Options{Root: cacheRoot, MaxBlobBytes: 1024})
	if err != nil {
		t.Fatalf("cache.Open: %v", err)
	}
	t.Cleanup(func() { _ = c.Close() })

	return NewHandlers(store, reg, c)
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
	if got := string(out); contains(got, "should-not-appear") || contains(got, "install_id") {
		t.Errorf("config.snapshot leaked InstallID: %s", got)
	}
}

func TestHandleSyncRefreshStub(t *testing.T) {
	h := newTestHandlers(t)
	res, err := h.handleSyncRefresh(context.Background(), mustJSON(t, SyncRefreshRequest{Alias: "work"}))
	if err != nil {
		t.Fatalf("sync.refresh: %v", err)
	}
	r, ok := res.(SyncRefreshResponse)
	if !ok || !r.Queued {
		t.Fatalf("expected {queued:true}, got %+v", res)
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

func contains(haystack, needle string) bool {
	return indexOf(haystack, needle) >= 0
}
