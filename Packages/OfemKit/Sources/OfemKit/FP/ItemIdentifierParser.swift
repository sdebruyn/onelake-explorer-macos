import Foundation

// MARK: - ItemIdentifierParser

/// Parses opaque File Provider identifier strings into typed ``ItemIdentifier``
/// values.
///
/// Strict validation: any identifier with an empty segment (leading slash,
/// double slash, empty workspace or item component) is rejected with
/// ``FPError/invalidIdentifier(_:)``.  Segment *content* is also validated:
/// control characters (U+0000–U+001F, U+007F), leading/trailing ASCII
/// whitespace, and path separator characters (`/`, `\`) inside a segment are
/// rejected so that a malformed identifier cannot be silently interpolated
/// into a DFS URL.
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
            try validateSegment(ws, label: "workspace", raw: raw)
            return .workspace(workspaceID: ws)

        case 2:
            let ws = String(parts[0])
            let item = String(parts[1])
            if ws.isEmpty || item.isEmpty {
                throw FPError.invalidIdentifier("empty workspace or item segment in \"\(raw)\"")
            }
            try validateSegment(ws, label: "workspace", raw: raw)
            try validateSegment(item, label: "item", raw: raw)
            return .item(workspaceID: ws, itemID: item)

        case 3:
            let ws = String(parts[0])
            let item = String(parts[1])
            if ws.isEmpty || item.isEmpty {
                throw FPError.invalidIdentifier("empty workspace or item segment in \"\(raw)\"")
            }
            try validateSegment(ws, label: "workspace", raw: raw)
            try validateSegment(item, label: "item", raw: raw)

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

            try validatePathSegments(rawPath, raw: raw)

            return .path(workspaceID: ws, itemID: item, path: rawPath)

        default:
            throw FPError.invalidIdentifier("unexpected segment count in \"\(raw)\"")
        }
    }

    // MARK: - Private segment validators

    /// Validates a single non-path segment (workspace or item ID).
    ///
    /// Rejects:
    /// - Control characters (U+0000–U+001F, U+007F DEL)
    /// - Leading or trailing ASCII whitespace
    /// - Backslash (`\`) — a path separator on Windows; illegal inside a
    ///   OneLake path segment regardless of platform
    private static func validateSegment(_ segment: String, label: String, raw: String) throws {
        // Reject leading/trailing space (U+0020).  All other ASCII whitespace
        // (tab U+0009, CR U+000D, LF U+000A, etc.) is already caught by the
        // control-character gate below (v < 0x20), so they need no separate
        // check here.  Non-ASCII whitespace (e.g. U+00A0 NBSP) is outside the
        // stated ASCII scope and is not rejected.
        if segment.hasPrefix(" ") || segment.hasSuffix(" ") {
            throw FPError.invalidIdentifier(
                "\(label) segment has leading/trailing whitespace in \"\(raw)\""
            )
        }
        for scalar in segment.unicodeScalars {
            let v = scalar.value
            if v < 0x20 || v == 0x7F {
                throw FPError.invalidIdentifier(
                    "\(label) segment contains control character U+\(String(v, radix: 16, uppercase: true)) in \"\(raw)\""
                )
            }
            if scalar == "\\" {
                throw FPError.invalidIdentifier(
                    "\(label) segment contains backslash in \"\(raw)\""
                )
            }
        }
    }

    /// Validates every slash-delimited component inside a path tail.
    ///
    /// Each component must pass the same rules as a standalone segment
    /// (no control chars, no leading/trailing whitespace, no backslash).
    private static func validatePathSegments(_ path: String, raw: String) throws {
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        for component in components {
            let seg = String(component)
            // Empty component means double-slash — already caught above, but
            // guard here defensively.
            if seg.isEmpty {
                throw FPError.invalidIdentifier("empty path segment in \"\(raw)\"")
            }
            try validateSegment(seg, label: "path", raw: raw)
        }
    }
}
