import Foundation

// MARK: - Workspace

/// A Microsoft Fabric workspace returned by the Fabric REST API.
public struct Workspace: Sendable, Equatable {
    /// Workspace unique identifier (UUID).
    public let id: String
    /// User-visible workspace name.
    public let displayName: String
    /// Workspace type string (e.g. `"Workspace"`, `"PersonalWorkspace"`).
    public let type: String
    /// Optional workspace description.
    public let description: String
    /// Capacity ID the workspace is assigned to; empty when not assigned.
    public let capacityID: String
    /// Domain ID the workspace belongs to; empty when not set.
    public let domainID: String

    public init(
        id: String,
        displayName: String,
        type: String,
        description: String = "",
        capacityID: String = "",
        domainID: String = ""
    ) {
        self.id = id
        self.displayName = displayName
        self.type = type
        self.description = description
        self.capacityID = capacityID
        self.domainID = domainID
    }
}

// MARK: - Item

/// A Fabric item (Lakehouse, Warehouse, Notebook, …) inside a workspace.
public struct Item: Sendable, Equatable {
    /// Item unique identifier (UUID).
    public let id: String
    /// User-visible item name.
    public let displayName: String
    /// Item type string (e.g. `"Lakehouse"`, `"Notebook"`).
    public let type: String
    /// Optional item description.
    public let description: String
    /// The workspace this item belongs to.
    public let workspaceID: String
    /// Optional workspace-folder ID this item is placed in.
    public let parentFolderID: String

    public init(
        id: String,
        displayName: String,
        type: String,
        description: String = "",
        workspaceID: String,
        parentFolderID: String = ""
    ) {
        self.id = id
        self.displayName = displayName
        self.type = type
        self.description = description
        self.workspaceID = workspaceID
        self.parentFolderID = parentFolderID
    }
}

// MARK: - Folder

/// A Fabric workspace-folder — the workspace-level organisational container
/// that groups items. Distinct from item-internal folders served by the DFS API.
public struct Folder: Sendable, Equatable {
    /// Folder unique identifier (UUID).
    public let id: String
    /// User-visible folder name.
    public let displayName: String
    /// The workspace this folder belongs to.
    public let workspaceID: String
    /// Parent folder ID; empty for top-level folders.
    public let parentFolderID: String

    public init(
        id: String,
        displayName: String,
        workspaceID: String,
        parentFolderID: String = ""
    ) {
        self.id = id
        self.displayName = displayName
        self.workspaceID = workspaceID
        self.parentFolderID = parentFolderID
    }
}

// MARK: - Page types

/// A single page of workspaces returned by the Fabric REST API.
///
/// Use ``FabricClient/listWorkspaces(alias:continuation:)`` to fetch pages one
/// at a time, or ``FabricClient/listAllWorkspaces(alias:)`` to follow
/// pagination to completion automatically.
public struct WorkspacePage: Sendable {
    /// The workspaces on this page.
    public let items: [Workspace]
    /// Opaque token to retrieve the next page; `nil` when this is the last page.
    public let continuationToken: String?

    public init(items: [Workspace], continuationToken: String?) {
        self.items = items
        self.continuationToken = continuationToken
    }
}

/// A single page of items returned by the Fabric REST API.
public struct ItemPage: Sendable {
    /// The items on this page.
    public let items: [Item]
    /// Opaque token to retrieve the next page; `nil` when this is the last page.
    public let continuationToken: String?

    public init(items: [Item], continuationToken: String?) {
        self.items = items
        self.continuationToken = continuationToken
    }
}

/// A single page of folders returned by the Fabric REST API.
public struct FolderPage: Sendable {
    /// The folders on this page.
    public let items: [Folder]
    /// Opaque token to retrieve the next page; `nil` when this is the last page.
    public let continuationToken: String?

    public init(items: [Folder], continuationToken: String?) {
        self.items = items
        self.continuationToken = continuationToken
    }
}

// MARK: - Wire types (private to Fabric module)

/// Common shape of a paged Fabric collection response.
struct FabricPageResponse<T: Decodable>: Decodable {
    let value: [T]
    let continuationToken: String?
    let continuationUri: String?
}

/// Wire representation of a ``Workspace`` as returned by the Fabric REST API.
struct WireWorkspace: Decodable {
    let id: String
    let displayName: String
    let type: String?
    let description: String?
    let capacityId: String?
    let domainId: String?

    func toWorkspace() -> Workspace {
        Workspace(
            id: id,
            displayName: displayName,
            type: type ?? "",
            description: description ?? "",
            capacityID: capacityId ?? "",
            domainID: domainId ?? ""
        )
    }
}

/// Wire representation of an ``Item`` as returned by the Fabric REST API.
struct WireItem: Decodable {
    let id: String
    let displayName: String
    let type: String?
    let description: String?
    let workspaceId: String
    let folderId: String?

    func toItem() -> Item {
        Item(
            id: id,
            displayName: displayName,
            type: type ?? "",
            description: description ?? "",
            workspaceID: workspaceId,
            parentFolderID: folderId ?? ""
        )
    }
}

/// Wire representation of a ``Folder`` as returned by the Fabric REST API.
struct WireFolder: Decodable {
    let id: String
    let displayName: String
    let workspaceId: String
    let parentFolderId: String?

    func toFolder() -> Folder {
        Folder(
            id: id,
            displayName: displayName,
            workspaceID: workspaceId,
            parentFolderID: parentFolderId ?? ""
        )
    }
}
