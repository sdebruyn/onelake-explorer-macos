package auth

import (
	"context"
	"crypto/rand"
	"errors"
	"fmt"
	"log/slog"
	"time"

	"github.com/AzureAD/microsoft-authentication-library-for-go/apps/public"
)

// LoginInteractive starts the OAuth authorization-code flow with PKCE in
// the user's default browser. The underlying MSAL Go library runs a
// tiny HTTP server on a random localhost port (port 0) to catch the
// redirect, then exchanges the code via MSAL.
//
// tenantHint can be:
//   - "" — uses [TenantHintCommon] ("organizations") so MSAL picks the
//     tenant from the user's home directory at sign-in time;
//   - a tenant GUID or a verified domain (e.g. "contoso.onmicrosoft.com").
//
// openURL, when non-nil, is called by MSAL with the authorization URL
// instead of spawning a subprocess to open the system browser. Pass nil
// to use MSAL's default behaviour (exec.Command("open", url)). Under
// App Sandbox the subprocess spawn is blocked, so callers running inside
// the sandbox must supply an openURL that delegates browser-opening to
// the host app via IPC (see internal/daemon for the IPC flow).
//
// The returned [Account] is populated from the ID token's claims and
// public.Account is the MSAL handle for the same identity. The byte
// slice is the serialised MSAL token cache: the caller MUST pass it to
// [Registry.Add] as the secret so subsequent silent acquisitions can
// refresh tokens.
func LoginInteractive(ctx context.Context, clientID, tenantHint string, kc Keychain, openURL func(string) error) (Account, public.Account, []byte, error) {
	if clientID == "" {
		return Account{}, public.Account{}, nil, errors.New("auth: clientID is required")
	}
	if kc == nil {
		return Account{}, public.Account{}, nil, errors.New("auth: keychain is required")
	}

	authority := AuthorityHostPublicCloud + "/" + resolveTenantHint(tenantHint)
	cache, tempAlias, cleanup := newScratchCache(kc)
	defer cleanup()

	client, err := public.New(
		clientID,
		public.WithAuthority(authority),
		public.WithCache(cache),
	)
	if err != nil {
		return Account{}, public.Account{}, nil, fmt.Errorf("auth: build MSAL client: %w", err)
	}

	slog.Info("auth: starting interactive browser login",
		"tenant_hint", tenantHint,
		"authority", authority,
	)

	// Build the option list. WithRedirectURI("http://localhost:0") lets
	// MSAL pick a free port for the OAuth loopback listener — this works
	// under App Sandbox because the daemon has the
	// com.apple.security.network.server entitlement.
	acquireOpts := []public.AcquireInteractiveOption{
		public.WithRedirectURI("http://localhost:0"),
	}
	if openURL != nil {
		// Override the default browser-open path (exec.Command("open",
		// url)) with the caller-supplied function. The daemon uses this to
		// forward the URL to the sandboxed host app via IPC so the host
		// can call NSWorkspace.shared.open(URL) on its behalf — avoiding
		// any subprocess spawn inside the sandbox.
		acquireOpts = append(acquireOpts, public.WithOpenURL(openURL))
	}

	// MSAL Go's interactive flow manages the localhost redirect server
	// and PKCE exchange end to end.
	res, err := client.AcquireTokenInteractive(ctx, LoginScopes, acquireOpts...)
	if err != nil {
		return Account{}, public.Account{}, nil, fmt.Errorf("auth: interactive login: %w", err)
	}

	acc := accountFromAuthResult(res)
	cacheBytes, kErr := kc.Get(tempAlias)
	if kErr != nil {
		// The scratch cache could not be read back. This is a hard
		// failure because without the bytes the caller cannot persist
		// the refresh token; the user will appear signed in but every
		// subsequent token request will need a fresh interactive login.
		return Account{}, public.Account{}, nil, fmt.Errorf("auth: read scratch cache: %w", kErr)
	}
	// HomeAccountID embeds the user's per-tenant objectId; keep it out of
	// the log to match findMSALAccount's policy (it logs only the alias).
	slog.Info("auth: interactive login succeeded",
		"username", acc.Username,
		"tenant_id", acc.TenantID,
		"cache_bytes", len(cacheBytes),
	)
	return acc, res.Account, cacheBytes, nil
}

// newScratchCache constructs a Keychain-backed MSAL cache under a unique
// temporary alias. The returned cleanup function deletes that scratch
// entry; callers always defer it. The temporary alias is also returned
// so callers can read the serialised cache bytes back after a login.
func newScratchCache(kc Keychain) (*KeychainCache, string, func()) {
	tempAlias := temporaryLoginAlias()
	return NewKeychainCache(kc, tempAlias), tempAlias, func() {
		_ = kc.Delete(tempAlias)
	}
}

// resolveTenantHint maps a possibly-empty caller hint to a value the
// Microsoft Entra authority host understands.
func resolveTenantHint(hint string) string {
	if hint == "" {
		return TenantHintCommon
	}
	return hint
}

// accountFromAuthResult extracts the OFEM [Account] fields from an MSAL
// AuthResult. AddedAt is set to the current time so the caller can
// persist a fresh "first signed in" timestamp; subsequent logins under
// the same alias should preserve the original via Registry semantics.
func accountFromAuthResult(res public.AuthResult) Account {
	return Account{
		HomeAccountID: res.Account.HomeAccountID,
		Username:      res.Account.PreferredUsername,
		TenantID:      res.IDToken.TenantID,
		TenantName:    "", // tenant display name is not in the ID token
		AddedAt:       time.Now().UTC(),
	}
}

// temporaryLoginAlias returns a unique alias used for the keychain entry
// during a login that has not yet been assigned a user-chosen alias. The
// timestamp + random suffix ensures that concurrent logins from different
// shells (or even from the same process within the same nanosecond on
// fast machines) do not stomp on each other.
func temporaryLoginAlias() string {
	var b [8]byte
	// crypto/rand never returns an error on a healthy macOS kernel; if
	// it ever does, we degrade to a timestamp-only alias which is still
	// unique enough for the loopback case.
	_, _ = rand.Read(b[:])
	return fmt.Sprintf(".ofem-login-tmp-%d-%x", time.Now().UnixNano(), b)
}
