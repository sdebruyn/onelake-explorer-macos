// ItemResolution.swift
// Engine-side item resolution and creation for the File Provider Extension.
//
// The FPE's item(for:), the metadata-only and content-bearing modifyItem
// paths, and createItem all funnel through the two `ItemResolution` statics
// below. Each returns a plain ``DomainItem``; the FPE wraps the result in its
// own `OfemFPEItem` at the edge. This file deliberately does NOT import
// FileProvider — the FileProvider-specific decisions (does `fields` contain
// `.contents`? did `options` include `.mayAlreadyExist`?) collapse into the
// plain-Swift parameters `uploadSource` and `mayAlreadyExist` that the FPE
// adapter computes before calling.

import Foundation
import os.log

private let itemResolutionLog = Logger(
    subsystem: "dev.debruyn.ofem",
    category: "ItemResolution"
)

/// Resolves and creates OneLake items on behalf of the File Provider Extension.
///
/// Both entry points take the ``SyncEngine`` and ``CacheStore`` subsystems
/// directly (rather than the whole ``OfemEngine``) so the resolution logic is
/// testable with a real engine built from mocks, and return a plain
/// ``DomainItem`` — the FPE owns the `OfemFPEItem` wrap and never leaks
/// FileProvider types into this layer.
public enum ItemResolution {
    /// Fetches a single item's metadata from the engine.
    ///
    /// Returns `.noSuchItem` for unknown workspace/item identifiers instead of
    /// fabricating GUID-named stub directories.
    ///
    /// Distinguishes `CacheError.notFound` (triggers parent enumerate + retry)
    /// from other cache errors (maps to cannotSynchronize, not noSuchItem) so
    /// a transient DB failure does not trigger local replica deletion.
    public static func resolveItem(
        identifier: ItemIdentifier,
        alias: String,
        sync: SyncEngine,
        cache: CacheStore
    ) async throws -> DomainItem {
        switch identifier {
        case .root:
            return DomainItem.root(alias: alias)

        case .trash, .workingSet:
            throw FPError.noSuchItem("synthetic container: \(identifier.identifierString)")

        case let .workspace(workspaceID):
            // Cache-first: the workspace-sentinel row is written by listWorkspaces,
            // keyed by (VirtualIDs.workspaceID, VirtualIDs.workspaceID, path: <wsGUID>).
            // A hit resolves without a Fabric round-trip (DomainItem.from delegates
            // sentinel rows to from(workspace:)); a definitive miss falls through to
            // the listWorkspaces fallback below.
            let key = CacheKey(
                accountAlias: alias, workspaceID: VirtualIDs.workspaceID,
                itemID: VirtualIDs.workspaceID, path: workspaceID
            )
            if let record = try await cacheFirstRecord(key: key, cache: cache, context: "workspace \(workspaceID)") {
                do {
                    return try DomainItem.from(record: record)
                } catch {
                    throw FPError.invalidRecord("DomainItem.from failed for workspace \(workspaceID): \(error)")
                }
            }
            // Cache miss → look up workspace display name from the discovery listing.
            let workspaces = try await sync.listWorkspaces(alias: alias)
            if let ws = workspaces.first(where: { $0.id == workspaceID }) {
                return DomainItem.from(workspace: ws)
            }
            // Absence after successful listing = definitive "not found".
            throw FPError.noSuchItem("workspace \(workspaceID) not in listing for alias \(alias)")

        case let .item(workspaceID, itemID):
            // Cache-first: the item-discovery row is written by the item-listing
            // reconcile, keyed by (workspaceID, VirtualIDs.itemID, path: <itemGUID>);
            // DomainItem.from maps it to the ".item" identifier via its
            // item-discovery branch. A definitive miss falls through to listItems.
            let key = CacheKey(
                accountAlias: alias, workspaceID: workspaceID,
                itemID: VirtualIDs.itemID, path: itemID
            )
            if let record = try await cacheFirstRecord(key: key, cache: cache, context: "item \(itemID)") {
                do {
                    return try DomainItem.from(record: record)
                } catch {
                    throw FPError.invalidRecord("DomainItem.from failed for item \(itemID): \(error)")
                }
            }
            // Cache miss → populate from the Fabric item listing.
            let items = try await sync.listItems(alias: alias, workspaceID: workspaceID)
            if let fi = items.first(where: { $0.id == itemID }) {
                return DomainItem.from(fabricItem: fi, workspaceID: workspaceID)
            }
            // Absence after successful listing = definitive "not found".
            throw FPError.noSuchItem("item \(itemID) not in listing for workspace \(workspaceID)")

        case let .path(workspaceID, itemID, path):
            let key = CacheKey(accountAlias: alias, workspaceID: workspaceID, itemID: itemID, path: path)
            let parent = Enumerator.parentPath(path)
            let parentKey = CacheKey(accountAlias: alias, workspaceID: workspaceID, itemID: itemID, path: parent)
            // Redacted at the throw site itself, not just at the log call: `identifier`
            // IS this `.path` case, so `opaqueLogPrefix` keeps the ws/item GUIDs while
            // dropping the human-readable path — matching every other case in this
            // function, which only ever embeds GUIDs into its error messages.
            let logID = identifier.opaqueLogPrefix

            guard let record = try await cachedRecordOrEnumerate(
                key: key, parentKey: parentKey, sync: sync, cache: cache, context: logID
            ) else {
                // Still absent after enumeration → definitively gone.
                throw FPError.noSuchItem(logID)
            }
            do {
                return try DomainItem.from(record: record)
            } catch {
                throw FPError.invalidRecord("DomainItem.from failed for \(logID): \(error)")
            }
        }
    }

    /// Creates a directory or file via the engine.
    ///
    /// The FileProvider-specific create options collapse into two plain-Swift
    /// parameters computed by the FPE adapter:
    /// - `uploadSource`: the URL to stream content from, or `nil` for a
    ///   placeholder-only create (no upload). The adapter passes non-nil only
    ///   when `fields` contained `.contents` AND a content URL was provided;
    ///   otherwise `nil`, so uploading `Data()` can never truncate an existing
    ///   remote file.
    /// - `mayAlreadyExist`: mirrors `NSFileProviderCreateItemOptions
    ///   .mayAlreadyExist`. When set, the system is re-importing items that may
    ///   have pre-existing remote content: do not upload; re-fetch and return
    ///   the existing remote item. Cache errors are discriminated — only
    ///   `CacheError.notFound` is treated as "not yet cached"; other errors
    ///   propagate so a DB failure does not silently trigger an unintended upload.
    ///
    /// Re-fetches real metadata after upload so the returned item's version/size
    /// matches subsequent enumerations.
    public static func createItem(
        parent: ItemIdentifier,
        filename: String,
        isDirectory: Bool,
        uploadSource: URL?,
        mayAlreadyExist: Bool,
        alias: String,
        sync: SyncEngine,
        cache: CacheStore
    ) async throws -> DomainItem {
        // Derive key for the new item based on its parent.
        let (wsID, itemID, parentPathStr): (String, String, String)
        switch parent {
        case let .item(w, i):
            wsID = w; itemID = i; parentPathStr = ""
        case let .path(w, i, p):
            wsID = w; itemID = i; parentPathStr = p
        default:
            throw FPError.invalidIdentifier("createItem: parent must be item or path, got \(parent)")
        }

        let newPath = parentPathStr.isEmpty ? filename : "\(parentPathStr)/\(filename)"
        let key = CacheKey(accountAlias: alias, workspaceID: wsID, itemID: itemID, path: newPath)
        let newIdentifier = ItemIdentifier.path(workspaceID: wsID, itemID: itemID, path: newPath)

        // Honour .mayAlreadyExist — the system is re-importing items that may
        // have pre-existing remote content. Don't upload/overwrite.
        if mayAlreadyExist {
            // Discriminate CacheError.notFound (not yet cached — enumerate parent
            // and retry once, then treat still-missing as "it's new") from real DB
            // errors, which must propagate rather than silently falling through to
            // an unintended create. A cached-but-undecodable row is treated the
            // same as "not yet cached" (via `isValid`) — it also gets the
            // enumerate-and-retry chance rather than immediately falling through
            // to create, which would overwrite/recreate an item that DOES exist
            // but whose cached row just failed to decode.
            let parentKey = CacheKey(accountAlias: alias, workspaceID: wsID, itemID: itemID, path: parentPathStr)
            if let record = try await cachedRecordOrEnumerate(
                key: key, parentKey: parentKey, sync: sync, cache: cache,
                // Redacted the same way as resolveItem's `.path` case: `context`
                // ends up embedded in FPError messages on the cache-error path.
                context: "createItem mayAlreadyExist \(newIdentifier.opaqueLogPrefix)",
                isValid: { (try? DomainItem.from(record: $0)) != nil }
            ), let di = try? DomainItem.from(record: record) {
                return di
            }
            // Still not found (or undecodable) — fall through to normal create path (it's new).
        }

        if isDirectory {
            try await sync.mkdir(key: key)
        } else {
            // Only upload when the adapter supplied a source URL. A nil
            // `uploadSource` means "placeholder only" — uploading Data() would
            // truncate an existing remote file. The real content is on the
            // remote and will be fetched on demand.
            if let url = uploadSource {
                // Stream from the provided URL — no in-memory Data load.
                try await sync.put(key: key, sourceURL: url)
            }
        }

        // Re-fetch real metadata so version/size matches enumeration.
        // If the cache row is not yet populated (e.g. mkdir with no enumerate),
        // fall back to a synthetic item but log the situation.
        let postCreateFetch: Result<MetadataRecord, Error>
        do {
            postCreateFetch = .success(try await cache.fetch(key: key))
        } catch {
            postCreateFetch = .failure(error)
        }
        switch postCreateFetch {
        case let .success(record):
            if let di = try? DomainItem.from(record: record) {
                return di
            }
        case let .failure(cacheError as CacheError):
            guard case .notFound = cacheError else {
                // A non-notFound cache error is unexpected but not fatal here;
                // log and fall through to the synthetic fallback.
                itemResolutionLog.warning(
                    "createItem: cache fetch error for \(filename, privacy: .private): \(cacheError.localizedDescription, privacy: .public)"
                )
                break
            }
            // .notFound: enumerate parent to populate it, then retry.
            let parentKey = CacheKey(accountAlias: alias, workspaceID: wsID, itemID: itemID, path: parentPathStr)
            _ = try? await sync.enumerate(key: parentKey)
            if let record = try? await cache.fetch(key: key),
               let di = try? DomainItem.from(record: record)
            {
                return di
            }
        case let .failure(other):
            itemResolutionLog.warning(
                "createItem: unexpected fetch error for \(filename, privacy: .private): \(other.localizedDescription, privacy: .public)"
            )
        }

        // Final fallback: synthetic item. This case should be rare (e.g. mkdir
        // on a backend that doesn't enumerate immediately), and the version
        // mismatch will resolve on the next full enumeration of the parent.
        itemResolutionLog.warning(
            "createItem: using synthetic fallback for \(filename, privacy: .private) parent=\(parent.opaqueLogPrefix, privacy: .public)"
        )
        // Carry the parent's item type so computeCapabilities returns the correct
        // caps immediately — without it, a file created under Lakehouse Files/
        // would appear read-only until the next refreshFolder. resolveItemType
        // reads the new item's own row (equal to the parent's type when written
        // by our own put/mkdir) and falls back to the parent directory row.
        let syntheticItemType = await sync.resolveItemType(for: key)
        return DomainItem.synthetic(
            identifier: newIdentifier,
            parentIdentifier: parent,
            name: filename,
            isDirectory: isDirectory,
            itemType: syntheticItemType
        )
    }
}

// MARK: - Cache-first fetch primitives

/// Fetches `key` cache-first, returning the row on a hit or `nil` on a
/// definitive `CacheError.notFound` miss (the caller then runs its remote
/// listing fallback).
///
/// Any OTHER cache error is an infrastructure failure re-thrown as
/// `FPError.invalidRecord` (→ cannotSynchronize), never `noSuchItem`: a
/// transient DB blip must not be mistaken for a deletion signal. This is the
/// single fetch primitive ``cachedRecordOrEnumerate(key:parentKey:sync:cache:context:isValid:)``
/// composes twice (first fetch, retry-after-enumerate fetch).
private func cacheFirstRecord(
    key: CacheKey,
    cache: CacheStore,
    context: String
) async throws -> MetadataRecord? {
    do {
        return try await cache.fetch(key: key)
    } catch let cacheError as CacheError {
        guard case .notFound = cacheError else {
            throw FPError.invalidRecord("cache DB error for \(context): \(cacheError)")
        }
        return nil
    } catch {
        throw FPError.invalidRecord("unexpected cache error for \(context): \(error)")
    }
}

/// Fetches `key` cache-first; on a definitive `CacheError.notFound` miss, OR
/// on a hit that `isValid` rejects, enumerates `parentKey` to populate the
/// cache and retries once.
///
/// Returns the record from either the first fetch or the retry, whichever
/// first satisfies `isValid` (defaults to accepting any record — the
/// ``ItemResolution/resolveItem(identifier:alias:sync:cache:)`` `.path` case
/// decodes the record itself afterwards and wants ANY row, decodable or not,
/// to short-circuit the retry so a decode failure surfaces immediately as
/// `cannotSynchronize` rather than masking itself behind a redundant
/// enumerate). Returns `nil` only when the retry ALSO misses — either
/// `CacheError.notFound` or an `isValid`-rejected row — after a fresh parent
/// enumeration. The caller decides what "still absent" means: a hard
/// `.noSuchItem` for a metadata lookup, or "proceed to create" for
/// `createItem`'s `.mayAlreadyExist` path, which passes an `isValid` that
/// requires the row to decode — a cached-but-undecodable row must not be
/// mistaken for "not yet cached" and fall straight through to an unintended
/// create/overwrite; it gets the same one enumerate-and-retry chance a genuine
/// cache miss gets.
///
/// Any OTHER cache error — on either the first fetch or the retry —
/// propagates as `FPError.invalidRecord` (→ cannotSynchronize), never as a
/// definitive-absence `nil`: a transient DB blip must never be mistaken for
/// "not found", which would read as a deletion to a metadata caller, or
/// trigger an unwanted create/overwrite here (the safety property both call
/// sites previously open-coded separately). Enumeration failures (network,
/// auth) also propagate as-is — they are retriable.
private func cachedRecordOrEnumerate(
    key: CacheKey,
    parentKey: CacheKey,
    sync: SyncEngine,
    cache: CacheStore,
    context: String,
    isValid: (MetadataRecord) -> Bool = { _ in true }
) async throws -> MetadataRecord? {
    if let record = try await cacheFirstRecord(key: key, cache: cache, context: context), isValid(record) {
        return record
    }
    // Cache miss (or an isValid-rejected hit) → enumerate parent to
    // populate/refresh the cache, then retry once.
    _ = try await sync.enumerate(key: parentKey)
    if let record = try await cacheFirstRecord(key: key, cache: cache, context: "\(context) (retry)"), isValid(record) {
        return record
    }
    return nil
}
