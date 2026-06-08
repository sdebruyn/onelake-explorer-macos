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
| Redirect URI | `http://localhost` (Public client/native) |
| Allow public client flows | **Yes** |
| API permissions | `https://storage.azure.com/user_impersonation` (Azure Storage, delegated) **and** Power BI Service `Workspace.Read.All` + `Item.Read.All` (delegated, admin-consented) for Fabric REST discovery. |

The client ID lives in `Packages/OfemKit/Sources/OfemKit/Auth/` as a constant — it is a public identifier, not a secret.

## Token acquisition flow

Sign-in uses the **interactive browser** flow:

- Opens `https://login.microsoftonline.com/{tenantId}/oauth2/v2.0/authorize?...` in the system default browser.
- We run a tiny localhost HTTP server (random port between 49152–65535) to catch the redirect.
- User signs in, consents (first time), and is redirected back to `http://localhost:PORT/?code=...&state=...`.
- We exchange the authorization code for an access token + refresh token.

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

### Single interactive consent via loginScopes

`loginScopes` is the union of both scope sets and is passed during the one-shot interactive login flow. Microsoft Entra records the user's consent for every resource in a single call. After that first consent:

- `acquireTokenSilent` for `oneLakeScopes` returns a storage-audience token from the refresh token — no browser pop-up.
- `acquireTokenSilent` for `fabricScopes` returns a Power BI-audience token from the same refresh token — also silent.

MSAL manages this internally: one `MSALPublicClientApplication` per tenant can silently serve tokens for multiple resources as long as the refresh token carries the necessary consent.

### Wiring in OFEM

The `OfemAuth` class implements `TokenProvider`. For the Fabric REST client, `OfemAuth.scopedProvider(fabricScopes)` returns a `TokenProvider` that calls `tokenForScopes` with `fabricScopes`. This ensures each upstream receives a token its audience will accept.

```
auth.token(for: alias)                        → OneLake DFS token
auth.scopedProvider(fabricScopes).token(...)  → Fabric REST token
```

Passing the wrong scope set to a resource results in a 401 from the server.

## Sovereign clouds

OFEM targets the Microsoft public cloud. The authority host is kept configurable per account (`authorityHost: login.microsoftonline.com` default), so adding US Gov / China / Germany is a config change plus an endpoint mapping.

## Security considerations

- **No client secret**: public client only, so there is no secret to leak.
- **PKCE** is used for the authorization code flow (MSAL does this by default).
- **State parameter** is generated per flow and validated.
- **Random port** for localhost redirect avoids collisions and reduces attack surface vs. a fixed well-known port.
- **Refresh tokens** are stored in Keychain, scoped per account; tokens are never exported or echoed anywhere.
- **No token printing**: tokens never appear in logs, telemetry, or any XPC response.
- The Entra App Registration is owned by the project maintainer; users only consent to delegated permissions and can revoke at any time via [https://myapplications.microsoft.com](https://myapplications.microsoft.com).
