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

    /// Returns every workspace the principal can see, plus the count of wire
    /// elements dropped during decode for missing required fields (the
    /// fabric-06 leniency: a row missing `id` is dropped rather than aborting
    /// the whole page — see ``WireWorkspace/toWorkspace()``).
    ///
    /// `droppedCount > 0` means the listing is INCOMPLETE: a live workspace
    /// may be the element that got dropped, not one genuinely removed.
    /// Callers that treat absence-from-listing as authoritative for a
    /// destructive action (e.g. ``SyncEngine``'s workspace-orphan purge) must
    /// gate on `droppedCount == 0` rather than trust `workspaces` alone.
    ///
    /// Defaults to `(try await listAllWorkspaces(alias: alias), 0)` — always
    /// "complete" — so conformers that cannot observe per-element drops (test
    /// doubles built directly from a `[Workspace]` array) need no changes.
    func listAllWorkspacesDetailed(alias: String) async throws -> (workspaces: [Workspace], droppedCount: Int)

    /// Returns all items in a workspace.
    func listAllItems(alias: String, workspaceID: String) async throws -> [Item]

    /// Returns all workspace-level folders in a workspace.
    // periphery:ignore
    func listAllFolders(alias: String, workspaceID: String) async throws -> [Folder]
}

public extension FabricClientProtocol {
    func listAllWorkspacesDetailed(alias: String) async throws -> (workspaces: [Workspace], droppedCount: Int) {
        (try await listAllWorkspaces(alias: alias), 0)
    }
}

// MARK: - FabricClient conformance

extension FabricClient: FabricClientProtocol {}
