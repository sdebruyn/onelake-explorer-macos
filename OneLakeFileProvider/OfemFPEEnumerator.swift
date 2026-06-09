// OfemFPEEnumerator.swift
// NSFileProviderEnumerator backed by the Swift OfemEngine.
//
// Design notes:
//
// - The engine's SyncEngine.enumerate(key:) method operates on
// CacheKey values. We map NSFileProviderItemIdentifier → ItemIdentifier
// (OfemKit) → CacheKey for the enumerate call.
//
// - Workspace and item discovery (listWorkspaces, listItems) produce
// DomainItem values that never go through the cache layer; regular
// file/folder enumeration uses SyncEngine.enumerate(key:) which
// hits the cache + remote refresh.
//
// - Cursor / page tokens: the Swift engine's enumerate(key:) returns
// the full listing in one call (no server-side pagination at the DFS
// level). We use one page, nil cursor.
//
// - enumerateChanges: answers syncAnchorExpired so macOS drops its
// cache and re-runs enumerateItems on every Finder refresh.

import FileProvider
import Foundation
import OfemKit
import os.log

private let staticSyncAnchorFPE = NSFileProviderSyncAnchor(Data())

// MARK: - Identifier parsing helper

/// Parses a raw NSFileProviderItemIdentifier string into an OfemKit ItemIdentifier.
///
/// OfemKit's `ItemIdentifierParser` (returns `ItemIdentifier`) is the primary
/// parser for engine operations. `BridgeItemIdentifierParser` (returns `EnumScope`)
/// is used only by `ItemIdentifierParserTests`.
func parseOfemItemIdentifier(_ rawIdentifier: String) throws -> ItemIdentifier {
    try ItemIdentifierParser.parse(rawIdentifier)
}

/// Engine-backed enumerator for one container in one FPE domain.
final class OfemFPEEnumerator: NSObject, NSFileProviderEnumerator {
    private static let log = Logger(
        subsystem: "dev.debruyn.ofem.fileprovider",
        category: "fpe-enumerator"
    )

    let containerItemIdentifier: NSFileProviderItemIdentifier
    let identifier: ItemIdentifier         // OfemKit-typed
    let alias: String
    let engineHost: FPEEngineHost

    private var inFlightTask: Task<Void, Never>?

    init(
        containerItemIdentifier: NSFileProviderItemIdentifier,
        identifier: ItemIdentifier,
        alias: String,
        engineHost: FPEEngineHost
    ) {
        self.containerItemIdentifier = containerItemIdentifier
        self.identifier = identifier
        self.alias = alias
        self.engineHost = engineHost
        super.init()
    }

    /// Convenience init that parses the raw identifier via OfemKit's
    /// ItemIdentifierParser.
    convenience init(
        containerItemIdentifier: NSFileProviderItemIdentifier,
        alias: String,
        engineHost: FPEEngineHost
    ) throws {
        let identifier = try ItemIdentifierParser.parse(containerItemIdentifier.rawValue)
        self.init(
            containerItemIdentifier: containerItemIdentifier,
            identifier: identifier,
            alias: alias,
            engineHost: engineHost
        )
    }

    func invalidate() {
        inFlightTask?.cancel()
        inFlightTask = nil
    }

    // MARK: - Enumeration

    func enumerateItems(
        for observer: NSFileProviderEnumerationObserver,
        startingAt _: NSFileProviderPage
    ) {
        let aliasCopy = alias
        let identifierCopy = identifier
        let hostCopy = engineHost

        inFlightTask?.cancel()
        inFlightTask = Task {
            do {
                let engine = try await hostCopy.engine()
                let items = try await Self.enumerate(
                    identifier: identifierCopy,
                    alias: aliasCopy,
                    engine: engine
                )
                observer.didEnumerate(items)
                observer.finishEnumerating(upTo: nil)
            } catch is CancellationError {
                Self.log.debug(
                    "OfemFPEEnumerator cancelled for \(aliasCopy, privacy: .public)/\(identifierCopy.identifierString, privacy: .public)"
                )
                observer.finishEnumeratingWithError(NSFileProviderError(.cannotSynchronize))
            } catch {
                let code = FPError.classify(error)
                Self.log.error(
                    "OfemFPEEnumerator failed for \(aliasCopy, privacy: .public)/\(identifierCopy.identifierString, privacy: .public): \(error.localizedDescription, privacy: .public) (code=\(code.rawValue, privacy: .public))"
                )
                observer.finishEnumeratingWithError(nsFileProviderError(for: code))
            }
        }
    }

    func enumerateChanges(
        for observer: NSFileProviderChangeObserver,
        from _: NSFileProviderSyncAnchor
    ) {
        // No incremental change support yet. Expire the anchor so macOS
        // drops its cache and re-runs enumerateItems.
        Self.log.debug(
            "OfemFPEEnumerator enumerateChanges \(self.alias, privacy: .public)/\(self.containerItemIdentifier.rawValue, privacy: .public) -> syncAnchorExpired"
        )
        observer.finishEnumeratingWithError(NSFileProviderError(.syncAnchorExpired))
    }

    func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        completionHandler(staticSyncAnchorFPE)
    }

    // MARK: - Private engine dispatch

    /// Dispatches enumeration based on the identifier level.
    private static func enumerate(
        identifier: ItemIdentifier,
        alias: String,
        engine: OfemEngine
    ) async throws -> [NSFileProviderItem] {
        switch identifier {
        case .root:
            // List all workspaces for this alias.
            let workspaces = try await engine.sync.listWorkspaces(alias: alias)
            return workspaces.map { ws in
                OfemFPEItem(from: DomainItem.from(workspace: ws))
            }

        case let .workspace(workspaceID):
            // List all Fabric items inside the workspace.
            let items = try await engine.sync.listItems(alias: alias, workspaceID: workspaceID)
            return items.map { fabricItem in
                OfemFPEItem(from: DomainItem.from(fabricItem: fabricItem, workspaceID: workspaceID))
            }

        case let .item(workspaceID, itemID):
            // List the root of a Fabric item (e.g. lakehouse root).
            let key = CacheKey(
                accountAlias: alias,
                workspaceID: workspaceID,
                itemID: itemID,
                path: ""
            )
            let records = try await engine.sync.enumerate(key: key)
            return try records.compactMap { record in
                try? OfemFPEItem(from: DomainItem.from(record: record))
            }

        case let .path(workspaceID, itemID, path):
            // List a sub-path inside a Fabric item.
            let key = CacheKey(
                accountAlias: alias,
                workspaceID: workspaceID,
                itemID: itemID,
                path: path
            )
            let records = try await engine.sync.enumerate(key: key)
            return try records.compactMap { record in
                try? OfemFPEItem(from: DomainItem.from(record: record))
            }
        }
    }
}

// MARK: - FPError.Code → NSFileProviderError

private func nsFileProviderError(for code: FPError.Code) -> Error {
    switch code {
    case .noSuchItem:        return NSFileProviderError(.noSuchItem)
    case .notAuthenticated:  return NSFileProviderError(.notAuthenticated)
    case .serverBusy:        return NSFileProviderError(.serverUnreachable)
    case .serverUnreachable: return NSFileProviderError(.serverUnreachable)
    case .cannotSynchronize: return NSFileProviderError(.cannotSynchronize)
    }
}
