// StatusTypes.swift
// Wire types for the "status" and "account.list" IPC methods, shared by
// the host app and (for compilation completeness) the File Provider Extension.
// The extension never calls these methods; the types live here so CoreBridge
// compiles cleanly in both targets.

import Foundation

// MARK: - status

/// Decoded result of the "status" IPC method.
public struct StatusInfo: Decodable {
    public let daemonVersion: String
    public let offline: Bool
    public let cacheBytes: Int64
    public let cacheMaxBytes: Int64
    public let pausedWorkspaces: [PausedWorkspaceInfo]

    private enum CodingKeys: String, CodingKey {
        case daemonVersion, offline, cacheBytes, cacheMaxBytes, pausedWorkspaces
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        daemonVersion = (try c.decodeIfPresent(String.self, forKey: .daemonVersion)) ?? ""
        offline = (try c.decodeIfPresent(Bool.self, forKey: .offline)) ?? false
        cacheBytes = (try c.decodeIfPresent(Int64.self, forKey: .cacheBytes)) ?? -1
        cacheMaxBytes = (try c.decodeIfPresent(Int64.self, forKey: .cacheMaxBytes)) ?? 0
        pausedWorkspaces = (try c.decodeIfPresent([PausedWorkspaceInfo].self, forKey: .pausedWorkspaces)) ?? []
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

// BridgeErrorPayload is defined in CoreBridge.swift (internal visibility)
// and is visible here because both files compile into the same module.
