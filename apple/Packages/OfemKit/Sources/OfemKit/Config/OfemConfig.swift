import Foundation
import TOMLKit

// MARK: - Top-level config

/// The on-disk OFEM configuration schema, loaded from `config.toml`.
///
/// New fields must be backwards-compatible: add with sensible zero-value
/// defaults rather than removing or renaming existing fields. The TOML
/// schema is shared with the Go daemon (`internal/config/config.go`) so
/// both implementations must agree on key names at all times.
///
/// Mirrors `internal/config/config.go` — `File`.
public struct OfemConfig: Codable, Sendable {
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

    // MARK: Coding keys — must match the TOML/Go field names exactly.

    enum CodingKeys: String, CodingKey {
        case installID = "install_id"
        case telemetry
        case defaultAccount = "default_account"
        case cache
        case net
        case log
        case accounts
    }

    // MARK: Initialisers

    /// Returns the zero-but-sensible config used when OFEM starts for the
    /// first time. Callers should persist this after generating `installID`.
    ///
    /// Mirrors `internal/config/config.go` — `Default()`.
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
///
/// **Legacy migration**: pre-2026.06 configs used `max_size_bytes` (raw
/// `Int64`). ``OfemConfigStore`` migrates those on first read, converting
/// to whole GBs with ceiling rounding so a customised limit never shrinks
/// below what the user originally set. After migration the legacy key is
/// dropped from disk.
///
/// Mirrors `internal/config/config.go` — `CacheConfig`.
public struct CacheConfig: Codable, Sendable {
    /// Lower bound for the cache size limit (1 GB).
    public static let minSizeGB = 1
    /// Upper bound for the cache size limit (100 GB).
    public static let maxSizeGB = 100
    /// Default size for new installations (10 GB, matching Go default).
    public static let defaultSizeGB = 10

    /// The LRU eviction threshold in binary gigabytes.
    /// `0` means "no limit" (eviction is a no-op).
    public var maxSizeGB: Int

    /// Returns the cache size limit in bytes for callers that need
    /// byte-precision. `0` means "no limit".
    ///
    /// Mirrors `internal/config/config.go` — `CacheConfig.MaxBytes()`.
    public var maxBytes: Int64 { Int64(maxSizeGB) * bytesPerGB }

    enum CodingKeys: String, CodingKey {
        case maxSizeGB = "max_size_gb"
    }

    public init(maxSizeGB: Int) {
        self.maxSizeGB = maxSizeGB
    }

    // MARK: - Private

    private let bytesPerGB: Int64 = 1024 * 1024 * 1024
}

// MARK: - NetConfig

/// Controls HTTP behaviour to OneLake and Fabric endpoints.
///
/// Mirrors `internal/config/config.go` — `NetConfig`.
public struct NetConfig: Codable, Sendable {
    /// Caps parallel sync-put calls per account. Default 4.
    public var maxConcurrentUploadsPerAccount: Int

    /// Caps parallel sync-open calls per account. Default 8.
    public var maxConcurrentDownloadsPerAccount: Int

    enum CodingKeys: String, CodingKey {
        case maxConcurrentUploadsPerAccount = "max_concurrent_uploads_per_account"
        case maxConcurrentDownloadsPerAccount = "max_concurrent_downloads_per_account"
    }

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
///
/// Mirrors `internal/config/config.go` — `LogConfig`.
public struct LogConfig: Codable, Sendable {
    /// Log level: one of `"debug"`, `"info"`, `"warn"`, `"error"`.
    /// Default `"info"`.
    public var level: String

    public init(level: String) {
        self.level = level
    }
}

// MARK: - Account

/// One signed-in OneLake account, scoped to a single tenant.
/// Multiple accounts in the same tenant are supported via distinct aliases.
///
/// Mirrors `internal/config/config.go` — `Account`.
public struct Account: Codable, Sendable {
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
    /// telemetry.
    public var username: String

    /// Wall-clock timestamp of the first successful login.
    public var addedAt: String

    /// The Entra App Registration client GUID this account authenticated
    /// against. `nil` or empty means "use the built-in OFEM registration".
    /// Persisted because MSAL's token cache is keyed on (client, tenant,
    /// account), so silent refresh must use the same client ID as the
    /// original login.
    public var clientID: String?

    enum CodingKeys: String, CodingKey {
        case alias
        case tenantID = "tenant_id"
        case tenantName = "tenant_name"
        case homeAccountID = "home_account_id"
        case username
        case addedAt = "added_at"
        case clientID = "client_id"
    }

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

// MARK: - OfemConfigStore

/// Thread-safe store that loads and saves ``OfemConfig`` from/to
/// `<configDir>/config.toml`.
///
/// The config is read atomically on `load`, mutated through
/// ``updateAndSave(_:)``, and written via a temp-file-then-rename sequence
/// with 0600 permissions — exactly as the Go `Store` does.
///
/// Mirrors `internal/config/config.go` — `Store`.
public final class OfemConfigStore: Sendable {
    private let paths: OfemPaths
    private let lock = NSLock()
    // Non-isolated mutable state guarded by `lock`.
    private nonisolated(unsafe) var config: OfemConfig

    // MARK: - Initialisers

    /// Loads the config from the canonical paths. If the file does not exist
    /// a default config is returned; call ``updateAndSave(_:)`` to persist it.
    ///
    /// - Throws: ``OfemConfigError`` on TOML parse failures or I/O errors.
    public convenience init() throws {
        try self.init(paths: OfemPaths())
    }

    /// Loads from explicit paths. Use in tests or sandboxed callers that
    /// resolve their App Group container via Apple's API.
    ///
    /// - Throws: ``OfemConfigError`` on TOML parse failures or I/O errors.
    public init(paths: OfemPaths) throws {
        self.paths = paths
        self.config = try Self.load(from: paths)
    }

    // MARK: - Public API

    /// Returns a snapshot copy of the current config. Mutations on the
    /// returned value do not affect the store.
    ///
    /// Mirrors `internal/config/config.go` — `Store.Snapshot()`.
    public func snapshot() -> OfemConfig {
        lock.withLock { config }
    }

    /// Applies `mutator` to the current config and persists the result
    /// atomically. The lock is held across both the mutation and the
    /// encode+rename so concurrent writers cannot interleave.
    /// The mutator must not call back into the store.
    ///
    /// Mirrors `internal/config/config.go` — `Store.UpdateAndSave()`.
    @discardableResult
    public func updateAndSave(_ mutator: (inout OfemConfig) -> Void) throws -> OfemConfig {
        try lock.withLock {
            mutator(&config)
            try Self.save(config, to: paths)
            return config
        }
    }

    // MARK: - Private helpers

    private static func load(from paths: OfemPaths) throws -> OfemConfig {
        var cfg = OfemConfig.makeDefault()

        let data: Data
        do {
            data = try Data(contentsOf: paths.configFile)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            // File doesn't exist yet — return the default.
            return cfg
        } catch {
            throw OfemConfigError.readFailed(error)
        }

        guard let tomlString = String(data: data, encoding: .utf8) else {
            throw OfemConfigError.invalidUTF8
        }

        // Decode. We need to handle the legacy `max_size_bytes` key, which is
        // not part of the canonical CacheConfig.CodingKeys. We use a temporary
        // intermediate type to detect and migrate it. toOfemConfig() handles
        // both the new and legacy schemas as well as the default-seeding case.
        do {
            let raw = try TOMLDecoder().decode(RawConfig.self, from: tomlString)
            cfg = raw.toOfemConfig()
        } catch {
            throw OfemConfigError.parseFailed(error)
        }

        return cfg
    }

    private static func save(_ cfg: OfemConfig, to paths: OfemPaths) throws {
        let fm = FileManager.default

        // Ensure the config directory exists.
        do {
            try fm.createDirectory(at: paths.configDir, withIntermediateDirectories: true, attributes: [
                .posixPermissions: 0o700,
            ])
        } catch {
            throw OfemConfigError.createDirectoryFailed(error)
        }

        // Encode to TOML.
        let tomlString: String
        do {
            tomlString = try TOMLEncoder().encode(cfg)
        } catch {
            throw OfemConfigError.encodeFailed(error)
        }

        guard let data = tomlString.data(using: .utf8) else {
            throw OfemConfigError.encodeFailed(
                NSError(domain: "OfemKit", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "TOML output is not valid UTF-8",
                ])
            )
        }

        // Write to a temp file in the same directory and atomically rename so
        // a crash mid-write never leaves a half-written config file.
        let tmpURL = paths.configDir.appending(
            path: "config.toml.\(ProcessInfo.processInfo.globallyUniqueString)",
            directoryHint: .notDirectory
        )

        do {
            try data.write(to: tmpURL, options: .atomic)
        } catch {
            throw OfemConfigError.writeFailed(error)
        }

        do {
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tmpURL.path(percentEncoded: false))
        } catch {
            try? fm.removeItem(at: tmpURL)
            throw OfemConfigError.chmodFailed(error)
        }

        do {
            _ = try fm.replaceItemAt(paths.configFile, withItemAt: tmpURL)
        } catch {
            try? fm.removeItem(at: tmpURL)
            throw OfemConfigError.renameFailed(error)
        }
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
    case invalidUTF8
}

// MARK: - Raw intermediate types for legacy migration

/// Intermediate decoding type that captures both the canonical `max_size_gb`
/// key and the legacy `max_size_bytes` key from the `[cache]` TOML table.
/// After decoding, `toOfemConfig()` performs the GB migration if needed.
private struct RawConfig: Decodable {
    var installID: String
    var telemetry: Bool
    var defaultAccount: String
    var cache: RawCacheConfig
    var net: NetConfig
    var log: LogConfig
    var accounts: [String: Account]

    enum CodingKeys: String, CodingKey {
        case installID = "install_id"
        case telemetry
        case defaultAccount = "default_account"
        case cache
        case net
        case log
        case accounts
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        installID = try c.decodeIfPresent(String.self, forKey: .installID) ?? ""
        telemetry = try c.decodeIfPresent(Bool.self, forKey: .telemetry) ?? true
        defaultAccount = try c.decodeIfPresent(String.self, forKey: .defaultAccount) ?? ""
        // Decode cache separately to handle both new and legacy keys.
        cache = try c.decodeIfPresent(RawCacheConfig.self, forKey: .cache) ?? RawCacheConfig()
        net = try c.decodeIfPresent(NetConfig.self, forKey: .net) ?? NetConfig(
            maxConcurrentUploadsPerAccount: 4,
            maxConcurrentDownloadsPerAccount: 8
        )
        log = try c.decodeIfPresent(LogConfig.self, forKey: .log) ?? LogConfig(level: "info")
        accounts = try c.decodeIfPresent([String: Account].self, forKey: .accounts) ?? [:]
    }

    func toOfemConfig() -> OfemConfig {
        // Resolve `maxSizeGB` from the raw cache, performing the legacy
        // `max_size_bytes` migration.
        let resolvedGB: Int
        if let gb = cache.maxSizeGB, gb > 0 {
            // New schema: use as-is.
            resolvedGB = gb
        } else if let legacyBytes = cache.maxSizeBytes, legacyBytes > 0 {
            // Legacy schema: convert bytes → GB with ceiling rounding so a
            // user's customised limit never silently shrinks.
            let bytesPerGB: Int64 = 1024 * 1024 * 1024
            let gbFloat = Double(legacyBytes) / Double(bytesPerGB)
            let ceiled = Int(ceil(gbFloat))
            resolvedGB = max(ceiled, CacheConfig.minSizeGB)
        } else {
            // Both absent or zero — seed the default.
            resolvedGB = CacheConfig.defaultSizeGB
        }

        return OfemConfig(
            installID: installID,
            telemetry: telemetry,
            defaultAccount: defaultAccount,
            cache: CacheConfig(maxSizeGB: resolvedGB),
            net: net,
            log: log,
            accounts: accounts
        )
    }
}

private struct RawCacheConfig: Decodable {
    var maxSizeGB: Int?
    var maxSizeBytes: Int64?

    enum CodingKeys: String, CodingKey {
        case maxSizeGB = "max_size_gb"
        case maxSizeBytes = "max_size_bytes"
    }

    init() {
        maxSizeGB = nil
        maxSizeBytes = nil
    }
}
