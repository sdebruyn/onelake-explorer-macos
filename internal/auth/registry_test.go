package auth

import (
	"bytes"
	"context"
	"errors"
	"os"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/AzureAD/microsoft-authentication-library-for-go/apps/public"

	"github.com/sdebruyn/onelake-explorer-macos/internal/config"
)

// newTestStore returns a fresh, empty config.Store rooted at a temp HOME
// so that each test gets its own isolated config file.
func newTestStore(t *testing.T) *config.Store {
	t.Helper()
	t.Setenv("HOME", t.TempDir())
	store, err := config.Load()
	if err != nil {
		t.Fatalf("config.Load: %v", err)
	}
	return store
}

func sampleAccount(alias string) Account {
	return Account{
		Alias:         alias,
		HomeAccountID: "object-id." + alias,
		Username:      alias + "@example.com",
		TenantID:      "11111111-2222-3333-4444-555555555555",
		TenantName:    "Example Org",
		AddedAt:       time.Date(2026, 5, 23, 12, 0, 0, 0, time.UTC),
	}
}

func TestRegistryLifecycle(t *testing.T) {
	store := newTestStore(t)
	kc := NewMemoryKeychain()
	reg := NewRegistry(store, kc, EntraClientID, nil)

	// Initially empty.
	if got := reg.List(); len(got) != 0 {
		t.Fatalf("List on empty registry = %v, want empty", got)
	}
	if alias, ok := reg.Default(); ok || alias != "" {
		t.Fatalf("Default on empty = (%q, %v), want (\"\", false)", alias, ok)
	}

	// Add two accounts in non-alpha order.
	work := sampleAccount("work")
	client := sampleAccount("client-a")
	if err := reg.Add(work, []byte("work-secret")); err != nil {
		t.Fatalf("Add work: %v", err)
	}
	if err := reg.Add(client, []byte("client-secret")); err != nil {
		t.Fatalf("Add client-a: %v", err)
	}

	// List is alphabetically sorted.
	list := reg.List()
	if len(list) != 2 {
		t.Fatalf("List len = %d, want 2", len(list))
	}
	if list[0].Alias != "client-a" || list[1].Alias != "work" {
		t.Errorf("List order = [%q, %q], want [client-a, work]", list[0].Alias, list[1].Alias)
	}

	// Get round-trips the account and its secret.
	gotAcc, gotSecret, err := reg.Get("work")
	if err != nil {
		t.Fatalf("Get work: %v", err)
	}
	if gotAcc.Username != work.Username || gotAcc.TenantID != work.TenantID {
		t.Errorf("Get work account = %+v, want %+v", gotAcc, work)
	}
	if !gotAcc.AddedAt.Equal(work.AddedAt) {
		t.Errorf("AddedAt = %v, want %v", gotAcc.AddedAt, work.AddedAt)
	}
	if !bytes.Equal(gotSecret, []byte("work-secret")) {
		t.Errorf("Get work secret = %q, want %q", gotSecret, "work-secret")
	}

	// SetDefault + Default.
	if err := reg.SetDefault("work"); err != nil {
		t.Fatalf("SetDefault: %v", err)
	}
	if alias, ok := reg.Default(); !ok || alias != "work" {
		t.Errorf("Default = (%q, %v), want (work, true)", alias, ok)
	}

	// SetDefault on unknown alias is rejected.
	err = reg.SetDefault("nope")
	if !errors.Is(err, os.ErrNotExist) {
		t.Errorf("SetDefault unknown err = %v, want errors.Is os.ErrNotExist", err)
	}

	// Removing the default clears it.
	if err := reg.Remove("work"); err != nil {
		t.Fatalf("Remove work: %v", err)
	}
	if alias, ok := reg.Default(); ok {
		t.Errorf("Default after removing default = (%q, %v), want (\"\", false)", alias, ok)
	}
	if _, err := kc.Get("work"); !errors.Is(err, os.ErrNotExist) {
		t.Errorf("keychain still has entry after Remove: %v", err)
	}

	// Remove the remaining account, list is empty again.
	if err := reg.Remove("client-a"); err != nil {
		t.Fatalf("Remove client-a: %v", err)
	}
	if got := reg.List(); len(got) != 0 {
		t.Errorf("List after all removes = %v, want empty", got)
	}
}

func TestRegistryAddRejectsDuplicate(t *testing.T) {
	reg := NewRegistry(newTestStore(t), NewMemoryKeychain(), EntraClientID, nil)

	if err := reg.Add(sampleAccount("work"), []byte("s")); err != nil {
		t.Fatalf("Add first: %v", err)
	}
	err := reg.Add(sampleAccount("work"), []byte("s"))
	if err == nil {
		t.Fatal("Add duplicate alias accepted, want error")
	}
}

func TestRegistryAddValidatesAlias(t *testing.T) {
	reg := NewRegistry(newTestStore(t), NewMemoryKeychain(), EntraClientID, nil)

	err := reg.Add(sampleAccount("not valid"), []byte("s"))
	if err == nil {
		t.Fatal("Add with invalid alias accepted, want error")
	}
}

func TestRegistryGetUnknownIsNotExist(t *testing.T) {
	reg := NewRegistry(newTestStore(t), NewMemoryKeychain(), EntraClientID, nil)

	_, _, err := reg.Get("ghost")
	if !errors.Is(err, os.ErrNotExist) {
		t.Errorf("Get unknown err = %v, want errors.Is os.ErrNotExist", err)
	}
}

func TestRegistryRemoveUnknownIsNotExist(t *testing.T) {
	reg := NewRegistry(newTestStore(t), NewMemoryKeychain(), EntraClientID, nil)

	err := reg.Remove("ghost")
	if !errors.Is(err, os.ErrNotExist) {
		t.Errorf("Remove unknown err = %v, want errors.Is os.ErrNotExist", err)
	}
}

func TestRegistryGetToleratesMissingSecret(t *testing.T) {
	store := newTestStore(t)
	kc := NewMemoryKeychain()
	reg := NewRegistry(store, kc, EntraClientID, nil)

	if err := reg.Add(sampleAccount("work"), []byte("secret")); err != nil {
		t.Fatalf("Add: %v", err)
	}
	// Simulate someone deleting the keychain entry behind our back.
	if err := kc.Delete("work"); err != nil {
		t.Fatalf("kc.Delete: %v", err)
	}

	acc, secret, err := reg.Get("work")
	if err != nil {
		t.Fatalf("Get after kc delete: %v", err)
	}
	if acc.Alias != "work" {
		t.Errorf("acc.Alias = %q, want work", acc.Alias)
	}
	if secret != nil {
		t.Errorf("secret = %q, want nil", secret)
	}
}

func TestRegistryTokenSilentSuccess(t *testing.T) {
	store := newTestStore(t)
	stub := &stubMSALClient{
		silentResult: public.AuthResult{AccessToken: "tok-xyz"},
		accounts:     []public.Account{{HomeAccountID: "object-id.work"}},
	}
	factory := func(clientID, tenantID string, kc Keychain, alias string) (MSALClient, error) {
		if clientID != EntraClientID {
			t.Errorf("clientID = %q, want %q", clientID, EntraClientID)
		}
		if tenantID == "" {
			t.Errorf("empty tenantID passed to factory")
		}
		if alias != "work" {
			t.Errorf("alias = %q, want work", alias)
		}
		if kc == nil {
			t.Errorf("nil keychain passed to factory")
		}
		return stub, nil
	}
	reg := NewRegistry(store, NewMemoryKeychain(), EntraClientID, factory)
	if err := reg.Add(sampleAccount("work"), []byte("cache")); err != nil {
		t.Fatalf("Add: %v", err)
	}

	token, err := reg.Token(context.Background(), "work")
	if err != nil {
		t.Fatalf("Token: %v", err)
	}
	if token != "tok-xyz" {
		t.Errorf("token = %q, want tok-xyz", token)
	}
	if stub.silentCalls != 1 {
		t.Errorf("silentCalls = %d, want 1", stub.silentCalls)
	}

	// Second call must reuse the cached client (factory called once).
	calls := 0
	countingFactory := func(string, string, Keychain, string) (MSALClient, error) {
		calls++
		return stub, nil
	}
	reg2 := NewRegistry(store, NewMemoryKeychain(), EntraClientID, countingFactory)
	if _, err := reg2.Token(context.Background(), "work"); err != nil {
		t.Fatalf("Token first: %v", err)
	}
	if _, err := reg2.Token(context.Background(), "work"); err != nil {
		t.Fatalf("Token second: %v", err)
	}
	if calls != 1 {
		t.Errorf("factory called %d times, want 1 (client should be cached)", calls)
	}
}

func TestRegistryTokenUnknownAlias(t *testing.T) {
	reg := NewRegistry(newTestStore(t), NewMemoryKeychain(), EntraClientID, func(string, string, Keychain, string) (MSALClient, error) {
		return &stubMSALClient{}, nil
	})
	_, err := reg.Token(context.Background(), "ghost")
	if !errors.Is(err, os.ErrNotExist) {
		t.Errorf("err = %v, want errors.Is os.ErrNotExist", err)
	}
}

func TestRegistryTokenInteractionRequiredFromMSAL(t *testing.T) {
	store := newTestStore(t)
	stub := &stubMSALClient{
		accounts:  []public.Account{{HomeAccountID: "object-id.work"}},
		silentErr: errors.New("interaction_required: AADSTS50076 MFA"),
	}
	reg := NewRegistry(store, NewMemoryKeychain(), EntraClientID, func(string, string, Keychain, string) (MSALClient, error) {
		return stub, nil
	})
	if err := reg.Add(sampleAccount("work"), []byte("cache")); err != nil {
		t.Fatalf("Add: %v", err)
	}
	_, err := reg.Token(context.Background(), "work")
	if !errors.Is(err, ErrInteractionRequired) {
		t.Errorf("err = %v, want errors.Is ErrInteractionRequired", err)
	}
}

func TestRegistryTokenInteractionRequiredWhenNoMSALAccount(t *testing.T) {
	store := newTestStore(t)
	stub := &stubMSALClient{accounts: nil}
	reg := NewRegistry(store, NewMemoryKeychain(), EntraClientID, func(string, string, Keychain, string) (MSALClient, error) {
		return stub, nil
	})
	if err := reg.Add(sampleAccount("work"), []byte("cache")); err != nil {
		t.Fatalf("Add: %v", err)
	}
	_, err := reg.Token(context.Background(), "work")
	if !errors.Is(err, ErrInteractionRequired) {
		t.Errorf("err = %v, want errors.Is ErrInteractionRequired", err)
	}
}

func TestRegistryTenantID(t *testing.T) {
	store := newTestStore(t)
	reg := NewRegistry(store, NewMemoryKeychain(), EntraClientID, nil)

	// Unknown alias: ok=false, empty string.
	if tid, ok := reg.TenantID("nope"); ok || tid != "" {
		t.Errorf("TenantID(nope) = (%q, %v), want (\"\", false)", tid, ok)
	}

	if err := reg.Add(sampleAccount("work"), []byte("x")); err != nil {
		t.Fatalf("Add: %v", err)
	}
	tid, ok := reg.TenantID("work")
	if !ok {
		t.Fatalf("TenantID(work) ok=false, want true")
	}
	if tid != sampleAccount("work").TenantID {
		t.Errorf("TenantID(work) = %q, want %q", tid, sampleAccount("work").TenantID)
	}
}

func TestRegistryPersistsAcrossReload(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	store, err := config.Load()
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	reg := NewRegistry(store, NewMemoryKeychain(), EntraClientID, nil)
	if err := reg.Add(sampleAccount("work"), []byte("secret")); err != nil {
		t.Fatalf("Add: %v", err)
	}
	if err := reg.SetDefault("work"); err != nil {
		t.Fatalf("SetDefault: %v", err)
	}

	// Re-Load from the same HOME to make sure config was persisted.
	store2, err := config.Load()
	if err != nil {
		t.Fatalf("re-Load: %v", err)
	}
	snap := store2.Snapshot()
	if _, ok := snap.Accounts["work"]; !ok {
		t.Errorf("account not persisted: %+v", snap.Accounts)
	}
	if snap.DefaultAccount != "work" {
		t.Errorf("DefaultAccount = %q, want work", snap.DefaultAccount)
	}
}

// newTestRegistry is a helper that adds a "work" account and returns a
// Registry wired with a stubMSALClient that the caller can inspect.
func newTestRegistry(t *testing.T) (*Registry, *stubMSALClient) {
	t.Helper()
	store := newTestStore(t)
	stub := &stubMSALClient{
		silentResult: public.AuthResult{AccessToken: "scoped-tok"},
		accounts:     []public.Account{{HomeAccountID: "object-id.work"}},
	}
	factory := func(string, string, Keychain, string) (MSALClient, error) {
		return stub, nil
	}
	reg := NewRegistry(store, NewMemoryKeychain(), EntraClientID, factory)
	if err := reg.Add(sampleAccount("work"), []byte("cache")); err != nil {
		t.Fatalf("Add: %v", err)
	}
	return reg, stub
}

// TestRegistryTokenForScopesPassesScopes is the direct regression test for
// the bug that caused Fabric REST calls to receive an OneLake-audience token:
// TokenForScopes must forward the caller-supplied scopes verbatim to
// AcquireTokenSilent, not substitute OneLakeScopes.
func TestRegistryTokenForScopesPassesScopes(t *testing.T) {
	reg, stub := newTestRegistry(t)

	tok, err := reg.TokenForScopes(context.Background(), "work", FabricScopes)
	if err != nil {
		t.Fatalf("TokenForScopes: %v", err)
	}
	if tok != "scoped-tok" {
		t.Errorf("token = %q, want scoped-tok", tok)
	}

	// The stub must have received FabricScopes, not OneLakeScopes.
	if len(stub.lastScopes) != len(FabricScopes) {
		t.Fatalf("lastScopes len = %d, want %d", len(stub.lastScopes), len(FabricScopes))
	}
	for i, s := range FabricScopes {
		if stub.lastScopes[i] != s {
			t.Errorf("lastScopes[%d] = %q, want %q", i, stub.lastScopes[i], s)
		}
	}

	// Confirm Token() (the OneLake default path) passes OneLakeScopes.
	if _, err := reg.Token(context.Background(), "work"); err != nil {
		t.Fatalf("Token: %v", err)
	}
	if len(stub.lastScopes) != len(OneLakeScopes) || stub.lastScopes[0] != OneLakeScopes[0] {
		t.Errorf("Token() passed scopes %v, want OneLakeScopes %v", stub.lastScopes, OneLakeScopes)
	}
}

// TestScopedProviderUsesGivenScopes verifies that ScopedProvider(FabricScopes).Token
// takes the same code path as TokenForScopes(…, FabricScopes) and that the
// chosen scopes reach AcquireTokenSilent unchanged.
func TestScopedProviderUsesGivenScopes(t *testing.T) {
	reg, stub := newTestRegistry(t)

	provider := reg.ScopedProvider(FabricScopes)
	tok, err := provider.Token(context.Background(), "work")
	if err != nil {
		t.Fatalf("ScopedProvider.Token: %v", err)
	}
	if tok != "scoped-tok" {
		t.Errorf("token = %q, want scoped-tok", tok)
	}

	if len(stub.lastScopes) != len(FabricScopes) {
		t.Fatalf("lastScopes len = %d, want %d", len(stub.lastScopes), len(FabricScopes))
	}
	for i, s := range FabricScopes {
		if stub.lastScopes[i] != s {
			t.Errorf("lastScopes[%d] = %q, want %q", i, stub.lastScopes[i], s)
		}
	}
}

// TestFindMSALAccount_RejectsEmptyHomeAccountID covers H-1: an empty
// HomeAccountID must never match an MSAL cache entry (which could itself
// have an empty ID), or the registry would hand back a token for the wrong
// identity. Both an empty query and a real query against an empty-ID cache
// entry must fail closed with ErrInteractionRequired.
func TestFindMSALAccount_RejectsEmptyHomeAccountID(t *testing.T) {
	reg := NewRegistry(newTestStore(t), NewMemoryKeychain(), EntraClientID,
		func(string, string, Keychain, string) (MSALClient, error) {
			return &stubMSALClient{}, nil
		})
	stub := &stubMSALClient{accounts: []public.Account{{HomeAccountID: ""}}}

	if _, err := reg.findMSALAccount(context.Background(), stub, "work", ""); !errors.Is(err, ErrInteractionRequired) {
		t.Errorf("empty homeAccountID: err = %v, want ErrInteractionRequired", err)
	}
	if _, err := reg.findMSALAccount(context.Background(), stub, "work", "real-id"); !errors.Is(err, ErrInteractionRequired) {
		t.Errorf("real id vs empty-ID cache entry: err = %v, want ErrInteractionRequired", err)
	}
}

// TestRegistryAdd_ConcurrentSameAliasOneWinner covers M-2: writeMu must
// serialise Add so that N concurrent Add("work") calls produce exactly one
// winner (no clobbered keychain secret, no diverged config). Run under
// -race, it also asserts the shared store/keychain access is race-free.
func TestRegistryAdd_ConcurrentSameAliasOneWinner(t *testing.T) {
	store := newTestStore(t)
	reg := NewRegistry(store, NewMemoryKeychain(), EntraClientID,
		func(string, string, Keychain, string) (MSALClient, error) {
			return &stubMSALClient{}, nil
		})

	const n = 8
	var wg sync.WaitGroup
	var successes atomic.Int32
	for i := 0; i < n; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			if err := reg.Add(sampleAccount("work"), []byte("secret")); err == nil {
				successes.Add(1)
			}
		}()
	}
	wg.Wait()

	if got := successes.Load(); got != 1 {
		t.Errorf("concurrent Add of same alias: %d succeeded, want exactly 1", got)
	}
	if _, _, err := reg.Get("work"); err != nil {
		t.Errorf("account missing after concurrent Add: %v", err)
	}
}
