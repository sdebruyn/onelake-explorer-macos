import CryptoKit
import Foundation
import os.log

// MARK: - SyncEngine

/// The top-level sync coordinator.
///
/// `SyncEngine` wires `OfemAuth`, `CacheStore`, `OneLakeClientProtocol`,
/// `FabricClientProtocol`, `TelemetryClient`, and `OfemLogger` into the core
/// OFEM file-system operations: enumerate, open, put, delete, mkdir, and
/// workspace / item discovery.
///
/// ## Design notes
///
/// - `SyncEngine` is a Swift `actor` so all mutable state (the per-account
/// download / upload semaphore tables, in-flight download map) is automatically
/// serialised.
/// - Network-heavy methods (`open`, `put`) release the actor while the network
/// call is in flight so other tasks are not blocked (Swift structured
/// concurrency: `async` automatically suspends the caller).
/// - Blocking filesystem I/O (spill-file create/seek/hash) is dispatched via
/// `Task.detached` to a background executor and never runs on the actor's
/// thread (sync-14).
/// - Concurrency caps are enforced per account alias via `AsyncSemaphore`.
/// - Last-write-wins semantics: `put` and `delete` never use `If-Match` for
/// writes. This matches the agreed conflict policy in `docs/auth.md`.
public actor SyncEngine {
    // MARK: - Configuration

    /// Default per-account cap on concurrent downloads.
    public static let defaultMaxConcurrentDownloads = 8

    /// Default per-account cap on concurrent uploads.
    public static let defaultMaxConcurrentUploads = 4

    /// Default minimum gap between workspace-recovery probes (mirrors
    /// `PauseManager.defaultProbeInterval` so `SyncEngine.init` can expose it
    /// in a public default-argument without leaking the internal `PauseManager`
    /// type into the public API).
    public static let defaultPauseProbeInterval: Duration = .seconds(120)

    /// Default self-heal floor for ``refreshMaterialized`` (#380): force a
    /// non-gated full re-list of each container at least this often as insurance
    /// against the empirical "directory etag advances on any descendant write"
    /// invariant. PR B wires this to a configurable advanced setting
    /// (10–60 min, disableable); PR A uses this default and a `0 ⇒ disabled`
    /// parameter so the behaviour is testable in isolation.
    public static let defaultSelfHealIntervalMinutes = 30

    /// Default freshness window for ``open(key:)``'s cache-hit path: a row
    /// synced within this long ago is served without a `getProperties` HEAD.
    /// Aligned with `ChangeWatcher`'s default `materializedPollInterval`
    /// (60 s): `syncedAtNs` is stamped fresh by the initial download and by
    /// any subsequent `refreshFolder` pass that observes an actual change for
    /// this row (an unchanged row's `syncedAtNs` is deliberately left alone —
    /// see `refreshFolder`'s upsert-batch comment). So the window mainly
    /// covers the common burst case — Quick Look, a re-open shortly after a
    /// download or a poll-observed change — not an indefinitely-refreshed
    /// guarantee; a stable file still re-validates with a real HEAD roughly
    /// once per window. `.zero` disables the fast path (always HEAD, today's
    /// behaviour).
    public static let defaultBlobFreshnessTTL: Duration = .seconds(60)

    // MARK: - Dependencies (internal — callers should still go through SyncEngine API)

    //
    // sync-19: these were `nonisolated let` with default (internal) access,
    // letting any OfemKit code bypass the actor's pause/semaphore/telemetry
    // invariants by calling the clients directly. Made `private` now;
    // `nonisolated` is still required for wiring in init (which runs before
    // the actor is fully initialised).
    //
    // M10a (#466): promoted back to `internal` ahead of splitting this file
    // into `SyncEngine+*.swift` family extensions, which need to reference
    // this state from other files. The sync-19 guidance still holds as a
    // convention — callers outside `SyncEngine`'s own extensions should go
    // through its API, not this state directly.

    nonisolated let cache: CacheStore
    nonisolated let onelake: any OneLakeClientProtocol
    nonisolated let fabric: any FabricClientProtocol

    let logger: OfemLogger
    let telemetry: TelemetryClient?

    // MARK: - Internal state

    let pauseManager: PauseManager
    let offlineTracker: OfflineTracker
    let partials: PartialManager

    /// Per-account semaphores for downloads, uploads, and materialized-set refreshes.
    ///
    /// Entries are allocated lazily on first use per alias. Growth is bounded
    /// by the number of distinct account aliases active in this process
    /// (typically 1-3) so the unbounded-map concern is negligible in practice.
    /// A future `forgetAccount(alias:)` hook can prune entries on sign-out
    /// (sync-16).
    var downloadSlots: [String: AsyncSemaphore] = [:]
    var uploadSlots: [String: AsyncSemaphore] = [:]
    var refreshSlots: [String: AsyncSemaphore] = [:]
    let maxDownloads: Int
    let maxUploads: Int

    /// In-flight download tasks keyed by ``CacheKey/stableKeyString``.
    ///
    /// A second `open()` for the same key awaits the first's task rather than
    /// spawning a duplicate download. The map entry is removed when the task
    /// VALUE is delivered (not when the spawning frame unwinds) so a second
    /// caller that arrives while the task is still running always finds the
    /// entry (sync-24 fix).
    var inFlightDownloads: [String: Task<OpenResult, any Error>] = [:]

    /// Generation counter per key — incremented each time a new download task is
    /// spawned for a key. Used to guard against a stale cleanup (from a previous,
    /// now-cancelled task) removing an entry that belongs to a newer task.
    var downloadGenerations: [String: UInt64] = [:]

    /// Per-container timestamp (Unix nanoseconds) of the last self-heal forced
    /// full re-list in ``refreshMaterialized`` (#380). Keyed by
    /// ``CacheKey/stableKeyString``. Absent ⇒ never self-healed yet ⇒ the first
    /// poll forces a list and records the timestamp, so steady-state self-heals
    /// land roughly one interval apart rather than all firing on poll 1.
    var lastSelfHealNs: [String: Int64] = [:]

    /// Injectable time source (Unix nanoseconds) used by the self-heal floor so
    /// tests can drive elapsed time deterministically instead of sleeping on the
    /// wall clock. Defaults to the real clock.
    nonisolated let nowNsProvider: @Sendable () -> Int64

    /// ``defaultBlobFreshnessTTL`` (or the constructor-supplied override) used
    /// to gate ``open(key:)``'s freshness HEAD. Converted to nanoseconds
    /// inline where compared, mirroring how ``refreshMaterialized`` derives
    /// its self-heal threshold from `selfHealIntervalMinutes`.
    nonisolated let blobFreshnessTTL: Duration

    /// Account aliases with a ``refreshMaterialized`` pass currently in flight
    /// (#380). The production caller `pollMaterialized` spawns an unstructured
    /// `Task` per XPC poll with no cross-pass mutual exclusion, and the
    /// per-alias semaphore only caps concurrency *within* a pass — so two
    /// overlapping same-alias passes could interleave across the `cache.fetch`
    /// suspension points and break the "a parent vouched THIS pass" guarantee.
    /// A second pass for an alias already in flight returns early: the in-flight
    /// pass already covers this poll's freshness.
    var refreshInFlightAliases: Set<String> = []

    /// Minimum gap between Fabric item-listing refreshes for a single
    /// materialized workspace container (F6/C16). A workspace container is
    /// depth-0 with no subtree etag, so the #380 skip-gate can never elide it;
    /// without this throttle ``refreshMaterialized`` would issue one Fabric REST
    /// call per materialized workspace on every poll. 60 s mirrors the host
    /// working-set poll cadence (`OfemWorkingSetEnumerator.workspaceRefreshInterval`).
    static let itemListThrottleNs: Int64 = 60 * 1_000_000_000

    /// Unix-nanosecond timestamp of the last SUCCESSFUL Fabric item-listing
    /// refresh per `(alias, workspaceID)`, gating ``refreshItemListing`` by
    /// ``itemListThrottleNs``. Keyed by ``itemListKey(alias:workspaceID:)``.
    /// Stamped only after a successful list so a thrown attempt stays due.
    var lastItemListNs: [String: Int64] = [:]

    /// `(alias, workspaceID)` pairs with a ``refreshItemListing`` in flight, so
    /// overlapping poll-path refreshes for the same workspace coalesce instead
    /// of each reading pre-upsert discovery state and double-writing. Mirrors
    /// ``refreshInFlightAliases``. Keyed by ``itemListKey(alias:workspaceID:)``.
    var itemListInFlight: Set<String> = []

    /// Minimum gap between tombstone TTL purges for a single account alias.
    /// `refreshMaterialized` is the throttle host (the poll tick already fires
    /// ~every 60 s per alias), so the purge rides that cadence at most once per
    /// day instead of adding its own loop. 24 h is far tighter than the 30-day
    /// tombstone TTL, so the purge horizon never lags materially behind the TTL.
    static let tombstonePurgeThrottleNs: Int64 = 24 * 60 * 60 * 1_000_000_000

    /// Unix-nanosecond timestamp of the last SUCCESSFUL tombstone purge per
    /// account alias, gating ``purgeExpiredTombstonesThrottled(alias:)`` by
    /// ``tombstonePurgeThrottleNs``. Stamped only after a successful purge so a
    /// thrown attempt (e.g. a transient SQLite error) stays due next poll —
    /// mirrors the stamp-after-success policy of ``lastItemListNs`` /
    /// ``lastSelfHealNs``.
    var lastTombstonePurgeNs: [String: Int64] = [:]

    static let log = Logger(subsystem: "dev.debruyn.ofem", category: "SyncEngine")

    // MARK: - Init

    /// Creates a `SyncEngine`.
    ///
    /// - Parameters:
    /// - cache: Metadata + blob cache (required).
    /// - onelake: DFS HTTP client (required).
    /// - fabric: Fabric REST client (required).
    /// - logger: Structured logger.
    /// - telemetry: Optional telemetry sink.
    /// - maxConcurrentDownloads: Per-account download cap.
    /// - maxConcurrentUploads: Per-account upload cap.
    /// - scratchBase: Directory for download spill files. Defaults to
    /// `<tmp>/ofem-download-partials/<pid>`.
    /// - pauseProbeInterval: Minimum gap between workspace-recovery probes.
    /// - blobFreshnessTTL: Minimum row age below which ``open(key:)`` trusts a
    ///   cached blob without a `getProperties` HEAD. `.zero` always
    ///   HEADs (today's behaviour); tests that want to force a HEAD on every
    ///   open pass `.zero` explicitly.
    /// - nowNsProvider: Injectable Unix-nanosecond clock for the #380 self-heal
    ///   floor. Defaults to the real wall clock; tests pass a controllable
    ///   source to drive elapsed time deterministically.
    public init(
        cache: CacheStore,
        onelake: any OneLakeClientProtocol,
        fabric: any FabricClientProtocol,
        logger: OfemLogger = OfemLogger(),
        telemetry: TelemetryClient? = nil,
        maxConcurrentDownloads: Int = SyncEngine.defaultMaxConcurrentDownloads,
        maxConcurrentUploads: Int = SyncEngine.defaultMaxConcurrentUploads,
        scratchBase: URL? = nil,
        pauseProbeInterval: Duration = SyncEngine.defaultPauseProbeInterval,
        blobFreshnessTTL: Duration = SyncEngine.defaultBlobFreshnessTTL,
        nowNsProvider: (@Sendable () -> Int64)? = nil
    ) {
        self.cache = cache
        // Resolve the default inside the init body: the default-argument
        // expression is evaluated in the caller's scope, where the private
        // global `currentNowNs()` is not visible. `nil` ⇒ real wall clock.
        self.nowNsProvider = nowNsProvider ?? { currentNowNs() }
        self.blobFreshnessTTL = blobFreshnessTTL
        self.onelake = onelake
        self.fabric = fabric
        self.logger = logger
        self.telemetry = telemetry
        self.maxDownloads = max(1, maxConcurrentDownloads)
        self.maxUploads = max(1, maxConcurrentUploads)

        // Scratch dir: per-process sub-directory.
        let base: URL = if let sb = scratchBase {
            sb
        } else {
            URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent(PartialManager.partialsDirName)
        }
        let pid = ProcessInfo.processInfo.processIdentifier
        let scratchDir = base.appendingPathComponent("\(pid)")
        self.partials = PartialManager(scratchDir: scratchDir)

        // Defer the stale-partial reap to a background task so SyncEngine.init
        // (called from OfemEngine's @MainActor init) never performs synchronous
        // FileManager traversal or kill(2) probes on the main thread.
        Task.detached(priority: .utility) {
            PartialManager.reapStalePartialDirs(under: base)
        }

        self.pauseManager = PauseManager(cache: cache, onelake: onelake, probeInterval: pauseProbeInterval)
        self.offlineTracker = OfflineTracker()
    }

    // MARK: - Delete

    /// Removes a file or directory from OneLake and the local cache.
    ///
    /// macOS metadata files are dropped from the local cache only (no remote
    /// call, no telemetry).
    public func delete(key: CacheKey) async throws {
        let start = Date()

        // sync-05: surface cache read error — treating a DB failure as
        // `isDir = false` risks choosing non-recursive delete on a populated
        // directory, causing a 409. Log but continue with the safe assumption.
        let cached: MetadataRecord?
        do {
            cached = try await cache.fetch(key: key)
        } catch {
            Self.log.warning("delete: cache read failed, assuming isDir=false err=\(error, privacy: .public)")
            cached = nil
        }
        let isDir = cached?.isDir ?? false
        let eventName = isDir ? "folder_delete" : "file_delete"

        if isMacOSMetadata(key.path) {
            do { try await cache.delete(key: key) } catch {
                Self.log.warning("delete: macOS metadata cache delete failed err=\(error, privacy: .public)")
            }
            return
        }

        try await pauseManager.guardPaused(workspaceID: key.workspaceID, alias: key.accountAlias)

        // When cache has no row we cannot tell file from directory; ask DFS to
        // recurse to avoid 409 on a populated directory.
        let recursive = isDir || cached == nil

        do {
            try await onelake.delete(
                alias: key.accountAlias,
                workspaceGUID: key.workspaceID,
                itemGUID: key.itemID,
                path: key.path,
                recursive: recursive
            )
        } catch OneLakeError.notFound {
            // DELETE is in SessionPool's retryable HTTP methods, and the
            // `idempotent` flag Alamofire exposes is a documented no-op. If the
            // delete already committed server-side but its ack was lost, the
            // replayed DELETE 404s. The row is gone either way — that is the
            // goal of this call — so treat it as success rather than surfacing
            // `delete_failed`, mirroring the `destinationExists` guard for a
            // replayed rename PUT below.
            Self.log.info("delete: remote 404 — already gone, treating as success")
        } catch {
            try await withRemoteOperationError(
                error: error, key: key, eventName: eventName,
                failCode: "delete_failed", start: start
            )
        }
        await offlineTracker.observe(nil)

        do { try await cache.delete(key: key) } catch {
            Self.log.warning("delete: cache delete failed err=\(error, privacy: .public)")
        }

        await track(eventName: eventName, alias: key.accountAlias, start: start, outcome: .success())
    }

    // MARK: - Mkdir

    /// Creates a directory on OneLake and upserts the matching cache row.
    public func mkdir(key: CacheKey) async throws {
        let start = Date()
        try await pauseManager.guardPaused(workspaceID: key.workspaceID, alias: key.accountAlias)

        do {
            try await onelake.createDirectory(
                alias: key.accountAlias,
                workspaceGUID: key.workspaceID,
                itemGUID: key.itemID,
                path: key.path
            )
        } catch {
            try await withRemoteOperationError(
                error: error, key: key, eventName: "folder_create",
                failCode: "mkdir_failed", start: start
            )
        }
        await offlineTracker.observe(nil)

        let nowNs = currentNowNs()
        // Carry the item type from the parent directory row so that a newly
        // created folder under a Lakehouse Files/ subtree keeps writable
        // capabilities without waiting for the next refreshFolder (fp-05).
        let mkdirItemType = await resolveItemType(for: key)
        let row = MetadataRecord(
            accountAlias: key.accountAlias,
            workspaceID: key.workspaceID,
            itemID: key.itemID,
            path: key.path,
            parentPath: Enumerator.parentPath(key.path),
            name: Enumerator.baseName(key.path),
            isDir: true,
            lastAccessedNs: nowNs,
            syncedAtNs: nowNs,
            itemType: mkdirItemType
        )
        do { try await cache.upsert(row) } catch {
            Self.log.warning("mkdir: upsert failed err=\(error, privacy: .public)")
        }

        await track(eventName: "folder_create", alias: key.accountAlias, start: start, outcome: .success())
    }

    // MARK: - Rename

    /// Renames a file or directory within the same parent directory on OneLake
    /// and re-keys the matching cache row (and any cached descendants).
    ///
    /// Move/reparent (changing `.parentItemIdentifier`) is out of scope: only
    /// same-directory renames where the parent directory is unchanged are handled
    /// here. The caller is responsible for ensuring `newName` does not contain
    /// a path separator.
    ///
    /// - Parameters:
    ///   - key: The current ``CacheKey`` of the item to rename.
    ///   - newName: The new leaf name (final path segment, no `"/"`).
    /// - Returns: The updated ``MetadataRecord`` under the new path so the FPE
    ///   can build a fresh ``OfemFPEItem`` without an additional cache lookup.
    public func rename(key: CacheKey, newName: String) async throws -> MetadataRecord {
        let start = Date()
        try await pauseManager.guardPaused(workspaceID: key.workspaceID, alias: key.accountAlias)

        // Compute the destination path: same parent directory, new leaf name.
        let parentDir = Enumerator.parentPath(key.path)
        let destinationPath = parentDir.isEmpty ? newName : "\(parentDir)/\(newName)"

        do {
            try await onelake.rename(
                alias: key.accountAlias,
                workspaceGUID: key.workspaceID,
                itemGUID: key.itemID,
                sourcePath: key.path,
                destinationPath: destinationPath
            )
        } catch let error as OneLakeError {
            // Rename is non-idempotent, but the session retrier retries the PUT
            // on transient failures. If a retry runs after the rename already
            // committed server-side, the source path is gone → `notFound`,
            // surfaced as a spurious failure on an operation that succeeded.
            // Conservatively swallow `notFound` (and only `notFound`) when the
            // destination is now present, confirming the rename did commit, and
            // proceed to the cache re-key. Any other error propagates as before.
            if case .notFound = error,
               await destinationExists(
                   alias: key.accountAlias,
                   workspaceID: key.workspaceID,
                   itemID: key.itemID,
                   destinationPath: destinationPath
               )
            {
                Self.log.info("rename: source gone but destination present — treating retried rename as already committed")
            } else {
                try await withRemoteOperationError(
                    error: error, key: key, eventName: "item_rename",
                    failCode: "rename_failed", start: start
                )
            }
        } catch {
            try await withRemoteOperationError(
                error: error, key: key, eventName: "item_rename",
                failCode: "rename_failed", start: start
            )
        }
        await offlineTracker.observe(nil)

        // Read the existing row up front so we can both (a) carry forward fields
        // (created/modified dates, size, type) into the synthesised fallback and
        // (b) write a tombstone for the OLD identifier after the re-key succeeds.
        let existing = try? await cache.fetch(key: key)

        // Re-key the cache: update the exact row and all descendants atomically.
        // A cache failure must NOT be swallowed — reporting rename success while
        // the cache still holds the old key would make the old name reappear on
        // the next enumeration (cache/server divergence with no retry). Let it
        // propagate so the FPE leaves `.filename` pending and the framework
        // retries.
        let renamed = try await cache.renamePathPrefix(
            accountAlias: key.accountAlias,
            workspaceID: key.workspaceID,
            itemID: key.itemID,
            oldPath: key.path,
            newPath: destinationPath,
            newName: newName
        )

        // Tombstone the OLD identifier so other enumerators (working-set poll,
        // a re-opened materialized container) retire the row under the old name
        // via itemsChangedAfter → enumerateChanges → didDeleteItems, mirroring
        // `delete`. Written only after the new-path row is committed above.
        try? await cache.recordDeletion(
            accountAlias: key.accountAlias,
            identifierString: ItemIdentifier
                .path(workspaceID: key.workspaceID, itemID: key.itemID, path: key.path)
                .identifierString
        )

        // Prefer the row read back inside the rename transaction; fall back to a
        // synthesised record only when no row existed at the old path to rename.
        let updatedRecord: MetadataRecord
        if let renamed {
            updatedRecord = renamed
        } else {
            // Best-effort: build from the old key's cached data, carrying
            // created/modified dates forward so Finder does not regress to the
            // 1970 epoch (ab283ce).
            let nowNs = currentNowNs()
            updatedRecord = MetadataRecord(
                accountAlias: key.accountAlias,
                workspaceID: key.workspaceID,
                itemID: key.itemID,
                path: destinationPath,
                parentPath: parentDir,
                name: newName,
                isDir: existing?.isDir ?? false,
                contentLength: existing?.contentLength ?? 0,
                etag: existing?.etag ?? "",
                lastModifiedNs: existing?.lastModifiedNs ?? 0,
                contentType: existing?.contentType ?? "",
                lastAccessedNs: nowNs,
                syncedAtNs: nowNs,
                itemType: existing?.itemType ?? "",
                createdNs: existing?.createdNs ?? 0
            )
        }

        await track(eventName: "item_rename", alias: key.accountAlias, start: start, outcome: .success())
        return updatedRecord
    }

    /// Returns `true` when the rename destination is confirmed to exist, used to
    /// recognise an already-committed (retried) rename whose source has vanished.
    ///
    /// Checks the cache first (cheap, no network); only when the row is absent
    /// does it issue a single HEAD (`getProperties`). Any probe error is treated
    /// as "not present" so a transient network blip cannot make a genuinely
    /// failed rename look successful.
    private func destinationExists(
        alias: String,
        workspaceID: String,
        itemID: String,
        destinationPath: String
    ) async -> Bool {
        let newKey = CacheKey(
            accountAlias: alias,
            workspaceID: workspaceID,
            itemID: itemID,
            path: destinationPath
        )
        if (try? await cache.fetch(key: newKey)) != nil {
            return true
        }
        do {
            _ = try await onelake.getProperties(
                alias: alias,
                workspaceGUID: workspaceID,
                itemGUID: itemID,
                path: destinationPath
            )
            return true
        } catch {
            return false
        }
    }

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
/// clobbering it — see the `createdNs` call sites above, which chain
/// `?? cached?.createdNs ?? 0`. That fallback chain is why this stays a
/// separate copy rather than routing through the canonical helper.
///
/// `Date.distantPast` has a `timeIntervalSince1970` of roughly `-6.2e10` which,
/// when multiplied by `1e9`, yields `-6.2e19` — below `Int64.min`. We return
/// `nil` in that case (and symmetrically near `Int64.max`) so callers never see
/// an overflowed value.
///
/// M10a (#466): renamed from `dateToNs` to `dateToNsOrNil` and promoted to
/// `internal`, ahead of the upcoming family-extension split. The old
/// file-private name would, once cross-file-visible, collide with the
/// module-wide, non-optional `CacheModels.dateToNs(_:) -> Int64` — an
/// ambiguous-overload compile error at call sites outside `SyncEngine`
/// (`CacheReader`, `PauseManager`) that only ever intend the `CacheModels`
/// one. The new name sidesteps that collision.
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
