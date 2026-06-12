// FileProviderExtension.swift
// `NSFileProviderReplicatedExtension` subclass for OFEM.
//
// Architecture:
// - FPE creates one FPEEngineHost per domain (one per account alias).
// - Engine-backed enumerators (OfemFPEEnumerator) handle all
// list/enumerate operations.
// - Fetch and write operations call SyncEngine.open / put / delete /
// mkdir directly through OfemKit.
//
// Error mapping: FPError.classify(error) maps any OfemKit error to a
// stable FPError.Code which nsFileProviderError(for:) (FPErrorMapping.swift)
// then maps to NSFileProviderError.
//
// fpe-02 fix: createItem honours `fields` and `options`.
//   - `NSFileProviderCreateItemOptions.mayAlreadyExist`: do not upload
//     contents; return a metadata-only item referencing the existing remote.
//   - `fields` does not contain `.contents`: a nil-contents create must NOT
//     upload `Data()` that truncates an existing remote file. Instead return
//     the item without touching OneLake (directory or placeholder).
//
// fpe-04 fix: createItem re-fetches the item metadata after upload so the
//   returned item's version/size matches what later enumeration produces.
//
// fpe-07 fix: item(for:) returns .noSuchItem for unknown workspace/item
//   identifiers instead of fabricating GUID-named stub directories.
//
// fpe-08 fix: cache fetch errors are distinguished from item absence.
//   `try? await engine.cache.fetch(key:)` is replaced with `do/catch`
//   that maps `CacheError.notFound` → `.noSuchItem` and any other error
//   → `.cannotSynchronize` (a retriable error that does not trigger local
//   replica deletion).
//
// fpe-09 fix: metadata-only modifyItem succeeds by acknowledging the call
//   and returning the existing item (applying what's applicable, dropping
//   the rest) instead of returning .featureUnsupported.
//
// fpe-18 fix: CacheKey construction and parent-path arithmetic use the
//   shared helpers in FPEHelpers.swift.
//
// fpe-22 fix: fetchContents returns a determinate Progress whose
//   totalUnitCount is seeded from the known documentSize when available.

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
/// File-scoped logger for the free `engineXxx` helper functions, which cannot
/// reach `FileProviderExtension`'s private static logger.
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
    /// Built lazily on first use by FPEEngineHost.
    private let engineHost: FPEEngineHost

    // MARK: - Designated initializer

    required init(domain: NSFileProviderDomain) {
        self.domain = domain
        self.alias = FileProviderExtension.extractAlias(from: domain)
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
    ///
    /// fpe-11: sets the invalidated flag before spawning the shutdown task so
    /// any concurrent `engine()` call fails fast instead of rebuilding.
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
        // fpe-22: seed totalUnitCount from the item's known documentSize.
        // We start at -1 (indeterminate) and update it when we know the size.
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

                // Seed the progress with the known size so Finder shows
                // a determinate progress bar (fpe-22).
                let knownSize = domainItem.documentSize?.int64Value ?? 0
                if knownSize > 0 {
                    progress.totalUnitCount = knownSize
                }

                // Download via the sync engine (returns Data).
                guard case let .path(wsID, itemID, path) = ofemID else {
                    completionHandler(nil, nil, NSFileProviderError(.noSuchItem))
                    return
                }
                let key = cacheKey(alias: aliasCopy, workspaceID: wsID, itemID: itemID, path: path)
                let data = try await engine.sync.open(key: key)

                // Update totalUnitCount to the actual size if it was unknown or
                // underestimated, so completedUnitCount never exceeds totalUnitCount.
                let actualBytes = Int64(data.count)
                if progress.totalUnitCount < actualBytes {
                    progress.totalUnitCount = actualBytes
                }
                progress.completedUnitCount = actualBytes
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
        fields: NSFileProviderItemFields,
        contents: URL?,
        options: NSFileProviderCreateItemOptions = [],
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

        // fpe-09: honour metadata-only modifications (mtime, tags, lastUsedDate,
        // favoriteRank). The system sends these routinely and expects an ack, not
        // an error. We apply what we can (nothing persisted remotely for these
        // fields currently) and return the existing item.
        if !changedFields.contains(.contents) {
            FileProviderExtension.log.debug(
                "modifyItem \(item.itemIdentifier.rawValue, privacy: .public) — metadata-only (fields=\(changedFields.rawValue, privacy: .public)), acknowledging"
            )
            // Re-fetch and return the existing item so the system has a
            // fresh version token. If fetch fails the error is mapped and
            // returned so the system can retry.
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
                    // Return the item with no pending fields — we've acknowledged.
                    completionHandler(existing, [], false, nil)
                } catch is CancellationError {
                    completionHandler(nil, [], false, NSFileProviderError(.cannotSynchronize))
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
                let data = try Data(contentsOf: contentsURL)
                // Seed progress.
                if data.count > 0 {
                    progress.totalUnitCount = Int64(data.count)
                }
                let key = cacheKey(alias: aliasCopy, workspaceID: wsID, itemID: itemID, path: path)
                try await engine.sync.put(key: key, content: data)
                progress.completedUnitCount = progress.totalUnitCount
                // Re-fetch the item metadata after upload (fpe-04 pattern).
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
                let key = cacheKey(alias: aliasCopy, workspaceID: wsID, itemID: itemID, path: path)
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
        // Parse first so we can branch on the typed identifier.
        let ofemID = try parseOfemItemIdentifier(containerItemIdentifier.rawValue)

        // Working set / trash → lightweight empty enumerator (no engine needed).
        // Trash is not supported; returning an empty enumerator prevents macOS
        // from retrying indefinitely (which would happen if OfemFPEEnumerator
        // threw noSuchItem → cannotSynchronize for the trash container).
        if ofemID == .workingSet || ofemID == .trash {
            FileProviderExtension.log.debug(
                "enumerator(for: .workingSet/.trash) for \(self.alias, privacy: .public)"
            )
            return OfemWorkingSetEnumerator(alias: alias, engineHost: engineHost)
        }
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
///
/// fpe-07 fix: returns `.noSuchItem` for unknown workspace/item identifiers
/// instead of fabricating GUID-named stub directories.
///
/// fpe-08 fix: distinguishes `CacheError.notFound` (→ noSuchItem) from other
/// cache errors (→ cannotSynchronize) so a transient DB failure doesn't
/// trigger local replica deletion.
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
        // fpe-07: absence after successful listing = definitive "not found".
        throw FPError.noSuchItem("workspace \(workspaceID) not in listing for alias \(alias)")

    case let .item(workspaceID, itemID):
        let items = try await engine.sync.listItems(alias: alias, workspaceID: workspaceID)
        if let fi = items.first(where: { $0.id == itemID }) {
            return OfemFPEItem(from: DomainItem.from(fabricItem: fi, workspaceID: workspaceID))
        }
        // fpe-07: absence after successful listing = definitive "not found".
        throw FPError.noSuchItem("item \(itemID) not in listing for workspace \(workspaceID)")

    case let .path(workspaceID, itemID, path):
        let key = cacheKey(alias: alias, workspaceID: workspaceID, itemID: itemID, path: path)

        // fpe-08: distinguish CacheError.notFound (→ try parent enumerate)
        // from real DB failures (→ cannotSynchronize, not noSuchItem).
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
/// fpe-02 fix: honours `fields` and `options`.
/// - `.mayAlreadyExist`: do not upload content; re-fetch and return the
///   existing remote item.
/// - `fields` does not contain `.contents`: create a directory or metadata-
///   only placeholder without uploading `Data()`.
///
/// fpe-04 fix: re-fetches real metadata after upload so the returned item's
/// version/size matches subsequent enumerations.
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

    // fpe-02: honour .mayAlreadyExist — the system is re-importing items
    // that may have pre-existing remote content. Don't upload/overwrite.
    if options.contains(.mayAlreadyExist) {
        // Try to fetch the existing item. If not found, treat as a new
        // create but still don't upload nil-contents data.
        if let record = try? await engine.cache.fetch(key: key),
           let di = try? DomainItem.from(record: record) {
            return OfemFPEItem(from: di)
        }
        // Not in cache: enumerate parent to populate, then retry.
        // C4: propagate auth/network errors instead of silently swallowing them.
        let parentKey = cacheKey(alias: alias, workspaceID: wsID, itemID: itemID, path: parentPathStr)
        _ = try await engine.sync.enumerate(key: parentKey)
        if let record = try? await engine.cache.fetch(key: key),
           let di = try? DomainItem.from(record: record) {
            return OfemFPEItem(from: di)
        }
        // Still not found — fall through to normal create path (it's new).
    }

    if isDir {
        try await engine.sync.mkdir(key: key)
    } else {
        // fpe-02: only upload if `fields` includes `.contents` AND a URL
        // was provided. A nil URL or absent `.contents` field means
        // "placeholder only" — uploading Data() would truncate an existing
        // remote file.
        let shouldUpload = fields.contains(.contents) && contents != nil
        if shouldUpload, let url = contents {
            let data = try Data(contentsOf: url)
            // Seed progress if caller can observe it.
            try await engine.sync.put(key: key, content: data)
        }
        // If no upload: we still return an item descriptor; the real content
        // is on the remote and will be fetched on demand.
    }

    // fpe-04: re-fetch real metadata so version/size matches enumeration.
    // If the cache row is not yet populated (e.g. mkdir with no enumerate),
    // fall back to a synthetic item but log the situation.
    do {
        let record = try await engine.cache.fetch(key: key)
        if let di = try? DomainItem.from(record: record) {
            return OfemFPEItem(from: di)
        }
    } catch is CacheError {
        // Not yet in cache: enumerate parent to populate it, then retry.
        let parentKey = cacheKey(alias: alias, workspaceID: wsID, itemID: itemID, path: parentPathStr)
        _ = try? await engine.sync.enumerate(key: parentKey)
        if let record = try? await engine.cache.fetch(key: key),
           let di = try? DomainItem.from(record: record) {
            return OfemFPEItem(from: di)
        }
    }

    // Final fallback: synthetic item. This case should be rare (e.g. mkdir
    // on a backend that doesn't enumerate immediately), and the version
    // mismatch will resolve on the next full enumeration of the parent.
    // N2: log the fallback so it is visible in diagnostics.
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
