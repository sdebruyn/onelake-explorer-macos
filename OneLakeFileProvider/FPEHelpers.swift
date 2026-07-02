// FPEHelpers.swift
// Shared helpers for CacheKey construction, parent-path arithmetic,
// and materialized-container depth filtering.

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
/// **Known limitation**: the depth-3 cap also excludes `Files/` paths deeper
/// than 3 components (e.g. `Files/reports/2024/Q1`). Those directories are not
/// proactively polled; they refresh on user navigation. This is an acceptable
/// trade-off: deep `Files/` nesting is uncommon and does not carry Delta-table
/// write semantics, so the absence of a background poll is not user-visible in
/// practice.
///
/// - Parameter path: The path portion of a `.path` ``ItemIdentifier``
///   (i.e. the tail after `"<wsGUID>/<itemGUID>/"`).
/// - Returns: `true` if this path should be polled for freshness.
func isMaterializablePathContainer(_ path: String) -> Bool {
    let components = path.split(separator: "/")
    guard components.count <= 3 else { return false }
    return !components.contains("_delta_log")
}
