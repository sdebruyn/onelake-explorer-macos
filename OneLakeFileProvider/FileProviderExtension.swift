// FileProviderExtension.swift
// NSFileProviderReplicatedExtension subclass for OFEM.
//
// Architecture:
// - FPE creates one FPEEngineHost per domain (one per account alias).
// - Engine-backed enumerators (OfemFPEEnumerator) handle all
//   list/enumerate operations.
// - Fetch and write operations call SyncEngine.open / put / delete /
//   mkdir directly through OfemKit.
//
// Error mapping: FPError.classify(error) maps any OfemKit error to a
// stable FPError.Code which nsFileProviderError(for:) (FPErrorMapping.swift)
// then maps to NSFileProviderError.
//
// Cancellation: CancellationError maps to CocoaError(.userCancelled) so the
// framework treats a cancelled request as an intentional abort rather than
// a sync failure.
//
// Rename / move: modifyItem detects filename and parentItemIdentifier changes
// and either performs the remote move or explicitly returns those fields as
// still-pending (.featureUnsupported) so the system does not believe the
// change was applied when it was not.

import FileProvider
import Foundation
import OfemKit
import os.log

// Identifier parsing uses OfemKit's `ItemIdentifierParser` exclusively, via
// the `parseOfemItemIdentifier` helper defined in OfemFPEEnumerator.swift.

/// File Provider Extension entry point. Sandboxed; each registered
/// OneLake account-alias gets its own instance.
///
/// `NSFileProviderServicing` is the optional protocol for exposing
/// `NSFileProviderService` sources to the host app over XPC.
private let fpeLog = Logger(
    subsystem: "dev.debruyn.ofem.fileprovider",
    category: "extension"
)

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
    /// Built lazily on first use by the engine host.
    ///
    /// Typed as `any EngineProviding` so tests can inject a mock without
    /// a live fileproviderd or a real OfemEngine.
    private let engineHost: any EngineProviding

    // MARK: - Designated initializer

    required init(domain: NSFileProviderDomain) {
        self.domain = domain
        self.alias = FileProviderExtension.extractAlias(from: domain)
        self.engineHost = FPEEngineHost(alias: self.alias, domain: domain)
        super.init()
        FileProviderExtension.log.info(
            "Initialised extension for domain \(domain.identifier.rawValue, privacy: .public) (alias=\(self.alias, privacy: .public))"
        )
    }

    /// Internal init for testing: accepts any EngineProviding.
    init(domain: NSFileProviderDomain, engineHost: any EngineProviding) {
        self.domain = domain
        self.alias = FileProviderExtension.extractAlias(from: domain)
        self.engineHost = engineHost
        super.init()
    }

    /// Directory for staging fetched file contents.
    private func fetchScratchDirectory() throws -> URL {
        guard let manager = NSFileProviderManager(for: domain) else {
            throw NSFileProviderError(.cannotSynchronize)
        }
        return try manager.temporaryDirectoryURL()
    }

    /// Called when macOS is done with this extension instance.
    ///
    /// Sets the invalidated flag synchronously before spawning the shutdown
    /// task so any concurrent `engine()` call fails fast.
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
        let progress = Progress(totalUnitCount: 0)

        // Parse identifier — use OfemKit's parser.
        let ofemID: ItemIdentifier
        do {
            ofemID = try parseOfemItemIdentifier(identifier.rawValue)
        } catch {
            completionHandler(nil, NSFileProviderError(.noSuchItem))
            return progress
        }

        // Working set / trash are synthetic; return noSuchItem.
        if ofemID == .workingSet || ofemID == .trash {
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
                completionHandler(nil, CocoaError(.userCancelled))
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
        let progress = Progress(totalUnitCount: 0)

        let ofemID: ItemIdentifier
        do {
            ofemID = try parseOfemItemIdentifier(itemIdentifier.rawValue)
        } catch {
            completionHandler(nil, nil, NSFileProviderError(.noSuchItem))
            return progress
        }

        // Only file-level paths make sense for content fetch.
        guard case let .path(wsID, itemID, path) = ofemID else {
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
            // Scratch dir failure is a retriable infrastructure error, not noSuchItem.
            completionHandler(nil, nil, nsFileProviderError(for: FPError.classify(error)))
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

                // Seed the progress with the known size so Finder shows
                // a determinate progress bar when the size is known.
                let knownSize = domainItem.documentSize?.int64Value ?? 0
                if knownSize > 0 {
                    progress.totalUnitCount = knownSize
                }

                // Download via the sync engine.
                // open() returns a file URL (streaming path):
                // bytes never pass through memory as a whole. We copy the blob
                // file to `dest` so the File Provider framework can hand it to
                // the system without touching the shared blob cache.
                let key = cacheKey(alias: aliasCopy, workspaceID: wsID, itemID: itemID, path: path)
                let blobURL = try await engine.sync.open(key: key)

                // Copy blob to the staging destination without loading into RAM.
                // Remove dest first so retries are idempotent.
                try? FileManager.default.removeItem(at: dest)
                try FileManager.default.copyItem(at: blobURL, to: dest)

                // Update progress from the file size on disk.
                let actualBytes: Int64
                if let attrs = try? FileManager.default.attributesOfItem(atPath: dest.path),
                   let sz = attrs[.size] as? NSNumber {
                    actualBytes = sz.int64Value
                } else {
                    actualBytes = knownSize
                }
                if progress.totalUnitCount < actualBytes {
                    progress.totalUnitCount = actualBytes
                }
                progress.completedUnitCount = actualBytes
                completionHandler(dest, domainItem, nil)
            } catch is CancellationError {
                completionHandler(nil, nil, CocoaError(.userCancelled))
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
        fields: NSFileProviderItemFields,
        contents: URL?,
        options: NSFileProviderCreateItemOptions = [],
        request _: NSFileProviderRequest,
        completionHandler: @escaping (
            NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?
        ) -> Void
    ) -> Progress {
        let progress = Progress(totalUnitCount: 0)

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
        let fieldsCopy = fields
        let optionsCopy = options

        FileProviderExtension.log.debug(
            "createItem \(filename, privacy: .public) isDir=\(isDir, privacy: .public) parent=\(parentID.identifierString, privacy: .public) fields=\(fieldsCopy.rawValue, privacy: .public) options=\(optionsCopy.rawValue, privacy: .public)"
        )

        let task = Task {
            do {
                let engine = try await hostCopy.engine()
                let item = try await engineCreateItem(
                    parentID: parentID,
                    filename: filename,
                    isDir: isDir,
                    contents: srcURL,
                    fields: fieldsCopy,
                    options: optionsCopy,
                    alias: aliasCopy,
                    engine: engine
                )
                completionHandler(item, [], false, nil)
            } catch is CancellationError {
                completionHandler(nil, [], false, CocoaError(.userCancelled))
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
        let progress = Progress(totalUnitCount: 0)

        // Detect rename / reparent before anything else.
        // OFEM does not implement server-side move/rename on the DFS API, so we
        // explicitly leave those fields as still-pending. The system will not
        // believe the operation succeeded and will retry or show the item at its
        // original name/location.
        let wantsRename   = changedFields.contains(.filename)
        let wantsReparent = changedFields.contains(.parentItemIdentifier)
        if wantsRename || wantsReparent {
            FileProviderExtension.log.debug(
                "modifyItem \(item.itemIdentifier.rawValue, privacy: .public) — rename/reparent not supported, leaving pending (fields=\(changedFields.rawValue, privacy: .public))"
            )
            // Return the item unchanged with the unsupported fields still pending
            // so the framework knows the operation was not applied.
            var pendingFields: NSFileProviderItemFields = []
            if wantsRename   { pendingFields.insert(.filename) }
            if wantsReparent { pendingFields.insert(.parentItemIdentifier) }
            completionHandler(item, pendingFields, false, nil)
            return progress
        }

        // Metadata-only modifications (mtime, tags, lastUsedDate, favoriteRank).
        // The system sends these routinely and expects an ack. We apply what we
        // can (nothing persisted remotely for these fields) and return the
        // existing item with a fresh version token.
        if !changedFields.contains(.contents) {
            FileProviderExtension.log.debug(
                "modifyItem \(item.itemIdentifier.rawValue, privacy: .public) — metadata-only (fields=\(changedFields.rawValue, privacy: .public)), acknowledging"
            )
            let ofemID: ItemIdentifier
            do {
                ofemID = try parseOfemItemIdentifier(item.itemIdentifier.rawValue)
            } catch {
                completionHandler(nil, [], false, NSFileProviderError(.noSuchItem))
                return progress
            }

            let aliasCopy = alias
            let hostCopy = engineHost
            let task = Task {
                do {
                    let engine = try await hostCopy.engine()
                    let existing = try await engineFetchItem(
                        identifier: ofemID,
                        alias: aliasCopy,
                        engine: engine
                    )
                    completionHandler(existing, [], false, nil)
                } catch is CancellationError {
                    completionHandler(nil, [], false, CocoaError(.userCancelled))
                } catch {
                    let code = FPError.classify(error)
                    FileProviderExtension.log.error(
                        "modifyItem(metadata) fetch failed: \(error.localizedDescription, privacy: .public)"
                    )
                    completionHandler(nil, [], false, nsFileProviderError(for: code))
                }
            }
            progress.cancellationHandler = { task.cancel() }
            return progress
        }

        // Content-bearing modification.
        guard let contentsURL = contents else {
            // changedFields includes .contents but the URL is nil — treat as
            // metadata-only (nothing to upload).
            FileProviderExtension.log.debug(
                "modifyItem \(item.itemIdentifier.rawValue, privacy: .public) — .contents set but URL nil, acknowledging"
            )
            completionHandler(item, [], false, nil)
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
                let fileSize: Int64
                if let attrs = try? FileManager.default.attributesOfItem(atPath: contentsURL.path),
                   let sz = attrs[.size] as? NSNumber {
                    fileSize = sz.int64Value
                } else {
                    fileSize = 0
                }
                if fileSize > 0 {
                    progress.totalUnitCount = fileSize
                }
                let key = cacheKey(alias: aliasCopy, workspaceID: wsID, itemID: itemID, path: path)
                try await engine.sync.put(key: key, sourceURL: contentsURL)
                progress.completedUnitCount = progress.totalUnitCount
                // Re-fetch the item metadata after upload so the returned version
                // matches what subsequent enumeration produces.
                let updated = try await engineFetchItem(
                    identifier: ofemID,
                    alias: aliasCopy,
                    engine: engine
                )
                completionHandler(updated, [], false, nil)
            } catch is CancellationError {
                completionHandler(nil, [], false, CocoaError(.userCancelled))
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
        let progress = Progress(totalUnitCount: 0)

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
                let key = cacheKey(alias: aliasCopy, workspaceID: wsID, itemID: itemID, path: path)
                try await engine.sync.delete(key: key)
                completionHandler(nil)
            } catch is CancellationError {
                completionHandler(CocoaError(.userCancelled))
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
        let progress = Progress(totalUnitCount: 0)
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
        // Parse first so we can branch on the typed identifier.
        let ofemID = try parseOfemItemIdentifier(containerItemIdentifier.rawValue)

        // Working set / trash → lightweight empty enumerator (no engine needed).
        // Trash is not supported; returning an empty enumerator prevents macOS
        // from retrying indefinitely.
        if ofemID == .workingSet || ofemID == .trash {
            FileProviderExtension.log.debug(
                "enumerator(for: .workingSet/.trash) for \(self.alias, privacy: .public)"
            )
            return OfemWorkingSetEnumerator(alias: alias, engineHost: engineHost)
        }
        FileProviderExtension.log.debug(
            "enumerator(for:) for \(containerItemIdentifier.rawValue, privacy: .public)"
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
///
/// Returns `.noSuchItem` for unknown workspace/item identifiers instead of
/// fabricating GUID-named stub directories.
///
/// Distinguishes `CacheError.notFound` (triggers parent enumerate + retry)
/// from other cache errors (maps to cannotSynchronize, not noSuchItem) so
/// a transient DB failure does not trigger local replica deletion.
private func engineFetchItem(
    identifier: ItemIdentifier,
    alias: String,
    engine: OfemEngine
) async throws -> OfemFPEItem {
    switch identifier {
    case .root:
        return OfemFPEItem(from: DomainItem.root(alias: alias))

    case .trash, .workingSet:
        throw FPError.noSuchItem("synthetic container: \(identifier.identifierString)")

    case let .workspace(workspaceID):
        // Look up workspace display name from the cache / discovery.
        let workspaces = try await engine.sync.listWorkspaces(alias: alias)
        if let ws = workspaces.first(where: { $0.id == workspaceID }) {
            return OfemFPEItem(from: DomainItem.from(workspace: ws))
        }
        // Absence after successful listing = definitive "not found".
        throw FPError.noSuchItem("workspace \(workspaceID) not in listing for alias \(alias)")

    case let .item(workspaceID, itemID):
        let items = try await engine.sync.listItems(alias: alias, workspaceID: workspaceID)
        if let fi = items.first(where: { $0.id == itemID }) {
            return OfemFPEItem(from: DomainItem.from(fabricItem: fi, workspaceID: workspaceID))
        }
        // Absence after successful listing = definitive "not found".
        throw FPError.noSuchItem("item \(itemID) not in listing for workspace \(workspaceID)")

    case let .path(workspaceID, itemID, path):
        let key = cacheKey(alias: alias, workspaceID: workspaceID, itemID: itemID, path: path)

        // Distinguish CacheError.notFound (trigger parent enumerate)
        // from real DB failures (cannotSynchronize, not noSuchItem).
        let firstFetchResult: Result<MetadataRecord, Error>
        do {
            firstFetchResult = .success(try await engine.cache.fetch(key: key))
        } catch {
            firstFetchResult = .failure(error)
        }

        switch firstFetchResult {
        case .success(let record):
            do {
                return OfemFPEItem(from: try DomainItem.from(record: record))
            } catch {
                throw FPError.invalidRecord("DomainItem.from failed for \(path): \(error)")
            }

        case .failure(let cacheError as CacheError):
            // Only .notFound means "not in cache, try enumerating parent".
            // Any other CacheError is an infrastructure failure — propagate.
            guard case .notFound = cacheError else {
                throw FPError.invalidRecord("cache DB error for \(path): \(cacheError)")
            }
            // Fall through to parent enumerate.

        case .failure(let other):
            throw FPError.invalidRecord("unexpected cache error for \(path): \(other)")
        }

        // Cache miss → enumerate parent to populate, then retry.
        let parent = parentPath(of: path)
        let parentKey = cacheKey(alias: alias, workspaceID: workspaceID, itemID: itemID, path: parent)
        // Propagate enumeration failures (network, auth) — they are retriable.
        _ = try await engine.sync.enumerate(key: parentKey)

        // Retry cache lookup with full error discrimination.
        do {
            let record = try await engine.cache.fetch(key: key)
            return OfemFPEItem(from: try DomainItem.from(record: record))
        } catch let cacheError as CacheError {
            switch cacheError {
            case .notFound:
                // Still absent after enumeration → definitively gone.
                throw FPError.noSuchItem(path)
            default:
                // DB failure on retry — retriable, not a deletion signal.
                throw FPError.invalidRecord("cache DB error on retry for \(path): \(cacheError)")
            }
        } catch {
            throw FPError.invalidRecord("DomainItem.from failed on retry for \(path): \(error)")
        }
    }
}

/// Creates a directory or file via the engine.
///
/// Honours `fields` and `options`:
/// - `.mayAlreadyExist`: do not upload content; re-fetch and return the
///   existing remote item. Cache errors are discriminated — only
///   `CacheError.notFound` is treated as "not yet cached"; other errors
///   propagate so a DB failure does not silently trigger an unintended upload.
/// - `fields` does not contain `.contents`: create a directory or metadata-
///   only placeholder without uploading `Data()`.
///
/// Re-fetches real metadata after upload so the returned item's version/size
/// matches subsequent enumerations.
private func engineCreateItem(
    parentID: ItemIdentifier,
    filename: String,
    isDir: Bool,
    contents: URL?,
    fields: NSFileProviderItemFields,
    options: NSFileProviderCreateItemOptions,
    alias: String,
    engine: OfemEngine
) async throws -> OfemFPEItem {
    // Derive key for the new item based on its parent.
    let (wsID, itemID, parentPathStr): (String, String, String)
    switch parentID {
    case let .item(w, i):
        wsID = w; itemID = i; parentPathStr = ""
    case let .path(w, i, p):
        wsID = w; itemID = i; parentPathStr = p
    default:
        throw FPError.invalidIdentifier("createItem: parent must be item or path, got \(parentID)")
    }

    let newPath = parentPathStr.isEmpty ? filename : "\(parentPathStr)/\(filename)"
    let key = cacheKey(alias: alias, workspaceID: wsID, itemID: itemID, path: newPath)
    let newIdentifier = ItemIdentifier.path(workspaceID: wsID, itemID: itemID, path: newPath)

    // Honour .mayAlreadyExist — the system is re-importing items that may
    // have pre-existing remote content. Don't upload/overwrite.
    if options.contains(.mayAlreadyExist) {
        // Discriminate CacheError.notFound from real DB errors: only .notFound
        // means "not yet cached"; other errors must propagate.
        let cacheResult: Result<MetadataRecord, Error>
        do {
            cacheResult = .success(try await engine.cache.fetch(key: key))
        } catch {
            cacheResult = .failure(error)
        }
        switch cacheResult {
        case .success(let record):
            if let di = try? DomainItem.from(record: record) {
                return OfemFPEItem(from: di)
            }
        case .failure(let cacheError as CacheError):
            guard case .notFound = cacheError else {
                throw cacheError  // Real DB error — propagate
            }
            // .notFound: fall through to parent enumerate
        case .failure(let other):
            throw other
        }

        // Not in cache: enumerate parent to populate, then retry.
        let parentKey = cacheKey(alias: alias, workspaceID: wsID, itemID: itemID, path: parentPathStr)
        _ = try await engine.sync.enumerate(key: parentKey)

        let retryResult: Result<MetadataRecord, Error>
        do {
            retryResult = .success(try await engine.cache.fetch(key: key))
        } catch {
            retryResult = .failure(error)
        }
        switch retryResult {
        case .success(let record):
            if let di = try? DomainItem.from(record: record) {
                return OfemFPEItem(from: di)
            }
        case .failure(let cacheError as CacheError):
            guard case .notFound = cacheError else {
                throw cacheError  // Real DB error — propagate
            }
            // .notFound: still not found — fall through to normal create
        case .failure(let other):
            throw other
        }
        // Still not found — fall through to normal create path (it's new).
    }

    if isDir {
        try await engine.sync.mkdir(key: key)
    } else {
        // Only upload if `fields` includes `.contents` AND a URL was provided.
        // A nil URL or absent `.contents` field means "placeholder only" —
        // uploading Data() would truncate an existing remote file.
        let shouldUpload = fields.contains(.contents) && contents != nil
        if shouldUpload, let url = contents {
            // Stream from the provided URL — no in-memory Data load.
            try await engine.sync.put(key: key, sourceURL: url)
        }
        // If no upload: we still return an item descriptor; the real content
        // is on the remote and will be fetched on demand.
    }

    // Re-fetch real metadata so version/size matches enumeration.
    // If the cache row is not yet populated (e.g. mkdir with no enumerate),
    // fall back to a synthetic item but log the situation.
    let postCreateFetch: Result<MetadataRecord, Error>
    do {
        postCreateFetch = .success(try await engine.cache.fetch(key: key))
    } catch {
        postCreateFetch = .failure(error)
    }
    switch postCreateFetch {
    case .success(let record):
        if let di = try? DomainItem.from(record: record) {
            return OfemFPEItem(from: di)
        }
    case .failure(let cacheError as CacheError):
        guard case .notFound = cacheError else {
            // A non-notFound cache error is unexpected but not fatal here;
            // log and fall through to the synthetic fallback.
            fpeLog.warning(
                "createItem: cache fetch error for \(filename, privacy: .public): \(cacheError.localizedDescription, privacy: .public)"
            )
            break
        }
        // .notFound: enumerate parent to populate it, then retry.
        let parentKey = cacheKey(alias: alias, workspaceID: wsID, itemID: itemID, path: parentPathStr)
        _ = try? await engine.sync.enumerate(key: parentKey)
        if let record = try? await engine.cache.fetch(key: key),
           let di = try? DomainItem.from(record: record) {
            return OfemFPEItem(from: di)
        }
    case .failure(let other):
        fpeLog.warning(
            "createItem: unexpected fetch error for \(filename, privacy: .public): \(other.localizedDescription, privacy: .public)"
        )
    }

    // Final fallback: synthetic item. This case should be rare (e.g. mkdir
    // on a backend that doesn't enumerate immediately), and the version
    // mismatch will resolve on the next full enumeration of the parent.
    fpeLog.warning(
        "createItem: using synthetic fallback for \(filename, privacy: .public) parent=\(parentID.identifierString, privacy: .public)"
    )
    return OfemFPEItem(from: DomainItem.synthetic(
        identifier: newIdentifier,
        parentIdentifier: parentID,
        name: filename,
        isDirectory: isDir
    ))
}

// MARK: - Domain identifier → alias

/// Identifier prefix every OFEM-owned domain carries.
/// Mirrored in `DomainSyncManager` in the host app target; the two
/// targets do not share source files, so it is defined in both.
private let ofemDomainIdentifierPrefix = "ofem."

extension FileProviderExtension {
    /// Strips the `ofem.` prefix from the domain identifier to recover
    /// the user-chosen account alias (e.g. `"ofem.work"` → `"work"`).
    static func extractAlias(from domain: NSFileProviderDomain) -> String {
        let raw = domain.identifier.rawValue
        if raw.hasPrefix(ofemDomainIdentifierPrefix) {
            return String(raw.dropFirst(ofemDomainIdentifierPrefix.count))
        }
        return raw
    }
}
