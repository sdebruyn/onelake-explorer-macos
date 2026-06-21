// FPEHelpers.swift
// Shared helpers for CacheKey construction and parent-path arithmetic.
//
// Previously hand-rolled at ~6 call sites (fpe-18). One canonical pair
// of helpers removes all the duplication and gives the tests a clean seam.

import OfemKit

// MARK: - CacheKey from identifier

// periphery:ignore
/// Builds a ``CacheKey`` from an ``ItemIdentifier`` and the account alias.
///
/// Only `.item` and `.path` identifiers map to cache keys; callers must
/// guard on those cases before calling this helper.
///
/// - Parameters:
///   - alias:      The account alias (non-empty).
///   - identifier: An `.item` or `.path` identifier.
/// - Returns: The cache key for the identified item or path.
/// - Throws: ``FPError/invalidIdentifier(_:)`` for non-cacheable identifiers.
func cacheKey(alias: String, identifier: ItemIdentifier) throws -> CacheKey {
    switch identifier {
    case let .item(ws, item):
        return CacheKey(accountAlias: alias, workspaceID: ws, itemID: item, path: "")
    case let .path(ws, item, path):
        return CacheKey(accountAlias: alias, workspaceID: ws, itemID: item, path: path)
    default:
        throw FPError.invalidIdentifier("cacheKey: expected .item or .path, got \(identifier.identifierString)")
    }
}

/// Builds a ``CacheKey`` from the three components of a `.path` or `.item`
/// identifier.
///
/// - Parameters:
///   - alias:       The account alias.
///   - workspaceID: The workspace GUID.
///   - itemID:      The item GUID.
///   - path:        The POSIX path relative to item root. `""` = item root.
func cacheKey(
    alias: String,
    workspaceID: String,
    itemID: String,
    path: String
) -> CacheKey {
    CacheKey(accountAlias: alias, workspaceID: workspaceID, itemID: itemID, path: path)
}

// MARK: - Parent path arithmetic

/// Derives the parent-path string for `path`.
///
/// - `"Files/raw/2024/sales.csv"` → `"Files/raw/2024"`
/// - `"Files"` → `""`
/// - `""` → `""`
///
/// This is the single implementation of parent-path arithmetic for the FPE;
/// ``ItemIdentifier/parentIdentifier`` (OfemKit) and the legacy
/// `buildParentIdentifier` free function in `DomainItem.swift` are the only
/// other copies — this function exists at the FPE level so callers don't
/// need to use the full ``ItemIdentifier`` type.
func parentPath(of path: String) -> String {
    guard let slashIdx = path.lastIndex(of: "/") else { return "" }
    return String(path[path.startIndex ..< slashIdx])
}
