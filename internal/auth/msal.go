package auth

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"os"
	"strings"
	"sync"

	"github.com/AzureAD/microsoft-authentication-library-for-go/apps/cache"
	"github.com/AzureAD/microsoft-authentication-library-for-go/apps/public"
)

// ErrInteractionRequired is returned by [Registry.Token] and the silent
// helpers in this package when MSAL signals that the user must interact
// again to complete authentication (Conditional Access challenge, MFA
// re-prompt, refresh-token expiry). Callers should surface this with a
// "click to re-auth" indicator rather than blocking — see docs/auth.md.
var ErrInteractionRequired = errors.New("auth: interaction required")

// MSALClient is the subset of *public.Client that OFEM depends on. It is
// declared here, rather than imported in callers, so tests can substitute
// a stub without depending on the real MSAL transport. The real
// implementation is satisfied by *publicClientAdapter wrapping
// *public.Client.
type MSALClient interface {
	// AcquireTokenSilent attempts to return a token from the cache or via
	// a refresh token, scoped to the given MSAL Account.
	AcquireTokenSilent(ctx context.Context, scopes []string, account public.Account) (public.AuthResult, error)

	// Accounts returns every account known to the MSAL token cache backing
	// this client.
	Accounts(ctx context.Context) ([]public.Account, error)
}

// ClientFactory builds an MSALClient for a given (clientID, tenantID)
// tuple. The returned client uses the per-account Keychain entry as its
// MSAL token cache backend via [NewKeychainCache].
//
// Factories are pure constructors: callers cache the returned client to
// avoid rebuilding it on every Token() call.
type ClientFactory func(clientID, tenantID string, kc Keychain, accountAlias string) (MSALClient, error)

// DefaultClientFactory returns an MSALClient backed by the real
// github.com/AzureAD/microsoft-authentication-library-for-go public.Client.
// The authority is https://login.microsoftonline.com/<tenantID>.
//
// The returned client has the per-account Keychain entry installed as
// its cache.ExportReplace accessor, so refresh tokens persist across
// daemon restarts.
func DefaultClientFactory(clientID, tenantID string, kc Keychain, accountAlias string) (MSALClient, error) {
	if clientID == "" {
		return nil, errors.New("auth: clientID is required")
	}
	if tenantID == "" {
		return nil, errors.New("auth: tenantID is required")
	}
	if kc == nil {
		return nil, errors.New("auth: keychain is required")
	}
	if accountAlias == "" {
		return nil, errors.New("auth: accountAlias is required")
	}

	authority := AuthorityHostPublicCloud + "/" + tenantID
	accessor := NewKeychainCache(kc, accountAlias)

	c, err := public.New(
		clientID,
		public.WithAuthority(authority),
		public.WithCache(accessor),
	)
	if err != nil {
		return nil, fmt.Errorf("auth: build MSAL client for %q: %w", accountAlias, err)
	}
	return &publicClientAdapter{inner: c}, nil
}

// publicClientAdapter wires the concrete public.Client API to the
// trimmed MSALClient interface used inside OFEM.
type publicClientAdapter struct {
	inner public.Client
}

// AcquireTokenSilent forwards to public.Client.AcquireTokenSilent with
// the supplied account.
func (a *publicClientAdapter) AcquireTokenSilent(ctx context.Context, scopes []string, account public.Account) (public.AuthResult, error) {
	return a.inner.AcquireTokenSilent(ctx, scopes, public.WithSilentAccount(account))
}

// Accounts forwards to public.Client.Accounts.
func (a *publicClientAdapter) Accounts(ctx context.Context) ([]public.Account, error) {
	return a.inner.Accounts(ctx)
}

// Underlying returns the wrapped public.Client. The login flows use this
// to call MSAL APIs (AcquireTokenInteractive, AcquireTokenByDeviceCode)
// that are not part of the [MSALClient] interface because they are only
// invoked during the one-shot login path, not by the hot-path token
// provider.
func (a *publicClientAdapter) Underlying() *public.Client {
	return &a.inner
}

// KeychainCache adapts a [Keychain] to MSAL Go's cache.ExportReplace
// interface. Each instance is bound to a single account alias: the alias
// is used as the keychain key, matching the convention in [Registry].
//
// Concurrency: MSAL serialises Replace/Export calls per client around
// each token acquisition. The underlying Keychain implementations in
// this package (system and memory) are themselves safe for concurrent
// use, but KeychainCache also takes its own lock so that an Export
// during one acquisition cannot interleave with a Replace from another.
type KeychainCache struct {
	mu    sync.Mutex
	kc    Keychain
	alias string
}

// NewKeychainCache returns a KeychainCache that persists MSAL's
// serialised token cache for accountAlias into kc. Both arguments must
// be non-nil / non-empty.
func NewKeychainCache(kc Keychain, accountAlias string) *KeychainCache {
	return &KeychainCache{kc: kc, alias: accountAlias}
}

// Replace loads the serialised MSAL cache from the keychain and feeds it
// to the supplied Unmarshaler. If no entry exists yet it is a no-op (the
// in-memory cache stays empty), which is the documented behaviour for
// first-run login.
//
// The cache.ReplaceHints argument is intentionally ignored: this instance
// is bound to one alias (one keychain entry, one tenant), so there is no
// partition keyed by hint to consult — the keychain key is fixed at
// construction.
func (c *KeychainCache) Replace(ctx context.Context, marshaler cache.Unmarshaler, _ cache.ReplaceHints) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	c.mu.Lock()
	defer c.mu.Unlock()

	data, err := c.kc.Get(c.alias)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			// First login for this alias: MSAL keeps the in-memory cache
			// empty, the subsequent Export persists the new tokens.
			return nil
		}
		return fmt.Errorf("auth: load token cache for %q: %w", c.alias, err)
	}
	if len(data) == 0 {
		return nil
	}
	if err := marshaler.Unmarshal(data); err != nil {
		return fmt.Errorf("auth: unmarshal token cache for %q: %w", c.alias, err)
	}
	return nil
}

// Export serialises the in-memory MSAL cache and writes it to the
// keychain. An empty payload is treated as "delete" by the keychain
// layer, which is appropriate when MSAL clears the cache on logout.
//
// The cache.ExportHints argument is intentionally ignored for the same
// reason Replace ignores ReplaceHints: this instance owns exactly one
// keychain entry for one account alias.
func (c *KeychainCache) Export(ctx context.Context, marshaler cache.Marshaler, _ cache.ExportHints) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	c.mu.Lock()
	defer c.mu.Unlock()

	data, err := marshaler.Marshal()
	if err != nil {
		return fmt.Errorf("auth: marshal token cache for %q: %w", c.alias, err)
	}
	if err := c.kc.Set(c.alias, data); err != nil {
		return fmt.Errorf("auth: store token cache for %q: %w", c.alias, err)
	}
	return nil
}

// SilentToken runs MSAL's silent token acquisition for the given account
// and returns the access token string. The msalAccount argument is the
// MSAL-side account object (typically obtained from
// public.Client.Accounts() and matched by HomeAccountID).
//
// If MSAL reports that the user must interact again, SilentToken returns
// [ErrInteractionRequired] wrapped with the original message so callers
// can use errors.Is and still log the detail.
func SilentToken(ctx context.Context, client MSALClient, accountAlias string, msalAccount public.Account) (string, error) {
	if client == nil {
		return "", errors.New("auth: nil MSAL client")
	}
	res, err := client.AcquireTokenSilent(ctx, Scopes, msalAccount)
	if err != nil {
		if isInteractionRequired(err) {
			slog.Info("auth: silent acquisition requires interaction",
				"alias", accountAlias,
				"err", err,
			)
			return "", fmt.Errorf("%w: %w", ErrInteractionRequired, err)
		}
		return "", fmt.Errorf("auth: silent token for %q: %w", accountAlias, err)
	}
	return res.AccessToken, nil
}

// isInteractionRequired returns true when the MSAL error string contains
// one of the OAuth/AAD signals that the user must interact again. MSAL
// Go does not export a sentinel for this — every code path wraps the
// raw "<error_code>: <error_description>" returned by the token endpoint
// — so we match on substring.
func isInteractionRequired(err error) bool {
	if err == nil {
		return false
	}
	msg := strings.ToLower(err.Error())
	signals := []string{
		"interaction_required",
		"login_required",
		"consent_required",
		"invalid_grant",
		"mfa_required",
		"password_change_required",
		// AAD STS codes that map to "you must re-auth in the browser":
		// AADSTS50076  — MFA required.
		// AADSTS50079  — strong auth (MFA) registration required.
		// AADSTS50158  — external MFA required.
		// AADSTS50173  — fresh token required after password change.
		// AADSTS65001  — user or admin has not consented.
		// AADSTS70043  — refresh token expired due to inactivity.
		// AADSTS700082 — refresh token expired due to inactivity (90 d).
		"aadsts50076",
		"aadsts50079",
		"aadsts50158",
		"aadsts50173",
		"aadsts65001",
		"aadsts70043",
		"aadsts700082",
	}
	for _, s := range signals {
		if strings.Contains(msg, s) {
			return true
		}
	}
	return false
}
