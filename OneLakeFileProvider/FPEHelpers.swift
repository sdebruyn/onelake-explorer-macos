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

// MARK: - Materialized-container depth filter

/// Returns `true` when a parsed `.path` identifier should be admitted to the
/// materialized-container poll set.
///
/// **Why this exists** — when a user browses a Delta table macOS materializes
/// deep internals: `_delta_log`, partition GUID directories, and individual
/// `.parquet` files. Polling every one fans out thousands of `refreshFolder`
/// calls per cycle. This predicate is the depth backstop that keeps the set to
/// user-navigable directories only.
///
/// **Admitted** (path component count ≤ 3 AND no `_delta_log` segment):
/// ```
/// "Tables"                           — depth 1
/// "Tables/dbo"                       — depth 2
/// "Tables/dbo/events"                — depth 3  ← the table folder
/// "Files"                            — depth 1
/// "Files/reports"                    — depth 2
/// ```
///
/// **Excluded**:
/// ```
/// "Tables/dbo/events/_delta_log"     — _delta_log segment
/// "Tables/dbo/events/<partition-id>" — depth 4
/// "Files/a/b/c/d.parquet"            — depth 5
/// ```
///
/// - Parameter path: The path portion of a `.path` ``ItemIdentifier``
///   (i.e. the tail after `"<wsGUID>/<itemGUID>/"`).
/// - Returns: `true` if this path should be polled for freshness.
func isMaterializablePathContainer(_ path: String) -> Bool {
    let components = path.split(separator: "/", omittingEmptySubsequences: false)
    guard components.count <= 3 else { return false }
    return !components.contains("_delta_log")
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
