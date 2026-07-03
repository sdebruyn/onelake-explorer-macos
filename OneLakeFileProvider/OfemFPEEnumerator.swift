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
//   re-enumeration on every poll. Every vended anchor is clamped up to the
//   tombstone-purge horizon (`tombstonesPurgedThroughNs`); a client whose anchor
//   predates that horizon is expired (the lagging-client guard), since deletions
//   before the horizon may have been TTL-purged and would be missing from a
//   delta. See `syncAnchorDecision` / `effectiveAnchorNs`.
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
//
// - Shared decode/delta helpers: `decodeRecords` (the per-record decode loop
//   + empty-filename guard) and `serveCacheDelta` (the anchor-check → fetch →
//   decode → deliver → advance-anchor sequence) are file-scope functions used
//   by every enumeration path that turns `MetadataRecord`s into `OfemFPEItem`s
//   — both enumerators' `enumerateChanges` and `OfemFPEEnumerator.enumerate`'s
//   `.item`/`.path` branches. A fix to either guard therefore lives in one
//   place instead of four copies.
//
// - Trash: `.trash` gets `OfemTrashEnumerator`, a real always-empty
//   enumerator — OneLake has no trash/recycle-bin concept. It must NOT share
//   `OfemWorkingSetEnumerator`: that type's `enumerateChanges` refreshes the
//   workspace list and reports alias-wide cache deltas, which have nothing to
//   do with — and would be misattributed to — the trash container.

@preconcurrency import FileProvider
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
    // `Data.withUnsafeBytes` gives no alignment guarantee for the backing
    // buffer, so a plain `load(as:)` is an unaligned-load trap waiting to
    // happen (UB in release, a debug-build crash). `loadUnaligned` is the
    // alignment-safe equivalent.
    return data.withUnsafeBytes { ptr -> Int64 in
        Int64(bigEndian: ptr.loadUnaligned(as: Int64.self))
    }
}

// MARK: - Shared change-delta helpers

/// Decodes cache records into `OfemFPEItem`s, skipping any row that fails to
/// decode or that would produce a blank filename.
///
/// Two independent skip conditions, both logged at `.error` (observable, not
/// silent) rather than failing the whole batch:
///
/// 1. `DomainItem.from(record:)` throws — a permanently corrupt or
///    non-enumerable (sentinel) row.
/// 2. The decoded item's filename is empty — delivering it would trip
///    `__FILEPROVIDER_BAD_ITEM_MISSING_FILENAME__` → SIGABRT.
///
/// This is the single place both conditions are checked; every enumeration
/// path that decodes `MetadataRecord`s (`OfemFPEEnumerator.enumerate`'s
/// `.item`/`.path` branches and both enumerators' `enumerateChanges` via
/// `serveCacheDelta`) goes through it, so a fix to either guard lives in one
/// place. Callers that drive a sync anchor off the input batch must still
/// advance the anchor past any skipped record — see the "Anchor-on-decode-
/// failure policy" note at the top of this file.
func decodeRecords(
    _ records: [MetadataRecord],
    logPrefix: String,
    log: Logger
) -> [OfemFPEItem] {
    var items: [OfemFPEItem] = []
    items.reserveCapacity(records.count)
    for record in records {
        do {
            let di = try DomainItem.from(record: record)
            let item = OfemFPEItem(from: di)
            // Defensive guard: a blank filename would cause
            // __FILEPROVIDER_BAD_ITEM_MISSING_FILENAME__ → SIGABRT.
            guard !item.filename.isEmpty else {
                log.error(
                    "\(logPrefix, privacy: .public): skipping empty-filename row (path=\(record.path, privacy: .public))"
                )
                continue
            }
            items.append(item)
        } catch {
            log.error(
                "\(logPrefix, privacy: .public): skipping un-decodable record (path=\(record.path, privacy: .public)): \(error.localizedDescription, privacy: .public)"
            )
        }
    }
    return items
}

// MARK: - Sync-anchor expiry decision

/// The outcome of evaluating an incoming sync anchor against the cache.
enum SyncAnchorDecision: Equatable {
    /// Force a full re-enumeration (`.syncAnchorExpired`).
    case expire
    /// Serve an incremental delta and advance the anchor to `effectiveNs`.
    case serve(effectiveNs: Int64)
}

/// Decides how to handle an incoming sync anchor `previousNs`, given the store's
/// current sync anchor `currentNs` (newest `synced_at_ns`/`deleted_at_ns`) and
/// the tombstone-purge horizon `purgedThroughNs`.
///
/// Pure and total so the whole anchor-window policy is unit-testable without a
/// live `OfemEngine` (which carries an auth dependency).
///
/// The anchor a client may hold lives in the window `[purgedThroughNs,
/// effectiveNs]` where `effectiveNs = max(currentNs, purgedThroughNs)`:
///
///   - `previousNs == 0` — first mount: a full enumeration already happens, so
///     always serve. (Never expire on a zero anchor.)
///   - `previousNs < purgedThroughNs` — LAGGING-CLIENT GUARD (safety-critical):
///     the client last synced before the purge horizon, so deletions between its
///     anchor and the horizon may have been TTL-purged and are now invisible in
///     an incremental delta. Expire → the framework reconciles those deletions
///     by absence during the forced full re-enumeration. This is the one guard a
///     purge can trip; the anchor-ahead check below can NEVER catch a purge,
///     because purging old tombstones only removes rows — it never raises
///     `currentNs` above `previousNs`.
///   - `previousNs > effectiveNs` — anchor ahead of everything we can serve (the
///     DB was reset/rebuilt): expire so the client rebases.
///   - otherwise — serve an incremental delta.
///
/// Every served/handed-out anchor is `effectiveNs`, i.e. clamped UP to the purge
/// horizon. Without that clamp, an alias idle longer than the tombstone TTL
/// (whose newest `synced_at_ns` has fallen below the horizon — unchanged rows
/// are never re-stamped, see `SyncEngine.refreshFolder`) would hand back an
/// anchor below `purgedThroughNs`, and the very next `enumerateChanges` would
/// re-trip the lagging-client guard forever — a tight re-enumeration loop.
/// Clamping to the horizon turns that into at most one forced re-enumeration per
/// 24 h purge step.
func syncAnchorDecision(previousNs: Int64, currentNs: Int64, purgedThroughNs: Int64) -> SyncAnchorDecision {
    let effectiveNs = max(currentNs, purgedThroughNs)
    // First mount → full enum already happened; never expire a zero anchor.
    if previousNs == 0 { return .serve(effectiveNs: effectiveNs) }
    // Lagging past the purge horizon → purged deletions may be missing.
    if previousNs < purgedThroughNs { return .expire }
    // Anchor ahead of the cache (DB reset) → rebase.
    if previousNs > effectiveNs { return .expire }
    return .serve(effectiveNs: effectiveNs)
}

/// Anchor floor for `alias`: `max(syncAnchorNs, tombstonesPurgedThroughNs)`.
///
/// Every anchor the FPE vends (from `serveCacheDelta` and both enumerators'
/// `currentSyncAnchor`) is clamped up to the tombstone-purge horizon so it never
/// sits below `purgedThroughNs` — see `syncAnchorDecision` for why an anchor
/// below the horizon would cause an infinite re-enumeration loop. Returns `0` on
/// any read failure, which forces a full diff on the next poll (safe: a spurious
/// full re-enumeration, never a silent skip).
func effectiveAnchorNs(engine: OfemEngine, alias: String) async -> Int64 {
    let currentNs = (try? await engine.cache.syncAnchorNs(accountAlias: alias)) ?? 0
    let purgedThroughNs = (try? await engine.cache.tombstonesPurgedThroughNs(accountAlias: alias)) ?? 0
    return max(currentNs, purgedThroughNs)
}

/// Computes the cache delta since `previousNs` for `alias` and delivers it to
/// `observer`, advancing the sync anchor to the store's anchor floor
/// (`max(syncAnchorNs, tombstonesPurgedThroughNs)`; see the "Anchor-on-decode-
/// failure policy" note at the top of this file — the anchor tracks
/// `synced_at_ns`, not decode success, so a permanently corrupt row decoded via
/// `decodeRecords` can never hold it back).
///
/// Shared by `OfemFPEEnumerator.enumerateChanges` (workspace/item/path
/// containers) and `OfemWorkingSetEnumerator.enumerateChanges` (the working
/// set, called after its own throttled workspace-list refresh). Each caller
/// keeps its own outer `do/catch` for `CancellationError` and auth-error
/// handling (`markNeedsSignIn`), since only the working set also needs to
/// reset its refresh throttle on an auth failure.
///
/// The incoming anchor is evaluated by ``syncAnchorDecision(previousNs:currentNs:purgedThroughNs:)``.
/// When it returns `.expire` — the anchor is ahead of the cache (DB reset) OR it
/// predates the tombstone-purge horizon (lagging-client guard) — this calls
/// `finishEnumeratingWithError(.syncAnchorExpired)` and returns without touching
/// the delta, so the framework performs a full re-enumeration.
func serveCacheDelta(
    engine: OfemEngine,
    alias: String,
    previousNs: Int64,
    observer: NSFileProviderChangeObserver,
    log: Logger,
    logPrefix: String
) async throws {
    let currentNs = (try? await engine.cache.syncAnchorNs(accountAlias: alias)) ?? 0
    // Propagate (not `try?`) a watermark read failure: silently defaulting the
    // horizon to 0 would disable the lagging-client guard and could serve a
    // delta missing purged deletions — the exact silent loss this guards against.
    let purgedThroughNs = try await engine.cache.tombstonesPurgedThroughNs(accountAlias: alias)

    let effectiveNs: Int64
    switch syncAnchorDecision(previousNs: previousNs, currentNs: currentNs, purgedThroughNs: purgedThroughNs) {
    case .expire:
        log.debug(
            "\(logPrefix, privacy: .public): expiring anchor (previous=\(previousNs, privacy: .public) purgedThrough=\(purgedThroughNs, privacy: .public))"
        )
        observer.finishEnumeratingWithError(NSFileProviderError(.syncAnchorExpired))
        return
    case let .serve(ns):
        effectiveNs = ns
    }

    // Propagate SQLite errors rather than silently returning an empty delta
    // with an advanced anchor (which would hide data loss).
    let (updatedRecords, deletedIdStrings) = try await engine.cache.itemsChangedAfter(
        accountAlias: alias,
        ns: previousNs
    )

    let updatedItems = decodeRecords(updatedRecords, logPrefix: logPrefix, log: log)
    if !updatedItems.isEmpty {
        observer.didUpdate(updatedItems)
    }

    // Report remote deletions so Finder removes the items.
    if !deletedIdStrings.isEmpty {
        let deletedIdentifiers = deletedIdStrings.map { NSFileProviderItemIdentifier($0) }
        observer.didDeleteItems(withIdentifiers: deletedIdentifiers)
    }

    let newAnchor = encodeSyncAnchor(effectiveNs)
    observer.finishEnumeratingChanges(upTo: newAnchor, moreComing: false)

    log.debug(
        "\(logPrefix, privacy: .public): delivered — updates=\(updatedRecords.count, privacy: .public) deletions=\(deletedIdStrings.count, privacy: .public) anchor=\(previousNs, privacy: .public)→\(effectiveNs, privacy: .public)"
    )
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
///
/// `@unchecked Sendable`: the FileProvider framework invokes the synchronous,
/// non-isolated `NSFileProviderEnumerator` requirements from arbitrary queues,
/// so an `actor` is not viable. All mutable state — the three in-flight `Task`
/// handles — is `nonisolated(unsafe)` and guarded by `taskLock`; every other
/// stored property is an immutable `let`. The lock is the concurrency guard, so
/// `@unchecked` is the correct, idiomatic choice (mirrors the lock-guarded
/// framework-delegate pattern used for the XPC service types).
final class OfemFPEEnumerator: NSObject, NSFileProviderEnumerator, @unchecked Sendable {
    private static let log = Logger(
        subsystem: "dev.debruyn.ofem.fileprovider",
        category: "fpe-enumerator"
    )

    // periphery:ignore - stored to satisfy NSFileProviderEnumerator context; not read back
    let containerItemIdentifier: NSFileProviderItemIdentifier
    let identifier: ItemIdentifier // OfemKit-typed
    let alias: String
    let engineHost: any EngineProviding

    /// Guards mutations to all in-flight task handles and `isInvalidated`.
    private let taskLock = NSLock()
    /// Set to `true` inside `invalidate()` under `taskLock`. Every
    /// `enumerate*`/`currentSyncAnchor` method checks this flag — under the
    /// same lock acquisition that would store the new task handle — and cancels
    /// the just-created task instead of storing it when the flag is set.  This
    /// closes the create-before-lock window: a task racing with `invalidate()`
    /// is guaranteed to be cancelled even if `invalidate()` ran to completion
    /// before the new handle was stored.
    private nonisolated(unsafe) var isInvalidated = false
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

    // periphery:ignore
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
        // Set `isInvalidated` so any task created concurrently (after the lock
        // is released here) is guaranteed to be cancelled when it acquires the
        // lock to store its handle.
        taskLock.withLock {
            isInvalidated = true
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

        // NSFileProviderEnumerationObserver is @_nonSendable. Box it so the
        // Task closure can capture it across the region-isolation boundary.
        // The FPE framework guarantees the observer remains valid for the
        // duration of the enumeration call.
        struct ObsBox: @unchecked Sendable {
            let value: NSFileProviderEnumerationObserver
        }
        let obs = ObsBox(value: observer)

        // Cancel any previous in-flight items task. Only cancel on a new
        // *items* enumeration — not on change observation — so concurrent
        // change-observation and items-enumeration tasks remain independent.
        let newTask = Task<Void, Never> {
            // Bail out immediately if the enumerator was invalidated in the
            // narrow window between Task creation and the lock-store check.
            guard !Task.isCancelled else { return }
            do {
                let engine = try await hostCopy.engine()
                let items = try await Self.enumerate(
                    identifier: identifierCopy,
                    alias: aliasCopy,
                    engine: engine
                )
                obs.value.didEnumerate(items)
                obs.value.finishEnumerating(upTo: nil)
                Self.log.debug(
                    "OfemFPEEnumerator[\(aliasCopy, privacy: .public)]: enumerateItems delivered — container=\(containerLogID, privacy: .public) count=\(items.count, privacy: .public) nextPage=nil"
                )
            } catch is CancellationError {
                Self.log.debug(
                    "OfemFPEEnumerator[\(aliasCopy, privacy: .public)]: enumerateItems cancelled — container=\(containerLogID, privacy: .public)"
                )
                obs.value.finishEnumeratingWithError(CocoaError(.userCancelled))
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
                obs.value.finishEnumeratingWithError(nsFileProviderError(for: code))
            }
        }

        taskLock.withLock {
            inFlightTask?.cancel()
            if isInvalidated {
                newTask.cancel()
            } else {
                inFlightTask = newTask
            }
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

        // NSFileProviderChangeObserver is @_nonSendable. Box it so the Task
        // closure can capture it across the region-isolation boundary.
        struct ObsBox: @unchecked Sendable { let value: NSFileProviderChangeObserver }
        let obs = ObsBox(value: observer)

        // Change-observation tasks are independent from items tasks.
        // We do NOT cancel inFlightTask here (avoids aborting an ongoing items
        // enumeration for an unrelated change observer). Store the new task in
        // inFlightChangesTask so invalidate() can cancel it (fpe-15).
        let changesTask = Task<Void, Never> {
            // Bail out immediately if the enumerator was invalidated in the
            // narrow window between Task creation and the lock-store check.
            // This is especially important for the synchronous `.root` early-
            // return below: Swift cooperative cancellation only fires at
            // suspension points, so cancelling the handle alone would not
            // prevent the synchronous observer call on a torn-down observer.
            guard !Task.isCancelled else { return }
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
                obs.value.finishEnumeratingWithError(NSFileProviderError(.syncAnchorExpired))
                Self.log.debug(
                    "OfemFPEEnumerator[\(aliasCopy, privacy: .public)]: enumerateChanges — root container, anchor expired to force full re-enum"
                )
                return
            }

            do {
                let engine = try await hostCopy.engine()
                try await serveCacheDelta(
                    engine: engine,
                    alias: aliasCopy,
                    previousNs: previousNs,
                    observer: obs.value,
                    log: Self.log,
                    logPrefix: "OfemFPEEnumerator[\(aliasCopy)] enumerateChanges container=\(containerLogID)"
                )
            } catch is CancellationError {
                obs.value.finishEnumeratingWithError(CocoaError(.userCancelled))
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
                obs.value.finishEnumeratingWithError(nsFileProviderError(for: code))
            }
        }
        taskLock.withLock {
            inFlightChangesTask?.cancel()
            if isInvalidated {
                changesTask.cancel()
            } else {
                inFlightChangesTask = changesTask
            }
        }
    }

    func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        let aliasCopy = alias
        let hostCopy = engineHost
        // NSFileProviderEnumerator completion handlers are @escaping but not
        // @Sendable. Box to cross the Task isolation boundary safely.
        struct CH: @unchecked Sendable { let fn: (NSFileProviderSyncAnchor?) -> Void }
        let ch = CH(fn: completionHandler)
        // Store the task so invalidate() can cancel it (fpe-15).
        let anchorTask = Task<Void, Never> {
            do {
                let engine = try await hostCopy.engine()
                // Clamp to the tombstone-purge horizon so the baseline anchor the
                // framework adopts after a full (re-)enumeration never sits below
                // the horizon — otherwise the next enumerateChanges would re-trip
                // the lagging-client guard forever (see effectiveAnchorNs).
                let ns = await effectiveAnchorNs(engine: engine, alias: aliasCopy)
                ch.fn(encodeSyncAnchor(ns))
            } catch is CancellationError {
                // Task was cancelled (enumerator invalidated); do not call the
                // completion handler on a torn-down enumerator.
            } catch {
                // Engine unavailable; return a zero anchor so the next poll
                // gets a full diff rather than an opaque failure.
                ch.fn(encodeSyncAnchor(0))
            }
        }
        taskLock.withLock {
            inFlightAnchorTask?.cancel()
            if isInvalidated {
                anchorTask.cancel()
            } else {
                inFlightAnchorTask = anchorTask
            }
        }
    }

    // MARK: - Private engine dispatch

    /// Dispatches enumeration based on the identifier level.
    ///
    /// Returns the concrete `OfemFPEItem` (which is `Sendable`) rather than the
    /// non-Sendable `NSFileProviderItem` existential so the result can cross the
    /// enumeration `Task`'s isolation boundary without a data-race diagnostic.
    private static func enumerate(
        identifier: ItemIdentifier,
        alias: String,
        engine: OfemEngine
    ) async throws -> [OfemFPEItem] {
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
            // Skip-and-continue on any bad row, matching the enumerateChanges
            // policy. A hard throw here would abort the entire folder listing.
            return decodeRecords(
                records,
                logPrefix: "OfemFPEEnumerator[\(alias)] enumerate(.item)",
                log: Self.log
            )

        case let .path(workspaceID, itemID, path):
            // List a sub-path inside a Fabric item.
            let key = cacheKey(alias: alias, workspaceID: workspaceID, itemID: itemID, path: path)
            let records = try await engine.sync.enumerate(key: key)
            // Skip-and-continue on any bad row, matching the enumerateChanges
            // policy. A hard throw here would abort the entire folder listing.
            return decodeRecords(
                records,
                logPrefix: "OfemFPEEnumerator[\(alias)] enumerate(.path)",
                log: Self.log
            )
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
///
/// `@unchecked Sendable`: same justification as `OfemFPEEnumerator` — the
/// framework invokes the synchronous `NSFileProviderEnumerator` requirements
/// from arbitrary queues (actor not viable); the in-flight `Task` handles are
/// `nonisolated(unsafe)` and guarded by `taskLock`, and the shared per-alias
/// throttle state is guarded by `staticThrottleLock`.
final class OfemWorkingSetEnumerator: NSObject, NSFileProviderEnumerator, @unchecked Sendable {
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

    /// Guards mutations to task handles and `isInvalidated`.
    private let taskLock = NSLock()
    /// Set to `true` inside `invalidate()` under `taskLock`. Every
    /// `enumerateChanges`/`currentSyncAnchor` method checks this flag — under
    /// the same lock acquisition that would store the new task handle — and
    /// cancels the just-created task instead of storing it when the flag is
    /// set.  Closes the create-before-lock window (mirrors OfemFPEEnumerator).
    private nonisolated(unsafe) var isInvalidated = false
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
        // Set `isInvalidated` so any task created concurrently (after the lock
        // is released here) is guaranteed to be cancelled when it acquires the
        // lock to store its handle.
        taskLock.withLock {
            isInvalidated = true
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
        // Guard against calling a torn-down observer after invalidation.
        // enumerateItems is synchronous here (no Task), so check the flag
        // directly under the lock before touching the observer.
        guard taskLock.withLock({ !isInvalidated }) else { return }
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

        // NSFileProviderChangeObserver is @_nonSendable. Box it so the Task
        // closure can capture it across the region-isolation boundary.
        struct ObsBox: @unchecked Sendable { let value: NSFileProviderChangeObserver }
        let obs = ObsBox(value: observer)

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
            // Bail out immediately if the enumerator was invalidated in the
            // narrow window between Task creation and the lock-store check.
            guard !Task.isCancelled else { return }
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
                            obs.value.finishEnumeratingWithError(nsFileProviderError(for: code))
                            return
                        }
                        // Non-auth errors: proceed with the existing cache.
                    }
                }

                // If the anchor is ahead of the cache, the store's decode/skip
                // batch is empty, or the delta is delivered — all handled by
                // serveCacheDelta, mirroring OfemFPEEnumerator.enumerateChanges.
                try await serveCacheDelta(
                    engine: engine,
                    alias: aliasCopy,
                    previousNs: previousNs,
                    observer: obs.value,
                    log: Self.log,
                    logPrefix: "WorkingSet[\(aliasCopy)] enumerateChanges"
                )
            } catch is CancellationError {
                // The enumerator was invalidated while the task was in flight.
                // Signal userCancelled so the framework knows this was a clean
                // cancellation, not a sync failure (mirrors OfemFPEEnumerator
                // enumerateChanges — fpe-15).
                obs.value.finishEnumeratingWithError(CocoaError(.userCancelled))
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
                obs.value.finishEnumeratingWithError(nsFileProviderError(for: code))
            }
        }
        taskLock.withLock {
            inFlightChangesTask?.cancel()
            if isInvalidated {
                changesTask.cancel()
            } else {
                inFlightChangesTask = changesTask
            }
        }
    }

    func currentSyncAnchor(
        completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void
    ) {
        let aliasCopy = alias
        let hostCopy = engineHost
        // NSFileProviderEnumerator completion handlers are @escaping but not
        // @Sendable. Box to cross the Task isolation boundary safely.
        struct CH: @unchecked Sendable { let fn: (NSFileProviderSyncAnchor?) -> Void }
        let ch = CH(fn: completionHandler)
        // Store the task so invalidate() can cancel it (fpe-15).
        let anchorTask = Task<Void, Never> {
            do {
                let engine = try await hostCopy.engine()
                // Clamp to the tombstone-purge horizon (see effectiveAnchorNs and
                // OfemFPEEnumerator.currentSyncAnchor) so the working-set baseline
                // anchor never sits below the horizon and re-trips the guard.
                let ns = await effectiveAnchorNs(engine: engine, alias: aliasCopy)
                ch.fn(encodeSyncAnchor(ns))
            } catch is CancellationError {
                // Task was cancelled (enumerator invalidated); do not call the
                // completion handler on a torn-down enumerator.
            } catch {
                ch.fn(encodeSyncAnchor(0))
            }
        }
        taskLock.withLock {
            inFlightAnchorTask?.cancel()
            if isInvalidated {
                anchorTask.cancel()
            } else {
                inFlightAnchorTask = anchorTask
            }
        }
    }
}

// MARK: - Trash enumerator

/// Enumerator for the `.trashContainer` sentinel.
///
/// OneLake has no trash / recycle-bin concept — deletes are permanent DFS
/// deletes (see `docs/onelake-api.md`). This type is a real, always-empty
/// enumerator: `enumerateItems` reports zero items and `enumerateChanges`
/// reports zero changes, both synchronously and without touching the engine.
///
/// It exists specifically so `FileProviderExtension.enumerator(for:)` does
/// NOT fall back to `OfemWorkingSetEnumerator` for the trash container.
/// Before this type existed, both `.trash` and `.workingSet` shared that one
/// enumerator instance — but `OfemWorkingSetEnumerator.enumerateChanges` does
/// a throttled `listWorkspaces` refresh and reports alias-wide cache deltas,
/// none of which has anything to do with trash. Routing trash through it
/// meant every working-set-driven delta was also (incorrectly) attributed to
/// the trash container, and vice versa.
///
/// No mutable state, so no task tracking / locking is needed (contrast
/// `OfemFPEEnumerator` and `OfemWorkingSetEnumerator`, which own in-flight
/// `Task` handles guarded by an `NSLock`).
final class OfemTrashEnumerator: NSObject, NSFileProviderEnumerator, @unchecked Sendable {
    func invalidate() {}

    func enumerateItems(
        for observer: NSFileProviderEnumerationObserver,
        startingAt _: NSFileProviderPage
    ) {
        observer.didEnumerate([])
        observer.finishEnumerating(upTo: nil)
    }

    func enumerateChanges(
        for observer: NSFileProviderChangeObserver,
        from anchor: NSFileProviderSyncAnchor
    ) {
        // Trash never changes: echo the same anchor back so the framework
        // sees a stable, empty delta instead of expiring it into a full
        // re-enumeration on every poll.
        observer.finishEnumeratingChanges(upTo: anchor, moreComing: false)
    }

    func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        completionHandler(encodeSyncAnchor(0))
    }
}
