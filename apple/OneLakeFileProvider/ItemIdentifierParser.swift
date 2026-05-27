// ItemIdentifierParser.swift
// Maps between `NSFileProviderItemIdentifier` and the bridge-side
// identifier format the Go core understands.
//
// The Go core speaks a flat string format:
//
//   ""                          -> root container of the alias
//   "<wsId>"                    -> a workspace inside the alias
//   "<wsId>/<itemId>"           -> a Fabric item (lakehouse, etc.)
//   "<wsId>/<itemId>/<path>"    -> a folder or file inside an item
//
// macOS additionally hands us three well-known constants:
//   `.rootContainer`, `.workingSet`, `.trashContainer`. We translate
// those to dedicated scopes so the enumerator code can pattern-match
// on a typed enum instead of brittle string equality.

import FileProvider
import Foundation

/// Logical container scope a File Provider enumeration / item lookup
/// is targeting. `parse(_:)` produces these from raw item
/// identifiers; `bridgeIdentifier(for:)` is the inverse for the
/// scopes the Go core can serve.
enum EnumScope: Equatable {
    /// The root of the domain (an account's top level). macOS uses the
    /// well-known `.rootContainer` constant for this.
    case rootContainer
    /// A single Fabric workspace.
    case workspace(workspaceId: String)
    /// The root of a Fabric item — e.g. the top level of a lakehouse.
    case itemRoot(workspaceId: String, itemId: String)
    /// A folder or file inside a Fabric item.
    case itemPath(workspaceId: String, itemId: String, path: String)
    /// The recently-used / search working set the framework owns.
    case workingSet
    /// macOS's trash container. We never put anything in it.
    case trashContainer
}

enum ItemIdentifierParser {
    /// Parse a `NSFileProviderItemIdentifier` into an `EnumScope`.
    /// Throws `BridgeError.noSuchItem` for malformed input so callers
    /// can map it straight to `NSFileProviderError(.noSuchItem)`.
    static func parse(_ raw: NSFileProviderItemIdentifier) throws -> EnumScope {
        if raw == .rootContainer {
            return .rootContainer
        }
        if raw == .workingSet {
            return .workingSet
        }
        if raw == .trashContainer {
            return .trashContainer
        }
        let value = raw.rawValue
        if value.isEmpty {
            return .rootContainer
        }
        // The Go core may legitimately hand back the literal string
        // `.rootContainer` as an identifier (it is the canonical wire
        // form for "root of the alias"). Treat it the same as the
        // Apple constant.
        if value == NSFileProviderItemIdentifier.rootContainer.rawValue {
            return .rootContainer
        }
        // Split on `/` with a cap so a path-inside-item retains its
        // slashes verbatim — only the first two segments are GUIDs we
        // need to peel off.
        let parts = value.split(separator: "/", maxSplits: 2, omittingEmptySubsequences: false)
        switch parts.count {
        case 1:
            let ws = String(parts[0])
            guard !ws.isEmpty else {
                throw BridgeError.noSuchItem("empty workspace identifier")
            }
            return .workspace(workspaceId: ws)
        case 2:
            let ws = String(parts[0])
            let item = String(parts[1])
            guard !ws.isEmpty, !item.isEmpty else {
                throw BridgeError.noSuchItem("empty workspace or item identifier")
            }
            return .itemRoot(workspaceId: ws, itemId: item)
        case 3:
            let ws = String(parts[0])
            let item = String(parts[1])
            let path = String(parts[2])
            guard !ws.isEmpty, !item.isEmpty, !path.isEmpty else {
                throw BridgeError.noSuchItem("empty segment in nested identifier")
            }
            return .itemPath(workspaceId: ws, itemId: item, path: path)
        default:
            throw BridgeError.noSuchItem("could not parse identifier \(value)")
        }
    }

    /// Inverse of `parse(_:)` for the scopes the Go core can serve.
    /// `.workingSet` and `.trashContainer` are not addressable on the
    /// bridge — callers must short-circuit those before getting here.
    static func bridgeIdentifier(for scope: EnumScope) -> String {
        switch scope {
        case .rootContainer:
            return ""
        case .workspace(let ws):
            return ws
        case .itemRoot(let ws, let item):
            return "\(ws)/\(item)"
        case .itemPath(let ws, let item, let path):
            return "\(ws)/\(item)/\(path)"
        case .workingSet, .trashContainer:
            // Not addressable on the bridge — by contract callers
            // never invoke this for these scopes. Returning the
            // empty string keeps the API total without crashing.
            return ""
        }
    }
}
