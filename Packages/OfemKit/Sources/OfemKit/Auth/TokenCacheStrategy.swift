import Foundation

// MARK: - TokenCacheStrategy

/// Selects how MSAL token cache data is persisted on disk.
///
/// ## Background
///
/// MSAL Swift on macOS stores its token cache as two JSON blobs in the
/// macOS **login.keychain** (not the iCloud Keychain). The login.keychain
/// uses `SecKeychainItem` ACL APIs and does **not** have the ~16 KB
/// per-item size limit that applies to iCloud Keychain sync items.
///
/// By contrast, MSAL Go stores its serialised token cache as a single flat
/// blob via `go-keyring`, which used `SecItemAdd` against the iCloud-sync
/// path and hit the 16 KB limit after a single Entra login (see
/// `internal/auth/keychain.go` comment). That is why the Go implementation
/// switched to a file-backed store.
///
/// ## MSAL Swift on macOS: architecture
///
/// `MSIDMacKeychainTokenCache` (the backing store used by MSAL Swift on
/// macOS) stores **two** `kSecClassGenericPassword` items in the login.keychain:
///
/// 1. **Shared blob** — all refresh tokens and account records for all apps
///    sharing the `com.microsoft.identity.universalstorage` access group.
///    Key: `(kSecAttrAccount = "<access_group>", kSecAttrService = "Microsoft Credentials")`.
/// 2. **Non-shared blob** — access tokens, ID tokens, app metadata, and
///    account metadata scoped to this app bundle. Key:
///    `(kSecAttrAccount = "<access_group>-<bundle_id>", kSecAttrService = "Microsoft Credentials")`.
///
/// Both blobs are JSON-encoded and grow as more accounts/tenants are added.
/// The login.keychain does not impose a hard size cap on the `kSecValueData`
/// field, so this is the preferred strategy for OFEM's multi-account,
/// multi-tenant use case.
///
/// ## Fallback
///
/// If a future macOS release or an App Sandbox restriction prevents writes
/// to the login.keychain, the ``.fileBackedFallback`` strategy delegates
/// to `OfemKit`'s existing ``FileTokenStore``. In that case MSAL's cache
/// is serialised and de-serialised via `MSALSerializedADALCacheProviding`,
/// and the raw bytes are stored under `<configDir>/tokens/<alias>.bin`.
///
/// The active strategy is stored per-process; on a fresh install the
/// default (`.msalKeychain`) is tried first.
public enum TokenCacheStrategy: Sendable {
    /// Use MSAL's native macOS login.keychain cache (recommended).
    ///
    /// MSAL writes two `kSecClassGenericPassword` blobs to the login.keychain
    /// via the ACL-based `MSIDMacACLKeychainAccessor`. The login.keychain
    /// supports arbitrary data sizes, so this strategy works for any
    /// realistic number of accounts and tenants.
    case msalKeychain

    /// Fall back to `OfemKit`'s file-backed ``FileTokenStore``.
    ///
    /// Used when the login.keychain is unavailable (e.g. certain CI
    /// environments or edge-case sandbox configurations). MSAL's serialised
    /// cache bytes are written to `<configDir>/tokens/<alias>.bin` via an
    /// `MSALSerializedADALCacheProviding` bridge.
    ///
    /// This is the same storage scheme the Go daemon uses; selecting this
    /// strategy makes the on-disk token blobs cross-readable between the
    /// Go daemon and the Swift FPE during the dual-engine migration period
    /// (Phases 1–4).
    case fileBackedFallback
}
