package auth

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"time"

	"github.com/AzureAD/microsoft-authentication-library-for-go/apps/public"
)

// LoginDeviceCode starts the OAuth device-code flow. The prompt callback
// receives the verification URL and user code so the CLI can display
// them. The function blocks until the user completes the flow in their
// browser, the device code expires, or the context is cancelled.
//
// tenantHint follows the same rules as [LoginInteractive].
func LoginDeviceCode(ctx context.Context, clientID, tenantHint string, kc Keychain, prompt func(verificationURL, userCode string, expiresAt time.Time)) (Account, public.Account, []byte, error) {
	if clientID == "" {
		return Account{}, public.Account{}, nil, errors.New("auth: clientID is required")
	}
	if kc == nil {
		return Account{}, public.Account{}, nil, errors.New("auth: keychain is required")
	}
	if prompt == nil {
		return Account{}, public.Account{}, nil, errors.New("auth: prompt callback is required")
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

	slog.Info("auth: starting device-code login",
		"tenant_hint", tenantHint,
		"authority", authority,
	)

	dc, err := client.AcquireTokenByDeviceCode(ctx, LoginScopes)
	if err != nil {
		return Account{}, public.Account{}, nil, fmt.Errorf("auth: start device code: %w", err)
	}

	prompt(dc.Result.VerificationURL, dc.Result.UserCode, dc.Result.ExpiresOn)

	res, err := dc.AuthenticationResult(ctx)
	if err != nil {
		return Account{}, public.Account{}, nil, fmt.Errorf("auth: device code authentication: %w", err)
	}

	acc := accountFromAuthResult(res)
	cacheBytes, kErr := kc.Get(tempAlias)
	if kErr != nil {
		return Account{}, public.Account{}, nil, fmt.Errorf("auth: read scratch cache: %w", kErr)
	}
	slog.Info("auth: device-code login succeeded",
		"username", acc.Username,
		"tenant_id", acc.TenantID,
		"home_account_id", acc.HomeAccountID,
		"cache_bytes", len(cacheBytes),
	)
	return acc, res.Account, cacheBytes, nil
}
