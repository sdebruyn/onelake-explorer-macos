import Foundation
import TOMLKit

// MARK: - Codable conformances for config schema types

//
// All conformances live here so the schema structs in ConfigSchema.swift remain
// free of encoding details, and so there is exactly ONE place to update when a
// field is added or renamed.
//
// Decoding strategy: `decodeIfPresent` with a fallback to `makeDefault()` for
// every optional field, so a partial TOML file (e.g. a hand-edited file that
// omits entire sections) never throws — it just inherits the factory default.
//
// Clamping strategy: performed inside the `init(from:)` of the owning type,
// not in a separate decoding shim, so the bounds are discoverable and testable
// on the type itself.

// MARK: OfemConfig

extension OfemConfig: Codable {
    enum CodingKeys: String, CodingKey {
        case installID = "install_id"
        case telemetry
        case defaultAccount = "default_account"
        case cache
        case net
        case log
        case sync
        case accounts
    }

    public init(from decoder: Decoder) throws {
        let defaults = OfemConfig.makeDefault()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        installID = try c.decodeIfPresent(String.self, forKey: .installID) ?? defaults.installID
        telemetry = try c.decodeIfPresent(Bool.self, forKey: .telemetry) ?? defaults.telemetry
        defaultAccount = try c.decodeIfPresent(String.self, forKey: .defaultAccount) ?? defaults.defaultAccount
        cache = try c.decodeIfPresent(CacheConfig.self, forKey: .cache) ?? defaults.cache
        net = try c.decodeIfPresent(NetConfig.self, forKey: .net) ?? defaults.net
        log = try c.decodeIfPresent(LogConfig.self, forKey: .log) ?? defaults.log
        sync = try c.decodeIfPresent(SyncConfig.self, forKey: .sync) ?? defaults.sync
        accounts = try c.decodeIfPresent([String: Account].self, forKey: .accounts) ?? defaults.accounts
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(installID, forKey: .installID)
        try c.encode(telemetry, forKey: .telemetry)
        try c.encode(defaultAccount, forKey: .defaultAccount)
        try c.encode(cache, forKey: .cache)
        try c.encode(net, forKey: .net)
        try c.encode(log, forKey: .log)
        try c.encode(sync, forKey: .sync)
        try c.encode(accounts, forKey: .accounts)
    }
}

// MARK: CacheConfig

extension CacheConfig: Codable {
    enum CodingKeys: String, CodingKey {
        case maxSizeGB = "max_size_gb"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // `decodeIfPresent` returns nil when the key is absent (e.g. the
        // entire [cache] section is missing). nil → default.
        // An explicit 0 is preserved: it signals "no limit", not "absent".
        if let rawGB = try c.decodeIfPresent(Int.self, forKey: .maxSizeGB) {
            if rawGB == 0 {
                maxSizeGB = 0
            } else {
                // Clamp hand-edited values to the documented [min, max] range.
                maxSizeGB = min(max(rawGB, CacheConfig.minSizeGB), CacheConfig.maxSizeGB)
            }
        } else {
            maxSizeGB = CacheConfig.defaultSizeGB
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(maxSizeGB, forKey: .maxSizeGB)
    }
}

// MARK: NetConfig

extension NetConfig: Codable {
    enum CodingKeys: String, CodingKey {
        case maxConcurrentUploadsPerAccount = "max_concurrent_uploads_per_account"
        case maxConcurrentDownloadsPerAccount = "max_concurrent_downloads_per_account"
    }

    public init(from decoder: Decoder) throws {
        let defaults = OfemConfig.makeDefault().net
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let rawUp = try c.decodeIfPresent(Int.self, forKey: .maxConcurrentUploadsPerAccount) ?? defaults.maxConcurrentUploadsPerAccount
        let rawDown = try c.decodeIfPresent(Int.self, forKey: .maxConcurrentDownloadsPerAccount) ?? defaults.maxConcurrentDownloadsPerAccount
        // Clamp to [1, 64] so a zero or negative value never creates a
        // zero-bound semaphore downstream. An absurdly large value (e.g. 999)
        // is also capped to avoid starving other consumers of the HTTP stack.
        maxConcurrentUploadsPerAccount = min(max(rawUp, NetConfig.minConcurrent), NetConfig.maxConcurrent)
        maxConcurrentDownloadsPerAccount = min(max(rawDown, NetConfig.minConcurrent), NetConfig.maxConcurrent)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(maxConcurrentUploadsPerAccount, forKey: .maxConcurrentUploadsPerAccount)
        try c.encode(maxConcurrentDownloadsPerAccount, forKey: .maxConcurrentDownloadsPerAccount)
    }
}

// MARK: LogConfig

extension LogConfig: Codable {
    enum CodingKeys: String, CodingKey {
        case level
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let raw = try c.decodeIfPresent(String.self, forKey: .level) ?? LogConfig.defaultLevel
        // Reject unknown level strings so a typo in the TOML doesn't
        // silently produce an unrecognised level that OfemEngine has to
        // handle further downstream.
        level = LogConfig.validLevels.contains(raw) ? raw : LogConfig.defaultLevel
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(level, forKey: .level)
    }
}

// MARK: SyncConfig

extension SyncConfig: Codable {
    enum CodingKeys: String, CodingKey {
        case materializedPollIntervalS = "materialized_poll_interval_s"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let raw = try c.decodeIfPresent(Int.self, forKey: .materializedPollIntervalS)
            ?? SyncConfig.defaultMaterializedPollIntervalS
        // Clamp to [min, max] so a hand-edited value is always valid.
        materializedPollIntervalS = max(
            SyncConfig.minMaterializedPollIntervalS,
            min(SyncConfig.maxMaterializedPollIntervalS, raw)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(materializedPollIntervalS, forKey: .materializedPollIntervalS)
    }
}

// MARK: Account

extension Account: Codable {
    enum CodingKeys: String, CodingKey {
        case alias
        case tenantID = "tenant_id"
        case tenantName = "tenant_name"
        case homeAccountID = "home_account_id"
        case username
        case addedAt = "added_at"
        case clientID = "client_id"
    }

    // Explicit synthesis required because the struct is declared in a
    // different file from this Codable conformance (Swift limitation).
    //
    // Field contract: `alias`, `tenantID`, `homeAccountID`, `username`, and
    // `addedAt` are required — a missing key throws `parseFailed` rather than
    // defaulting. `tenantName` and `clientID` are optional (`decodeIfPresent`).

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        alias = try c.decode(String.self, forKey: .alias)
        tenantID = try c.decode(String.self, forKey: .tenantID)
        tenantName = try c.decodeIfPresent(String.self, forKey: .tenantName)
        homeAccountID = try c.decode(String.self, forKey: .homeAccountID)
        username = try c.decode(String.self, forKey: .username)
        addedAt = try c.decode(String.self, forKey: .addedAt)
        clientID = try c.decodeIfPresent(String.self, forKey: .clientID)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(alias, forKey: .alias)
        try c.encode(tenantID, forKey: .tenantID)
        try c.encodeIfPresent(tenantName, forKey: .tenantName)
        try c.encode(homeAccountID, forKey: .homeAccountID)
        try c.encode(username, forKey: .username)
        try c.encode(addedAt, forKey: .addedAt)
        try c.encodeIfPresent(clientID, forKey: .clientID)
    }
}
