// FPEHelpers.swift
// Shared helpers for CacheKey construction and parent-path arithmetic.
//
// Previously hand-rolled at ~6 call sites (fpe-18). One canonical pair
// of helpers removes all the duplication and gives the tests a clean seam.

@preconcurrency import FileProvider
import OfemKit

// MARK: - CacheKey from identifier

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

// MARK: - CacheKey to signallable container identifier

/// Maps a container ``CacheKey`` back to the ``ItemIdentifier`` whose enumerator
/// the FPE should signal, or `nil` when the container must not be signalled.
///
/// This is the inverse of the discovery / path cache-key construction in
/// `SyncEngine`, accounting for the `VirtualIDs` sentinels:
///
/// - `workspaceID == VirtualIDs.workspaceID` — the top-level workspaces listing.
///   Its container is the domain root, which must NOT be signalled (signalling
///   `.rootContainer` throws `.syncAnchorExpired`); root stays remount-driven.
///   Returns `nil`.
/// - `itemID == VirtualIDs.itemID` — a workspace's item listing. Maps to
///   `.workspace(workspaceID:)`.
/// - empty `path` — an item root. Maps to `.item(workspaceID:itemID:)`.
/// - non-empty `path` — a folder inside an item. Maps to
///   `.path(workspaceID:itemID:path:)`.
///
/// The result round-trips through `ItemIdentifier.identifierString` and the
/// identifier parser, so the FPE can hand it straight to `signal(container:)`.
func signallableContainer(for key: CacheKey) -> ItemIdentifier? {
    // The workspaces listing lives under the root container — never signalled.
    if key.workspaceID == VirtualIDs.workspaceID {
        return nil
    }
    // The per-workspace item listing → the .workspace container.
    if key.itemID == VirtualIDs.itemID {
        return .workspace(workspaceID: key.workspaceID)
    }
    // An item root vs a folder within an item.
    if key.path.isEmpty {
        return .item(workspaceID: key.workspaceID, itemID: key.itemID)
    }
    return .path(workspaceID: key.workspaceID, itemID: key.itemID, path: key.path)
}

/// Builds the engine's ``ContainerChangeHandler`` that signals the FPE container
/// for a changed cache container.
///
/// The returned handler maps the changed ``CacheKey`` to a signallable
/// ``ItemIdentifier`` (skipping non-signallable containers such as the domain
/// root — see ``signallableContainer(for:)``), turns it into an
/// `NSFileProviderItemIdentifier`, and dispatches `signal` on a detached `Task`
/// (the handler is synchronous; `signal` is async). Factored out of
/// `FPEEngineHost.buildEngine` so the mapping + dispatch is unit-testable with a
/// spy in place of the real `ContainerSignaller`.
///
/// - Parameter signal: The async signal sink (production: the host's
///   `ContainerSignaller`; tests: a spy). Must be `@Sendable`.
func makeContainerChangeHandler(
    signal: @escaping @Sendable (NSFileProviderItemIdentifier) async -> Void
) -> ContainerChangeHandler {
    { key, _ in
        guard let container = signallableContainer(for: key) else { return }
        let identifier = NSFileProviderItemIdentifier(container.identifierString)
        Task { await signal(identifier) }
    }
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
