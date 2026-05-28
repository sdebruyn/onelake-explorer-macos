# Authentication design

## Goals

- Authenticate end users (never service principals) against Microsoft Entra ID.
- Support **multiple accounts in multiple tenants simultaneously**.
- Get tokens with the audience that OneLake DFS and the Fabric REST API both accept: `https://storage.azure.com/`.
- Cache tokens persistently across daemon restarts using the macOS Keychain.
- Handle token refresh transparently; surface re-auth requests through a quiet menu bar indicator rather than system notifications.
- Microsoft public cloud only.

## Microsoft Entra App Registration

We register a **multi-tenant public client application** in our own tenant:

| Property | Value |
|---|---|
| Display name | `OneLake Explorer for macOS` |
| Supported account types | Accounts in any organizational directory (multi-tenant) |
| Redirect URI | `http://localhost` (Public client/native) |
| Allow public client flows | **Yes** |
| API permissions | `https://storage.azure.com/user_impersonation` (delegated). Optionally Fabric Service for admin-search endpoints. |

The client ID lives in `internal/auth/client.go` as a constant — it is a public identifier, not a secret.

## Token acquisition flows

We support two flows, chosen automatically per environment:

1. **Interactive browser** (default on macOS desktop):
   - Opens `https://login.microsoftonline.com/{tenantId}/oauth2/v2.0/authorize?...` in the system default browser.
   - We run a tiny localhost HTTP server (random port between 49152–65535) to catch the redirect.
   - User signs in, consents (first time), and is redirected back to `http://localhost:PORT/?code=...&state=...`.
   - We exchange the authorization code for an access token + refresh token.

2. **Device code** (fallback for SSH sessions, headless environments, or when `--device-code` is passed):
   - We call `/devicecode` endpoint to get `user_code` and `device_code`.
   - We display: `To sign in, visit https://microsoft.com/devicelogin and enter the code: XXXX-YYYY`.
   - We poll `/token` every 5 seconds until success, error, or expiry.

Both flows are implemented on top of the Go MSAL library [`github.com/AzureAD/microsoft-authentication-library-for-go`](https://github.com/AzureAD/microsoft-authentication-library-for-go) (`msal-go`). MSAL Go natively supports both flows on a `PublicClientApplication`.

## Multi-tenant + multi-account model

Each account is identified by a user-chosen short alias (e.g. `work`, `client-a`). Internally each account has:

```go
type Account struct {
    Alias        string    // user-chosen, unique
    HomeAccountID string   // MSAL's unique identifier (objectId.tenantId)
    Username     string    // UPN, for display only
    TenantID     string    // GUID
    TenantName   string    // display name, optional
    AddedAt      time.Time
}
```

We construct **one `PublicClientApplication` per account-tenant** (MSAL recommends a separate authority per tenant for clean cache scoping). The authority for account X is `https://login.microsoftonline.com/{tenantId}`, not `/common` or `/organizations` — that way refresh and silent acquisition stay scoped to the right tenant.

A shared in-process **account registry** keeps the list of accounts and dispatches token requests to the right MSAL client.

## Token cache: macOS Keychain

MSAL Go uses an in-memory `cache.ExportReplace` interface by default. We implement it backed by the macOS **Keychain**:

- One Keychain item per account, labeled `dev.debruyn.ofem — <alias> (<UPN>)`.
- Service: `dev.debruyn.ofem`.
- Account name: `<HomeAccountID>`.
- Data: MSAL's serialized JSON token cache for that account.

Library: [`github.com/keybase/go-keychain`](https://github.com/keybase/go-keychain) or [`github.com/zalando/go-keyring`](https://github.com/zalando/go-keyring). Both work on macOS without any C dependency.

Keychain access is scoped per-app via the app's code signature. Unsigned local development builds get per-user scope.

## Token refresh and silent acquisition

On every OneLake request:

1. Look up the cached access token for the account.
2. If present and not within 5 minutes of expiry → use it.
3. Otherwise call MSAL `AcquireTokenSilent` to refresh.
4. If silent refresh fails with `interaction_required` (e.g. Conditional Access challenge, MFA expired) → mark account as `needs_reauth`, queue a menu-bar error indicator. No system notification.
5. The next time the user opens the menu bar app (or runs `ofem status`), the indicator shows them which account needs re-auth. They re-run `ofem login --account <alias>` to interactively unblock.

## Conditional Access / MFA challenges

On `AADSTS50076` / `AADSTS50079` / `interaction_required`, the daemon silently retries on a 30 minute interval and surfaces a menu bar error indicator. No macOS notification is posted.

## Logout / account removal

`ofem account remove <alias>`:

1. Removes the Keychain item.
2. Removes the account from the registry config.
3. Optionally calls Microsoft's `/oauth2/v2.0/logout` (best effort, no error if it fails).
4. Removes the account's folder from `~/Library/CloudStorage/OneLake-<alias>/` (and the matching Finder sidebar entry `OneLake — <alias>`) after a confirmation prompt (or `--force`).

## Two-audience scope model

OFEM talks to two distinct Microsoft resource APIs that require different token audiences:

| Scope set | Constant | Audience | Used by |
|---|---|---|---|
| `OneLakeScopes` | `internal/auth/client.go` | `https://storage.azure.com/` | OneLake ADLS Gen2 DFS file I/O |
| `FabricScopes` | `internal/auth/client.go` | `https://analysis.windows.net/powerbi/api` | Fabric REST workspace + item discovery |

### Single interactive consent via LoginScopes

`LoginScopes` is the union of both scope sets and is passed during the one-shot interactive or device-code login flow. Microsoft Entra records the user's consent for every resource in a single call. After that first consent:

- `AcquireTokenSilent` for `OneLakeScopes` returns a storage-audience token from the refresh token — no browser pop-up.
- `AcquireTokenSilent` for `FabricScopes` returns a Power BI-audience token from the same refresh token — also silent.

MSAL Go manages this internally: one `PublicClientApplication` per tenant can silently serve tokens for multiple resources as long as the refresh token carries the necessary consent.

### Wiring in OFEM

The `Registry` implements `TokenProvider` via its `Token` method (uses `OneLakeScopes`). For the Fabric REST client, `Registry.ScopedProvider(FabricScopes)` returns a `TokenProvider` that calls `TokenForScopes` with `FabricScopes`. This ensures each upstream receives a token its audience will accept.

```
registry.Token(ctx, alias)                         → OneLake DFS token
registry.ScopedProvider(FabricScopes).Token(ctx, alias) → Fabric REST token
```

Passing the wrong scope set to a resource results in a 401 from the server; OFEM's `SilentToken` helper returns an explicit error if an empty scope set is supplied, so that caller bugs are caught immediately rather than producing confusing server errors.

## Sovereign clouds

OFEM targets the Microsoft public cloud. The authority host is kept configurable per account (`authority_host: login.microsoftonline.com` default), so adding US Gov / China / Germany is a config change plus an endpoint mapping.

## Security considerations

- **No client secret**: public client only, so there is no secret to leak.
- **PKCE** is used for the authorization code flow (MSAL Go does this by default).
- **State parameter** is generated per flow and validated.
- **Random port** for localhost redirect avoids collisions and reduces attack surface vs. a fixed well-known port.
- **Refresh tokens** are stored in Keychain, scoped per account; they cannot be exported via the CLI.
- **No token printing**: even `ofem debug` commands never echo tokens.
- The Entra App Registration is owned by the project maintainer; users only consent to delegated permissions and can revoke at any time via [https://myapplications.microsoft.com](https://myapplications.microsoft.com).
