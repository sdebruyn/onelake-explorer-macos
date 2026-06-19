# Authentication design

## Goals

- Authenticate end users (never service principals) against Microsoft Entra ID.
- Support **multiple accounts in multiple tenants simultaneously**.
- Get tokens with the right audience for each resource: OneLake DFS file I/O uses `https://storage.azure.com/`, while the Fabric REST API uses the Power BI Service audience (`https://analysis.windows.net/powerbi/api`). See "Two-audience scope model" below — a single audience does **not** cover both (it returns 401 on Fabric REST).
- Cache tokens persistently across app restarts using the macOS Keychain.
- Handle token refresh transparently; surface re-auth requests through a quiet menu bar indicator rather than system notifications.
- Microsoft public cloud only.

## Microsoft Entra App Registration

We register a **multi-tenant public client application** in our own tenant:

| Property | Value |
|---|---|
| Display name | `OneLake Explorer for macOS` |
| Supported account types | Accounts in any organizational directory (multi-tenant) |
| Redirect URIs | See below — **both** URIs must be registered |
| Allow public client flows | **Yes** |
| API permissions | `https://storage.azure.com/user_impersonation` (Azure Storage, delegated) **and** Power BI Service `Workspace.Read.All` + `Item.Read.All` (delegated, user-consented) for Fabric REST discovery. |

The client ID lives in `Packages/OfemKit/Sources/OfemKit/Auth/` as a constant — it is a public identifier, not a secret.

### Required redirect URIs

The app registration **must** include both of the following public-client redirect URIs under **Mobile and desktop applications**:

| URI | Used by |
|---|---|
| `msauth.dev.debruyn.ofem://auth` | Host app (`dev.debruyn.ofem`) |
| `msauth.dev.debruyn.ofem.fileprovider://auth` | File Provider Extension (`dev.debruyn.ofem.fileprovider`) |

**Why two URIs?** MSAL for Apple Platforms constructs the redirect URI from the calling process's bundle ID (`msauth.<bundleID>://auth`) and validates it locally before sending any request. The host app and the File Provider Extension run as separate processes with different bundle IDs, so each process produces a different redirect URI. Both URIs must also be registered server-side in the Entra app registration — if one is missing, Entra rejects every token refresh from that process with `invalid_client` (`MSALInternalErrorInvalidClient`, internal error code -42003), which surfaces as ``OfemAuthError/configRejection(_:)`` in the logs. The FPE's redirect URI (`msauth.dev.debruyn.ofem.fileprovider://auth`) was introduced in commit `4c6de3f` alongside the per-process redirect URI strategy; omitting it from the registration causes the FPE's silent MSAL refresh to fail on every mount until the registration is corrected.

**Registration command** (Azure CLI, run once):

```bash
az ad app update \
  --id <appId> \
  --public-client-redirect-uris \
    "msauth.dev.debruyn.ofem://auth" \
    "msauth.dev.debruyn.ofem.fileprovider://auth"
```

## Token acquisition flow

Sign-in uses the **interactive browser** flow via `ASWebAuthenticationSession`:

- MSAL for Apple Platforms opens the Microsoft sign-in page (`https://login.microsoftonline.com/{tenantId}/oauth2/v2.0/authorize?...`) inside an `ASWebAuthenticationSession` sheet anchored to the "Add Account" window.
- User signs in and consents (first time only).
- Microsoft redirects to `msauth.dev.debruyn.ofem://auth?code=...&state=...`. `ASWebAuthenticationSession` captures this callback via the registered custom URL scheme — no local web server is involved.
- MSAL exchanges the authorization code for an access token + refresh token.

The flow is implemented using **MSAL for Apple Platforms** (the official Swift SDK from Microsoft) on a `MSALPublicClientApplication`.

## Multi-tenant + multi-account model

Each account is identified by a user-chosen short alias (e.g. `work`, `client-a`). Internally each account has:

```swift
struct Account {
    let alias: String         // user-chosen, unique
    let homeAccountID: String // MSAL's unique identifier (objectId.tenantId)
    let username: String      // UPN, for display only
    let tenantID: String      // GUID
    let tenantName: String?   // display name, optional
    let addedAt: Date
}
```

We construct **one `MSALPublicClientApplication` per account-tenant** (MSAL recommends a separate authority per tenant for clean cache scoping). The authority for account X is `https://login.microsoftonline.com/{tenantId}`, not `/common` or `/organizations` — that way refresh and silent acquisition stay scoped to the right tenant.

A shared in-process **account registry** (`OfemKit.SharedOfemAuth`) keeps the list of accounts and dispatches token requests to the right MSAL client.

## Token cache: macOS Keychain

MSAL for Apple Platforms uses the macOS **Keychain** natively via its `MSALSerializableTokenCache` interface:

- One Keychain item per account, labeled `dev.debruyn.ofem — <alias> (<UPN>)`.
- Service: `dev.debruyn.ofem`.
- Account name: `<homeAccountID>`.
- Data: MSAL's serialized JSON token cache for that account.

Keychain access is scoped per-app via the app's code signature. Unsigned local development builds get per-user scope.

## Token refresh and silent acquisition

On every OneLake request:

1. Look up the cached access token for the account.
2. If present and not within 5 minutes of expiry → use it.
3. Otherwise call MSAL `acquireTokenSilent` to refresh.
4. If silent refresh fails with `interaction_required` (e.g. Conditional Access challenge, MFA expired) → mark account as `needsReauth`, queue a menu-bar error indicator. No system notification.
5. The next time the user opens the menu bar app, the indicator shows them which account needs re-auth. They sign that account out and add it again from the menu bar to interactively unblock.

### Silent-failure error classification

`OfemAuth.silentToken` maps MSAL silent-acquisition failures into three distinct ``OfemAuthError`` cases:

| Condition | MSAL signal | Thrown error |
|---|---|---|
| User must interact (CA, MFA, expired RT) | `MSALError.interactionRequired` (-50002) or AADSTS STS codes 50076/50079/50078/50158 | ``OfemAuthError/interactionRequired`` |
| Permanent config/credential rejection | `MSALInternalErrorCodeKey` = -42003 (`invalid_client`) or -42004 (`invalid_grant`) | ``OfemAuthError/configRejection(_:)`` |
| Other transient failure (network, server 5xx) | Any other error | ``OfemAuthError/silentTokenFailed(_:)`` |

`configRejection` is distinct from `interactionRequired` because a config error cannot be fixed by re-authenticating. The most common cause is a missing redirect URI in the Entra app registration (see above). When `configRejection` is thrown, `OfemAuth` also logs at `.critical` level — including the full MSAL error with `MSALInternalErrorCodeKey` — so misconfigurations are diagnosable from Console.app logs without a debugger.

All three cases propagate through `HTTPClientError.tokenAcquisitionFailed` → `FabricError.unauthorized` → `FPError.notAuthenticated`, so Finder shows an auth-required indicator in all cases. The distinction is in the log output and the error type available to the host app's error-handling layer.

## Conditional Access / MFA challenges

On `AADSTS50076` / `AADSTS50079` / `interaction_required`, the FPE engine silently retries on a 30 minute interval and surfaces a menu bar error indicator. No macOS notification is posted.

## Logout / account removal

Signing out via the menu bar (account submenu -> **Sign Out…**) triggers the FPE's `removeAccount` XPC method, which:

1. Removes the Keychain item.
2. Removes the account from the registry config.
3. Optionally calls Microsoft's `/oauth2/v2.0/logout` (best effort, no error if it fails).
4. Removes the account's File Provider domain from Finder (and the sidebar entry `OneLake — <alias>`). The menu bar confirms before invoking it.

## Two-audience scope model

OFEM talks to two distinct Microsoft resource APIs that require different token audiences:

| Scope set | Audience | Used by |
|---|---|---|
| `oneLakeScopes` | `https://storage.azure.com/` | OneLake ADLS Gen2 DFS file I/O |
| `fabricScopes` | `https://analysis.windows.net/powerbi/api` | Fabric REST workspace + item discovery |

### Two sequential interactive consent flows

`loginScopes` is limited to the OneLake (storage) resource only. The Microsoft
Entra v2 endpoint returns AADSTS28000 if an interactive request spans more than
one resource, so sign-in requires two sequential browser flows:

1. **OneLake flow** — `TokenScope.loginScopes` (`user_impersonation` for
   `https://storage.azure.com/`). The user signs in, consents to the storage
   scope, and the account is committed to `OfemAuth`.
2. **Fabric consent flow** — `TokenScope.fabricScopes` (`Workspace.Read.All` +
   `Item.Read.All` for the Power BI audience). Immediately after the OneLake
   flow, a second browser prompt asks the user to consent to the Fabric
   delegated permissions. No admin pre-consent is assumed or required —
   `Workspace.Read.All` and `Item.Read.All` are standard user-consentable
   delegated permissions.

MSAL writes both the OneLake and Fabric tokens to the shared App Group Keychain
after the respective flows, so subsequent silent acquisitions (`acquireTokenSilent`)
for either resource are fast cache hits.

### Wiring in OFEM

The `OfemAuth` actor implements `TokenProvider`. For the Fabric REST client, `tokenForScope(alias:scope:.fabric)` returns a token for the Power BI audience. `tokenForScope(alias:scope:.oneLake)` returns a token for the storage audience.

```
auth.tokenForScope(alias:scope:.oneLake)  → OneLake DFS token
auth.tokenForScope(alias:scope:.fabric)   → Fabric REST token
```

Passing the wrong scope set to a resource results in a 401 from the server.

## Integration-test authentication

The shipped app authenticates users interactively through MSAL — that is the only auth path end users see.

The integration test suite runs headless in CI, where interactive auth is impossible. OfemKit clients receive tokens through the `TokenProvider` protocol, so the tests inject bearer tokens directly at that seam via a test-only `EnvVarTokenProvider` (in the OfemKit test target). No service-principal or token-injection code is present in the shipped product.

CI mints those tokens using a dedicated Microsoft Entra service principal that authenticates to Azure through GitHub Actions OIDC (workload identity federation — no client secret). The federated credential is scoped to the repo's `integration` environment.

OFEM requires two token audiences (see `docs/onelake-api.md`), so CI mints two tokens with `az account get-access-token`:

- `https://storage.azure.com/` — for the OneLake DFS data plane.
- `https://analysis.windows.net/powerbi/api` — for Fabric REST discovery.

The service principal is a Contributor member of the test workspace and is used solely for test infrastructure; it plays no role in end-user authentication.

## Sovereign clouds

OFEM targets the Microsoft public cloud. The authority host is kept configurable per account (`authorityHost: login.microsoftonline.com` default), so adding US Gov / China / Germany is a config change plus an endpoint mapping.

## Security considerations

- **No client secret**: public client only, so there is no secret to leak.
- **PKCE** is used for the authorization code flow (MSAL does this by default).
- **State parameter** is generated per flow and validated.
- **Custom URL scheme** (`msauth.dev.debruyn.ofem://auth`) is captured by `ASWebAuthenticationSession`, which the OS enforces can only be intercepted by the registered app — no local web server or open port is involved.
- **Refresh tokens** are stored in Keychain, scoped per account; tokens are never exported or echoed anywhere.
- **No token printing**: tokens never appear in logs, telemetry, or any XPC response.
- The Entra App Registration is owned by the project maintainer; users only consent to delegated permissions and can revoke at any time via [https://myapplications.microsoft.com](https://myapplications.microsoft.com).
