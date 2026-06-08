// AccountInfo.swift
// Lightweight value types for account and paused-workspace data
// displayed in the menu-bar UI.
//
// Previously these lived in apple/Shared/StatusTypes.swift as Go IPC
// wire types. After the Swift migration (Fase 7.3b-2) there is no
// IPC layer; the types are kept here as plain Swift structs used
// exclusively by the host-app UI layer.

import Foundation

// MARK: - AccountInfo

/// One account entry displayed in the menu-bar dropdown.
///
/// Constructed from an ``OfemKit/Account`` by ``MenuStatusModel``; not
/// serialised over any transport.
public struct AccountInfo: Identifiable {
    public var id: String { alias }
    public let alias: String
    public let username: String
    public let tenantId: String
    public let tenantName: String

    public init(alias: String, username: String, tenantId: String, tenantName: String) {
        self.alias = alias
        self.username = username
        self.tenantId = tenantId
        self.tenantName = tenantName
    }
}

// MARK: - PausedWorkspaceInfo

/// A Fabric capacity workspace that is temporarily paused.
///
/// Paused-workspace detection is emitted by the Swift sync engine;
/// this type is kept as a placeholder for the menu-bar paused-badge
/// feature until the engine emits status updates.
public struct PausedWorkspaceInfo {
    public let accountAlias: String
    public let workspaceId: String
    public let reason: String
    public let detectedAt: Date
    public let probedAt: Date?

    public init(
        accountAlias: String,
        workspaceId: String,
        reason: String,
        detectedAt: Date,
        probedAt: Date? = nil
    ) {
        self.accountAlias = accountAlias
        self.workspaceId = workspaceId
        self.reason = reason
        self.detectedAt = detectedAt
        self.probedAt = probedAt
    }
}
