import Foundation
import TOMLKit

// MARK: - Top-level config

/// The on-disk OFEM configuration schema, loaded from `config.toml`.
///
/// New fields must be backwards-compatible: add with sensible zero-value
/// defaults rather than removing or renaming existing fields.
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

    // MARK: Coding keys — must match the TOML field names exactly.

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
    /// This is the single source of truth for all default field values.
    /// `RawConfig` derives its own defaults from this function so there is
    /// exactly one place to update when a default changes.
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
public struct CacheConfig: Codable, Sendable {
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
        // Detect overflow: if gb > Int64.max / bytesPerGB, clamp to Int64.max.
        let limit = Int64.max / bytesPerGB
        guard maxSizeGB <= limit else { return Int64.max }
        return Int64(maxSizeGB) * bytesPerGB
    }

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
/// ## Cross-process safety
///
/// The host app and the File Provider Extension both write to the same
/// `config.toml` in the shared App Group container. `updateAndSave` uses a
/// POSIX advisory lock (`flock(2)`) on a sidecar `.config.lock` file to
/// serialise writers across processes:
///
/// 1. Acquire an exclusive lock on `.config.lock`.
/// 2. Re-read `config.toml` from disk (discard the stale in-memory snapshot).
/// 3. Apply the caller's mutation closure to the freshly loaded state.
/// 4. Write the result atomically (temp file + rename).
/// 5. Update the in-memory snapshot and release the lock.
///
/// This prevents a write from one process from silently reverting fields that
/// the other process wrote after the first process last loaded the file.
///
/// The in-process `NSLock` (`lock`) serialises concurrent Swift tasks/threads
/// within the same process; the `flock` on `.config.lock` serialises across
/// process boundaries.
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
    public func snapshot() -> OfemConfig {
        lock.withLock { config }
    }

    /// Applies `mutator` to the **freshly re-read on-disk state** and persists
    /// the result atomically.
    ///
    /// The sequence is:
    /// 1. Acquire the cross-process file lock (`.config.lock` sidecar).
    /// 2. Re-read `config.toml` from disk so any writes made by another
    ///    process since the last load are incorporated.
    /// 3. Call `mutator` on the fresh state.
    /// 4. Write the result atomically (temp file + rename).
    /// 5. Update the in-memory snapshot and release the lock.
    ///
    /// Concurrent callers within the same process are serialised by an
    /// `NSLock`; callers in different processes are serialised by `flock(2)`
    /// on the sidecar lock file.
    ///
    /// The mutator must not call back into the store.
    @discardableResult
    public func updateAndSave(_ mutator: (inout OfemConfig) throws -> Void) throws -> OfemConfig {
        try lock.withLock {
            // Acquire the cross-process exclusive file lock.
            let lockFD = try Self.acquireFileLock(paths: paths)
            defer { Self.releaseFileLock(lockFD) }

            // Re-read from disk to pick up changes made by the other process.
            var fresh = try Self.load(from: paths)

            // Apply the caller's mutation to the fresh state.
            try mutator(&fresh)

            // Persist atomically.
            try Self.save(fresh, to: paths)

            // Update the in-memory snapshot.
            config = fresh
            return config
        }
    }

    // MARK: - Cross-process file lock

    /// Acquires an exclusive POSIX advisory lock on `.config.lock` in the
    /// same directory as `config.toml`.
    ///
    /// Uses `fcntl(2)` with `F_SETLKW` (write-lock, blocking) rather than
    /// `flock(2)` to avoid a name collision with GRDB's `flock` struct.
    ///
    /// - Returns: An open file descriptor for the lock file. The caller is
    ///   responsible for releasing it via ``releaseFileLock(_:)``.
    private static func acquireFileLock(paths: OfemPaths) throws -> Int32 {
        let lockURL = paths.configDir.appending(
            path: ".config.lock",
            directoryHint: .notDirectory
        )

        // Ensure the config directory exists (mirrors save()'s own mkdir).
        let fm = FileManager.default
        if !fm.fileExists(atPath: paths.configDir.path(percentEncoded: false)) {
            do {
                try fm.createDirectory(
                    at: paths.configDir,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
            } catch {
                throw OfemConfigError.createDirectoryFailed(error)
            }
        }

        // O_CREAT | O_RDWR — create the lock file if it doesn't exist.
        let fd = Darwin.open(lockURL.path(percentEncoded: false), O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard fd >= 0 else {
            throw OfemConfigError.lockFailed(
                NSError(domain: NSPOSIXErrorDomain, code: Int(Darwin.errno))
            )
        }

        // F_SETLKW — set an exclusive write lock; blocks until available.
        // (Using fcntl rather than flock() to avoid a name collision with
        // GRDB's `flock` struct type that is in scope via the package graph.)
        var lk = Darwin.flock()
        lk.l_type   = Int16(F_WRLCK)
        lk.l_whence = Int16(SEEK_SET)
        lk.l_start  = 0
        lk.l_len    = 0 // Lock the whole file.

        guard Darwin.fcntl(fd, F_SETLKW, &lk) == 0 else {
            Darwin.close(fd)
            throw OfemConfigError.lockFailed(
                NSError(domain: NSPOSIXErrorDomain, code: Int(Darwin.errno))
            )
        }

        return fd
    }

    /// Releases the POSIX advisory lock and closes the file descriptor.
    private static func releaseFileLock(_ fd: Int32) {
        var lk = Darwin.flock()
        lk.l_type   = Int16(F_UNLCK)
        lk.l_whence = Int16(SEEK_SET)
        lk.l_start  = 0
        lk.l_len    = 0
        Darwin.fcntl(fd, F_SETLK, &lk)
        Darwin.close(fd)
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

        // Decode through RawConfig so missing top-level sections fall back to
        // sensible defaults instead of throwing.
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
    case lockFailed(Error)
    case invalidUTF8
}

// MARK: - Raw intermediate type

/// Intermediate decoding type so missing top-level sections fall back to
/// defaults instead of throwing.
///
/// Missing fields fall back to the values from ``OfemConfig/makeDefault()``
/// so there is exactly one source of truth for defaults.
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
        // Pull defaults from the canonical source so only one definition exists.
        let defaults = OfemConfig.makeDefault()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        installID     = try c.decodeIfPresent(String.self,            forKey: .installID)     ?? defaults.installID
        telemetry     = try c.decodeIfPresent(Bool.self,              forKey: .telemetry)     ?? defaults.telemetry
        defaultAccount = try c.decodeIfPresent(String.self,           forKey: .defaultAccount) ?? defaults.defaultAccount
        cache         = try c.decodeIfPresent(RawCacheConfig.self,    forKey: .cache)         ?? RawCacheConfig()
        net           = try c.decodeIfPresent(NetConfig.self,         forKey: .net)           ?? defaults.net
        log           = try c.decodeIfPresent(LogConfig.self,         forKey: .log)           ?? defaults.log
        accounts      = try c.decodeIfPresent([String: Account].self, forKey: .accounts)      ?? defaults.accounts
    }

    func toOfemConfig() -> OfemConfig {
        // Honor max_size_gb = 0 as "no limit" (eviction is a no-op in CacheStore
        // when maxBlobBytes == 0). Only absent cache sections fall back to the
        // default; an explicit 0 is preserved as the user's intent.
        let resolvedGB: Int
        if let gb = cache.maxSizeGB {
            // Explicit value in the file: clamp to [minSizeGB, maxSizeGB] or 0.
            // 0 is the special "no limit" sentinel and must not be clamped away.
            if gb == 0 {
                resolvedGB = 0
            } else {
                resolvedGB = min(max(gb, CacheConfig.minSizeGB), CacheConfig.maxSizeGB)
            }
        } else {
            // Section absent or max_size_gb key absent: use the default.
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

    enum CodingKeys: String, CodingKey {
        case maxSizeGB = "max_size_gb"
    }

    init() {
        maxSizeGB = nil
    }
}
