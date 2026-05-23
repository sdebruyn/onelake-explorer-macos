// Package auth manages Microsoft Entra ID authentication for OFE.
//
// Surface area:
//   - The [TokenProvider] interface, the contract that the rest of the
//     codebase uses to obtain OneLake-audience access tokens.
//   - The [Account] value type plus [ValidateAlias], the canonical
//     representation of a signed-in OneLake account.
//   - A [Keychain] abstraction backed by github.com/zalando/go-keyring on
//     macOS, with [MemoryKeychain] for tests.
//   - A Keychain-backed MSAL token cache via [KeychainCache], which
//     adapts our [Keychain] to MSAL Go's cache.ExportReplace.
//   - The [Registry], which persists accounts to the OFE TOML config and
//     per-account opaque secrets to the keychain, and implements
//     [TokenProvider] via MSAL silent acquisition.
//   - The interactive-browser and device-code login flows
//     ([LoginInteractive], [LoginDeviceCode]).
//
// Sentinel errors:
//   - [ErrInteractionRequired] — silent refresh failed because the user
//     must complete an interactive sign-in (Conditional Access challenge,
//     MFA re-prompt, expired refresh token).
//
// Out of scope:
//   - The daemon-side background loop that silently refreshes tokens and
//     surfaces re-auth indicators in the menu bar; that lives in the
//     daemon package.
//   - Sovereign clouds (US Gov, China, Germany); MVP is public cloud
//     only, see docs/auth.md.
//
// See docs/auth.md for the full design.
package auth
