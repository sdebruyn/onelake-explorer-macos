import Foundation

// MARK: - FabricClientProtocol

/// The subset of ``FabricClient`` that ``SyncEngine`` uses.
///
/// Defining a protocol makes ``SyncEngine`` testable without a live HTTP stack:
/// inject a mock conformance in tests and the concrete ``FabricClient`` in
/// production.
///
/// **fabric-05:** `listAllFolders` is now part of the protocol so
/// ``SyncEngine`` can depend on it through the mockable seam.
public protocol FabricClientProtocol: Sendable {
    /// Returns every workspace the principal can see.
    func listAllWorkspaces(alias: String) async throws -> [Workspace]

    /// Returns all items in a workspace.
    func listAllItems(alias: String, workspaceID: String) async throws -> [Item]

    /// Returns all workspace-level folders in a workspace.
    // periphery:ignore
    func listAllFolders(alias: String, workspaceID: String) async throws -> [Folder]
}

// MARK: - FabricClient conformance

extension FabricClient: FabricClientProtocol {}
