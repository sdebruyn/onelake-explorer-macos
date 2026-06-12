import Foundation

// MARK: - ItemIdentifierParser

/// Parses opaque File Provider identifier strings into typed ``ItemIdentifier``
/// values.
///
/// Strict validation: any identifier with an empty segment (leading slash,
/// double slash, empty workspace or item component) is rejected with
/// ``FPError/invalidIdentifier(_:)``.
///
/// Well-known sentinel handling:
/// - `""` or `NSFileProviderRootContainerItemIdentifier`  → `.root`
/// - `NSFileProviderTrashContainerItemIdentifier`         → `.trash`
/// - `NSFileProviderWorkingSetContainerItemIdentifier`    → `.workingSet`
///
/// Trailing-slash normalisation (sync-13):
/// - `"ws/item/"` is normalised to `.item`, matching `"ws/item"`.
///
/// Double-slash rejection in path tail (sync-13):
/// - Any empty segment in the path portion (e.g. `"ws/item//file"`) is
///   rejected so callers surface `noSuchItem` instead of emitting a
///   malformed double-slash DFS URL.
public enum ItemIdentifierParser {

    // MARK: - Parse

    /// Parses an opaque identifier string.
    ///
    /// - Parameter raw: The identifier string from the File Provider stack.
    /// - Returns: The structured ``ItemIdentifier``.
    /// - Throws: ``FPError/invalidIdentifier(_:)`` for malformed identifiers.
    public static func parse(_ raw: String) throws -> ItemIdentifier {
        // Well-known sentinels — check before any other processing.
        if raw.isEmpty || raw == ItemIdentifier.rootContainerString {
            return .root
        }
        if raw == ItemIdentifier.trashContainerString {
            return .trash
        }
        if raw == ItemIdentifier.workingSetString {
            return .workingSet
        }

        // Leading slash is always invalid.
        if raw.hasPrefix("/") {
            throw FPError.invalidIdentifier("leading slash in \"\(raw)\"")
        }

        // Split into at most 3 segments: workspace, item, path.
        let parts = raw.split(separator: "/", maxSplits: 2, omittingEmptySubsequences: false)

        switch parts.count {
        case 1:
            let ws = String(parts[0])
            if ws.isEmpty {
                throw FPError.invalidIdentifier("empty workspace segment in \"\(raw)\"")
            }
            return .workspace(workspaceID: ws)

        case 2:
            let ws = String(parts[0])
            let item = String(parts[1])
            if ws.isEmpty || item.isEmpty {
                throw FPError.invalidIdentifier("empty workspace or item segment in \"\(raw)\"")
            }
            return .item(workspaceID: ws, itemID: item)

        case 3:
            let ws = String(parts[0])
            let item = String(parts[1])
            if ws.isEmpty || item.isEmpty {
                throw FPError.invalidIdentifier("empty workspace or item segment in \"\(raw)\"")
            }
            let rawPath = String(parts[2])

            // Trailing slash normalisation (sync-13): "ws/item/" → .item.
            if rawPath.isEmpty {
                return .item(workspaceID: ws, itemID: item)
            }

            // Reject any empty segment in the path tail (sync-13).
            // "ws/item//file" would produce a malformed double-slash DFS URL.
            if rawPath.hasPrefix("/") || rawPath.contains("//") {
                throw FPError.invalidIdentifier(
                    "empty path segment in \"\(raw)\""
                )
            }

            return .path(workspaceID: ws, itemID: item, path: rawPath)

        default:
            throw FPError.invalidIdentifier("unexpected segment count in \"\(raw)\"")
        }
    }
}
