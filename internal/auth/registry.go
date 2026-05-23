package auth

import (
	"errors"
	"fmt"
	"os"
	"sort"
	"time"

	"github.com/sdebruyn/onelake-explorer-macos/internal/config"
)

// Registry holds the set of signed-in accounts. The list of accounts is
// persisted in the OFE TOML config (via [config.Store]); the per-account
// opaque secret material is persisted in the [Keychain].
//
// Registry exposes the full Add/Remove/Get/List/Default/SetDefault
// lifecycle but does NOT implement [TokenProvider] yet — token
// acquisition requires MSAL, which lands in a follow-up change.
type Registry struct {
	store *config.Store
	kc    Keychain
}

// NewRegistry returns a Registry that reads and writes accounts to the
// given [config.Store] and per-account secrets to the given [Keychain].
// Both arguments must be non-nil.
func NewRegistry(store *config.Store, kc Keychain) *Registry {
	return &Registry{store: store, kc: kc}
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

	snap := r.store.Snapshot()
	if _, exists := snap.Accounts[account.Alias]; exists {
		return fmt.Errorf("auth: account %q already exists", account.Alias)
	}

	if err := r.kc.Set(account.Alias, secret); err != nil {
		return fmt.Errorf("auth: store secret for %q: %w", account.Alias, err)
	}

	r.store.Update(func(f *config.File) {
		if f.Accounts == nil {
			f.Accounts = map[string]config.Account{}
		}
		f.Accounts[account.Alias] = toConfigAccount(account)
	})

	if err := r.store.Save(); err != nil {
		// roll back the keychain so we do not leak orphan secrets
		_ = r.kc.Delete(account.Alias)
		r.store.Update(func(f *config.File) {
			delete(f.Accounts, account.Alias)
		})
		return fmt.Errorf("auth: save config: %w", err)
	}
	return nil
}

// Remove deletes the account from the config and the keychain. If the
// removed account was the configured default it is also cleared.
// Removing a missing alias returns an error wrapping os.ErrNotExist.
func (r *Registry) Remove(alias string) error {
	snap := r.store.Snapshot()
	if _, ok := snap.Accounts[alias]; !ok {
		return fmt.Errorf("auth: account %q: %w", alias, os.ErrNotExist)
	}

	if err := r.kc.Delete(alias); err != nil {
		return fmt.Errorf("auth: delete keychain entry for %q: %w", alias, err)
	}

	r.store.Update(func(f *config.File) {
		delete(f.Accounts, alias)
		if f.DefaultAccount == alias {
			f.DefaultAccount = ""
		}
	})

	if err := r.store.Save(); err != nil {
		return fmt.Errorf("auth: save config: %w", err)
	}
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
	// errors.Is(err, os.ErrNotExist) → fall through with secret == nil

	return fromConfigAccount(cfg), secret, nil
}

// List returns all known accounts sorted by alias for deterministic
// output (helpful for tests and for `ofe account list`).
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

// SetDefault sets the default account alias. It rejects unknown aliases
// with an error wrapping os.ErrNotExist.
func (r *Registry) SetDefault(alias string) error {
	snap := r.store.Snapshot()
	if _, ok := snap.Accounts[alias]; !ok {
		return fmt.Errorf("auth: account %q: %w", alias, os.ErrNotExist)
	}
	r.store.Update(func(f *config.File) {
		f.DefaultAccount = alias
	})
	if err := r.store.Save(); err != nil {
		return fmt.Errorf("auth: save config: %w", err)
	}
	return nil
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
	}
}
