// FileProviderExtension.swift
// `NSFileProviderReplicatedExtension` subclass for OFEM.
//
// Fase 7.2: The FPE now hosts an OfemEngine (via FPEEngineHost) and
// drives enumeration, fetch and write operations directly through the
// Swift engine rather than the Go-daemon Unix-socket IPC.
//
// Architecture transition:
//   - FPE creates one FPEEngineHost per domain (one per account alias).
//   - Engine-backed enumerators (OfemFPEEnumerator) replace
//     CoreBridge calls for all list/enumerate operations.
//   - Fetch and write operations call SyncEngine.open / put / delete /
//     mkdir directly.
//   - The CoreBridge / Unix-socket IPC code in apple/Shared/ remains
//     compiled and in use for the host app's account management (status,
//     addAccount, etc.). It is removed in Fase 7.3.
//
// Error mapping: FPError.classify(error) maps any OfemKit error to a
// stable FPError.Code which nsFileProviderError(for:) then maps to
// NSFileProviderError. This replaces the BridgeError.nsFileProviderError
// extension used on the IPC path.

import FileProvider
import Foundation
import OfemKit
import os.log

// The FPE target's legacy IPC parser is now named `BridgeItemIdentifierParser`
// (returns `EnumScope` from `NSFileProviderItemIdentifier`).
// OfemKit exports `ItemIdentifierParser` (returns `ItemIdentifier` from `String`).
// This file calls the OfemKit version via `parseOfemItemIdentifier` (defined in
// OfemFPEEnumerator.swift) to keep call sites readable.

/// File Provider Extension entry point. Sandboxed; each registered
/// OneLake account-alias gets its own instance.
///
/// `NSFileProviderServicing` is the optional protocol for exposing
/// `NSFileProviderService` sources to the host app over XPC.
final class FileProviderExtension: NSObject, NSFileProviderReplicatedExtension, NSFileProviderServicing {
    private static let log = Logger(
        subsystem: "dev.debruyn.ofem.fileprovider",
        category: "extension"
    )

    /// The domain this extension instance was created for.
    let domain: NSFileProviderDomain

    /// Cached alias so we don't re-strip the prefix on every call.
    private let alias: String

    /// Per-domain engine container.
    ///
    /// One engine per FPE domain instance = one engine per alias.
    /// Built lazily on first use by FPEEngineHost.
    private let engineHost: FPEEngineHost

    // MARK: - Designated initializer

    required init(domain: NSFileProviderDomain) {
        self.domain = domain
        self.alias = OneLakeEnumerator.alias(from: domain)
        self.engineHost = FPEEngineHost(alias: self.alias, domain: domain)
        super.init()
        FileProviderExtension.log.info(
            "Initialised extension for domain \(domain.identifier.rawValue, privacy: .public) (alias=\(self.alias, privacy: .public)) [engine-path]"
        )
    }

    /// Directory for staging fetched file contents.
    private func fetchScratchDirectory() throws -> URL {
        guard let manager = NSFileProviderManager(for: domain) else {
            throw NSError(domain: NSCocoaErrorDomain, code: NSFileNoSuchFileError)
        }
        return try manager.temporaryDirectoryURL()
    }

    /// Called when macOS is done with this extension instance.
    func invalidate() {
        FileProviderExtension.log.info(
            "Invalidating extension for domain \(self.domain.identifier.rawValue, privacy: .public)"
        )
        Task {
            await engineHost.shutdown()
        }
    }

    // MARK: - Item metadata

    func item(
        for identifier: NSFileProviderItemIdentifier,
        request _: NSFileProviderRequest,
        completionHandler: @escaping (NSFileProviderItem?, Error?) -> Void
    ) -> Progress {
        let progress = Progress(totalUnitCount: -1)

        // Parse identifier — use OfemKit's parser.
        let ofemID: ItemIdentifier
        do {
            ofemID = try parseOfemItemIdentifier(identifier.rawValue)
        } catch {
            completionHandler(nil, NSFileProviderError(.noSuchItem))
            return progress
        }

        // Working set / trash are synthetic; return noSuchItem.
        if identifier == .workingSet || identifier == .trashContainer {
            completionHandler(nil, NSFileProviderError(.noSuchItem))
            return progress
        }

        let aliasCopy = alias
        let hostCopy = engineHost
        let task = Task {
            do {
                let engine = try await hostCopy.engine()
                let item = try await engineFetchItem(
                    identifier: ofemID,
                    alias: aliasCopy,
                    engine: engine
                )
                completionHandler(item, nil)
            } catch is CancellationError {
                completionHandler(nil, NSFileProviderError(.cannotSynchronize))
            } catch {
                let code = FPError.classify(error)
                FileProviderExtension.log.error(
                    "item(for:) failed for \(aliasCopy, privacy: .public)/\(ofemID.identifierString, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
                completionHandler(nil, nsFileProviderError(for: code))
            }
        }
        progress.cancellationHandler = { task.cancel() }
        return progress
    }

    // MARK: - Content fetch

    func fetchContents(
        for itemIdentifier: NSFileProviderItemIdentifier,
        version _: NSFileProviderItemVersion?,
        request _: NSFileProviderRequest,
        completionHandler: @escaping (URL?, NSFileProviderItem?, Error?) -> Void
    ) -> Progress {
        let progress = Progress(totalUnitCount: -1)

        let ofemID: ItemIdentifier
        do {
            ofemID = try parseOfemItemIdentifier(itemIdentifier.rawValue)
        } catch {
            completionHandler(nil, nil, NSFileProviderError(.noSuchItem))
            return progress
        }

        // Only file-level paths make sense for content fetch.
        guard case .path = ofemID else {
            // root / workspace / item root don't have file contents.
            completionHandler(nil, nil, NSFileProviderError(.noSuchItem))
            return progress
        }

        let dest: URL
        do {
            let tmpDir = try fetchScratchDirectory()
            dest = tmpDir.appendingPathComponent(UUID().uuidString)
        } catch {
            FileProviderExtension.log.error(
                "fetchContents: temp dir failed: \(error.localizedDescription, privacy: .public)"
            )
            completionHandler(nil, nil, error)
            return progress
        }

        let aliasCopy = alias
        let hostCopy = engineHost
        let task = Task {
            do {
                let engine = try await hostCopy.engine()
                let domainItem = try await engineFetchItem(
                    identifier: ofemID,
                    alias: aliasCopy,
                    engine: engine
                )
                // Download via the sync engine (returns Data).
                guard case let .path(wsID, itemID, path) = ofemID else {
                    completionHandler(nil, nil, NSFileProviderError(.noSuchItem))
                    return
                }
                let key = CacheKey(
                    accountAlias: aliasCopy,
                    workspaceID: wsID,
                    itemID: itemID,
                    path: path
                )
                let data = try await engine.sync.open(key: key)
                try data.write(to: dest)
                completionHandler(dest, domainItem, nil)
            } catch is CancellationError {
                completionHandler(nil, nil, NSFileProviderError(.cannotSynchronize))
            } catch {
                let code = FPError.classify(error)
                FileProviderExtension.log.error(
                    "fetchContents failed for \(aliasCopy, privacy: .public)/\(ofemID.identifierString, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
                completionHandler(nil, nil, nsFileProviderError(for: code))
            }
        }
        progress.cancellationHandler = { task.cancel() }
        return progress
    }

    // MARK: - Mutations

    func createItem(
        basedOn template: NSFileProviderItem,
        fields _: NSFileProviderItemFields,
        contents: URL?,
        options _: NSFileProviderCreateItemOptions = [],
        request _: NSFileProviderRequest,
        completionHandler: @escaping (
            NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?
        ) -> Void
    ) -> Progress {
        let progress = Progress(totalUnitCount: -1)

        let parentID: ItemIdentifier
        do {
            parentID = try parseOfemItemIdentifier(
                template.parentItemIdentifier.rawValue
            )
        } catch {
            completionHandler(nil, [], false, NSFileProviderError(.noSuchItem))
            return progress
        }

        let aliasCopy = alias
        let hostCopy = engineHost
        let isDir = template.contentType == .folder
        let filename = template.filename
        let srcURL = contents

        FileProviderExtension.log.debug(
            "createItem \(filename, privacy: .public) isDir=\(isDir, privacy: .public) parent=\(parentID.identifierString, privacy: .public)"
        )

        let task = Task {
            do {
                let engine = try await hostCopy.engine()
                let item = try await engineCreateItem(
                    parentID: parentID,
                    filename: filename,
                    isDir: isDir,
                    contents: srcURL,
                    alias: aliasCopy,
                    engine: engine
                )
                completionHandler(item, [], false, nil)
            } catch is CancellationError {
                completionHandler(nil, [], false, NSFileProviderError(.cannotSynchronize))
            } catch {
                let code = FPError.classify(error)
                FileProviderExtension.log.error(
                    "createItem failed: \(error.localizedDescription, privacy: .public)"
                )
                completionHandler(nil, [], false, nsFileProviderError(for: code))
            }
        }
        progress.cancellationHandler = { task.cancel() }
        return progress
    }

    func modifyItem(
        _ item: NSFileProviderItem,
        baseVersion _: NSFileProviderItemVersion,
        changedFields: NSFileProviderItemFields,
        contents: URL?,
        options _: NSFileProviderModifyItemOptions = [],
        request _: NSFileProviderRequest,
        completionHandler: @escaping (
            NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?
        ) -> Void
    ) -> Progress {
        let progress = Progress(totalUnitCount: -1)

        // Content-bearing modifications only.
        guard changedFields.contains(.contents), let contentsURL = contents else {
            FileProviderExtension.log.debug(
                "modifyItem \(item.itemIdentifier.rawValue, privacy: .public) — metadata-only, not supported"
            )
            completionHandler(
                nil, [], false,
                NSError(domain: NSCocoaErrorDomain, code: NSFeatureUnsupportedError)
            )
            return progress
        }

        let ofemID: ItemIdentifier
        do {
            ofemID = try parseOfemItemIdentifier(item.itemIdentifier.rawValue)
        } catch {
            completionHandler(nil, [], false, NSFileProviderError(.noSuchItem))
            return progress
        }

        guard case let .path(wsID, itemID, path) = ofemID else {
            completionHandler(nil, [], false, NSFileProviderError(.noSuchItem))
            return progress
        }

        let aliasCopy = alias
        let hostCopy = engineHost

        FileProviderExtension.log.debug(
            "modifyItem \(ofemID.identifierString, privacy: .public)"
        )

        let task = Task {
            do {
                let engine = try await hostCopy.engine()
                let data = try Data(contentsOf: contentsURL)
                let key = CacheKey(
                    accountAlias: aliasCopy,
                    workspaceID: wsID,
                    itemID: itemID,
                    path: path
                )
                try await engine.sync.put(key: key, content: data)
                // Re-fetch the item metadata after upload.
                let updated = try await engineFetchItem(
                    identifier: ofemID,
                    alias: aliasCopy,
                    engine: engine
                )
                completionHandler(updated, [], false, nil)
            } catch is CancellationError {
                completionHandler(nil, [], false, NSFileProviderError(.cannotSynchronize))
            } catch {
                let code = FPError.classify(error)
                FileProviderExtension.log.error(
                    "modifyItem failed: \(error.localizedDescription, privacy: .public)"
                )
                completionHandler(nil, [], false, nsFileProviderError(for: code))
            }
        }
        progress.cancellationHandler = { task.cancel() }
        return progress
    }

    func deleteItem(
        identifier: NSFileProviderItemIdentifier,
        baseVersion _: NSFileProviderItemVersion,
        options _: NSFileProviderDeleteItemOptions = [],
        request _: NSFileProviderRequest,
        completionHandler: @escaping (Error?) -> Void
    ) -> Progress {
        let progress = Progress(totalUnitCount: -1)

        let ofemID: ItemIdentifier
        do {
            ofemID = try parseOfemItemIdentifier(identifier.rawValue)
        } catch {
            completionHandler(NSFileProviderError(.noSuchItem))
            return progress
        }

        guard case let .path(wsID, itemID, path) = ofemID else {
            completionHandler(NSFileProviderError(.noSuchItem))
            return progress
        }

        let aliasCopy = alias
        let hostCopy = engineHost

        FileProviderExtension.log.debug(
            "deleteItem \(ofemID.identifierString, privacy: .public)"
        )

        let task = Task {
            do {
                let engine = try await hostCopy.engine()
                let key = CacheKey(
                    accountAlias: aliasCopy,
                    workspaceID: wsID,
                    itemID: itemID,
                    path: path
                )
                try await engine.sync.delete(key: key)
                completionHandler(nil)
            } catch is CancellationError {
                completionHandler(NSFileProviderError(.cannotSynchronize))
            } catch {
                let code = FPError.classify(error)
                FileProviderExtension.log.error(
                    "deleteItem failed: \(error.localizedDescription, privacy: .public)"
                )
                completionHandler(nsFileProviderError(for: code))
            }
        }
        progress.cancellationHandler = { task.cancel() }
        return progress
    }

    // MARK: - NSFileProviderService (XPC for host app)

    /// Exposes the OfemClientControlProtocol XPC service to the host app.
    ///
    /// The NSFileProviderReplicatedExtension protocol's async variant takes a
    /// completionHandler and returns NSProgress. The host app connects via
    /// NSFileProviderManager.service(named:for:) then calls
    /// NSFileProviderService.getFileProviderConnectionWithCompletionHandler:
    /// to obtain the NSXPCConnection.
    func supportedServiceSources(
        for itemIdentifier: NSFileProviderItemIdentifier,
        completionHandler: @escaping ([any NSFileProviderServiceSource]?, Error?) -> Void
    ) -> Progress {
        let progress = Progress(totalUnitCount: -1)
        // Only expose the service from the root container.
        if itemIdentifier == .rootContainer {
            completionHandler([OfemClientControlService(engineHost: engineHost)], nil)
        } else {
            completionHandler([], nil)
        }
        return progress
    }

    // MARK: - Enumeration

    func enumerator(
        for containerItemIdentifier: NSFileProviderItemIdentifier,
        request _: NSFileProviderRequest
    ) throws -> NSFileProviderEnumerator {
        // Working set → lightweight enumerator (no engine needed).
        if containerItemIdentifier == .workingSet {
            FileProviderExtension.log.debug(
                "enumerator(for: .workingSet) for \(self.alias, privacy: .public)"
            )
            return WorkingSetEnumerator(domain: domain)
        }

        let ofemID = try parseOfemItemIdentifier(containerItemIdentifier.rawValue)
        FileProviderExtension.log.debug(
            "enumerator(for:) for \(containerItemIdentifier.rawValue, privacy: .public) [engine-path]"
        )

        return OfemFPEEnumerator(
            containerItemIdentifier: containerItemIdentifier,
            identifier: ofemID,
            alias: alias,
            engineHost: engineHost
        )
    }
}

// MARK: - Engine helper functions

/// Fetches a single item's metadata from the engine.
private func engineFetchItem(
    identifier: ItemIdentifier,
    alias: String,
    engine: OfemEngine
) async throws -> OfemFPEItem {
    switch identifier {
    case .root:
        return OfemFPEItem(from: DomainItem.root(alias: alias))

    case let .workspace(workspaceID):
        // Look up workspace display name from the cache / discovery.
        let workspaces = try await engine.sync.listWorkspaces(alias: alias)
        if let ws = workspaces.first(where: { $0.id == workspaceID }) {
            return OfemFPEItem(from: DomainItem.from(workspace: ws))
        }
        // Not found → return a stub.
        return OfemFPEItem(from: DomainItem.stubDirectory(
            identifier: identifier,
            parentIdentifier: .root,
            name: workspaceID
        ))

    case let .item(workspaceID, itemID):
        let items = try await engine.sync.listItems(alias: alias, workspaceID: workspaceID)
        if let fi = items.first(where: { $0.id == itemID }) {
            return OfemFPEItem(from: DomainItem.from(fabricItem: fi, workspaceID: workspaceID))
        }
        return OfemFPEItem(from: DomainItem.stubDirectory(
            identifier: identifier,
            parentIdentifier: .workspace(workspaceID: workspaceID),
            name: itemID
        ))

    case let .path(workspaceID, itemID, path):
        let key = CacheKey(
            accountAlias: alias,
            workspaceID: workspaceID,
            itemID: itemID,
            path: path
        )
        // Try cache first; on miss fall back to parent enumerate.
        if let record = try? await engine.cache.fetch(key: key) {
            return OfemFPEItem(from: try DomainItem.from(record: record))
        }
        // Cache miss → enumerate parent to populate, then retry.
        let parentPath: String
        if let slashIdx = path.lastIndex(of: "/") {
            parentPath = String(path[path.startIndex..<slashIdx])
        } else {
            parentPath = ""
        }
        let parentKey = CacheKey(
            accountAlias: alias,
            workspaceID: workspaceID,
            itemID: itemID,
            path: parentPath
        )
        _ = try await engine.sync.enumerate(key: parentKey)
        if let record = try? await engine.cache.fetch(key: key) {
            return OfemFPEItem(from: try DomainItem.from(record: record))
        }
        throw FPError.noSuchItem(path)
    }
}

/// Creates a directory or file via the engine.
private func engineCreateItem(
    parentID: ItemIdentifier,
    filename: String,
    isDir: Bool,
    contents: URL?,
    alias: String,
    engine: OfemEngine
) async throws -> OfemFPEItem {
    // Derive key for the new item based on its parent.
    let (wsID, itemID, parentPath): (String, String, String)
    switch parentID {
    case let .item(w, i):
        wsID = w; itemID = i; parentPath = ""
    case let .path(w, i, p):
        wsID = w; itemID = i; parentPath = p
    default:
        throw FPError.invalidIdentifier("createItem: parent must be item or path, got \(parentID)")
    }

    let newPath = parentPath.isEmpty ? filename : "\(parentPath)/\(filename)"
    let key = CacheKey(accountAlias: alias, workspaceID: wsID, itemID: itemID, path: newPath)

    if isDir {
        try await engine.sync.mkdir(key: key)
    } else if let url = contents {
        let data = try Data(contentsOf: url)
        try await engine.sync.put(key: key, content: data)
    } else {
        // Empty file.
        try await engine.sync.put(key: key, content: Data())
    }

    // Build a synthetic item for the completion — cache row will be
    // populated after the first enumerate of the parent.
    return OfemFPEItem(from: DomainItem.synthetic(
        identifier: .path(workspaceID: wsID, itemID: itemID, path: newPath),
        parentIdentifier: parentID,
        name: filename,
        isDirectory: isDir
    ))
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
