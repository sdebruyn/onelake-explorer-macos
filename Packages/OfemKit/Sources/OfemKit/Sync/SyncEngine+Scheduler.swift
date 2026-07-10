import Foundation
import os.log

// MARK: - SyncEngine+Scheduler

extension SyncEngine {
    // MARK: - Offline status

    // periphery:ignore
    /// Returns `true` when the engine is currently considered offline (recently
    /// observed an offline-class error and the cooldown has not yet expired).
    ///
    /// Matches `OfflineTracker.currentlyOffline()` naming: two consecutive calls
    /// may return different values (the cooldown can expire between them).
    public var currentlyOffline: Bool {
        get async { await offlineTracker.currentlyOffline() }
    }

    // MARK: - Shared discovery/reconcile helpers

    /// Indexes cache rows by their `path` (the workspace/item GUID for discovery
    /// rows, or the relative path for folder children). Used to look up each
    /// freshly-listed candidate's prior state before deciding whether to upsert.
    static func indexByPath(_ rows: [MetadataRecord]) -> [String: MetadataRecord] {
        var byPath: [String: MetadataRecord] = [:]
        byPath.reserveCapacity(rows.count)
        for r in rows {
            byPath[r.path] = r
        }
        return byPath
    }

    /// Classifies listing candidates against their cached counterparts, returning
    /// the conditional upsert batch plus the added/updated counts.
    ///
    /// Shared new-or-changed predicate for ``refreshFolder(key:)`` and the
    /// discovery/item-listing reconciles (#361/#379), so the rule lives in one
    /// place: a candidate is written back only when it is new (absent from
    /// `cachedByPath`) or ``Enumerator/entryChanged(current:next:)`` reports a
    /// real change. An unchanged candidate is left out entirely, so its cached
    /// row (and `syncedAtNs`) stays exactly as-is — bumping it on every poll
    /// would shift the working-set delta baseline forward and produce a phantom
    /// `didUpdate` for every unchanged entry.
    static func classifyUpserts(
        candidates: [MetadataRecord],
        cachedByPath: [String: MetadataRecord]
    ) -> (batch: [MetadataRecord], added: Int, updated: Int) {
        var batch: [MetadataRecord] = []
        var added = 0
        var updated = 0
        for next in candidates {
            guard let cur = cachedByPath[next.path] else {
                added += 1
                batch.append(next)
                continue
            }
            if Enumerator.entryChanged(current: cur, next: next) {
                updated += 1
                batch.append(next)
            }
        }
        return (batch, added, updated)
    }

    // MARK: - Shared remote-operation error handler

    /// Handles the common error path for remote operations: observes offline
    /// state, marks workspace paused when appropriate, emits a failure telemetry
    /// event, and always rethrows.
    func withRemoteOperationError(
        error: any Error,
        key: CacheKey,
        eventName: String,
        failCode: String,
        start: Date
    ) async throws -> Never {
        await offlineTracker.observe(error)
        if await pauseManager.markPausedIfNeeded(
            workspaceID: key.workspaceID, alias: key.accountAlias, error: error
        ) {
            await track(eventName: eventName, alias: key.accountAlias, start: start, outcome: .paused)
            throw SyncError.workspacePaused
        }
        await track(eventName: eventName, alias: key.accountAlias, start: start, outcome: .failed(failCode))
        throw error
    }

    // MARK: - Batch cache helpers

    /// Upserts all records in one GRDB transaction.
    func batchUpsert(_ records: [MetadataRecord], context: String) async {
        guard !records.isEmpty else { return }
        do {
            try await cache.batchUpsert(records)
        } catch {
            Self.log.warning("SyncEngine: batchUpsert failed context=\(context, privacy: .public) err=\(error, privacy: .public)")
        }
    }

    /// Deletes all keys in one GRDB transaction.
    ///
    /// `recordTombstones` is passed through to ``CacheStore/batchDelete(_:recordTombstones:)``:
    /// `true` for remote-reconcile deletes that Finder must see as removals,
    /// which is every call site in this engine.
    func batchDelete(_ keys: [CacheKey], recordTombstones: Bool, context: String) async {
        guard !keys.isEmpty else { return }
        do {
            try await cache.batchDelete(keys, recordTombstones: recordTombstones)
        } catch {
            Self.log.warning("SyncEngine: batchDelete failed context=\(context, privacy: .public) err=\(error, privacy: .public)")
        }
    }

    // MARK: - Telemetry helpers (sync-06)

    /// Outcome descriptor for telemetry emission.
    enum TrackOutcome {
        case success(bytes: Int64? = nil)
        case successWithCode(_ code: String)
        case failed(_ code: String)
        case paused
    }

    /// Emits a telemetry event with common fields pre-filled (sync-06: single
    /// helper replaces 15+ near-identical construction sites).
    func track(
        eventName: String,
        alias: String,
        start: Date,
        outcome: TrackOutcome
    ) async {
        let aliasHash = TelemetryRedaction.hashAlias(alias)
        let ms = elapsedMs(since: start)
        let event = switch outcome {
        case let .success(bytes):
            // `bytesTransferred` defaults to 0 when `bytes` is nil, which means
            // "not applicable" (e.g. a cache-hit path that does no I/O). The field
            // is omitted from the AppInsights measurement map when it is 0, so a
            // nil result is correctly distinguishable from a genuine 0-byte transfer
            // at the analytics level (both emit no measurement, which is the desired
            // behaviour — a 0-byte file is a legitimate edge case but not worth
            // special-casing in the wire format).
            TelemetryEvent(
                name: eventName,
                accountAliasHash: aliasHash,
                durationMs: ms,
                success: true,
                bytesTransferred: bytes ?? 0
            )
        case let .successWithCode(code):
            TelemetryEvent(
                name: eventName,
                accountAliasHash: aliasHash,
                durationMs: ms,
                success: true,
                errorCode: code
            )
        case let .failed(code):
            TelemetryEvent(
                name: eventName,
                accountAliasHash: aliasHash,
                durationMs: ms,
                success: false,
                errorCode: code
            )
        case .paused:
            TelemetryEvent(
                name: eventName,
                accountAliasHash: aliasHash,
                durationMs: ms,
                success: false,
                errorCode: "capacity_paused"
            )
        }
        await track(event)
    }

    func track(_ event: TelemetryEvent) async {
        await telemetry?.track(event)
    }
}

// MARK: - Elapsed helper

/// Returns elapsed milliseconds since `start`, floored at 1 ms to avoid
/// reporting a sub-millisecond / zero duration in telemetry (the 1 ms floor
/// is intentional and documented here rather than as a magic literal — sync-07).
private let elapsedMsMinimum: Int64 = 1

func elapsedMs(since start: Date) -> Int64 {
    let d = Int64(Date().timeIntervalSince(start) * 1000)
    return max(elapsedMsMinimum, d)
}

// MARK: - nowNs helper (sync-21)

/// Returns the current time as Unix nanoseconds, clamped to `Int64` range.
///
/// Replaces the six `dateToNs(Date())!` force-unwraps throughout `SyncEngine`.
/// `dateToNsOrNil` returns `nil` only for a `nil` input; passing `Date()` (never
/// nil) could only fail if the clock is radically wrong. Clamping to `0`
/// (the "unknown" sentinel) avoids both the force-unwrap and a crash (sync-21).
func currentNowNs() -> Int64 {
    dateToNsOrNil(Date()) ?? 0
}

// MARK: - dateToNsOrNil (nonisolated helper)

/// Converts `date` to Unix nanoseconds, or `nil` if `date` is `nil` or out of
/// `Int64` range.
///
/// This mirrors `CacheModels.dateToNs` but keeps `nil` (rather than folding it
/// to `0`) so call sites can distinguish "no timestamp in this response" from
/// "timestamp is genuinely zero" and fall back to a cached value instead of
/// clobbering it — see the `createdNs` call sites in `put` and
/// `performDownload` (`SyncEngine+Transfer.swift`), which chain
/// `?? cached?.createdNs ?? 0`. That fallback chain is why this stays a
/// separate copy rather than routing through the canonical helper.
///
/// `Date.distantPast` has a `timeIntervalSince1970` of roughly `-6.2e10` which,
/// when multiplied by `1e9`, yields `-6.2e19` — below `Int64.min`. We return
/// `nil` in that case (and symmetrically near `Int64.max`) so callers never see
/// an overflowed value.
///
/// M10a (#466): renamed from `dateToNs` to `dateToNsOrNil` and promoted to
/// `internal` on the family-extension split. The old file-private name would,
/// once cross-file-visible, collide with the module-wide, non-optional
/// `CacheModels.dateToNs(_:) -> Int64` — an ambiguous-overload compile error at
/// call sites outside `SyncEngine` (`CacheReader`, `PauseManager`) that only
/// ever intend the `CacheModels` one. The new name sidesteps that collision.
///
/// The upper-bound check must use `<`, not `<=`: `Double(Int64.max)` rounds
/// *up* to exactly `2^63` (one past `Int64.max`, since `Int64.max` itself isn't
/// exactly representable as a `Double`), so a date whose nanosecond value lands
/// on that rounded boundary would pass an `<=` guard and then trap in
/// `Int64(ns)`. Several call sites feed this remote, attacker-influenced
/// timestamps (DFS `lastModified` / `creationDate`), so the boundary matters.
func dateToNsOrNil(_ date: Date?) -> Int64? {
    guard let d = date else { return nil }
    let ns = d.timeIntervalSince1970 * 1_000_000_000
    guard ns >= Double(Int64.min), ns < Double(Int64.max) else { return nil }
    return Int64(ns)
}
