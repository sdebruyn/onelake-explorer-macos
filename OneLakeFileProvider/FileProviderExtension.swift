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
//
// Logging: a `.path` ItemIdentifier's `identifierString` and an
// NSFileProviderItemIdentifier's raw string both embed a human-readable
// file/folder name — never interpolate either with `privacy: .public`.
// Use `ItemIdentifier.opaqueLogPrefix` (already-parsed identifier) or
// `opaqueLogIdentifier(_:)` (raw string, not yet parsed) instead; a bare
// filename value goes out with `privacy: .private`. See docs/telemetry.md.

@preconcurrency import FileProvider
import Foundation
import OfemKit
import os.log

// Identifier parsing uses OfemKit's `ItemIdentifierParser` exclusively, via
// the `parseOfemItemIdentifier` helper defined in OfemFPEEnumerator.swift.

/// Boxes a non-`Sendable` value for safe capture across `Task` isolation boundaries.
///
/// `NSFileProviderReplicatedExtension` completion handlers are `@escaping` but not
/// `@Sendable`. Wrapping them in this struct lets `Task` closures capture them without
/// triggering Swift 6 sendability diagnostics. The caller is responsible for ensuring
/// that the wrapped value is only invoked on a thread where it is safe to do so —
/// in practice the FPE callbacks are called once at the end of each operation.
private struct UncheckedSendable<T>: @unchecked Sendable { let value: T }

/// Outcome of `modifyItem`'s rename branch, run through `runFPEOperation`.
///
/// A rename failure is NOT an error result — it leaves the changed fields
/// pending so the framework retries — so the branch's `work` closure folds
/// both outcomes into this type instead of throwing (see the `.pending` case
/// doc on the call site for why).
private enum RenameOutcome {
    case renamed(OfemFPEItem, NSFileProviderItemFields)
    case pending
}

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
    /// Sets the invalidated flag synchronously — via `invalidateSynchronously()`
    /// — before spawning the async shutdown task, so an `engine()` call that
    /// races teardown (including one already in flight) observes the flag
    /// immediately, rather than only after the shutdown Task happens to be
    /// scheduled and reach its own lock acquisition.
    func invalidate() {
        FileProviderExtension.log.info(
            "Invalidating extension for domain \(self.domain.identifier.rawValue, privacy: .public)"
        )
        engineHost.invalidateSynchronously()

        // Capture engineHost (Sendable) explicitly so the Task body does not
        // need to capture self, which is not Sendable.
        let hostCopy = engineHost
        Task {
            await hostCopy.shutdown()
        }
    }

    // MARK: - Shared entry-point scaffolding

    /// Centralizes the scaffolding every FPE entry point below repeats: run
    /// `work`, map `CancellationError` to `CocoaError(.userCancelled)`,
    /// classify any other error via `FPError.classify`/`nsFileProviderError(for:)`,
    /// log it, and invoke `complete` exactly once with the outcome. Returns a
    /// fresh `Progress` whose `cancellationHandler` cancels the spawned
    /// `Task` — the same `Progress`/cancellation/classification/completion
    /// contract every call site previously hand-rolled.
    ///
    /// `work` receives the engine HOST, not an already-resolved engine — it
    /// calls `host.engine()` itself as its first step. This is deliberate:
    /// on `main`, every entry point's `do` block wrapped `engine()`
    /// resolution together with the rest of the operation, so an
    /// engine-unavailable failure (invalidated host, build-error back-off, a
    /// transient build failure) was classified identically to any other
    /// failure in that operation. Resolving the engine here instead, outside
    /// `work`, would put engine-resolution failures on a DIFFERENT code path
    /// than `work`'s own errors — which silently broke `modifyItem`'s rename
    /// branch (see below) in an earlier version of this helper: its
    /// leave-fields-pending-on-failure behavior only wrapped `work`'s body,
    /// so an engine() failure during rename incorrectly surfaced as a hard
    /// error instead of folding into the pending outcome.
    ///
    /// Callers do their own identifier parsing and pre-engine validation
    /// BEFORE calling this (each entry point's parse-failure mapping
    /// differs — e.g. an invalid rename filename maps to
    /// `.filenameCollision`, not `.noSuchItem`) and capture whatever they
    /// resolved for `work` to use.
    ///
    /// An entry point whose error handling itself diverges from the
    /// standard classify-and-fail shape (`modifyItem`'s rename branch keeps
    /// the changed fields pending instead of failing) catches its own
    /// non-cancellation errors — including from its own `host.engine()` call —
    /// inside `work` and folds them into its `Success` value, letting only
    /// `CancellationError` propagate so the standard catch here still
    /// applies to cancellation uniformly.
    ///
    /// `work` also receives the `Progress` this call returns, so entry
    /// points that report byte-level progress (`fetchContents`, the
    /// content-bearing `modifyItem` branch) can update `totalUnitCount` /
    /// `completedUnitCount` on it exactly as before.
    private func runFPEOperation<Success>(
        logContext: String,
        work: @escaping (any EngineProviding, Progress) async throws -> Success,
        complete: @escaping (Result<Success, Error>) -> Void
    ) -> Progress {
        let progress = Progress(totalUnitCount: 0)
        let hostCopy = engineHost
        // `work` and `complete` are @escaping but not necessarily @Sendable —
        // `complete` in particular typically closes over the framework's own
        // completionHandler, which is itself @escaping-but-not-@Sendable. Box
        // both to cross the Task isolation boundary safely, the same
        // technique every entry point previously applied to its raw
        // completionHandler directly.
        let workBox = UncheckedSendable(value: work)
        let ch = UncheckedSendable(value: complete)
        let task = Task {
            do {
                let value = try await workBox.value(hostCopy, progress)
                ch.value(.success(value))
            } catch is CancellationError {
                ch.value(.failure(CocoaError(.userCancelled)))
            } catch {
                let code = FPError.classify(error)
                FileProviderExtension.log.error(
                    "\(logContext, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
                hostCopy.fileLogger.error(logContext, error: error)
                ch.value(.failure(nsFileProviderError(for: code)))
            }
        }
        progress.cancellationHandler = { task.cancel() }
        return progress
    }

    // MARK: - Item metadata

    func item(
        for identifier: NSFileProviderItemIdentifier,
        request _: NSFileProviderRequest,
        completionHandler: @escaping (NSFileProviderItem?, Error?) -> Void
    ) -> Progress {
        // Parse identifier — use OfemKit's parser.
        let ofemID: ItemIdentifier
        do {
            ofemID = try parseOfemItemIdentifier(identifier.rawValue)
        } catch {
            engineHost.fileLogger.warn("item(for:) parse failed", error: error, metadata: ["alias": alias])
            completionHandler(nil, NSFileProviderError(.noSuchItem))
            return Progress(totalUnitCount: 0)
        }

        // Working set / trash are synthetic; return noSuchItem.
        if ofemID == .workingSet || ofemID == .trash {
            completionHandler(nil, NSFileProviderError(.noSuchItem))
            return Progress(totalUnitCount: 0)
        }

        let aliasCopy = alias
        return runFPEOperation(
            logContext: "item(for:) failed for \(aliasCopy)/\(ofemID.opaqueLogPrefix)",
            work: { host, _ in
                OfemFPEItem(from: try await host.resolveItem(identifier: ofemID, alias: aliasCopy))
            },
            complete: { result in
                switch result {
                case let .success(item): completionHandler(item, nil)
                case let .failure(error): completionHandler(nil, error)
                }
            }
        )
    }

    // MARK: - Content fetch

    func fetchContents(
        for itemIdentifier: NSFileProviderItemIdentifier,
        version _: NSFileProviderItemVersion?,
        request _: NSFileProviderRequest,
        completionHandler: @escaping (URL?, NSFileProviderItem?, Error?) -> Void
    ) -> Progress {
        let ofemID: ItemIdentifier
        do {
            ofemID = try parseOfemItemIdentifier(itemIdentifier.rawValue)
        } catch {
            engineHost.fileLogger.warn("fetchContents: parse failed", error: error, metadata: ["alias": alias])
            completionHandler(nil, nil, NSFileProviderError(.noSuchItem))
            return Progress(totalUnitCount: 0)
        }

        // Only file-level paths make sense for content fetch.
        guard case let .path(wsID, itemID, path) = ofemID else {
            // root / workspace / item root don't have file contents.
            engineHost.fileLogger.warn("fetchContents: identifier is not a path", metadata: ["alias": alias, "id": ofemID.opaqueLogPrefix])
            completionHandler(nil, nil, NSFileProviderError(.noSuchItem))
            return Progress(totalUnitCount: 0)
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
            return Progress(totalUnitCount: 0)
        }

        let aliasCopy = alias
        return runFPEOperation(
            logContext: "fetchContents failed for \(aliasCopy)/\(ofemID.opaqueLogPrefix)",
            work: { host, progress -> (URL, OfemFPEItem) in
                let engine = try await host.engine()
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
                // Progress isn't Sendable-checked by the compiler; box it like
                // `work`/`complete` above so it can be captured by the
                // @Sendable progress callback. That callback fires on
                // Alamofire's own delivery queue (`.main` by default — see
                // `doStreamRequest`) rather than this Task's, so it may not
                // land on the same thread as the rest of `work` (#461).
                // Progress itself is documented as safe to mutate off-main.
                let progressBox = UncheckedSendable(value: progress)
                let (_, record) = try await engine.sync.openReturningRecord(key: key) { completed, total in
                    if total > 0 {
                        progressBox.value.totalUnitCount = total
                    }
                    progressBox.value.completedUnitCount = completed
                }
                let domainItem: OfemFPEItem
                do {
                    domainItem = OfemFPEItem(from: try DomainItem.from(record: record))
                } catch {
                    throw FPError.invalidRecord("DomainItem.from failed for \(ofemID.opaqueLogPrefix): \(error)")
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
                // Force exact 100% regardless of where the incremental ticks
                // (or the documentSize hint above) landed: an in-flight
                // progress tick's total can end up ABOVE actualBytes just as
                // easily as below it (e.g. the remote size changed mid-
                // download), and completedUnitCount must never end up short
                // of totalUnitCount once the transfer is actually done (#461
                // review round 2) — so both are set to the same
                // known-correct value here, not merely raised.
                progress.totalUnitCount = actualBytes
                progress.completedUnitCount = actualBytes
                return (dest, domainItem)
            },
            complete: { result in
                switch result {
                case let .success((dest, domainItem)): completionHandler(dest, domainItem, nil)
                case let .failure(error): completionHandler(nil, nil, error)
                }
            }
        )
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
        let parentID: ItemIdentifier
        do {
            parentID = try parseOfemItemIdentifier(
                template.parentItemIdentifier.rawValue
            )
        } catch {
            engineHost.fileLogger.warn("createItem: parent parse failed", error: error, metadata: ["alias": alias])
            completionHandler(nil, [], false, NSFileProviderError(.noSuchItem))
            return Progress(totalUnitCount: 0)
        }

        let aliasCopy = alias
        let isDir = template.contentType == .folder
        let filename = template.filename
        let srcURL = contents
        let fieldsCopy = fields
        let optionsCopy = options

        FileProviderExtension.log.debug(
            "createItem \(filename, privacy: .private) isDir=\(isDir, privacy: .public) parent=\(parentID.opaqueLogPrefix, privacy: .public) fields=\(fieldsCopy.rawValue, privacy: .public) options=\(optionsCopy.rawValue, privacy: .public)"
        )

        engineHost.fileLogger.info("createItem starting", metadata: ["alias": aliasCopy, "parent": parentID.opaqueLogPrefix])

        return runFPEOperation(
            logContext: "createItem failed for \(aliasCopy)/\(parentID.opaqueLogPrefix)",
            work: { host, _ in
                // Collapse the FileProvider create semantics into plain-Swift
                // parameters before crossing into OfemKit: `.contents` present
                // AND a source URL → upload; otherwise placeholder-only (nil).
                let item = OfemFPEItem(from: try await host.createOfemItem(
                    parent: parentID,
                    filename: filename,
                    isDirectory: isDir,
                    uploadSource: fieldsCopy.contains(.contents) ? srcURL : nil,
                    mayAlreadyExist: optionsCopy.contains(.mayAlreadyExist),
                    alias: aliasCopy
                ))
                host.fileLogger.info("createItem succeeded", metadata: ["alias": aliasCopy, "parent": parentID.opaqueLogPrefix])
                return item
            },
            complete: { result in
                switch result {
                case let .success(item): completionHandler(item, [], false, nil)
                case let .failure(error): completionHandler(nil, [], false, error)
                }
            }
        )
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
        // Detect rename / reparent before anything else.
        // Move/reparent (parentItemIdentifier change) is not yet implemented —
        // leave it as still-pending. Same-directory rename (filename change only)
        // is handled below via the DFS x-ms-rename-source API.
        let wantsRename = changedFields.contains(.filename)
        let wantsReparent = changedFields.contains(.parentItemIdentifier)
        if wantsReparent {
            FileProviderExtension.log.debug(
                "modifyItem \(opaqueLogIdentifier(item.itemIdentifier.rawValue), privacy: .public) — reparent not supported, leaving pending (fields=\(changedFields.rawValue, privacy: .public))"
            )
            var pendingFields: NSFileProviderItemFields = [.parentItemIdentifier]
            if wantsRename { pendingFields.insert(.filename) }
            completionHandler(item, pendingFields, false, nil)
            return Progress(totalUnitCount: 0)
        }

        if wantsRename {
            return handleModifyItemRename(item, changedFields: changedFields, completionHandler: completionHandler)
        }

        // Metadata-only modifications (mtime, tags, lastUsedDate, favoriteRank).
        // The system sends these routinely and expects an ack. We apply what we
        // can (nothing persisted remotely for these fields) and return the
        // existing item with a fresh version token.
        if !changedFields.contains(.contents) {
            FileProviderExtension.log.debug(
                "modifyItem \(opaqueLogIdentifier(item.itemIdentifier.rawValue), privacy: .public) — metadata-only (fields=\(changedFields.rawValue, privacy: .public)), acknowledging"
            )
            return handleModifyItemMetadata(item, completionHandler: completionHandler)
        }

        // Content-bearing modification.
        guard let contentsURL = contents else {
            // changedFields includes .contents but the URL is nil — treat as
            // metadata-only (nothing to upload).
            FileProviderExtension.log.debug(
                "modifyItem \(opaqueLogIdentifier(item.itemIdentifier.rawValue), privacy: .public) — .contents set but URL nil, acknowledging"
            )
            completionHandler(item, [], false, nil)
            return Progress(totalUnitCount: 0)
        }

        return handleModifyItemContentReplace(item, contentsURL: contentsURL, completionHandler: completionHandler)
    }

    /// Shared identifier-parse prologue for `modifyItem`'s three branches
    /// (rename / metadata-only / content-bearing). On parse failure it fires
    /// `completionHandler` with the standard `.noSuchItem` outcome and
    /// returns `nil`; callers should return `Progress(totalUnitCount: 0)`
    /// in that case. Scoped to `modifyItem`'s completion-handler shape —
    /// other call sites in this file use different signatures.
    private func parseModifyItemIdentifier(
        _ rawValue: String,
        completionHandler: @escaping (
            NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?
        ) -> Void
    ) -> ItemIdentifier? {
        do {
            return try parseOfemItemIdentifier(rawValue)
        } catch {
            engineHost.fileLogger.warn("modifyItem: identifier parse failed", error: error, metadata: ["alias": alias])
            completionHandler(nil, [], false, NSFileProviderError(.noSuchItem))
            return nil
        }
    }

    // MARK: - modifyItem branch helpers

    private func handleModifyItemRename(
        _ item: NSFileProviderItem,
        changedFields: NSFileProviderItemFields,
        completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void
    ) -> Progress {
        guard let ofemID = parseModifyItemIdentifier(
            item.itemIdentifier.rawValue, completionHandler: completionHandler
        ) else {
            return Progress(totalUnitCount: 0)
        }
        guard case let .path(wsID, itemID, path) = ofemID else {
            engineHost.fileLogger.warn("rename: identifier is not a path", metadata: ["alias": alias, "id": ofemID.opaqueLogPrefix])
            completionHandler(nil, [], false, NSFileProviderError(.noSuchItem))
            return Progress(totalUnitCount: 0)
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
            return Progress(totalUnitCount: 0)
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
        FileProviderExtension.log.debug(
            "modifyItem \(ofemID.opaqueLogPrefix, privacy: .public) — rename to \(newFilename, privacy: .private)"
        )

        engineHost.fileLogger.info("rename starting", metadata: ["alias": aliasCopy, "id": ofemID.opaqueLogPrefix])

        // A rename failure does NOT surface as an error result: it leaves ALL
        // changed fields pending so the framework retries rather than treating
        // the item as renamed (or, for a co-delivered .contents, as uploaded)
        // locally. That diverges from `runFPEOperation`'s standard
        // classify-and-fail catch, so non-cancellation errors — INCLUDING a
        // `host.engine()` failure, resolved inside this same do/catch rather
        // than left to the shared harness — are caught HERE and folded into
        // a `.pending` outcome. That covers an invalidated host, a
        // build-error back-off window, or a transient engine build failure
        // during a rename; only `CancellationError` propagates to the
        // shared catch.
        return runFPEOperation(
            logContext: "rename failed for \(aliasCopy)/\(ofemID.opaqueLogPrefix)",
            work: { host, _ -> RenameOutcome in
                do {
                    let key = CacheKey(
                        accountAlias: aliasCopy,
                        workspaceID: wsID,
                        itemID: itemID,
                        path: path
                    )
                    let updated = try await host.renameOfemItem(key: key, newName: newFilename)
                    host.fileLogger.info("rename succeeded", metadata: ["alias": aliasCopy, "id": ofemID.opaqueLogPrefix])
                    // Return the ORIGINAL identifier with the new filename/size/
                    // dates so the framework registers a metadata change, not a
                    // delete+add (see DomainItem.from(record:overridingIdentifier:)).
                    let fpeItem = OfemFPEItem(
                        from: try DomainItem.from(record: updated, overridingIdentifier: originalIdentifier)
                    )
                    return .renamed(fpeItem, nonRenameFields)
                } catch let cancellationError as CancellationError {
                    throw cancellationError
                } catch {
                    FileProviderExtension.log.error(
                        "modifyItem rename failed: \(error.localizedDescription, privacy: .public)"
                    )
                    return .pending
                }
            },
            complete: { result in
                switch result {
                case let .success(.renamed(fpeItem, fields)):
                    completionHandler(fpeItem, fields, false, nil)
                case .success(.pending):
                    completionHandler(item, changedFields, false, nil)
                case let .failure(error):
                    completionHandler(nil, [], false, error)
                }
            }
        )
    }

    private func handleModifyItemMetadata(
        _ item: NSFileProviderItem,
        completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void
    ) -> Progress {
        guard let ofemID = parseModifyItemIdentifier(
            item.itemIdentifier.rawValue, completionHandler: completionHandler
        ) else {
            return Progress(totalUnitCount: 0)
        }

        let aliasCopy = alias
        return runFPEOperation(
            logContext: "modifyItem(metadata) fetch failed",
            work: { host, _ in
                OfemFPEItem(from: try await host.resolveItem(identifier: ofemID, alias: aliasCopy))
            },
            complete: { result in
                switch result {
                case let .success(existing): completionHandler(existing, [], false, nil)
                case let .failure(error): completionHandler(nil, [], false, error)
                }
            }
        )
    }

    private func handleModifyItemContentReplace(
        _ item: NSFileProviderItem,
        contentsURL: URL,
        completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void
    ) -> Progress {
        guard let ofemID = parseModifyItemIdentifier(
            item.itemIdentifier.rawValue, completionHandler: completionHandler
        ) else {
            return Progress(totalUnitCount: 0)
        }

        guard case let .path(wsID, itemID, path) = ofemID else {
            engineHost.fileLogger.warn("upload: identifier is not a path", metadata: ["alias": alias, "id": ofemID.opaqueLogPrefix])
            completionHandler(nil, [], false, NSFileProviderError(.noSuchItem))
            return Progress(totalUnitCount: 0)
        }

        let aliasCopy = alias

        FileProviderExtension.log.debug(
            "modifyItem \(ofemID.opaqueLogPrefix, privacy: .public)"
        )

        engineHost.fileLogger.info("upload starting", metadata: ["alias": aliasCopy, "id": ofemID.opaqueLogPrefix])

        return runFPEOperation(
            logContext: "upload failed for \(aliasCopy)/\(ofemID.opaqueLogPrefix)",
            work: { host, progress -> OfemFPEItem in
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
                // putOfemContents uploads AND re-fetches the item metadata (so the
                // returned version matches what subsequent enumeration produces)
                // against the SAME engine() resolution — see that method's doc.
                let updated = try await host.putOfemContents(
                    key: key, sourceURL: contentsURL, identifier: ofemID, alias: aliasCopy
                )
                host.fileLogger.info("upload succeeded", metadata: ["alias": aliasCopy, "id": ofemID.opaqueLogPrefix])
                progress.completedUnitCount = progress.totalUnitCount
                return OfemFPEItem(from: updated)
            },
            complete: { result in
                switch result {
                case let .success(updated): completionHandler(updated, [], false, nil)
                case let .failure(error): completionHandler(nil, [], false, error)
                }
            }
        )
    }

    func deleteItem(
        identifier: NSFileProviderItemIdentifier,
        baseVersion _: NSFileProviderItemVersion,
        options _: NSFileProviderDeleteItemOptions = [],
        request _: NSFileProviderRequest,
        completionHandler: @escaping (Error?) -> Void
    ) -> Progress {
        let ofemID: ItemIdentifier
        do {
            ofemID = try parseOfemItemIdentifier(identifier.rawValue)
        } catch {
            engineHost.fileLogger.warn("deleteItem: parse failed", error: error, metadata: ["alias": alias])
            completionHandler(NSFileProviderError(.noSuchItem))
            return Progress(totalUnitCount: 0)
        }

        guard case let .path(wsID, itemID, path) = ofemID else {
            engineHost.fileLogger.warn("deleteItem: identifier is not a path", metadata: ["alias": alias, "id": ofemID.opaqueLogPrefix])
            completionHandler(NSFileProviderError(.noSuchItem))
            return Progress(totalUnitCount: 0)
        }

        let aliasCopy = alias

        FileProviderExtension.log.debug(
            "deleteItem \(ofemID.opaqueLogPrefix, privacy: .public)"
        )

        engineHost.fileLogger.info("deleteItem starting", metadata: ["alias": aliasCopy, "id": ofemID.opaqueLogPrefix])

        return runFPEOperation(
            logContext: "deleteItem failed for \(aliasCopy)/\(ofemID.opaqueLogPrefix)",
            work: { host, _ in
                let key = cacheKey(alias: aliasCopy, workspaceID: wsID, itemID: itemID, path: path)
                try await host.deleteOfemItem(key: key)
                host.fileLogger.info("deleteItem succeeded", metadata: ["alias": aliasCopy, "id": ofemID.opaqueLogPrefix])
            },
            complete: { result in
                switch result {
                case .success: completionHandler(nil)
                case let .failure(error): completionHandler(error)
                }
            }
        )
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
        // Parse first so we can branch on the typed identifier. A parse
        // failure maps to NSFileProviderError(.noSuchItem) — matching every
        // other entry point's identifier-parsing guard — rather than letting
        // the raw FPError escape unmapped.
        let ofemID: ItemIdentifier
        do {
            ofemID = try parseOfemItemIdentifier(containerItemIdentifier.rawValue)
        } catch {
            engineHost.fileLogger.warn("enumerator(for:) parse failed", error: error, metadata: ["alias": alias])
            throw NSFileProviderError(.noSuchItem)
        }

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
            "enumerator(for:) for \(ofemID.opaqueLogPrefix, privacy: .public)"
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
