import Foundation

// MARK: - ItemIdentifier

/// A typed wrapper for a File Provider item identifier string.
///
/// The identifier grammar (mirroring `internal/fp/fp.go` — `parseIdentifier`):
///
/// ```
/// ""                   → .root
/// ".rootContainer"     → .root
/// "<ws>"               → .workspace(workspaceID: ws)
/// "<ws>/<item>"        → .item(workspaceID: ws, itemID: item)
/// "<ws>/<item>/<path>" → .path(workspaceID: ws, itemID: item, path: path)
/// ```
///
/// Identifiers are strictly validated on construction; any identifier with an
/// empty segment (double slash, leading slash) is rejected so callers surface
/// `noSuchItem` rather than a Fabric call with an empty ID.
public enum ItemIdentifier: Hashable, Sendable {

    // MARK: - Cases

    /// The domain root: represents the list of all workspaces.
    ///
    /// Maps to `NSFileProviderItemIdentifier.rootContainer` on the FPE side.
    case root

    /// A Fabric workspace. The identifier string is `workspaceID`.
    case workspace(workspaceID: String)

    /// A Fabric item (Lakehouse, Warehouse, …) inside a workspace.
    /// The identifier string is `"<workspaceID>/<itemID>"`.
    case item(workspaceID: String, itemID: String)

    /// A POSIX path relative to the item root.
    /// The identifier string is `"<workspaceID>/<itemID>/<path>"`.
    case path(workspaceID: String, itemID: String, path: String)

    // MARK: - Well-known string

    /// The canonical string for the root container, matching
    /// `NSFileProviderItemIdentifier.rootContainer`'s backing value on the
    /// Swift side and `RootContainerID` in the Go daemon.
    public static let rootContainerString = ".rootContainer"

    // MARK: - Stringified identifier

    /// Reconstructs the opaque identifier string the File Provider stack uses.
    ///
    /// Mirrors `internal/fp/fp.go` — `buildPathID` and related helpers.
    public var identifierString: String {
        switch self {
        case .root:
            return Self.rootContainerString
        case .workspace(let ws):
            return ws
        case .item(let ws, let item):
            return "\(ws)/\(item)"
        case .path(let ws, let item, let path):
            if path.isEmpty {
                return "\(ws)/\(item)"
            }
            return "\(ws)/\(item)/\(path)"
        }
    }

    // MARK: - Parent identifier

    /// Returns the identifier of the parent container.
    ///
    /// Mirrors `internal/fp/fp.go` — `buildPathParentID`.
    public var parentIdentifier: ItemIdentifier {
        switch self {
        case .root:
            return .root
        case .workspace:
            return .root
        case let .item(ws, _):
            return .workspace(workspaceID: ws)
        case let .path(ws, item, path):
            if path.isEmpty {
                return .workspace(workspaceID: ws)
            }
            if let slashIdx = path.lastIndex(of: "/") {
                let parentPath = String(path[path.startIndex..<slashIdx])
                return .path(workspaceID: ws, itemID: item, path: parentPath)
            }
            return .item(workspaceID: ws, itemID: item)
        }
    }
}

// MARK: - CustomStringConvertible

extension ItemIdentifier: CustomStringConvertible {
    public var description: String { identifierString }
}
