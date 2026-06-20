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

    /// `true` when this item has its own OneLake DFS storage path
    /// (`/{workspaceGUID}/{itemGUID}/…`) and should appear as a browsable
    /// folder in Finder.
    ///
    /// Uses a strict **allowlist**: only `Lakehouse`, `Warehouse`,
    /// `MirroredDatabase`, and `SQLDatabase` are shown. All other item types —
    /// including types that have OneLake storage but are not yet supported
    /// (e.g. `KQLDatabase`, `Eventhouse`, `MirroredWarehouse`) — are hidden
    /// until explicitly added here.
    ///
    /// `SQLDatabase` auto-replicates all its tables to OneLake as read-only
    /// Delta tables, making it a fully OneLake-backed item type.
    ///
    /// Comparison is **case-insensitive**: a casing drift in the Fabric REST API
    /// response can never hide a user's storage item.
    ///
    /// Source: Fabric REST API `ItemType` enumeration
    /// (https://learn.microsoft.com/en-us/rest/api/fabric/core/items/list-items?WT.mc_id=MVP_310840#itemtype)
    public var hasOneLakeStorage: Bool {
        Self.allowedStorageTypes.contains(type.lowercased(with: Self.posixLocale))
    }

    /// `true` when the item type is `"Lakehouse"` (case-insensitive).
    ///
    /// Use this predicate wherever `"lakehouse"` must be checked to avoid
    /// duplicating the locale-independent string comparison.
    public var isLakehouse: Bool {
        type.lowercased(with: Self.posixLocale) == "lakehouse"
    }

    /// Shared POSIX locale for case-insensitive item-type comparisons.
    private static let posixLocale = Locale(identifier: "en_US_POSIX")

    /// Lowercased canonical forms of the four item types surfaced in Finder.
    private static let allowedStorageTypes: Set<String> = [
        "lakehouse",
        "warehouse",
        "mirroreddatabase",
        "sqldatabase",
    ]
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
///
/// **fabric-04:** when `continuationToken` is `nil` but `hasContinuation` is
/// `true`, the server returned a `continuationUri`-only response. The next-page
/// URI cannot be represented as an opaque token. Use
/// ``FabricClient/listAllWorkspaces(alias:)`` to follow pagination exhaustively
/// via either continuation form.
public struct WorkspacePage: Sendable {
    /// The workspaces on this page.
    public let items: [Workspace]
    /// Opaque token to retrieve the next page; `nil` when this is the last page
    /// **or** when the server returned only a `continuationUri` (see `hasContinuation`).
    public let continuationToken: String?
    /// `true` when more pages exist (either via `continuationToken` or
    /// `continuationUri`). Use the exhaust-all variants to follow both forms.
    public let hasContinuation: Bool

    public init(items: [Workspace], continuationToken: String?, hasContinuation: Bool = false) {
        self.items = items
        self.continuationToken = continuationToken
        self.hasContinuation = hasContinuation
    }
}

/// A single page of items returned by the Fabric REST API.
///
/// **fabric-04:** see `hasContinuation` — a `nil` token does not always mean
/// last page.
public struct ItemPage: Sendable {
    /// The items on this page.
    public let items: [Item]
    /// Opaque token to retrieve the next page; `nil` when last page or when
    /// only a `continuationUri` is available.
    public let continuationToken: String?
    /// `true` when more pages exist (either via token or URI).
    public let hasContinuation: Bool

    public init(items: [Item], continuationToken: String?, hasContinuation: Bool = false) {
        self.items = items
        self.continuationToken = continuationToken
        self.hasContinuation = hasContinuation
    }
}

/// A single page of folders returned by the Fabric REST API.
///
/// **fabric-04:** see `hasContinuation` — a `nil` token does not always mean
/// last page.
public struct FolderPage: Sendable {
    /// The folders on this page.
    public let items: [Folder]
    /// Opaque token to retrieve the next page; `nil` when last page or when
    /// only a `continuationUri` is available.
    public let continuationToken: String?
    /// `true` when more pages exist (either via token or URI).
    public let hasContinuation: Bool

    public init(items: [Folder], continuationToken: String?, hasContinuation: Bool = false) {
        self.items = items
        self.continuationToken = continuationToken
        self.hasContinuation = hasContinuation
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
///
/// **fabric-06:** `id` and `displayName` are made optional so that a single
/// workspace row with a missing or null field does not abort the entire page
/// decode. Rows lacking an `id` are silently dropped in `toWorkspace()?`.
struct WireWorkspace: Decodable {
    let id: String?
    let displayName: String?
    let type: String?
    let description: String?
    let capacityId: String?
    let domainId: String?

    /// Returns a `Workspace` or `nil` when required fields are absent.
    func toWorkspace() -> Workspace? {
        guard let id = id, !id.isEmpty else { return nil }
        return Workspace(
            id: id,
            displayName: displayName ?? "",
            type: type ?? "",
            description: description ?? "",
            capacityID: capacityId ?? "",
            domainID: domainId ?? ""
        )
    }
}

/// Wire representation of an ``Item`` as returned by the Fabric REST API.
///
/// **fabric-06:** optional `id` and `displayName` for per-element resilience.
struct WireItem: Decodable {
    let id: String?
    let displayName: String?
    let type: String?
    let description: String?
    let workspaceId: String?
    let folderId: String?

    /// Returns an `Item` or `nil` when required fields are absent.
    func toItem() -> Item? {
        guard let id = id, !id.isEmpty,
              let workspaceId = workspaceId, !workspaceId.isEmpty else { return nil }
        return Item(
            id: id,
            displayName: displayName ?? "",
            type: type ?? "",
            description: description ?? "",
            workspaceID: workspaceId,
            parentFolderID: folderId ?? ""
        )
    }
}

/// Wire representation of a ``Folder`` as returned by the Fabric REST API.
///
/// **fabric-06:** optional `id`, `displayName`, `workspaceId` for per-element
/// resilience.
struct WireFolder: Decodable {
    let id: String?
    let displayName: String?
    let workspaceId: String?
    let parentFolderId: String?

    /// Returns a `Folder` or `nil` when required fields are absent.
    func toFolder() -> Folder? {
        guard let id = id, !id.isEmpty,
              let workspaceId = workspaceId, !workspaceId.isEmpty else { return nil }
        return Folder(
            id: id,
            displayName: displayName ?? "",
            workspaceID: workspaceId,
            parentFolderID: parentFolderId ?? ""
        )
    }
}
