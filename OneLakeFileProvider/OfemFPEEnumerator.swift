// OfemFPEEnumerator.swift
// NSFileProviderEnumerator backed by the Swift OfemEngine.
//
// Design notes:
//
// - The engine's SyncEngine.enumerate(key:) method operates on
//   CacheKey values. We map NSFileProviderItemIdentifier → ItemIdentifier
//   (OfemKit) → CacheKey for the enumerate call.
//
// - Workspace and item discovery (listWorkspaces, listItems) produce
//   DomainItem values that never go through the cache layer; regular
//   file/folder enumeration uses SyncEngine.enumerate(key:) which
//   hits the cache + remote refresh.
//
// - Cursor / page tokens: the Swift engine's enumerate(key:) returns
//   the full listing in one call (no server-side pagination at the DFS
//   level). We use one page, nil cursor.
//
// - Sync anchors: `currentSyncAnchor` returns the max(synced_at_ns) value
//   from the cache database for the account alias, encoded as a big-endian
//   Int64. When `enumerateChanges` is called with a prior anchor, we look up
//   all records changed since that anchor instead of unconditionally throwing
//   `.syncAnchorExpired`. The anchor value advances with every `upsert`, so
//   the system can request incremental deltas rather than performing a full
//   re-enumeration on every poll.
//
// - Anchor-on-decode-failure policy: when a cache record fails to decode
//   (permanently corrupt), the anchor still advances past it. Holding the
//   anchor back would cause an infinite re-enumeration loop: the framework
//   would retry from the same anchor, encounter the same undecodable record,
//   and never make progress. Instead, the failure is logged at .error (so it
//   is observable in Console.app and os_log streams) and the record is skipped.
//   Good records in the same batch ARE delivered. This matches the project's
//   "observable failure, not silent loss" philosophy.
//
// - Working set: `OfemWorkingSetEnumerator.enumerateChanges` drives a real
//   cache diff: it computes changed items since the anchor and calls `didUpdate`
//   for the affected identifiers. This means `signalEnumerator(for: .workingSet)`
//   produces an actual delta.
//
// - inFlightTask safety: `inFlightTask` mutations are serialised by an NSLock
//   so concurrent `enumerateItems` / `invalidate` calls from the framework
//   (which may arrive on arbitrary queues) do not data-race. `enumerateItems`
//   only cancels an in-flight task when starting a NEW items enumeration — not
//   when a change-observation arrives.

import FileProvider
import Foundation
import OfemKit
import os.log

// MARK: - Identifier parsing helper

/// Parses a raw NSFileProviderItemIdentifier string into an OfemKit ItemIdentifier.
///
/// OfemKit's `ItemIdentifierParser` is the single owner of the identifier
/// grammar. All FPE call sites use this helper exclusively.
func parseOfemItemIdentifier(_ rawIdentifier: String) throws -> ItemIdentifier {
    try ItemIdentifierParser.parse(rawIdentifier)
}

// MARK: - Sync anchor encoding/decoding

/// Encodes an Int64 nanosecond timestamp as an 8-byte big-endian anchor token.
func encodeSyncAnchor(_ ns: Int64) -> NSFileProviderSyncAnchor {
    var value = ns.bigEndian
    let data = withUnsafeBytes(of: &value) { Data($0) }
    return NSFileProviderSyncAnchor(data)
}

/// Decodes an anchor token back to an Int64 nanosecond timestamp.
/// Returns 0 for an empty / unrecognised anchor (forces full diff).
func decodeSyncAnchor(_ anchor: NSFileProviderSyncAnchor) -> Int64 {
    let data = anchor.rawValue
    guard data.count == 8 else { return 0 }
    return data.withUnsafeBytes { ptr -> Int64 in
        Int64(bigEndian: ptr.load(as: Int64.self))
    }
}

// MARK: - Engine-backed enumerator

/// Engine-backed enumerator for one container in one FPE domain.
///
/// Thread-safety: `taskLock` serialises mutations to all three task handles
/// (`inFlightTask`, `inFlightChangesTask`, `inFlightAnchorTask`) so that
/// concurrent `enumerateItems` / `enumerateChanges` / `currentSyncAnchor` /
/// `invalidate` calls from the framework (arriving on arbitrary queues) do
/// not data-race.
///
/// Task ownership:
/// - `inFlightTask` — the current items enumeration Task.
/// - `inFlightChangesTask` — the current `enumerateChanges` Task (fpe-15).
/// - `inFlightAnchorTask` — the current `currentSyncAnchor` Task (fpe-15).
///
/// `invalidate()` cancels all three handles synchronously without awaiting,
/// honouring the `NSFileProviderEnumerator.invalidate()` synchronous contract.
final class OfemFPEEnumerator: NSObject, NSFileProviderEnumerator {
    private static let log = Logger(
        subsystem: "dev.debruyn.ofem.fileprovider",
        category: "fpe-enumerator"
    )

    let containerItemIdentifier: NSFileProviderItemIdentifier
    let identifier: ItemIdentifier         // OfemKit-typed
    let alias: String
    let engineHost: any EngineProviding

    /// Guards mutations to all in-flight task handles.
    private let taskLock = NSLock()
    /// The current items-enumeration Task (started by enumerateItems).
    private nonisolated(unsafe) var inFlightTask: Task<Void, Never>?
    /// The current change-observation Task (started by enumerateChanges, fpe-15).
    private nonisolated(unsafe) var inFlightChangesTask: Task<Void, Never>?
    /// The current sync-anchor query Task (started by currentSyncAnchor, fpe-15).
    private nonisolated(unsafe) var inFlightAnchorTask: Task<Void, Never>?

    init(
        containerItemIdentifier: NSFileProviderItemIdentifier,
        identifier: ItemIdentifier,
        alias: String,
        engineHost: any EngineProviding
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
        engineHost: any EngineProviding
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
        // Cancel all tracked tasks synchronously — invalidate() is synchronous
        // per the NSFileProviderEnumerator contract; do NOT await here.
        taskLock.withLock {
            inFlightTask?.cancel()
            inFlightTask = nil
            inFlightChangesTask?.cancel()
            inFlightChangesTask = nil
            inFlightAnchorTask?.cancel()
            inFlightAnchorTask = nil
        }
        Self.log.debug("OfemFPEEnumerator[\(self.alias, privacy: .public)]: invalidated")
    }

    // MARK: - Enumeration

    func enumerateItems(
        for observer: NSFileProviderEnumerationObserver,
        startingAt _: NSFileProviderPage
    ) {
        let aliasCopy = alias
        let identifierCopy = identifier
        let hostCopy = engineHost

        // Cancel any previous in-flight items task. Only cancel on a new
        // *items* enumeration — not on change observation — so concurrent
        // change-observation and items-enumeration tasks remain independent.
        let newTask = Task<Void, Never> {
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
                observer.finishEnumeratingWithError(CocoaError(.userCancelled))
            } catch {
                let code = FPError.classify(error)
                Self.log.error(
                    "OfemFPEEnumerator failed for \(aliasCopy, privacy: .public)/\(identifierCopy.identifierString, privacy: .public): \(error.localizedDescription, privacy: .public) (code=\(code.rawValue, privacy: .public))"
                )
                observer.finishEnumeratingWithError(nsFileProviderError(for: code))
            }
        }

        taskLock.withLock {
            inFlightTask?.cancel()
            inFlightTask = newTask
        }
    }

    /// Responds with actual cache deltas since `anchor`.
    ///
    /// Decodes the anchor (max `synced_at_ns` from the last poll), queries the
    /// cache for rows that changed after that timestamp, and reports the deltas.
    /// If the anchor is empty or no longer decodable (DB was reset) we fall back
    /// to expiry so the framework can restart from scratch.
    ///
    /// Anchor advancement: the anchor is advanced unconditionally at the end of
    /// each batch, even when individual records failed to decode. Holding the
    /// anchor back on a decode failure would cause an infinite retry loop because
    /// the same corrupt record would appear on every subsequent call from the
    /// same anchor. Instead, decode failures are logged at .error so they are
    /// observable, and the good records in the batch are still delivered.
    func enumerateChanges(
        for observer: NSFileProviderChangeObserver,
        from anchor: NSFileProviderSyncAnchor
    ) {
        let aliasCopy = alias
        let identifierCopy = identifier
        let hostCopy = engineHost
        let previousNs = decodeSyncAnchor(anchor)

        // Change-observation tasks are independent from items tasks.
        // We do NOT cancel inFlightTask here (avoids aborting an ongoing items
        // enumeration for an unrelated change observer). Store the new task in
        // inFlightChangesTask so invalidate() can cancel it (fpe-15).
        let changesTask = Task<Void, Never> {
            do {
                let engine = try await hostCopy.engine()
                let currentNs = (try? await engine.cache.maxSyncedAtNs(accountAlias: aliasCopy)) ?? 0

                // If the anchor is ahead of the cache the DB may have been
                // reset (or a new process started). Expire so the framework
                // performs a full re-enumeration.
                if previousNs > currentNs && previousNs != 0 {
                    Self.log.debug(
                        "OfemFPEEnumerator: anchor ahead of cache for \(aliasCopy, privacy: .public) — expiring"
                    )
                    observer.finishEnumeratingWithError(NSFileProviderError(.syncAnchorExpired))
                    return
                }

                // Compute changed items since the last known anchor.
                // Propagate SQLite errors rather than silently returning an
                // empty delta with an advanced anchor (which would hide data loss).
                let (updatedRecords, deletedIdStrings) = try await engine.cache.itemsChangedAfter(
                    accountAlias: aliasCopy,
                    ns: previousNs
                )

                // Decode each updated record. On failure: log at .error so the
                // drop is observable, skip the record, and advance the anchor
                // past it. NOT advancing would cause an infinite retry loop
                // because the same undecodable record would reappear on every
                // subsequent call from the same anchor.
                var updatedItems: [NSFileProviderItem] = []
                for record in updatedRecords {
                    do {
                        let di = try DomainItem.from(record: record)
                        updatedItems.append(OfemFPEItem(from: di))
                    } catch {
                        Self.log.error(
                            "OfemFPEEnumerator: skipping un-decodable record for \(aliasCopy, privacy: .public): \(error.localizedDescription, privacy: .public)"
                        )
                    }
                }

                if !updatedItems.isEmpty {
                    observer.didUpdate(updatedItems)
                }

                // Report remote deletions so Finder removes the items.
                if !deletedIdStrings.isEmpty {
                    let deletedIdentifiers = deletedIdStrings.map {
                        NSFileProviderItemIdentifier($0)
                    }
                    observer.didDeleteItems(withIdentifiers: deletedIdentifiers)
                }

                let newAnchor = encodeSyncAnchor(currentNs)
                observer.finishEnumeratingChanges(upTo: newAnchor, moreComing: false)

                Self.log.debug(
                    "OfemFPEEnumerator: enumerateChanges for \(aliasCopy, privacy: .public)/\(identifierCopy.identifierString, privacy: .public): \(updatedRecords.count, privacy: .public) updates, \(deletedIdStrings.count, privacy: .public) deletions, anchor \(previousNs, privacy: .public) → \(currentNs, privacy: .public)"
                )
            } catch is CancellationError {
                observer.finishEnumeratingWithError(CocoaError(.userCancelled))
            } catch {
                let code = FPError.classify(error)
                Self.log.error(
                    "OfemFPEEnumerator: enumerateChanges failed for \(aliasCopy, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
                observer.finishEnumeratingWithError(nsFileProviderError(for: code))
            }
        }
        taskLock.withLock {
            inFlightChangesTask?.cancel()
            inFlightChangesTask = changesTask
        }
    }

    func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        let aliasCopy = alias
        let hostCopy = engineHost
        // Store the task so invalidate() can cancel it (fpe-15).
        let anchorTask = Task<Void, Never> {
            do {
                let engine = try await hostCopy.engine()
                let ns = (try? await engine.cache.maxSyncedAtNs(accountAlias: aliasCopy)) ?? 0
                completionHandler(encodeSyncAnchor(ns))
            } catch {
                // Engine unavailable; return a zero anchor so the next poll
                // gets a full diff rather than an opaque failure.
                completionHandler(encodeSyncAnchor(0))
            }
        }
        taskLock.withLock {
            inFlightAnchorTask?.cancel()
            inFlightAnchorTask = anchorTask
        }
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

        case .trash, .workingSet:
            // Synthetic containers we never populate.
            throw FPError.noSuchItem("synthetic container: \(identifier.identifierString)")

        case let .workspace(workspaceID):
            // List all Fabric items inside the workspace.
            let items = try await engine.sync.listItems(alias: alias, workspaceID: workspaceID)
            return items.map { fabricItem in
                OfemFPEItem(from: DomainItem.from(fabricItem: fabricItem, workspaceID: workspaceID))
            }

        case let .item(workspaceID, itemID):
            // List the root of a Fabric item (e.g. lakehouse root).
            let key = cacheKey(alias: alias, workspaceID: workspaceID, itemID: itemID, path: "")
            let records = try await engine.sync.enumerate(key: key)
            return try records.map { record in
                let di = try DomainItem.from(record: record)
                return OfemFPEItem(from: di)
            }

        case let .path(workspaceID, itemID, path):
            // List a sub-path inside a Fabric item.
            let key = cacheKey(alias: alias, workspaceID: workspaceID, itemID: itemID, path: path)
            let records = try await engine.sync.enumerate(key: key)
            return try records.map { record in
                let di = try DomainItem.from(record: record)
                return OfemFPEItem(from: di)
            }
        }
    }
}

// MARK: - Working set enumerator

/// Minimal enumerator for the `.workingSet` container.
///
/// The working set is macOS's bag of "recently used / actively
/// referenced" items used for cross-folder search, badges, and the
/// recents list. `enumerateItems` returns an empty page; `enumerateChanges`
/// drives a real cache diff: changed records since the anchor are surfaced
/// as `didUpdate` calls instead of always answering "no changes".
///
/// Task ownership: `taskLock` guards `inFlightChangesTask` and
/// `inFlightAnchorTask`. `invalidate()` cancels both synchronously (fpe-15).
final class OfemWorkingSetEnumerator: NSObject, NSFileProviderEnumerator {
    private static let log = Logger(
        subsystem: "dev.debruyn.ofem.fileprovider",
        category: "working-set"
    )

    private let alias: String
    private let engineHost: any EngineProviding

    /// Guards mutations to task handles.
    private let taskLock = NSLock()
    private nonisolated(unsafe) var inFlightChangesTask: Task<Void, Never>?
    private nonisolated(unsafe) var inFlightAnchorTask: Task<Void, Never>?

    init(alias: String, engineHost: any EngineProviding) {
        self.alias = alias
        self.engineHost = engineHost
        super.init()
    }

    func invalidate() {
        // Cancel tracked tasks synchronously — invalidate() is synchronous
        // per the NSFileProviderEnumerator contract (fpe-15).
        taskLock.withLock {
            inFlightChangesTask?.cancel()
            inFlightChangesTask = nil
            inFlightAnchorTask?.cancel()
            inFlightAnchorTask = nil
        }
        OfemWorkingSetEnumerator.log.debug(
            "Invalidate working set enumerator for \(self.alias, privacy: .public)"
        )
    }

    func enumerateItems(
        for observer: NSFileProviderEnumerationObserver,
        startingAt _: NSFileProviderPage
    ) {
        OfemWorkingSetEnumerator.log.debug(
            "enumerateItems (working set) for \(self.alias, privacy: .public) -> empty"
        )
        observer.didEnumerate([])
        observer.finishEnumerating(upTo: nil)
    }

    /// Reports real cache deltas since `anchor` for the working set.
    ///
    /// `signalEnumerator(for: .workingSet)` causes macOS to call here. Instead
    /// of always answering "no changes" (which made that signal a no-op), we
    /// look up all records updated since the anchor and report them so Finder
    /// badge / recents lists stay current.
    func enumerateChanges(
        for observer: NSFileProviderChangeObserver,
        from anchor: NSFileProviderSyncAnchor
    ) {
        let aliasCopy = alias
        let hostCopy = engineHost
        let previousNs = decodeSyncAnchor(anchor)

        // Store the task so invalidate() can cancel it (fpe-15).
        let changesTask = Task<Void, Never> {
            do {
                let engine = try await hostCopy.engine()
                let currentNs = (try? await engine.cache.maxSyncedAtNs(accountAlias: aliasCopy)) ?? 0

                // Propagate SQLite errors; report deletions.
                let (updatedRecords, deletedIdStrings) = try await engine.cache.itemsChangedAfter(
                    accountAlias: aliasCopy,
                    ns: previousNs
                )

                // Decode each updated record. On failure: log at .error so the
                // drop is observable, skip the record, and advance the anchor
                // past it. The same policy as OfemFPEEnumerator.enumerateChanges —
                // NOT advancing would cause an infinite retry loop on corrupt data.
                var updatedItems: [NSFileProviderItem] = []
                for record in updatedRecords {
                    do {
                        let di = try DomainItem.from(record: record)
                        updatedItems.append(OfemFPEItem(from: di))
                    } catch {
                        Self.log.error(
                            "WorkingSet: skipping un-decodable record for \(aliasCopy, privacy: .public): \(error.localizedDescription, privacy: .public)"
                        )
                    }
                }
                if !updatedItems.isEmpty {
                    observer.didUpdate(updatedItems)
                }

                if !deletedIdStrings.isEmpty {
                    let deletedIdentifiers = deletedIdStrings.map {
                        NSFileProviderItemIdentifier($0)
                    }
                    observer.didDeleteItems(withIdentifiers: deletedIdentifiers)
                }

                let newAnchor = encodeSyncAnchor(currentNs)
                observer.finishEnumeratingChanges(upTo: newAnchor, moreComing: false)

                Self.log.debug(
                    "WorkingSet: enumerateChanges for \(aliasCopy, privacy: .public): \(updatedRecords.count, privacy: .public) updates, \(deletedIdStrings.count, privacy: .public) deletions since anchor=\(previousNs, privacy: .public)"
                )
            } catch is CancellationError {
                // The enumerator was invalidated while the task was in flight.
                // Signal userCancelled so the framework knows this was a clean
                // cancellation, not a sync failure (mirrors OfemFPEEnumerator
                // enumerateChanges — fpe-15).
                observer.finishEnumeratingWithError(CocoaError(.userCancelled))
            } catch {
                let code = FPError.classify(error)
                Self.log.error(
                    "WorkingSet: enumerateChanges failed for \(aliasCopy, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
                observer.finishEnumeratingWithError(nsFileProviderError(for: code))
            }
        }
        taskLock.withLock {
            inFlightChangesTask?.cancel()
            inFlightChangesTask = changesTask
        }
    }

    func currentSyncAnchor(
        completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void
    ) {
        let aliasCopy = alias
        let hostCopy = engineHost
        // Store the task so invalidate() can cancel it (fpe-15).
        let anchorTask = Task<Void, Never> {
            do {
                let engine = try await hostCopy.engine()
                let ns = (try? await engine.cache.maxSyncedAtNs(accountAlias: aliasCopy)) ?? 0
                completionHandler(encodeSyncAnchor(ns))
            } catch {
                completionHandler(encodeSyncAnchor(0))
            }
        }
        taskLock.withLock {
            inFlightAnchorTask?.cancel()
            inFlightAnchorTask = anchorTask
        }
    }
}
