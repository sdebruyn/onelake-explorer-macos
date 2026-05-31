package auth

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"os"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/AzureAD/microsoft-authentication-library-for-go/apps/public"

	"github.com/sdebruyn/onelake-explorer-macos/internal/config"
)

// Registry holds the set of signed-in accounts. The list of accounts is
// persisted in the OFEM TOML config (via [config.Store]); the per-account
// opaque secret material is persisted in the [Keychain].
//
// Registry exposes the full Add/Remove/Get/List/Default/SetDefault
// lifecycle and implements [TokenProvider] via MSAL silent acquisition.
type Registry struct {
	store    *config.Store
	kc       Keychain
	clientID string
	factory  ClientFactory

	// writeMu serialises the multi-step account mutations (Add / Remove /
	// SetDefault). Each spans a duplicate check, a keychain write, and a
	// config write that are not individually atomic; without this lock two
	// concurrent Add("work") could both pass the existence check and the
	// second would clobber the first's keychain secret (M-2).
	writeMu sync.Mutex

	clientsMu sync.Mutex
	clients   map[string]MSALClient // keyed by tenantID|alias
}

// NewRegistry returns a Registry that reads and writes accounts to the
// given [config.Store] and per-account secrets to the given [Keychain].
// store and kc must be non-nil. clientID is the Microsoft Entra App
// Registration GUID; production callers pass [EntraClientID]. factory
// builds MSAL clients on demand; pass [DefaultClientFactory] in
// production code and a stub in tests.
//
// If factory is nil, [DefaultClientFactory] is used.
func NewRegistry(store *config.Store, kc Keychain, clientID string, factory ClientFactory) *Registry {
	if factory == nil {
		factory = DefaultClientFactory
	}
	return &Registry{
		store:    store,
		kc:       kc,
		clientID: clientID,
		factory:  factory,
		clients:  make(map[string]MSALClient),
	}
}

// Add persists account in the config and stores secret in the keychain,
// then saves the config to disk. The alias is validated; duplicate
// aliases are rejected. The keychain entry uses the alias as its
// account-name key.
//
// If persisting the config fails, Add removes the secret it just wrote
// to the keychain on a best-effort basis to keep the two sides in sync.
func (r *Registry) Add(account Account, secret []byte) error {
	if err := ValidateAlias(account.Alias); err != nil {
		return err
	}

	r.writeMu.Lock()
	defer r.writeMu.Unlock()

	snap := r.store.Snapshot()
	if _, exists := snap.Accounts[account.Alias]; exists {
		return fmt.Errorf("auth: account %q already exists", account.Alias)
	}

	if err := r.kc.Set(account.Alias, secret); err != nil {
		return fmt.Errorf("auth: store secret for %q: %w", account.Alias, err)
	}

	if err := r.store.UpdateAndSave(func(f *config.File) {
		if f.Accounts == nil {
			f.Accounts = map[string]config.Account{}
		}
		f.Accounts[account.Alias] = toConfigAccount(account)
	}); err != nil {
		// Roll back the keychain so we do not leak orphan secrets, then
		// revert the in-memory config and persist the reverted state so
		// disk and memory stay in sync. The rollback is best-effort: if it
		// also fails there is nothing more we can do from this layer, so we
		// log it and return the original error.
		_ = r.kc.Delete(account.Alias)
		if rerr := r.store.UpdateAndSave(func(f *config.File) {
			delete(f.Accounts, account.Alias)
		}); rerr != nil {
			slog.Warn("auth: rollback save after failed Add also failed; in-memory and disk state may diverge",
				"alias", account.Alias,
				"original_err", err,
				"rollback_err", rerr,
			)
		}
		return fmt.Errorf("auth: save config: %w", err)
	}
	return nil
}

// Remove deletes the account from the config and the keychain. If the
// removed account was the configured default it is also cleared.
// Removing a missing alias returns an error wrapping os.ErrNotExist.
func (r *Registry) Remove(alias string) error {
	r.writeMu.Lock()
	defer r.writeMu.Unlock()

	snap := r.store.Snapshot()
	if _, ok := snap.Accounts[alias]; !ok {
		return fmt.Errorf("auth: account %q: %w", alias, os.ErrNotExist)
	}

	if err := r.kc.Delete(alias); err != nil {
		return fmt.Errorf("auth: delete keychain entry for %q: %w", alias, err)
	}

	if err := r.store.UpdateAndSave(func(f *config.File) {
		delete(f.Accounts, alias)
		if f.DefaultAccount == alias {
			f.DefaultAccount = ""
		}
	}); err != nil {
		return fmt.Errorf("auth: save config: %w", err)
	}

	// Evict any cached MSAL client for this alias. Without this, a
	// Remove-then-Add lifecycle inside a single daemon process would
	// reuse the stale client — which still serves tokens for the OLD
	// tenant/identity (the cache key is tenantID|alias, so re-adding
	// against a different tenant misses while the OLD entry lingers,
	// and re-adding against the same tenant after a keychain wipe
	// hands back tokens MSAL would no longer issue). Iterating the
	// map (rather than computing one key) covers all (tenant, alias)
	// pairs ever cached for this alias — re-adds under a different
	// tenant must still drop the prior entry. Aliases never contain
	// '|' (see ValidateAlias), so a suffix match is unambiguous.
	// Lock order: writeMu (held) → clientsMu; no other site takes
	// them in the reverse order.
	r.clientsMu.Lock()
	suffix := "|" + alias
	for key := range r.clients {
		if strings.HasSuffix(key, suffix) {
			delete(r.clients, key)
		}
	}
	r.clientsMu.Unlock()
	return nil
}

// Get returns the account and its persisted secret. It returns an error
// wrapping os.ErrNotExist when the alias is unknown. If the account is
// in the config but the keychain has no entry for it (for example after
// a manual Keychain Access.app deletion), Get still returns the account
// with a nil secret and no error — the auth layer is expected to detect
// the missing cache and force re-auth.
func (r *Registry) Get(alias string) (Account, []byte, error) {
	snap := r.store.Snapshot()
	cfg, ok := snap.Accounts[alias]
	if !ok {
		return Account{}, nil, fmt.Errorf("auth: account %q: %w", alias, os.ErrNotExist)
	}

	secret, err := r.kc.Get(alias)
	if err != nil && !errors.Is(err, os.ErrNotExist) {
		return Account{}, nil, fmt.Errorf("auth: load secret for %q: %w", alias, err)
	}
	if errors.Is(err, os.ErrNotExist) {
		// The account is in the config but its keychain entry is gone.
		// This typically means a user deleted the item via
		// Keychain Access.app or a system reset wiped it. We tolerate
		// it and return a nil secret so the caller can force re-auth,
		// but log a warning so the situation is debuggable rather than
		// silent.
		slog.Warn("auth: account present in config but no secret in keychain; re-auth required",
			"alias", alias,
		)
	}

	return fromConfigAccount(cfg), secret, nil
}

// List returns all known accounts sorted by alias for deterministic
// output (helpful for tests and for the menu bar's accounts list).
func (r *Registry) List() []Account {
	snap := r.store.Snapshot()
	out := make([]Account, 0, len(snap.Accounts))
	for _, a := range snap.Accounts {
		out = append(out, fromConfigAccount(a))
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Alias < out[j].Alias })
	return out
}

// Default returns the alias of the configured default account. The
// second return value is false when no default is set.
func (r *Registry) Default() (string, bool) {
	snap := r.store.Snapshot()
	if snap.DefaultAccount == "" {
		return "", false
	}
	return snap.DefaultAccount, true
}

// TenantID returns the Entra tenant GUID for alias. The second return
// value is false when alias is unknown; in that case the returned string
// is empty. This is a cheap accessor that reads from the config snapshot
// only — it does NOT touch MSAL or the keychain — so callers may invoke
// it freely on hot paths (for example, telemetry tagging in the adaptive
// poller).
func (r *Registry) TenantID(alias string) (string, bool) {
	snap := r.store.Snapshot()
	cfg, ok := snap.Accounts[alias]
	if !ok {
		return "", false
	}
	return cfg.TenantID, true
}

// SetDefault sets the default account alias. It rejects unknown aliases
// with an error wrapping os.ErrNotExist.
func (r *Registry) SetDefault(alias string) error {
	r.writeMu.Lock()
	defer r.writeMu.Unlock()

	snap := r.store.Snapshot()
	if _, ok := snap.Accounts[alias]; !ok {
		return fmt.Errorf("auth: account %q: %w", alias, os.ErrNotExist)
	}
	if err := r.store.UpdateAndSave(func(f *config.File) {
		f.DefaultAccount = alias
	}); err != nil {
		return fmt.Errorf("auth: save config: %w", err)
	}
	return nil
}

// Token implements [TokenProvider]. It acquires an access token silently
// from MSAL for the named account, using the per-account Keychain-backed
// MSAL cache. If silent acquisition needs user interaction (for example
// after a Conditional Access challenge, an MFA re-prompt, or a refresh
// token that expired due to inactivity), Token returns an error wrapping
// [ErrInteractionRequired] so callers can surface a "click to
// re-authenticate" indicator rather than blocking.
//
// Unknown aliases return an error wrapping os.ErrNotExist.
func (r *Registry) Token(ctx context.Context, alias string) (string, error) {
	return r.TokenForScopes(ctx, alias, OneLakeScopes)
}

// TokenForScopes acquires an access token for the given audience scopes.
// OneLake DFS file I/O passes OneLakeScopes; Fabric REST discovery passes
// FabricScopes. MSAL serves both from one cached refresh token (consented
// at login via LoginScopes), so no extra interaction is needed per scope.
func (r *Registry) TokenForScopes(ctx context.Context, alias string, scopes []string) (string, error) {
	snap := r.store.Snapshot()
	cfg, ok := snap.Accounts[alias]
	if !ok {
		return "", fmt.Errorf("auth: account %q: %w", alias, os.ErrNotExist)
	}

	client, err := r.clientFor(alias, cfg.TenantID, cfg.ClientID)
	if err != nil {
		return "", err
	}

	msalAccount, err := r.findMSALAccount(ctx, client, alias, cfg.HomeAccountID)
	if err != nil {
		return "", fmt.Errorf("auth: locate MSAL account for %q: %w", alias, err)
	}

	return SilentToken(ctx, client, alias, msalAccount, scopes)
}

// ScopedProvider returns a TokenProvider that always requests the given
// audience scopes. Wire the Fabric client with ScopedProvider(FabricScopes)
// and the OneLake client with the registry directly (OneLakeScopes default)
// so each upstream gets a token its audience accepts.
func (r *Registry) ScopedProvider(scopes []string) TokenProvider {
	return scopedProvider{reg: r, scopes: scopes}
}

// scopedProvider adapts Registry.TokenForScopes to the TokenProvider
// interface for a fixed scope set.
type scopedProvider struct {
	reg    *Registry
	scopes []string
}

func (s scopedProvider) Token(ctx context.Context, alias string) (string, error) {
	return s.reg.TokenForScopes(ctx, alias, s.scopes)
}

// clientFor returns the cached MSAL client for the (alias, tenant)
// pair, building it lazily via the registry's factory on first use.
// accountClientID overrides the registry-wide default when non-empty
// — Bring Your Own App Registration setups persist a per-account
// client ID that MUST be used here, otherwise MSAL's cache lookup
// (keyed on client+tenant+account) misses and the user is forced to
// re-authenticate on every daemon start.
func (r *Registry) clientFor(alias, tenantID, accountClientID string) (MSALClient, error) {
	clientID := accountClientID
	if clientID == "" {
		clientID = r.clientID
	}
	key := tenantID + "|" + alias
	r.clientsMu.Lock()
	defer r.clientsMu.Unlock()
	if c, ok := r.clients[key]; ok {
		return c, nil
	}
	c, err := r.factory(clientID, tenantID, r.kc, alias)
	if err != nil {
		return nil, fmt.Errorf("auth: build MSAL client for %q: %w", alias, err)
	}
	r.clients[key] = c
	return c, nil
}

// findMSALAccount looks up the public.Account whose HomeAccountID
// matches homeAccountID. The MSAL cache may hold zero or more accounts;
// we match by ID rather than position because the order is unspecified.
// On miss, only the user-chosen alias is logged — HomeAccountID embeds
// the user's per-tenant objectId which docs/telemetry.md keeps out of
// any log destination the user can't easily inspect.
func (r *Registry) findMSALAccount(ctx context.Context, client MSALClient, alias, homeAccountID string) (public.Account, error) {
	// A config account persisted with an empty HomeAccountID (malformed or
	// hand-edited TOML, or a future login path that fails to populate it)
	// must never match. Without this guard, "" would match the first MSAL
	// cache entry whose ID is also "" — handing back a token for the WRONG
	// identity in a tool whose whole job is juggling multiple accounts.
	if homeAccountID == "" {
		slog.Warn("auth: account has no HomeAccountID; re-auth required",
			"alias", alias,
		)
		return public.Account{}, ErrInteractionRequired
	}
	accounts, err := client.Accounts(ctx)
	if err != nil {
		return public.Account{}, err
	}
	for _, a := range accounts {
		if a.HomeAccountID == "" {
			continue // never match on an empty cache-entry ID either
		}
		if a.HomeAccountID == homeAccountID {
			return a, nil
		}
	}
	// The config has an account whose tokens are not in the MSAL cache,
	// typically because the Keychain entry was wiped (re-installed OS,
	// manual deletion). Treat this as interaction-required so the menu
	// bar prompts the user to re-auth.
	slog.Warn("auth: account not present in MSAL cache; re-auth required",
		"alias", alias,
	)
	return public.Account{}, ErrInteractionRequired
}

// toConfigAccount converts the in-memory [Account] to the TOML-shaped
// [config.Account]. AddedAt is encoded as RFC 3339 in UTC to keep the
// config file portable across time zones.
func toConfigAccount(a Account) config.Account {
	added := a.AddedAt
	if added.IsZero() {
		added = time.Now().UTC()
	}
	return config.Account{
		Alias:         a.Alias,
		TenantID:      a.TenantID,
		TenantName:    a.TenantName,
		HomeAccountID: a.HomeAccountID,
		Username:      a.Username,
		AddedAt:       added.UTC().Format(time.RFC3339),
		ClientID:      a.ClientID,
	}
}

// fromConfigAccount is the inverse of [toConfigAccount]. A malformed
// AddedAt is tolerated (zero value) rather than erroring, because the
// account is still usable for token acquisition.
func fromConfigAccount(c config.Account) Account {
	var added time.Time
	if c.AddedAt != "" {
		if t, err := time.Parse(time.RFC3339, c.AddedAt); err == nil {
			added = t
		}
	}
	return Account{
		Alias:         c.Alias,
		HomeAccountID: c.HomeAccountID,
		Username:      c.Username,
		TenantID:      c.TenantID,
		TenantName:    c.TenantName,
		AddedAt:       added,
		ClientID:      c.ClientID,
	}
}
