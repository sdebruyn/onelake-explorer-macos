import Foundation

// MARK: - ItemIdentifierParser

/// Parses opaque File Provider identifier strings into typed ``ItemIdentifier``
/// values.
///
/// The grammar is identical to the Go daemon's `parseIdentifier` in
/// `internal/fp/fp.go`. Strict validation: any identifier with an empty
/// segment (leading slash, double slash, empty workspace or item component)
/// is rejected with ``FPError/invalidIdentifier(_:)``.
public enum ItemIdentifierParser {

    // MARK: - Parse

    /// Parses an opaque identifier string.
    ///
    /// - Parameter raw: The identifier string from the File Provider stack.
    ///   `""` and `".rootContainer"` both map to `.root`.
    /// - Returns: The structured ``ItemIdentifier``.
    /// - Throws: ``FPError/invalidIdentifier(_:)`` for malformed identifiers.
    public static func parse(_ raw: String) throws -> ItemIdentifier {
        // Empty string or the explicit root-container sentinel.
        if raw.isEmpty || raw == ItemIdentifier.rootContainerString {
            return .root
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
            // Trim trailing slash from the path component (mirrors Go's
            // `strings.TrimSuffix(parts[2], "/")` in parseIdentifier).
            let path = String(parts[2]).trimmingSuffix("/")
            return .path(workspaceID: ws, itemID: item, path: path)

        default:
            throw FPError.invalidIdentifier("unexpected segment count in \"\(raw)\"")
        }
    }
}

// MARK: - String extension helper

private extension String {
    /// Removes a single trailing occurrence of `suffix`.
    func trimmingSuffix(_ suffix: String) -> String {
        hasSuffix(suffix) ? String(dropLast(suffix.count)) : self
    }
}
