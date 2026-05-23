// Package auth manages Microsoft Entra ID authentication for OFE.
//
// Scope today (foundation layer):
//   - The [TokenProvider] interface, which the rest of the codebase depends
//     on to obtain OneLake-audience access tokens.
//   - The [Account] value type plus [ValidateAlias], the canonical
//     representation of a signed-in OneLake account.
//   - A [Keychain] abstraction backed by github.com/zalando/go-keyring on
//     macOS, with [MemoryKeychain] for tests.
//   - The [Registry], which persists accounts to the OFE TOML config and
//     per-account opaque secrets to the keychain. It exposes the full
//     Add/Remove/Get/List/Default/SetDefault lifecycle but does NOT yet
//     implement [TokenProvider].
//
// Out of scope (lands in a follow-up PR):
//   - MSAL Go integration via
//     github.com/AzureAD/microsoft-authentication-library-for-go and its
//     PublicClientApplication.
//   - The interactive-browser and device-code login flows
//     (LoginInteractive, LoginDeviceCode) plus the localhost redirect HTTP
//     server.
//   - Wiring of the `ofe login` and `ofe account remove` CLI commands,
//     which currently remain stubbed.
//   - Making [Registry] implement [TokenProvider]; that step needs MSAL
//     to acquire and silently refresh tokens against the cache material
//     held in the keychain.
//
// See docs/auth.md for the full design.
package auth
