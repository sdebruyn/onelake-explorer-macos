import Foundation

// MARK: - TokenCacheStrategy

/// Selects how MSAL token cache data is persisted on disk.
///
/// ## MSAL on macOS: architecture
///
/// `MSIDMacKeychainTokenCache` (the backing store used by MSAL Swift on
/// macOS) stores **two** `kSecClassGenericPassword` items in the login.keychain:
///
/// 1. **Shared blob** — all refresh tokens and account records for all apps
/// sharing the `com.microsoft.identity.universalstorage` access group.
/// Key: `(kSecAttrAccount = "<access_group>", kSecAttrService = "Microsoft Credentials")`.
/// 2. **Non-shared blob** — access tokens, ID tokens, app metadata, and
/// account metadata scoped to this app bundle. Key:
/// `(kSecAttrAccount = "<access_group>-<bundle_id>", kSecAttrService = "Microsoft Credentials")`.
///
/// Both blobs are JSON-encoded and grow as more accounts/tenants are added.
/// The login.keychain does not impose a hard size cap on the `kSecValueData`
/// field, so this is the preferred strategy for OFEM's multi-account,
/// multi-tenant use case.
///
/// ## Alternative: file-backed storage (manual opt-in, not an automatic fallback)
///
/// ``.fileBackedFallback`` delegates to `OfemKit`'s ``FileTokenStore``: MSAL's
/// cache is serialised and de-serialised via `MSALSerializedADALCacheProviding`,
/// and the raw bytes are stored under `<configDir>/tokens/<alias>.bin`. The
/// `fcntl`+mutex machinery behind it is real, cross-process-safe, and covered
/// by tests (``FileTokenStore``, `FileTokenStoreCacheDelegate`).
///
/// Despite the case's name, OFEM does **not** auto-select it: nothing probes
/// the login.keychain for availability or retries with this strategy after a
/// Keychain write/read failure. `cacheStrategy` defaults to `.msalKeychain`
/// everywhere it's threaded through (``OfemAuth``, `MsalAuthClient`,
/// `InteractiveSignIn`), and no production call site overrides that default —
/// `.fileBackedFallback` is exercised only by unit tests today (investigated
/// as part of #449). It remains available as an explicit opt-in for a future
/// caller that wants file-backed storage deliberately, or for genuine
/// Keychain-unavailability detection if that is ever built — but until such a
/// caller exists, selecting it is something a caller must do on purpose.
public enum TokenCacheStrategy: Sendable {
    /// Use MSAL's native macOS login.keychain cache (recommended, and the
    /// default — the only strategy any production call site selects today).
    ///
    /// MSAL writes two `kSecClassGenericPassword` blobs to the login.keychain
    /// via the ACL-based `MSIDMacACLKeychainAccessor`. The login.keychain
    /// supports arbitrary data sizes, so this strategy works for any
    /// realistic number of accounts and tenants.
    case msalKeychain

    /// File-backed alternative to `.msalKeychain`, via `OfemKit`'s
    /// ``FileTokenStore``. MSAL's serialised cache bytes are written to
    /// `<configDir>/tokens/<alias>.bin` via an `MSALSerializedADALCacheProviding`
    /// bridge.
    ///
    /// Must be selected explicitly — see the type-level doc above for why
    /// this is not an automatic fallback despite the name. No production
    /// caller passes this today; only unit tests do.
    case fileBackedFallback
}
