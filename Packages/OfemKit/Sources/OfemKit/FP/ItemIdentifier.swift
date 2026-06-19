import FileProvider
import Foundation

// MARK: - ItemIdentifier

/// A typed wrapper for a File Provider item identifier string.
///
/// The identifier grammar:
///
/// ```
/// "" | NSFileProviderRootContainerItemIdentifier  → .root
/// NSFileProviderTrashContainerItemIdentifier      → .trash
/// NSFileProviderWorkingSetContainerItemIdentifier → .workingSet
/// "<ws>"                 → .workspace(workspaceID: ws)
/// "<ws>/<item>"          → .item(workspaceID: ws, itemID: item)
/// "<ws>/<item>/<path>"   → .path(workspaceID: ws, itemID: item, path: path)
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

    /// The trash container sentinel. OFEM never places items here; the FPE
    /// must short-circuit on this case and return `noSuchItem`.
    case trash

    /// The working-set container sentinel owned by the File Provider framework.
    /// The FPE must short-circuit on this case.
    case workingSet

    /// A Fabric workspace. The identifier string is `workspaceID`.
    case workspace(workspaceID: String)

    /// A Fabric item (Lakehouse, Warehouse, …) inside a workspace.
    /// The identifier string is `"<workspaceID>/<itemID>"`.
    case item(workspaceID: String, itemID: String)

    /// A POSIX path relative to the item root.
    /// The identifier string is `"<workspaceID>/<itemID>/<path>"`.
    case path(workspaceID: String, itemID: String, path: String)

    // MARK: - Well-known strings (pinned to Apple framework constants)

    /// The canonical string for the root container.
    ///
    /// Equals `NSFileProviderItemIdentifier.rootContainer.rawValue`
    /// (`"NSFileProviderRootContainerItemIdentifier"`).
    public static let rootContainerString = NSFileProviderItemIdentifier.rootContainer.rawValue

    /// The canonical string for the trash container.
    ///
    /// Equals `NSFileProviderItemIdentifier.trashContainer.rawValue`
    /// (`"NSFileProviderTrashContainerItemIdentifier"`).
    public static let trashContainerString = NSFileProviderItemIdentifier.trashContainer.rawValue

    /// The canonical string for the working-set container.
    ///
    /// Equals `NSFileProviderItemIdentifier.workingSet.rawValue`
    /// (`"NSFileProviderWorkingSetContainerItemIdentifier"`).
    public static let workingSetString = NSFileProviderItemIdentifier.workingSet.rawValue

    // MARK: - Stringified identifier

    /// Reconstructs the opaque identifier string the File Provider stack uses.
    public var identifierString: String {
        switch self {
        case .root:
            return Self.rootContainerString
        case .trash:
            return Self.trashContainerString
        case .workingSet:
            return Self.workingSetString
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

    // MARK: - Log-safe identifier prefix

    /// Returns an opaque identifier string safe for logging at `.public`.
    ///
    /// For `.path` identifiers, `identifierString` contains human-readable
    /// folder and file names (e.g. `"<wsGUID>/<itemGUID>/Files/HR Salaries.pbix"`),
    /// which must not appear unredacted in the system log (see `docs/telemetry.md`).
    /// This property replaces the path segment with `"..."` so the workspace and
    /// item GUIDs remain visible for debugging without leaking file names.
    ///
    /// All other cases (`root`, `trash`, `workingSet`, `workspace`, `item`)
    /// contain only GUIDs or well-known Apple constant strings and are safe
    /// to log as-is.
    public var opaqueLogPrefix: String {
        switch self {
        case .path(let ws, let item, _):
            return "\(ws)/\(item)/..."
        default:
            return identifierString
        }
    }

    // MARK: - Parent identifier

    /// Returns the identifier of the parent container.
    public var parentIdentifier: ItemIdentifier {
        switch self {
        case .root, .trash, .workingSet:
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
