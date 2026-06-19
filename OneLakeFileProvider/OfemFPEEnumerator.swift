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
// - Working set: `OfemWorkingSetEnumerator.enumerateChanges` refreshes the
//   workspace list from Fabric (throttled, at most once per
//   `OfemWorkingSetEnumerator.workspaceRefreshInterval` per alias) before
//   computing the cache diff. This populates the SQLite workspace cache so
//   the host-side ChangeWatcher can detect a changed workspace set and remount
//   the domain, which forces a fresh root enumeration.  The throttle is shared
//   across all enumerator instances for the same alias (static dictionary +
//   static lock) so a new enumerator vended by FileProviderExtension.enumerator(for:)
//   does not reset the 60-second window.  The stamp is written only AFTER a
//   successful listWorkspaces so a startup engine-failure does not consume the
//   window; an auth failure resets the stamp so re-auth triggers a prompt
//   refresh on the very next working-set signal.
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

        // For .path identifiers the identifierString contains human-readable
        // folder/file names. Log only the opaque GUID prefix (workspace/item)
        // and omit the leaf path so file names never appear in the system log.
        let containerLogID = identifierCopy.opaqueLogPrefix
        Self.log.debug(
            "OfemFPEEnumerator[\(aliasCopy, privacy: .public)]: enumerateItems entry — container=\(containerLogID, privacy: .public)"
        )

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
                Self.log.debug(
                    "OfemFPEEnumerator[\(aliasCopy, privacy: .public)]: enumerateItems delivered — container=\(containerLogID, privacy: .public) count=\(items.count, privacy: .public) nextPage=nil"
                )
            } catch is CancellationError {
                Self.log.debug(
                    "OfemFPEEnumerator[\(aliasCopy, privacy: .public)]: enumerateItems cancelled — container=\(containerLogID, privacy: .public)"
                )
                observer.finishEnumeratingWithError(CocoaError(.userCancelled))
            } catch {
                let code = FPError.classify(error)
                Self.log.error(
                    "OfemFPEEnumerator[\(aliasCopy, privacy: .public)]: enumerateItems failed — container=\(containerLogID, privacy: .public) error=\(error.localizedDescription, privacy: .public) code=\(code.rawValue, privacy: .public)"
                )
                // Surface auth-error state so the host-app menu bar can show
                // a "Sign-in required" indicator for this account.
                if code == .notAuthenticated {
                    hostCopy.markNeedsSignIn()
                }
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
    /// If the anchor is ahead of the cache (DB was reset) we expire it so the
    /// framework performs a full re-enumeration.
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
            let containerLogID = identifierCopy.opaqueLogPrefix
            Self.log.debug(
                "OfemFPEEnumerator[\(aliasCopy, privacy: .public)]: enumerateChanges entry — container=\(containerLogID, privacy: .public) anchor=\(previousNs, privacy: .public)"
            )
            // Root-container changes cannot be served from the cache delta path:
            // the cache stores file/folder rows keyed by path, not workspace
            // metadata rows, so DomainItem.from(record:) mis-maps workspace rows
            // and produces incorrect items. The only reliable source of truth for
            // workspaces is a fresh enumerateItems(.root) → listWorkspaces call.
            // Expire the anchor immediately so the framework performs that full
            // re-enumeration instead of relying on the broken delta path.
            if case .root = identifierCopy {
                observer.finishEnumeratingWithError(NSFileProviderError(.syncAnchorExpired))
                Self.log.debug(
                    "OfemFPEEnumerator[\(aliasCopy, privacy: .public)]: enumerateChanges — root container, anchor expired to force full re-enum"
                )
                return
            }

            do {
                let engine = try await hostCopy.engine()
                let currentNs = (try? await engine.cache.maxSyncedAtNs(accountAlias: aliasCopy)) ?? 0

                // If the anchor is ahead of the cache the DB may have been
                // reset (or a new process started). Expire so the framework
                // performs a full re-enumeration.
                if previousNs > currentNs && previousNs != 0 {
                    Self.log.debug(
                        "OfemFPEEnumerator[\(aliasCopy, privacy: .public)]: enumerateChanges — anchor ahead of cache, expiring"
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
                            "OfemFPEEnumerator[\(aliasCopy, privacy: .public)]: enumerateChanges — skipping un-decodable record: \(error.localizedDescription, privacy: .public)"
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
                    "OfemFPEEnumerator[\(aliasCopy, privacy: .public)]: enumerateChanges delivered — container=\(containerLogID, privacy: .public) updates=\(updatedRecords.count, privacy: .public) deletions=\(deletedIdStrings.count, privacy: .public) anchor=\(previousNs, privacy: .public)→\(currentNs, privacy: .public)"
                )
            } catch is CancellationError {
                observer.finishEnumeratingWithError(CocoaError(.userCancelled))
            } catch {
                let code = FPError.classify(error)
                Self.log.error(
                    "OfemFPEEnumerator[\(aliasCopy, privacy: .public)]: enumerateChanges failed — container=\(containerLogID, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
                )
                // Surface auth-error state so the host-app menu bar can show
                // a "Sign-in required" indicator. Token expiry in steady state
                // surfaces here, not in enumerateItems, so this is the critical
                // path for detecting post-initial-enumeration auth failures.
                if code == .notAuthenticated {
                    hostCopy.markNeedsSignIn()
                }
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
/// Workspace refresh: before computing the cache delta, `enumerateChanges`
/// calls `engine.sync.listWorkspaces(alias:)` to refresh the SQLite workspace
/// cache (adds new workspaces, tombstones removed ones, advances `synced_at`).
/// This refresh is throttled to at most once per `workspaceRefreshInterval` per
/// alias across all enumerator instances.  `FileProviderExtension.enumerator(for:)`
/// allocates a fresh `OfemWorkingSetEnumerator` on each call, so per-instance
/// throttle state would be reset on every vend — the throttle must be shared
/// via a static dictionary keyed by alias and protected by `staticThrottleLock`.
///
/// Stamp-after-success: the throttle timestamp is written only AFTER a
/// successful `listWorkspaces`.  If the engine is unavailable during early
/// startup the window is not consumed, so the next signal retries immediately.
///
/// Auth-failure reset: if `listWorkspaces` fails with an auth error the stamp
/// is cleared so the next working-set signal (which may arrive after the user
/// re-authenticates) triggers a fresh refresh without waiting for the full
/// throttle window to expire.
///
/// Task ownership: `taskLock` guards `inFlightChangesTask` and
/// `inFlightAnchorTask`. `invalidate()` cancels both synchronously (fpe-15).
final class OfemWorkingSetEnumerator: NSObject, NSFileProviderEnumerator {
    private static let log = Logger(
        subsystem: "dev.debruyn.ofem.fileprovider",
        category: "working-set"
    )

    /// At most one workspace-list refresh per this interval per alias.
    /// Shared across all enumerator instances for the same alias via the
    /// static `aliasRefreshTimestamps` dictionary.
    static let workspaceRefreshInterval: Duration = .seconds(60)

    // MARK: - Shared per-alias throttle state

    /// Guards all accesses to `aliasRefreshTimestamps`.
    private static let staticThrottleLock = NSLock()

    /// Maps account alias → monotonic instant of the last SUCCESSFUL workspace
    /// refresh.  A missing entry (or a `nil` value if we were to store nils)
    /// means "never refreshed" — forces a refresh on the next call.
    ///
    /// `nonisolated(unsafe)` is safe here because every read and write is
    /// serialised through `staticThrottleLock`.
    nonisolated(unsafe) static var aliasRefreshTimestamps: [String: ContinuousClock.Instant] = [:]

    // MARK: - Instance state

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

    // MARK: - Throttle helpers (internal for tests)

    /// Returns the last successful refresh instant for `alias`, or `nil` if
    /// none has been recorded yet.  Thread-safe.
    static func lastRefresh(for alias: String) -> ContinuousClock.Instant? {
        staticThrottleLock.withLock { aliasRefreshTimestamps[alias] }
    }

    /// Records a successful refresh for `alias` at `instant`.  Thread-safe.
    static func recordRefresh(for alias: String, at instant: ContinuousClock.Instant) {
        staticThrottleLock.withLock { aliasRefreshTimestamps[alias] = instant }
    }

    /// Clears the refresh timestamp for `alias` (used on auth failure so the
    /// next signal retries immediately without waiting for the full window).
    static func clearRefresh(for alias: String) {
        _ = staticThrottleLock.withLock { aliasRefreshTimestamps.removeValue(forKey: alias) }
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
            "WorkingSet[\(self.alias, privacy: .public)]: invalidated"
        )
    }

    func enumerateItems(
        for observer: NSFileProviderEnumerationObserver,
        startingAt _: NSFileProviderPage
    ) {
        OfemWorkingSetEnumerator.log.debug(
            "WorkingSet[\(self.alias, privacy: .public)]: enumerateItems entry — working set always returns empty"
        )
        let items: [NSFileProviderItem] = []
        observer.didEnumerate(items)
        observer.finishEnumerating(upTo: nil)
        OfemWorkingSetEnumerator.log.debug(
            "WorkingSet[\(self.alias, privacy: .public)]: enumerateItems delivered — count=\(items.count, privacy: .public) nextPage=nil"
        )
    }

    /// Reports real cache deltas since `anchor` for the working set.
    ///
    /// `signalEnumerator(for: .workingSet)` causes macOS to call here. Before
    /// computing the cache delta, this method refreshes the workspace list from
    /// Fabric (throttled to `workspaceRefreshInterval` per alias, shared across
    /// all enumerator instances) so newly created, removed, or renamed workspaces
    /// populate the cache before the delta is computed.  The host-side
    /// ChangeWatcher then reads the updated cache to detect workspace-set changes
    /// and remounts the domain when the set changes.
    ///
    /// Stamp-after-success: the throttle timestamp is advanced ONLY on a
    /// successful `listWorkspaces`, so engine failures during startup do not
    /// consume the window.  Auth failures reset the stamp so re-auth leads to
    /// an immediate retry on the next signal.
    func enumerateChanges(
        for observer: NSFileProviderChangeObserver,
        from anchor: NSFileProviderSyncAnchor
    ) {
        let aliasCopy = alias
        let hostCopy = engineHost
        let previousNs = decodeSyncAnchor(anchor)

        // Check the shared throttle (read-only — we only write AFTER success).
        let now = ContinuousClock.now
        let shouldRefresh: Bool = {
            if let last = Self.lastRefresh(for: aliasCopy),
               now - last < Self.workspaceRefreshInterval
            {
                return false
            }
            return true
        }()

        // Store the task so invalidate() can cancel it (fpe-15).
        let changesTask = Task<Void, Never> {
            Self.log.debug(
                "WorkingSet[\(aliasCopy, privacy: .public)]: enumerateChanges entry — anchor=\(previousNs, privacy: .public)"
            )
            do {
                let engine = try await hostCopy.engine()

                // Throttled workspace-list refresh: populate or update the
                // SQLite cache with fresh data from Fabric before computing
                // the delta. The stamp is written only on success (stamp-after-
                // success policy). Auth failures reset the stamp.
                if shouldRefresh {
                    do {
                        _ = try await engine.sync.listWorkspaces(alias: aliasCopy)
                        // Stamp only after a successful refresh.
                        Self.recordRefresh(for: aliasCopy, at: ContinuousClock.now)
                        Self.log.debug(
                            "WorkingSet: refreshed workspace list for \(aliasCopy, privacy: .public)"
                        )
                    } catch {
                        let code = FPError.classify(error)
                        Self.log.warning(
                            "WorkingSet: workspace refresh failed for \(aliasCopy, privacy: .public): \(error.localizedDescription, privacy: .public)"
                        )
                        if code == .notAuthenticated {
                            // Auth failure: reset throttle so the next signal
                            // retries immediately after re-auth, then surface
                            // the failure and abort.
                            Self.clearRefresh(for: aliasCopy)
                            hostCopy.markNeedsSignIn()
                            observer.finishEnumeratingWithError(nsFileProviderError(for: code))
                            return
                        }
                        // Non-auth errors: proceed with the existing cache.
                    }
                }

                let currentNs = (try? await engine.cache.maxSyncedAtNs(accountAlias: aliasCopy)) ?? 0

                // If the anchor is ahead of the cache the DB may have been
                // reset (or a new process started). Expire so the framework
                // performs a full re-enumeration, mirroring the same guard in
                // OfemFPEEnumerator.enumerateChanges.
                if previousNs > currentNs && previousNs != 0 {
                    Self.log.debug(
                        "WorkingSet: anchor ahead of cache for \(aliasCopy, privacy: .public) — expiring"
                    )
                    observer.finishEnumeratingWithError(NSFileProviderError(.syncAnchorExpired))
                    return
                }

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
                            "WorkingSet[\(aliasCopy, privacy: .public)]: enumerateChanges — skipping un-decodable record: \(error.localizedDescription, privacy: .public)"
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
                    "WorkingSet[\(aliasCopy, privacy: .public)]: enumerateChanges delivered — updates=\(updatedRecords.count, privacy: .public) deletions=\(deletedIdStrings.count, privacy: .public) anchor=\(previousNs, privacy: .public)→\(currentNs, privacy: .public)"
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
                    "WorkingSet[\(aliasCopy, privacy: .public)]: enumerateChanges failed — error=\(error.localizedDescription, privacy: .public)"
                )
                // Mirror OfemFPEEnumerator.enumerateChanges: surface auth failures
                // so the host-app menu bar can show "Sign-in required".
                // Also reset the shared throttle on auth failure so the next
                // working-set signal (after re-auth) triggers an immediate refresh.
                if code == .notAuthenticated {
                    Self.clearRefresh(for: aliasCopy)
                    hostCopy.markNeedsSignIn()
                }
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
