import Foundation

// MARK: - Top-level config

/// The on-disk OFEM configuration schema, loaded from `config.toml`.
///
/// New fields must be backwards-compatible: add with sensible zero-value
/// defaults rather than removing or renaming existing fields.
public struct OfemConfig: Sendable {
    /// A locally generated UUIDv4 that pseudonymously identifies this OFEM
    /// installation in telemetry. Removed when the user runs
    /// `brew uninstall --zap ofem`.
    public var installID: String

    /// Toggles opt-out telemetry. Default `true`.
    public var telemetry: Bool

    /// The alias used when a command omits an explicit account.
    /// Empty means "no default; require explicit alias".
    public var defaultAccount: String

    /// Blob-cache settings.
    public var cache: CacheConfig

    /// HTTP-client settings.
    public var net: NetConfig

    /// Logging settings.
    public var log: LogConfig

    /// Per-account registry. The key is the user-chosen alias.
    public var accounts: [String: Account]

    // MARK: Initialisers

    /// Returns the zero-but-sensible config used when OFEM starts for the
    /// first time. Callers should persist this after generating `installID`.
    ///
    /// This is the single source of truth for all default field values.
    public static func makeDefault() -> OfemConfig {
        OfemConfig(
            installID: "",
            telemetry: true,
            defaultAccount: "",
            cache: CacheConfig(maxSizeGB: CacheConfig.defaultSizeGB),
            net: NetConfig(
                maxConcurrentUploadsPerAccount: 4,
                maxConcurrentDownloadsPerAccount: 8
            ),
            log: LogConfig(level: "info"),
            accounts: [:]
        )
    }

    public init(
        installID: String,
        telemetry: Bool,
        defaultAccount: String,
        cache: CacheConfig,
        net: NetConfig,
        log: LogConfig,
        accounts: [String: Account]
    ) {
        self.installID = installID
        self.telemetry = telemetry
        self.defaultAccount = defaultAccount
        self.cache = cache
        self.net = net
        self.log = log
        self.accounts = accounts
    }
}

// MARK: - CacheConfig

/// Controls the on-disk blob cache.
///
/// The LRU eviction threshold is expressed in whole gigabytes (1 GB =
/// 1 073 741 824 bytes, binary — matching what Finder and `du -h` show).
public struct CacheConfig: Sendable {
    /// Lower bound for the cache size limit (1 GB).
    /// Enforced at config load time and in the XPC setConfig handler.
    public static let minSizeGB = 1
    /// Upper bound for the cache size limit (100 GB).
    /// Enforced at config load time and in the XPC setConfig handler.
    public static let maxSizeGB = 100
    /// Default size for new installations (10 GB).
    public static let defaultSizeGB = 10

    /// The LRU eviction threshold in binary gigabytes.
    /// `0` means "no limit" (eviction is a no-op).
    public var maxSizeGB: Int

    /// Returns the cache size limit in bytes for callers that need
    /// byte-precision. `0` means "no limit".
    ///
    /// Capped to `Int64.max` to guard against overflow on absurdly large
    /// hand-edited values (e.g. `max_size_gb = 9999999999`).
    public var maxBytes: Int64 {
        guard maxSizeGB > 0 else { return 0 }
        let limit = Int64.max / bytesPerGB
        guard maxSizeGB <= limit else { return Int64.max }
        return Int64(maxSizeGB) * bytesPerGB
    }

    public init(maxSizeGB: Int) {
        self.maxSizeGB = maxSizeGB
    }

    // MARK: - Private

    private let bytesPerGB: Int64 = 1024 * 1024 * 1024
}

// MARK: - NetConfig

/// Controls HTTP behaviour to OneLake and Fabric endpoints.
public struct NetConfig: Sendable {
    /// Minimum allowed value for concurrent upload/download limits.
    public static let minConcurrent = 1
    /// Maximum allowed value for concurrent upload/download limits.
    public static let maxConcurrent = 64

    /// Caps parallel sync-put calls per account. Default 4.
    /// Clamped to `[minConcurrent, maxConcurrent]` at load time.
    public var maxConcurrentUploadsPerAccount: Int

    /// Caps parallel sync-open calls per account. Default 8.
    /// Clamped to `[minConcurrent, maxConcurrent]` at load time.
    public var maxConcurrentDownloadsPerAccount: Int

    public init(
        maxConcurrentUploadsPerAccount: Int,
        maxConcurrentDownloadsPerAccount: Int
    ) {
        self.maxConcurrentUploadsPerAccount = maxConcurrentUploadsPerAccount
        self.maxConcurrentDownloadsPerAccount = maxConcurrentDownloadsPerAccount
    }
}

// MARK: - LogConfig

/// Controls structured log output.
public struct LogConfig: Sendable {
    /// Recognised log-level strings, in ascending severity order.
    public static let validLevels: Set<String> = ["debug", "info", "warn", "error"]
    /// Fallback level applied when an unrecognised value is loaded from disk.
    public static let defaultLevel = "info"

    /// Log level: one of `"debug"`, `"info"`, `"warn"`, `"error"`.
    /// Unknown values loaded from disk are clamped to `"info"` at load time.
    public var level: String

    public init(level: String) {
        self.level = level
    }
}

// MARK: - Account

/// One signed-in OneLake account, scoped to a single tenant.
/// Multiple accounts in the same tenant are supported via distinct aliases.
///
/// ## On-disk PII note
///
/// `username` (the UPN, e.g. `"sam@contoso.com"`) is written in plaintext to
/// `config.toml`. The file is restricted to mode `0600` (owner read/write only)
/// and its parent directory to `0700`, which is consistent with how macOS
/// stores other per-user credentials (e.g. `.netrc`). The UPN is never
/// transmitted to telemetry. This on-disk exposure is an accepted trade-off:
/// the UPN is required for MSAL silent-refresh matching and for Finder display
/// labels, and no stronger at-rest encryption mechanism (e.g. Keychain) is
/// warranted here given the existing filesystem-level protection.
public struct Account: Sendable {
    /// The user-chosen short name (e.g. `"work"`, `"client-a"`). Matches the
    /// dictionary key and is duplicated here for convenience.
    public var alias: String

    /// The Microsoft Entra tenant GUID.
    public var tenantID: String

    /// A human-friendly tenant label, if known. Display only.
    public var tenantName: String?

    /// MSAL's unique per-user-per-tenant identifier.
    public var homeAccountID: String

    /// The UPN (e.g. `"sam@contoso.com"`). Display only — never emitted to
    /// telemetry. Stored in plaintext; see the struct-level note above.
    public var username: String

    /// Wall-clock timestamp of the first successful login.
    public var addedAt: String

    /// The Entra App Registration client GUID this account authenticated
    /// against. `nil` or empty means "use the built-in OFEM registration".
    /// Persisted because MSAL's token cache is keyed on (client, tenant,
    /// account), so silent refresh must use the same client ID as the
    /// original login.
    public var clientID: String?

    public init(
        alias: String,
        tenantID: String,
        tenantName: String? = nil,
        homeAccountID: String,
        username: String,
        addedAt: String,
        clientID: String? = nil
    ) {
        self.alias = alias
        self.tenantID = tenantID
        self.tenantName = tenantName
        self.homeAccountID = homeAccountID
        self.username = username
        self.addedAt = addedAt
        self.clientID = clientID
    }
}

// MARK: - Errors

/// Errors thrown by ``OfemConfigStore``.
public enum OfemConfigError: Error {
    case readFailed(Error)
    case parseFailed(Error)
    case encodeFailed(Error)
    case writeFailed(Error)
    case chmodFailed(Error)
    case renameFailed(Error)
    case createDirectoryFailed(Error)
    case lockFailed(Error)
    /// The cross-process `fcntl` file lock could not be acquired within
    /// the allowed timeout (~5 s). This indicates a wedged peer process
    /// holding the lock without releasing it.
    case lockTimeout
    case invalidUTF8
}
