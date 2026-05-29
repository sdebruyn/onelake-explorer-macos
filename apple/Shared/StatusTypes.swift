// StatusTypes.swift
// Wire types for the "status", "account.list", and "config.snapshot" IPC
// methods, shared by the host app and (for compilation completeness) the File
// Provider Extension. The extension never calls these methods; the types live
// here so CoreBridge compiles cleanly in both targets.

import Foundation

// MARK: - status

/// On-disk locations the menu-bar app can surface to the user.
/// Mirrors the Go StatusPaths struct in internal/daemon/handlers.go.
public struct StatusPaths: Decodable {
    public let configFile: String
    public let cacheDir: String
    public let logDir: String

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        configFile = (try c.decodeIfPresent(String.self, forKey: .configFile)) ?? ""
        cacheDir = (try c.decodeIfPresent(String.self, forKey: .cacheDir)) ?? ""
        logDir = (try c.decodeIfPresent(String.self, forKey: .logDir)) ?? ""
    }

    private enum CodingKeys: String, CodingKey {
        case configFile, cacheDir, logDir
    }
}

/// Decoded result of the "status" IPC method.
public struct StatusInfo: Decodable {
    public let daemonVersion: String
    public let offline: Bool
    public let cacheBytes: Int64
    public let cacheMaxBytes: Int64
    public let pausedWorkspaces: [PausedWorkspaceInfo]
    /// File-system locations; absent on older daemon builds (falls back to empty strings).
    public let paths: StatusPaths

    private enum CodingKeys: String, CodingKey {
        case daemonVersion, offline, cacheBytes, cacheMaxBytes, pausedWorkspaces, paths
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        daemonVersion = (try c.decodeIfPresent(String.self, forKey: .daemonVersion)) ?? ""
        offline = (try c.decodeIfPresent(Bool.self, forKey: .offline)) ?? false
        cacheBytes = (try c.decodeIfPresent(Int64.self, forKey: .cacheBytes)) ?? -1
        cacheMaxBytes = (try c.decodeIfPresent(Int64.self, forKey: .cacheMaxBytes)) ?? 0
        pausedWorkspaces = (try c.decodeIfPresent([PausedWorkspaceInfo].self, forKey: .pausedWorkspaces)) ?? []
        paths = (try c.decodeIfPresent(StatusPaths.self, forKey: .paths)) ?? StatusPaths()
    }
}

extension StatusPaths {
    /// Memberwise init used as a fallback when the daemon omits the paths key.
    init() {
        configFile = ""
        cacheDir = ""
        logDir = ""
    }
}

public struct PausedWorkspaceInfo: Decodable {
    public let accountAlias: String
    public let workspaceId: String
    public let reason: String
}

// MARK: - account.list

/// Decoded result of the "account.list" IPC method, including the default alias.
public struct AccountListInfo: Decodable {
    public let accounts: [AccountInfo]
    public let defaultAccount: String

    private enum CodingKeys: String, CodingKey {
        case accounts, defaultAccount
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        accounts = (try c.decodeIfPresent([AccountInfo].self, forKey: .accounts)) ?? []
        defaultAccount = (try c.decodeIfPresent(String.self, forKey: .defaultAccount)) ?? ""
    }
}

/// One account entry in the "account.list" response. Richer than the existing
/// Account type (adds addedAt and is Identifiable via alias).
public struct AccountInfo: Decodable, Identifiable {
    public var id: String { alias }
    public let alias: String
    public let username: String
    public let tenantId: String
    public let tenantName: String

    private enum CodingKeys: String, CodingKey {
        case alias, username, tenantId, tenantName
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        alias = try c.decode(String.self, forKey: .alias)
        username = (try c.decodeIfPresent(String.self, forKey: .username)) ?? ""
        tenantId = (try c.decodeIfPresent(String.self, forKey: .tenantId)) ?? ""
        tenantName = (try c.decodeIfPresent(String.self, forKey: .tenantName)) ?? ""
    }
}

// MARK: - Private envelopes (used by CoreBridge; not part of the public API)

/// Top-level decoded shape for the "status" IPC call.
/// The daemon returns the status fields directly as the JSON-RPC result object.
struct StatusEnvelope: Decodable {
    let statusInfo: StatusInfo?
    let error: BridgeErrorPayload?

    // The daemon never puts both an error and a real result in the same
    // envelope; probe for the canonical "daemonVersion" key to distinguish.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: ProbingKey.self)
        if c.contains(ProbingKey("daemonVersion")) {
            statusInfo = try StatusInfo(from: decoder)
            error = nil
        } else {
            statusInfo = nil
            error = try c.decodeIfPresent(BridgeErrorPayload.self, forKey: ProbingKey("error"))
        }
    }
}

/// Top-level decoded shape for the "account.list" IPC call.
struct AccountListEnvelope: Decodable {
    let listInfo: AccountListInfo?
    let error: BridgeErrorPayload?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: ProbingKey.self)
        if c.contains(ProbingKey("accounts")) {
            listInfo = try AccountListInfo(from: decoder)
            error = nil
        } else {
            listInfo = nil
            error = try c.decodeIfPresent(BridgeErrorPayload.self, forKey: ProbingKey("error"))
        }
    }
}

/// A flexible CodingKey used to probe for known top-level JSON keys before
/// committing to a full typed decode. Accepts any string, int value unused.
private struct ProbingKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }
    init(_ s: String) { stringValue = s }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}

// MARK: - config.snapshot

/// Decoded result of the "config.snapshot" IPC method.
/// Only the fields the menu-bar UI needs are captured; the rest are ignored.
/// Mirrors ConfigSnapshotResponse in internal/daemon/handlers.go.
public struct ConfigInfo: Decodable {
    /// Whether anonymous telemetry is currently enabled (opt-out, default true).
    public let telemetryEnabled: Bool
    /// Configured LRU cache ceiling in bytes (0 means no limit).
    public let cacheMaxBytes: Int64

    private enum CodingKeys: String, CodingKey {
        // top-level "telemetry" bool
        case telemetry
        // nested "cache" object with "max_size_bytes" — handled manually below
        case cache
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        telemetryEnabled = (try c.decodeIfPresent(Bool.self, forKey: .telemetry)) ?? true
        // config.snapshot wraps cache as {"cache": {"max_size_bytes": N}}
        if let cacheObj = try c.decodeIfPresent(CachePayload.self, forKey: .cache) {
            cacheMaxBytes = cacheObj.maxSizeBytes
        } else {
            cacheMaxBytes = 0
        }
    }

    private struct CachePayload: Decodable {
        // Go toml:"max_size_bytes" serialises to snake_case JSON from Go
        // encoding/json only when there is an explicit json tag. The daemon
        // uses the toml tag but Go's encoding/json ignores toml tags —
        // it lowercases the field name. Actual key on the wire: "maxSizeBytes"
        // (camelCase, because Go lowercases the exported field name without a
        // json tag producing "maxSizeBytes" is NOT correct; Go encoding/json
        // lowercases only the first rune → "maxSizeBytes"). Check real Go
        // behaviour: CacheConfig.MaxSizeBytes without a json tag → "MaxSizeBytes".
        // But the daemon registers json tags via config.go — look up the real tag.
        let maxSizeBytes: Int64

        private enum CodingKeys: String, CodingKey {
            // config.CacheConfig has toml:"max_size_bytes" but no json tag,
            // so Go encoding/json emits the struct field name as-is: "MaxSizeBytes".
            case maxSizeBytes = "MaxSizeBytes"
        }
    }
}

/// Top-level decoded shape for the "config.snapshot" IPC call.
struct ConfigSnapshotEnvelope: Decodable {
    let configInfo: ConfigInfo?
    let error: BridgeErrorPayload?

    // Probe for "telemetry" to distinguish a real result from an error object.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: ProbingKey.self)
        if c.contains(ProbingKey("telemetry")) {
            configInfo = try ConfigInfo(from: decoder)
            error = nil
        } else {
            configInfo = nil
            error = try c.decodeIfPresent(BridgeErrorPayload.self, forKey: ProbingKey("error"))
        }
    }
}

// BridgeErrorPayload is defined in CoreBridge.swift (internal visibility)
// and is visible here because both files compile into the same module.
