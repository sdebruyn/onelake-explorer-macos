// FileProviderExtension.swift
// NSFileProviderReplicatedExtension subclass for OFEM.
//
// Architecture:
// - FPE creates one FPEEngineHost per domain (one per account alias).
// - Engine-backed enumerators (OfemFPEEnumerator) handle all
//   list/enumerate operations.
// - Fetch and write operations call SyncEngine.openReturningRecord / put /
//   delete / mkdir directly through OfemKit.
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

@preconcurrency import FileProvider
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

/// Boxes a non-`Sendable` value for safe capture across `Task` isolation boundaries.
///
/// `NSFileProviderReplicatedExtension` completion handlers are `@escaping` but not
/// `@Sendable`. Wrapping them in this struct lets `Task` closures capture them without
/// triggering Swift 6 sendability diagnostics. The caller is responsible for ensuring
/// that the wrapped value is only invoked on a thread where it is safe to do so —
/// in practice the FPE callbacks are called once at the end of each operation.
private struct UncheckedSendable<T>: @unchecked Sendable { let value: T }

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
        let ts = BuildInfo.buildTimestamp ?? "unknown"
        FileProviderExtension.log.info(
            "OneLake FPE starting — version \(BuildInfo.version, privacy: .public) built \(ts, privacy: .public) domain=\(domain.identifier.rawValue, privacy: .public) alias=\(self.alias, privacy: .public)"
        )
    }

    // periphery:ignore
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
        // Capture engineHost (Sendable) explicitly so the Task body does not
        // need to capture self, which is not Sendable.
        let hostCopy = engineHost
        Task {
            await hostCopy.shutdown()
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
        // NSFileProviderReplicatedExtension completion handlers are @escaping but
        // not @Sendable. Box to cross the Task isolation boundary safely.
        let ch = UncheckedSendable(value: completionHandler)
        let task = Task {
            do {
                let engine = try await hostCopy.engine()
                let item = try await engineFetchItem(
                    identifier: ofemID,
                    alias: aliasCopy,
                    engine: engine
                )
                ch.value(item, nil)
            } catch is CancellationError {
                ch.value(nil, CocoaError(.userCancelled))
            } catch {
                let code = FPError.classify(error)
                FileProviderExtension.log.error(
                    "item(for:) failed for \(aliasCopy, privacy: .public)/\(ofemID.identifierString, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
                ch.value(nil, nsFileProviderError(for: code))
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
        // NSFileProviderReplicatedExtension completion handlers are @escaping but
        // not @Sendable. Box to cross the Task isolation boundary safely.
        let ch = UncheckedSendable(value: completionHandler)
        let task = Task {
            do {
                let engine = try await hostCopy.engine()

                // Download (or serve from cache) first, then build the
                // returned item from the SAME record that describes what was
                // just served — not a snapshot fetched before the download
                // ran. The old order fetched the item, then downloaded, then
                // handed back the pre-download version alongside the
                // post-download bytes, so the framework recorded a stale
                // contentVersion and re-downloaded the "changed" file on the
                // next cycle. openReturningRecord also folds what used to be
                // several separate metadata reads (item lookup, freshness
                // check, blob link) into the single read/write `open()`
                // already performs.
                let key = cacheKey(alias: aliasCopy, workspaceID: wsID, itemID: itemID, path: path)
                let (_, record) = try await engine.sync.openReturningRecord(key: key)
                let domainItem: OfemFPEItem
                do {
                    domainItem = OfemFPEItem(from: try DomainItem.from(record: record))
                } catch {
                    throw FPError.invalidRecord("DomainItem.from failed for \(path): \(error)")
                }

                if let size = domainItem.documentSize?.int64Value, size > 0 {
                    progress.totalUnitCount = size
                }

                // Remove dest first so retries are idempotent, then hand off
                // the blob to the FPE without a full copy: handoffBlob hard-
                // links the cache file to `dest` (fpe-06) using the record we
                // already have, rather than re-fetching it. Because cache
                // blobs are immutable content-addressed files, the hard link
                // is safe: a cache eviction of the entry removes the shard
                // dir entry but leaves the inode (and `dest`) intact.
                try? FileManager.default.removeItem(at: dest)
                try await engine.cache.handoffBlob(record: record, to: dest)

                // Update progress from the file size on disk.
                let actualBytes: Int64 = if let attrs = try? FileManager.default.attributesOfItem(atPath: dest.path),
                                            let sz = attrs[.size] as? NSNumber
                {
                    sz.int64Value
                } else {
                    domainItem.documentSize?.int64Value ?? 0
                }
                if progress.totalUnitCount < actualBytes {
                    progress.totalUnitCount = actualBytes
                }
                progress.completedUnitCount = actualBytes
                ch.value(dest, domainItem, nil)
            } catch is CancellationError {
                ch.value(nil, nil, CocoaError(.userCancelled))
            } catch {
                let code = FPError.classify(error)
                FileProviderExtension.log.error(
                    "fetchContents failed for \(aliasCopy, privacy: .public)/\(ofemID.identifierString, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
                ch.value(nil, nil, nsFileProviderError(for: code))
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

        // NSFileProviderReplicatedExtension completion handlers are @escaping but
        // not @Sendable. Box to cross the Task isolation boundary safely.
        let ch = UncheckedSendable(value: completionHandler)
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
                ch.value(item, [], false, nil)
            } catch is CancellationError {
                ch.value(nil, [], false, CocoaError(.userCancelled))
            } catch {
                let code = FPError.classify(error)
                FileProviderExtension.log.error(
                    "createItem failed: \(error.localizedDescription, privacy: .public)"
                )
                ch.value(nil, [], false, nsFileProviderError(for: code))
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
        // Move/reparent (parentItemIdentifier change) is not yet implemented —
        // leave it as still-pending. Same-directory rename (filename change only)
        // is handled below via the DFS x-ms-rename-source API.
        let wantsRename = changedFields.contains(.filename)
        let wantsReparent = changedFields.contains(.parentItemIdentifier)
        if wantsReparent {
            FileProviderExtension.log.debug(
                "modifyItem \(item.itemIdentifier.rawValue, privacy: .public) — reparent not supported, leaving pending (fields=\(changedFields.rawValue, privacy: .public))"
            )
            var pendingFields: NSFileProviderItemFields = [.parentItemIdentifier]
            if wantsRename { pendingFields.insert(.filename) }
            completionHandler(item, pendingFields, false, nil)
            return progress
        }

        if wantsRename {
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
            let newFilename = item.filename
            // Reject an empty filename or one containing a path separator before
            // touching the engine. An empty name yields a trailing-slash
            // destination (the empty-filename class fixed in a0b2e66/ab283ce);
            // a "/"-containing name would silently turn a same-directory rename
            // into a cross-directory move on DFS. macOS should never send one,
            // but guard rather than rely on that.
            guard !newFilename.isEmpty, !newFilename.contains("/") else {
                FileProviderExtension.log.error(
                    "modifyItem \(ofemID.opaqueLogPrefix, privacy: .public) — rejecting invalid rename filename"
                )
                completionHandler(nil, [], false, NSFileProviderError(.filenameCollision))
                return progress
            }
            // Preserve the original identifier so the success path can return it
            // unchanged; returning a new (path-derived) identifier would make the
            // framework treat the rename as delete-old + add-new.
            let originalIdentifier = ofemID
            // Any non-filename fields delivered in the same modifyItem (e.g. a
            // coalesced [.filename, .contents] from a save-then-rename) must stay
            // pending so the framework re-issues a dedicated modifyItem for them;
            // acking [] would tell the framework those changes applied → data loss.
            let nonRenameFields = changedFields.subtracting([.filename])
            let aliasCopy = alias
            let hostCopy = engineHost
            FileProviderExtension.log.debug(
                "modifyItem \(ofemID.identifierString, privacy: .public) — rename to \(newFilename, privacy: .public)"
            )
            let ch = UncheckedSendable(value: completionHandler)
            let task = Task {
                do {
                    let engine = try await hostCopy.engine()
                    let key = CacheKey(
                        accountAlias: aliasCopy,
                        workspaceID: wsID,
                        itemID: itemID,
                        path: path
                    )
                    let updated = try await engine.sync.rename(key: key, newName: newFilename)
                    // Return the ORIGINAL identifier with the new filename/size/
                    // dates so the framework registers a metadata change, not a
                    // delete+add (see DomainItem.from(record:overridingIdentifier:)).
                    let fpeItem = OfemFPEItem(
                        from: try DomainItem.from(record: updated, overridingIdentifier: originalIdentifier)
                    )
                    ch.value(fpeItem, nonRenameFields, false, nil)
                } catch is CancellationError {
                    ch.value(nil, [], false, CocoaError(.userCancelled))
                } catch {
                    // Rename failed: leave ALL changed fields pending so the
                    // framework retries rather than treating the item as renamed
                    // (or, for a co-delivered .contents, as uploaded) locally.
                    FileProviderExtension.log.error(
                        "modifyItem rename failed: \(error.localizedDescription, privacy: .public)"
                    )
                    ch.value(item, changedFields, false, nil)
                }
            }
            progress.cancellationHandler = { task.cancel() }
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
            // NSFileProviderReplicatedExtension completion handlers are @escaping
            // but not @Sendable. Box to cross the Task isolation boundary safely.
            let ch = UncheckedSendable(value: completionHandler)
            let task = Task {
                do {
                    let engine = try await hostCopy.engine()
                    let existing = try await engineFetchItem(
                        identifier: ofemID,
                        alias: aliasCopy,
                        engine: engine
                    )
                    ch.value(existing, [], false, nil)
                } catch is CancellationError {
                    ch.value(nil, [], false, CocoaError(.userCancelled))
                } catch {
                    let code = FPError.classify(error)
                    FileProviderExtension.log.error(
                        "modifyItem(metadata) fetch failed: \(error.localizedDescription, privacy: .public)"
                    )
                    ch.value(nil, [], false, nsFileProviderError(for: code))
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

        // NSFileProviderReplicatedExtension completion handlers are @escaping but
        // not @Sendable. Box to cross the Task isolation boundary safely.
        let ch = UncheckedSendable(value: completionHandler)
        let task = Task {
            do {
                let engine = try await hostCopy.engine()
                let fileSize: Int64 = if let attrs = try? FileManager.default.attributesOfItem(atPath: contentsURL.path),
                                         let sz = attrs[.size] as? NSNumber
                {
                    sz.int64Value
                } else {
                    0
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
                ch.value(updated, [], false, nil)
            } catch is CancellationError {
                ch.value(nil, [], false, CocoaError(.userCancelled))
            } catch {
                let code = FPError.classify(error)
                FileProviderExtension.log.error(
                    "modifyItem failed: \(error.localizedDescription, privacy: .public)"
                )
                ch.value(nil, [], false, nsFileProviderError(for: code))
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

        // NSFileProviderReplicatedExtension completion handlers are @escaping but
        // not @Sendable. Box to cross the Task isolation boundary safely.
        let ch = UncheckedSendable(value: completionHandler)
        let task = Task {
            do {
                let engine = try await hostCopy.engine()
                let key = cacheKey(alias: aliasCopy, workspaceID: wsID, itemID: itemID, path: path)
                try await engine.sync.delete(key: key)
                ch.value(nil)
            } catch is CancellationError {
                ch.value(CocoaError(.userCancelled))
            } catch {
                let code = FPError.classify(error)
                FileProviderExtension.log.error(
                    "deleteItem failed: \(error.localizedDescription, privacy: .public)"
                )
                ch.value(nsFileProviderError(for: code))
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

    // MARK: - Materialized items tracking

    /// Guards against overlapping rescans when macOS fires the callback in bursts
    /// (e.g. during bulk materialization). Access is serialised by `materializeLock`.
    private let materializeLock = NSLock()
    private nonisolated(unsafe) var materializeTaskInFlight: Task<Void, Never>?

    /// Called by macOS when the set of materialized (on-disk, non-dataless) containers changes.
    ///
    /// **Re-entry / coalescing contract**: macOS fires this callback repeatedly during burst
    /// materializations. Each call cancels any still-pending scan and starts a fresh one so
    /// overlapping calls collapse into a single re-enumeration. Because `setMaterialized` is
    /// a full replace, the last completed scan always wins — no partial updates are possible.
    ///
    /// Enumerates `NSFileProviderManager(for:).enumeratorForMaterializedItems` across all
    /// pages, filters to directory-bearing containers (`.workspace`, `.item`, `.path`),
    /// excludes the root and working-set sentinels, and persists the resulting set via
    /// `CacheStore.setMaterialized`. Unexpected or unparseable identifiers are logged and
    /// skipped, not fatal.
    ///
    /// **Delta-internal depth cap**: `.path` containers whose path has more than 3
    /// slash-delimited components, or that contain the segment `_delta_log`, are
    /// excluded from the persisted set. This bounds the poll fan-out for partitioned
    /// Delta tables (where macOS materializes `_delta_log`, partition GUID dirs, and
    /// individual `.parquet` files) while keeping every user-navigable level
    /// (`Tables`, `Tables/<schema>`, `Tables/<schema>/<table>`, `Files/<dirs>`).
    func materializedItemsDidChange(completionHandler: @escaping () -> Void) {
        let aliasCopy = alias
        let domainCopy = domain
        let hostCopy = engineHost

        // NSFileProviderReplicatedExtension completion handlers are @escaping but
        // not @Sendable. Box to cross the Task isolation boundary safely.
        let ch = UncheckedSendable(value: completionHandler)

        // Coalesce: cancel any in-flight scan; this call's result supersedes it.
        materializeLock.withLock {
            materializeTaskInFlight?.cancel()
            let task = Task {
                defer { ch.value() }
                do {
                    guard let manager = NSFileProviderManager(for: domainCopy) else {
                        FileProviderExtension.log.error(
                            "materializedItemsDidChange: no manager for domain \(aliasCopy, privacy: .public)"
                        )
                        return
                    }

                    // Enumerate the full materialized set, spanning all pages.
                    let collected = try await enumerateMaterializedIdentifiers(
                        enumerator: manager.enumeratorForMaterializedItems()
                    )

                    // Parse and filter: keep .workspace, .item, .path only.
                    // Exclude root, trash, and workingSet sentinels.
                    var containerIdentStrings: [String] = []
                    for raw in collected {
                        guard let parsed = try? parseOfemItemIdentifier(raw) else {
                            FileProviderExtension.log.error(
                                "materializedItemsDidChange[\(aliasCopy, privacy: .public)]: skip unparseable identifier"
                            )
                            continue
                        }
                        switch parsed {
                        case .root, .trash, .workingSet:
                            // Sentinels are not trackable containers — skip silently.
                            continue
                        case .workspace, .item:
                            // Store the raw string directly: for these cases
                            // identifierString is a round-trip no-op, but `raw` avoids
                            // an unnecessary re-serialization through ItemIdentifier.
                            containerIdentStrings.append(raw)
                        case let .path(_, _, path):
                            // Defense-in-depth: exclude Delta-table internals from the
                            // poll set (see `isMaterializablePathContainer` in FPEHelpers).
                            guard isMaterializablePathContainer(path) else { continue }
                            containerIdentStrings.append(raw)
                        }
                    }

                    // Bail out if this scan was superseded while enumerating.
                    guard !Task.isCancelled else { return }

                    // Persist via the engine's cache store (full-replace).
                    let engine = try await hostCopy.engine()
                    try await engine.cache.setMaterialized(alias: aliasCopy, identifiers: containerIdentStrings)

                    FileProviderExtension.log.info(
                        "materializedItemsDidChange[\(aliasCopy, privacy: .public)]: persisted \(containerIdentStrings.count, privacy: .public) container(s)"
                    )
                } catch is CancellationError {
                    // Superseded by a newer call — completionHandler still fires via defer.
                } catch {
                    FileProviderExtension.log.error(
                        "materializedItemsDidChange[\(aliasCopy, privacy: .public)] failed: \(error.localizedDescription, privacy: .public)"
                    )
                }
            }
            materializeTaskInFlight = task
        }
    }

    // MARK: - Enumeration

    func enumerator(
        for containerItemIdentifier: NSFileProviderItemIdentifier,
        request _: NSFileProviderRequest
    ) throws -> NSFileProviderEnumerator {
        // Parse first so we can branch on the typed identifier.
        let ofemID = try parseOfemItemIdentifier(containerItemIdentifier.rawValue)

        // Trash → real always-empty enumerator (no engine needed). OneLake has
        // no trash concept; this must NOT share OfemWorkingSetEnumerator, which
        // refreshes workspaces and reports alias-wide deltas that don't belong
        // to the trash container (see the note in OfemFPEEnumerator.swift).
        if ofemID == .trash {
            FileProviderExtension.log.debug(
                "enumerator(for: .trash) for \(self.alias, privacy: .public)"
            )
            return OfemTrashEnumerator()
        }
        // Working set → lightweight enumerator that drives real cache deltas
        // (no items, but enumerateChanges refreshes workspaces and reports
        // updates/deletions — see OfemWorkingSetEnumerator).
        if ofemID == .workingSet {
            FileProviderExtension.log.debug(
                "enumerator(for: .workingSet) for \(self.alias, privacy: .public)"
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

// MARK: - Materialized-items enumeration helper

/// Drives `enumerator` to completion across all pages and returns the raw
/// identifier strings of every item it delivers.
///
/// The materialized-items enumerator is a pull-based callback API
/// (`NSFileProviderEnumerationObserver`). This helper bridges the multi-page
/// loop to async/await using a checked continuation. `didEnumerate` accumulates
/// items; `finishEnumerating(upTo:nextPage)` either issues the next page request
/// (when `nextPage != nil`) or resolves the continuation with the full set (when
/// `nextPage == nil`). Errors resolve the continuation via `throw`.
///
/// Passing `NSFileProviderPage(Data())` as the start page is required by the
/// `enumeratorForMaterializedItems` contract (documented in
/// `NSFileProviderManager.h`); the standard sort-page constants do not apply to
/// the materialized-set enumerator. Apple gives no single-page guarantee for
/// large materialized sets.
private func enumerateMaterializedIdentifiers(
    enumerator: NSFileProviderEnumerator
) async throws -> [String] {
    // `NSFileProviderEnumerationObserver` is `@_nonSendable`. The Collector is
    // marked `@unchecked Sendable` because the system-vended enumerator delivers
    // all observer callbacks serially on its own internal GCD queue, so `collected`
    // and `continuation` are never accessed concurrently. The `CheckedContinuation`
    // is resumed exactly once per the `withCheckedThrowingContinuation` contract.
    final class Collector: NSObject, NSFileProviderEnumerationObserver, @unchecked Sendable {
        var collected: [String] = []
        var continuation: CheckedContinuation<[String], Error>?
        /// Retained so the paging loop can issue subsequent page requests.
        var enumerator: NSFileProviderEnumerator?

        func didEnumerate(_ updatedItems: [any NSFileProviderItem]) {
            for item in updatedItems {
                collected.append(item.itemIdentifier.rawValue)
            }
        }

        func finishEnumerating(upTo nextPage: NSFileProviderPage?) {
            if let page = nextPage {
                // More pages available — fetch the next one on the same observer.
                enumerator?.enumerateItems(for: self, startingAt: page)
            } else {
                // All pages delivered — resolve the continuation.
                continuation?.resume(returning: collected)
                continuation = nil
            }
        }

        func finishEnumeratingWithError(_ error: Error) {
            continuation?.resume(throwing: error)
            continuation = nil
        }
    }

    let collector = Collector()
    collector.enumerator = enumerator
    return try await withCheckedThrowingContinuation { continuation in
        collector.continuation = continuation
        enumerator.enumerateItems(for: collector, startingAt: NSFileProviderPage(Data()))
    }
}

// MARK: - Engine helper functions

/// Fetches `key` cache-first, returning the row on a hit or `nil` on a
/// definitive `CacheError.notFound` miss (the caller then runs its remote
/// listing fallback).
///
/// Any OTHER cache error is an infrastructure failure re-thrown as
/// `FPError.invalidRecord` (→ cannotSynchronize), never `noSuchItem`: a
/// transient DB blip must not be mistaken for a deletion signal. This mirrors
/// the discrimination the `.path` branch of ``engineFetchItem`` open-codes.
private func cacheFirstRecord(
    key: CacheKey,
    engine: OfemEngine,
    context: String
) async throws -> MetadataRecord? {
    do {
        return try await engine.cache.fetch(key: key)
    } catch let cacheError as CacheError {
        guard case .notFound = cacheError else {
            throw FPError.invalidRecord("cache DB error for \(context): \(cacheError)")
        }
        return nil
    } catch {
        throw FPError.invalidRecord("unexpected cache error for \(context): \(error)")
    }
}

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
        // Cache-first: the workspace-sentinel row is written by listWorkspaces,
        // keyed by (VirtualIDs.workspaceID, VirtualIDs.workspaceID, path: <wsGUID>).
        // A hit resolves without a Fabric round-trip (DomainItem.from delegates
        // sentinel rows to from(workspace:)); a definitive miss falls through to
        // the listWorkspaces fallback below.
        let key = cacheKey(
            alias: alias, workspaceID: VirtualIDs.workspaceID,
            itemID: VirtualIDs.workspaceID, path: workspaceID
        )
        if let record = try await cacheFirstRecord(key: key, engine: engine, context: "workspace \(workspaceID)") {
            do {
                return OfemFPEItem(from: try DomainItem.from(record: record))
            } catch {
                throw FPError.invalidRecord("DomainItem.from failed for workspace \(workspaceID): \(error)")
            }
        }
        // Cache miss → look up workspace display name from the discovery listing.
        let workspaces = try await engine.sync.listWorkspaces(alias: alias)
        if let ws = workspaces.first(where: { $0.id == workspaceID }) {
            return OfemFPEItem(from: DomainItem.from(workspace: ws))
        }
        // Absence after successful listing = definitive "not found".
        throw FPError.noSuchItem("workspace \(workspaceID) not in listing for alias \(alias)")

    case let .item(workspaceID, itemID):
        // Cache-first: the item-discovery row is written by the item-listing
        // reconcile, keyed by (workspaceID, VirtualIDs.itemID, path: <itemGUID>);
        // DomainItem.from maps it to the ".item" identifier via its
        // item-discovery branch. A definitive miss falls through to listItems.
        let key = cacheKey(
            alias: alias, workspaceID: workspaceID,
            itemID: VirtualIDs.itemID, path: itemID
        )
        if let record = try await cacheFirstRecord(key: key, engine: engine, context: "item \(itemID)") {
            do {
                return OfemFPEItem(from: try DomainItem.from(record: record))
            } catch {
                throw FPError.invalidRecord("DomainItem.from failed for item \(itemID): \(error)")
            }
        }
        // Cache miss → populate from the Fabric item listing.
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
        case let .success(record):
            do {
                return OfemFPEItem(from: try DomainItem.from(record: record))
            } catch {
                throw FPError.invalidRecord("DomainItem.from failed for \(path): \(error)")
            }

        case let .failure(cacheError as CacheError):
            // Only .notFound means "not in cache, try enumerating parent".
            // Any other CacheError is an infrastructure failure — propagate.
            guard case .notFound = cacheError else {
                throw FPError.invalidRecord("cache DB error for \(path): \(cacheError)")
            }
            // Fall through to parent enumerate.

        case let .failure(other):
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
        case let .success(record):
            if let di = try? DomainItem.from(record: record) {
                return OfemFPEItem(from: di)
            }
        case let .failure(cacheError as CacheError):
            guard case .notFound = cacheError else {
                throw cacheError // Real DB error — propagate
            }
        // .notFound: fall through to parent enumerate
        case let .failure(other):
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
        case let .success(record):
            if let di = try? DomainItem.from(record: record) {
                return OfemFPEItem(from: di)
            }
        case let .failure(cacheError as CacheError):
            guard case .notFound = cacheError else {
                throw cacheError // Real DB error — propagate
            }
        // .notFound: still not found — fall through to normal create
        case let .failure(other):
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
    case let .success(record):
        if let di = try? DomainItem.from(record: record) {
            return OfemFPEItem(from: di)
        }
    case let .failure(cacheError as CacheError):
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
           let di = try? DomainItem.from(record: record)
        {
            return OfemFPEItem(from: di)
        }
    case let .failure(other):
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
    // Carry the parent's item type so computeCapabilities returns the correct
    // caps immediately — without it, a file created under Lakehouse Files/
    // would appear read-only until the next refreshFolder.
    let parentKey = cacheKey(alias: alias, workspaceID: wsID, itemID: itemID, path: parentPathStr)
    let syntheticItemType = (try? await engine.cache.fetch(key: parentKey))?.itemType ?? ""
    return OfemFPEItem(from: DomainItem.synthetic(
        identifier: newIdentifier,
        parentIdentifier: parentID,
        name: filename,
        isDirectory: isDir,
        itemType: syntheticItemType
    ))
}

// MARK: - Domain identifier → alias

extension FileProviderExtension {
    /// Strips the `ofem.` prefix from the domain identifier to recover
    /// the user-chosen account alias (e.g. `"ofem.work"` → `"work"`).
    ///
    /// Delegates to the shared `ofemAlias(fromDomainIdentifier:)` helper
    /// (`Shared/OfemDomainIdentifier.swift`), which is also what
    /// `DomainSyncManager` uses to compose the identifier on the host side
    /// (xpc-09) — a single source keeps the alias round-trip in lockstep.
    static func extractAlias(from domain: NSFileProviderDomain) -> String {
        ofemAlias(fromDomainIdentifier: domain.identifier.rawValue)
    }
}
