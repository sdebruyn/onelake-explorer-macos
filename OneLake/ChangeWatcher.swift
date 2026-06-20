// ChangeWatcher.swift
// Triggers Finder re-enumeration when OneLake content changes.
//
// The FPE owns the sync engine and calls NSFileProviderManager.signalEnumerator()
// directly from within the extension process whenever it detects changes.
//
// ChangeWatcher emits a single one-shot "full resync" signal at host-app launch
// so Finder re-enumerates all domains after the host starts (e.g. after a
// login-item boot), covering any changes that accumulated while the host was
// stopped.
//
// Additionally, ChangeWatcher runs two repeating loops:
//
//  Loop A — workspace-set refresh (every workingSetRefreshInterval = 90 s):
//   1. Signals the working set for every registered domain. The FPE's
//      OfemWorkingSetEnumerator.enumerateChanges refreshes the workspace list
//      from Fabric (throttled) and updates the shared SQLite cache.
//   2. Reads the cached workspace set for each registered account and computes a
//      stable signature. When the signature changes (add/remove/rename), the
//      account's File Provider domain is remounted
//      (removeDomain + addDomain with .preserveDownloadedUserData). The remount
//      forces a fresh root enumeration (enumerateItems(.root) / listWorkspaces),
//      which is the only mechanism that introduces new top-level workspaces into
//      the Finder sidebar. Downloaded files are preserved across the remount.
//
//  Loop B — materialized-container poll (every materializedPollInterval = 60 s default):
//   Calls pollMaterialized(alias:) over XPC for each registered account. The FPE
//   reads the materialized_containers table, calls SyncEngine.refreshMaterialized,
//   and returns true when at least one container had a non-zero diff. When any
//   account returns true, the host signals .workingSet on that account's domain so
//   the FPE's OfemWorkingSetEnumerator.enumerateChanges surfaces the new items.
//
//   The poll interval is configurable via TOML [sync] materialized_poll_interval_s
//   (default 60 s, min 30 s, max 600 s). MenuStatusModel propagates changes to
//   materializedPollInterval so the loop cadence updates without restart.
//
//   Testability: the static pollOnce(_:) method is the canonical body of one loop
//   iteration — the timer is a thin wrapper around it. Tests inject mock pollers
//   and signallers to verify the exact set of containers polled and the signal
//   count without a live FPE or NSFileProviderManager.
//
// Launch refresh: to catch workspace changes that accumulated while the host
// was stopped, the first tick compares the cache signature against a baseline
// captured BEFORE the launch working-set signal.  If the cache changed during
// the signal (FPE refreshed from Fabric) the domain is remounted in that first
// tick rather than waiting for the next full interval.
//
// This class is @MainActor because its mutable state (lastWorkspaceSignatures,
// remountInFlight, workingSetRefreshTask) must be accessed on the main actor.
// signalContainer itself calls signalEnumeratorOnce which is not main-thread-bound;
// the @MainActor constraint is on the class, not on the underlying API.
//
// Continuation hardening — resume-once guard:
//   Apple does not guarantee that NSFileProviderManager.signalEnumerator(for:completionHandler:)
//   always calls its completion handler (fileproviderd crash / domain teardown).
//   A plain withCheckedThrowingContinuation would leak the continuation forever.
//   signalEnumeratorOnce delegates to withCallbackOnce, which uses ResumeOnceBox
//   and a post-store Task.isCancelled check to cover all cancellation interleavings
//   (in-flight and pre-cancelled).

@preconcurrency import FileProvider
import Foundation
import OfemKit
import os.log

// MARK: - Testability seams

/// Asks the FPE whether any materialized container changed for an alias.
/// In production: `OfemFPEClient.shared.pollMaterialized(alias:)`.
/// In tests: a mock that records which aliases were polled.
protocol MaterializedPoller: Sendable {
    func pollMaterialized(alias: String) async -> Bool
}

/// Signals a `.workingSet` enumeration change for a domain.
/// In production: calls `signalEnumeratorOnce(manager:container:)`.
/// In tests: a spy that records which domains received signals.
protocol WorkingSetSignaller: Sendable {
    /// Signal `.workingSet` for a resolved domain.
    /// Receiving a pre-resolved `NSFileProviderDomain` avoids a second
    /// `ofemGetAllDomains()` call and eliminates the TOCTOU gap where a
    /// concurrent remount could change the domain set between the poll check
    /// and the signal.
    func signal(domain: NSFileProviderDomain) async
}

// MARK: - Production conformances

extension OfemFPEClient: MaterializedPoller {}

/// Signals `.workingSet` via a live `NSFileProviderManager` for the given domain.
struct LiveWorkingSetSignaller: WorkingSetSignaller, Sendable {
    private static let log = Logger(subsystem: ofemSubsystem, category: "change-watcher")

    func signal(domain: NSFileProviderDomain) async {
        let domainIdentifier = domain.identifier.rawValue
        guard let manager = NSFileProviderManager(for: domain) else {
            Self.log.debug(
                "pollOnce: no manager for domain \(domainIdentifier, privacy: .public)"
            )
            return
        }
        do {
            try await signalEnumeratorOnce(manager: manager, container: .workingSet)
            Self.log.debug(
                "pollOnce: signalled .workingSet for \(domainIdentifier, privacy: .public)"
            )
        } catch {
            Self.log.warning(
                "pollOnce: signalEnumerator failed for \(domainIdentifier, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
        }
    }
}

// MARK: - ResumeOnceBox (resume-once guard)

/// A lock-guarded box that ensures a `CheckedContinuation` is resumed at most
/// once across concurrent callers.
///
/// Both the "work completed" path and the "task cancelled" path call `take()`.
/// `take()` atomically reads and clears the stored continuation, returning it
/// to the caller only when it has not yet been claimed — so exactly one of the
/// two paths ever calls `resume` on the continuation.
///
/// `@unchecked Sendable`: the class is safe to pass across isolation domains
/// because all access to `stored` is protected by `lock`.
final class ResumeOnceBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: CheckedContinuation<Void, Error>?

    /// Stores `cont`. Must be called exactly once before any call to `take()`.
    func store(_ cont: CheckedContinuation<Void, Error>) {
        lock.withLock { stored = cont }
    }

    /// Atomically claims the stored continuation.  Returns the continuation the
    /// first time it is called; returns `nil` on every subsequent call.
    func take() -> CheckedContinuation<Void, Error>? {
        lock.withLock { let c = stored; stored = nil; return c }
    }
}

// MARK: - withCallbackOnce (testable resume-once primitive)

/// Awaits a callback-style operation exactly once, with a resume-once guard
/// and task-cancellation support.
///
/// `work` receives a `deliver` closure that it must call with `nil` for
/// success or an `Error` for failure.  `withCallbackOnce` guarantees that
/// the underlying `CheckedContinuation` is resumed exactly once regardless
/// of the interleaving of `deliver` and task cancellation:
///
/// - **Normal path**: `deliver(nil/error)` claims the continuation via
///   `box.take()` and resumes it. A subsequent `onCancel` call sees `nil`
///   and is a no-op.
/// - **In-flight cancellation**: `onCancel` fires while the continuation is
///   suspended, claims it via `box.take()`, and resumes with
///   `CancellationError`. A subsequent `deliver` call sees `nil` and is a
///   no-op.
/// - **Pre-cancelled task** (the task was already cancelled before entering
///   `withCallbackOnce`): `withTaskCancellationHandler` runs `onCancel`
///   synchronously BEFORE the operation body, so `box.take()` sees `nil`
///   and no-ops. The body then stores the continuation and calls `work`.
///   To cover this interleaving, the body immediately re-checks
///   `Task.isCancelled`; if set, it calls `box.take()` and resumes with
///   `CancellationError` itself — releasing the continuation before
///   `work`'s callback can ever fire.
///
/// This primitive is `internal` (not `private`) so unit tests can exercise
/// the guard logic directly without requiring a real `NSFileProviderManager`.
func withCallbackOnce(
    work: @Sendable @escaping (_ deliver: @escaping @Sendable (Error?) -> Void) -> Void
) async throws {
    let box = ResumeOnceBox()

    try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            box.store(cont)
            // Pre-cancelled-task path: onCancel ran before the continuation
            // was stored, so its box.take() returned nil and was a no-op.
            // Re-check here and self-cancel so the continuation is not left
            // hanging when work's callback never fires.
            if Task.isCancelled {
                box.take()?.resume(throwing: CancellationError())
                return
            }
            work { error in
                guard let c = box.take() else { return }
                if let error { c.resume(throwing: error) } else { c.resume() }
            }
        }
    } onCancel: {
        box.take()?.resume(throwing: CancellationError())
    }
}

// MARK: - signalEnumeratorOnce

/// Calls `manager.signalEnumerator(for:completionHandler:)` with the
/// resume-once guard provided by `withCallbackOnce`.
func signalEnumeratorOnce(
    manager: NSFileProviderManager,
    container: NSFileProviderItemIdentifier
) async throws {
    try await withCallbackOnce { deliver in
        manager.signalEnumerator(for: container) { error in deliver(error) }
    }
}

// MARK: - Workspace set signature helpers (pure, testable)

/// Computes a stable, order-independent signature for a set of workspace
/// cache rows.  Sorts the composed `"\(path)\tname"` strings so both renames
/// and add/removes are detected.
///
/// Exposed as a free function so unit tests can exercise it without touching
/// any network, file system, or FileProvider API.
func workspaceSignature(_ records: [MetadataRecord]) -> String {
    records
        .map { "\($0.path)\t\($0.name)" }
        .sorted()
        .joined(separator: "\n")
}

// MARK: - ChangeWatcher

@MainActor
final class ChangeWatcher {
    static let shared = ChangeWatcher()

    private static let log = Logger(subsystem: ofemSubsystem, category: "change-watcher")

    /// How often the working set is signalled and the workspace-set cache is
    /// checked for changes.
    static let workingSetRefreshInterval: Duration = .seconds(90)

    /// How often the materialized-container poll loop fires.
    /// Defaults to `SyncConfig.defaultMaterializedPollIntervalS` seconds.
    /// Updated by `MenuStatusModel` when the config value is refreshed from the FPE.
    ///
    /// Always enforced to be at least `SyncConfig.minMaterializedPollIntervalS`.
    /// A zero or sub-floor value (e.g. from an older FPE that omits the field)
    /// would cause the loop to busy-spin; this setter prevents that.
    var materializedPollInterval: Duration = .seconds(SyncConfig.defaultMaterializedPollIntervalS) {
        didSet {
            let floor: Duration = .seconds(SyncConfig.minMaterializedPollIntervalS)
            if materializedPollInterval < floor {
                materializedPollInterval = floor
            }
        }
    }

    /// Handle for the periodic working-set + remount-check loop.  Stored so a
    /// second `start()` call can cancel the previous loop before launching a new
    /// one.
    private var workingSetRefreshTask: Task<Void, Never>?

    /// Handle for the periodic materialized-container poll loop.  Stored so a
    /// second `start()` call can cancel the previous loop before launching a new one.
    private var materializedPollTask: Task<Void, Never>?

    /// Last-seen workspace-set signatures, keyed by account alias.
    ///
    /// - A missing entry means "baseline not yet established".
    /// - On the FIRST read for an alias the value is stored as the baseline and
    ///   no remount is performed.
    /// - On subsequent reads a change in signature triggers a remount, after
    ///   which the stored value is updated.
    private var lastWorkspaceSignatures: [String: String] = [:]

    /// Guards against concurrent remounts of the same domain.  Keyed by alias.
    private var remountInFlight: Set<String> = []

    /// Lazily-opened cache reader; reused across ticks to avoid reopening the
    /// SQLite database on every 90-second interval.  `nil` means the CacheStore
    /// could not be opened (catastrophic SQLite failure); callers skip detection
    /// gracefully when this is `nil`.
    private var cacheReader: CacheReader? = nil

    private init() {}

    // MARK: - Lifecycle

    /// Emit a one-shot full-resync signal to all registered domains so
    /// Finder re-enumerates after app launch, then start the periodic
    /// working-set refresh + workspace-change detection loop.
    ///
    /// Safe to call multiple times; each call cancels any previous loop and
    /// starts a fresh one.
    func start() {
        // Capture pre-launch baselines from the cache BEFORE sending the
        // launch working-set signal.  This lets the first tick detect workspace
        // changes that occurred while the host was stopped, without remounting
        // when the cache has not actually changed.
        Task { [weak self] in
            await self?.captureBaselines()
            // One-shot launch resync: signal the working set so the FPE
            // re-checks workspace changes that accumulated while the host
            // was stopped and updates the SQLite cache.
            await self?.signal(container: .workingSet)
        }
        Self.log.info("ChangeWatcher: one-shot launch resync triggered")

        startWorkingSetRefreshLoop()
        startMaterializedPollLoop()
    }

    // MARK: - Periodic working-set refresh + workspace-set detection

    /// Starts (or restarts) the repeating loop.  Cancels any previously running
    /// loop so calling `start()` twice does not stack two concurrent loops.
    private func startWorkingSetRefreshLoop() {
        workingSetRefreshTask?.cancel()
        workingSetRefreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.workingSetRefreshInterval)
                guard !Task.isCancelled else { break }
                // Signal the working set so the FPE's
                // OfemWorkingSetEnumerator.enumerateChanges refreshes the
                // workspace list from Fabric into the SQLite cache (throttled,
                // at most once per 60 s per alias).  The signal completes once
                // the signal has been QUEUED to the FPE — the FPE may not have
                // finished its listWorkspaces call yet.  checkAndRemountChangedDomains
                // therefore reads the PREVIOUS tick's cache (up to 90 s lag),
                // which is acceptable — the lag is bounded by the refresh interval.
                await self?.signal(container: .workingSet)
                // Read the cached workspace set for each account and remount
                // the domain when the signature changed.
                await self?.checkAndRemountChangedDomains()
            }
        }
        Self.log.info(
            "ChangeWatcher: periodic working-set refresh started (interval=\(Self.workingSetRefreshInterval, privacy: .public))"
        )
    }

    // MARK: - Workspace-set change detection + domain remount

    /// Reads the cached workspace set for each registered account.  On the
    /// first call per alias, establishes the baseline signature.  On subsequent
    /// calls, remounts the domain when the signature changes.
    ///
    /// Pruning: entries in `lastWorkspaceSignatures` for aliases that are no
    /// longer present in the account list are removed so that a re-added alias
    /// does not reuse a stale baseline.
    private func checkAndRemountChangedDomains() async {
        let accounts = await SharedOfemAuth.shared.auth.listAccounts()

        // Prune signatures for removed aliases so a re-added alias starts fresh.
        let currentAliases = Set(accounts.map(\.alias))
        for staleAlias in lastWorkspaceSignatures.keys where !currentAliases.contains(staleAlias) {
            lastWorkspaceSignatures.removeValue(forKey: staleAlias)
            Self.log.debug(
                "ChangeWatcher: pruned stale signature for removed alias \(staleAlias, privacy: .public)"
            )
        }

        guard !accounts.isEmpty else { return }

        guard let reader = getOrOpenCacheReader() else { return }

        for account in accounts {
            let alias = account.alias
            guard !remountInFlight.contains(alias) else {
                Self.log.debug(
                    "ChangeWatcher: remount already in flight for \(alias, privacy: .public), skipping"
                )
                continue
            }

            let records: [MetadataRecord]
            do {
                let key = CacheKey(
                    accountAlias: alias,
                    workspaceID: VirtualIDs.workspaceID,
                    itemID: VirtualIDs.workspaceID,
                    path: ""
                )
                records = try await reader.children(of: key)
            } catch {
                Self.log.warning(
                    "ChangeWatcher: could not read workspace cache for \(alias, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
                continue
            }

            let sig = workspaceSignature(records)

            guard let baseline = lastWorkspaceSignatures[alias] else {
                // First observation for this alias — store as baseline, no remount.
                lastWorkspaceSignatures[alias] = sig
                Self.log.debug(
                    "ChangeWatcher: established workspace baseline for \(alias, privacy: .public) (\(records.count, privacy: .public) workspaces)"
                )
                continue
            }

            guard sig != baseline else {
                Self.log.debug(
                    "ChangeWatcher: workspace set unchanged for \(alias, privacy: .public)"
                )
                continue
            }

            // Workspace set changed — remount the domain.
            Self.log.info(
                "ChangeWatcher: workspace set changed for \(alias, privacy: .public) — remounting domain"
            )
            remountInFlight.insert(alias)
            await DomainSyncManager.shared.removeDomain(alias: alias)
            await DomainSyncManager.shared.addDomain(alias: alias)
            remountInFlight.remove(alias)

            // Verify that the domain is actually registered after the remount
            // before updating the stored signature.  removeDomain / addDomain
            // are non-throwing — they catch, log, and return normally on failure.
            // If the add failed the domain is absent from the list; do NOT update
            // the signature so the next tick retries the remount.
            let domainId = DomainSyncManager.shared.domainIdentifier(for: alias)
            let registered: Bool
            do {
                let domains = try await ofemGetAllDomains()
                registered = domains.contains { $0.identifier.rawValue == domainId }
            } catch {
                // Cannot list domains — assume failure; retry next tick.
                Self.log.warning(
                    "ChangeWatcher: could not verify domain registration for \(alias, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
                continue
            }

            guard registered else {
                Self.log.warning(
                    "ChangeWatcher: remount of \(alias, privacy: .public) did not register domain — will retry next tick"
                )
                continue
            }

            // Signature updated only after confirmed-successful remount.
            lastWorkspaceSignatures[alias] = sig
            Self.log.info(
                "ChangeWatcher: remounted domain for \(alias, privacy: .public) (\(records.count, privacy: .public) workspaces)"
            )
        }
    }

    /// Captures baseline signatures for all registered accounts from the
    /// current cache state.  Called before the launch working-set signal so the
    /// first tick can detect changes that occurred while the host was stopped.
    private func captureBaselines() async {
        let accounts = await SharedOfemAuth.shared.auth.listAccounts()
        guard !accounts.isEmpty else { return }

        guard let reader = getOrOpenCacheReader() else { return }

        for account in accounts {
            let alias = account.alias
            guard lastWorkspaceSignatures[alias] == nil else { continue }

            let records: [MetadataRecord]
            do {
                let key = CacheKey(
                    accountAlias: alias,
                    workspaceID: VirtualIDs.workspaceID,
                    itemID: VirtualIDs.workspaceID,
                    path: ""
                )
                records = try await reader.children(of: key)
            } catch {
                Self.log.warning(
                    "ChangeWatcher: captureBaselines failed for \(alias, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
                continue
            }

            lastWorkspaceSignatures[alias] = workspaceSignature(records)
            Self.log.debug(
                "ChangeWatcher: pre-launch baseline for \(alias, privacy: .public): \(records.count, privacy: .public) workspaces"
            )
        }
    }

    /// Returns the shared `CacheReader`, opening it lazily on first use.
    ///
    /// Returns `nil` if the database file does not yet exist or cannot be opened.
    /// Callers must skip detection gracefully in that case.
    ///
    /// Uses `CacheStore.openReadOnly` to open only the DatabasePool in read-only
    /// mode, skipping the orphan-blob sweep that `CacheStore.init` would launch
    /// as a background write task.  The host process is a reader only; the FPE
    /// is the sole writer of the cache database.
    private func getOrOpenCacheReader() -> CacheReader? {
        if let existing = cacheReader { return existing }
        let paths = OfemPaths()
        guard let r = CacheStore.openReadOnly(root: paths.cacheDir) else {
            Self.log.debug("ChangeWatcher: cache not yet available — skipping detection this tick")
            return nil
        }
        cacheReader = r
        return r
    }

    // MARK: - Materialized-container poll loop

    /// Starts (or restarts) the repeating materialized-container poll loop.
    ///
    /// On each tick: calls `pollMaterialized(alias:)` over XPC for every registered
    /// account. When the FPE reports a delta (any container changed), signals
    /// `.workingSet` on that account's domain so the system calls
    /// `enumerateChanges(.workingSet)` and the new items appear in Finder.
    ///
    /// The interval is read from `materializedPollInterval` at the start of each
    /// sleep so a Settings change takes effect on the next tick without restarting
    /// the loop.
    private func startMaterializedPollLoop() {
        materializedPollTask?.cancel()
        materializedPollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                // Enforce floor at the point of use: an absent or legacy-zero
                // field in XPCEngineStatus decodes as 0, which the property setter
                // clamps to the floor, but an explicit sub-floor assignment would
                // cause a busy-spin. This max() is the last line of defense.
                let interval = max(
                    .seconds(SyncConfig.minMaterializedPollIntervalS),
                    self.materializedPollInterval
                )
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled else { break }
                await self.pollMaterializedAndSignal()
            }
        }
        Self.log.info(
            "ChangeWatcher: materialized-container poll loop started (interval=\(self.materializedPollInterval, privacy: .public))"
        )
    }

    /// One poll iteration: ask the FPE whether any materialized container changed
    /// for each registered account; signal `.workingSet` for domains with a delta.
    ///
    /// Delegates to `pollOnce` using the production poller and signaller.
    private func pollMaterializedAndSignal() async {
        let accounts = await SharedOfemAuth.shared.auth.listAccounts()
        guard !accounts.isEmpty else { return }

        let domains: [NSFileProviderDomain]
        do { domains = try await ofemGetAllDomains() } catch {
            Self.log.error(
                "ChangeWatcher: pollMaterializedAndSignal: cannot list domains: \(error.localizedDescription, privacy: .public)"
            )
            return
        }

        // Pre-compute alias → domain identifier map on the @MainActor before
        // entering the nonisolated pollOnce. DomainSyncManager.shared is
        // @MainActor-isolated; the closure passed to pollOnce must be @Sendable,
        // so we capture the pure-value dictionary instead of a live reference.
        let domainMap: [String: String] = Dictionary(
            uniqueKeysWithValues: accounts.map { ($0.alias, DomainSyncManager.shared.domainIdentifier(for: $0.alias)) }
        )

        await Self.pollOnce(
            accounts: accounts,
            domains: domains,
            domainIdentifierFor: { domainMap[$0] ?? "ofem.\($0)" },
            poller: OfemFPEClient.shared,
            signaller: LiveWorkingSetSignaller()
        )
    }

    /// Deterministic testability seam: body of one poll-loop iteration.
    ///
    /// For each account in `accounts`, calls `poller.pollMaterialized(alias:)`.
    /// When the poller returns `true` for an alias, resolves the domain once via
    /// `domains.first(where:)` and passes it directly to `signaller.signal(domain:)`.
    /// Passing the resolved domain avoids a second `ofemGetAllDomains()` round-trip
    /// in the signaller and closes the TOCTOU gap where a concurrent remount could
    /// change the domain set between the poll check and the signal.
    ///
    /// Marked `nonisolated` so tests can call it directly from a non-`@MainActor`
    /// context without wrapping in `MainActor.run`. The method accesses no class
    /// state; all collaborators are passed as parameters.
    ///
    /// - Parameters:
    ///   - accounts:            The accounts to poll this iteration.
    ///   - domains:             All currently registered File Provider domains.
    ///   - domainIdentifierFor: Maps an alias to its OFEM domain identifier string.
    ///   - poller:              Asks the FPE whether any container changed for an alias.
    ///   - signaller:           Signals `.workingSet` for a domain when a delta is found.
    nonisolated static func pollOnce(
        accounts: [Account],
        domains: [NSFileProviderDomain],
        domainIdentifierFor: @Sendable (String) -> String,
        poller: any MaterializedPoller,
        signaller: any WorkingSetSignaller
    ) async {
        let log = Logger(subsystem: ofemSubsystem, category: "change-watcher")
        for account in accounts {
            let alias = account.alias
            let changed = await poller.pollMaterialized(alias: alias)
            guard changed else {
                log.debug("pollOnce: no delta for \(alias, privacy: .public)")
                continue
            }
            let domainId = domainIdentifierFor(alias)
            guard let domain = domains.first(where: { $0.identifier.rawValue == domainId }) else {
                log.warning(
                    "pollOnce: delta for \(alias, privacy: .public) but domain \(domainId, privacy: .public) not found — skipping signal"
                )
                continue
            }
            log.info("pollOnce: delta for \(alias, privacy: .public) — signalling .workingSet")
            await signaller.signal(domain: domain)
        }
    }

    // MARK: - Signaling

    /// Signals `container` for every currently registered domain.
    private func signal(container: NSFileProviderItemIdentifier) async {
        let containerId = container.rawValue
        do {
            let domains = try await ofemGetAllDomains()
            for domain in domains {
                await signalContainer(domain: domain, containerId: containerId)
            }
            Self.log.info(
                "ChangeWatcher: resync signal sent to \(domains.count, privacy: .public) domain(s)"
            )
        } catch {
            Self.log.error(
                "ChangeWatcher: could not list domains for resync: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    private func signalContainer(domain: NSFileProviderDomain, containerId: String) async {
        let domainId = domain.identifier.rawValue
        let itemIdentifier = NSFileProviderItemIdentifier(rawValue: containerId)

        // Use the real domain object (not a re-fabricated one with an empty
        // displayName) so that NSFileProviderManager(for:) receives the
        // same domain that macOS registered.
        guard let manager = NSFileProviderManager(for: domain) else {
            Self.log.debug(
                "ChangeWatcher: no manager for domain \(domainId, privacy: .public); domain may not be registered yet"
            )
            return
        }

        do {
            try await signalEnumeratorOnce(manager: manager, container: itemIdentifier)
            Self.log.debug(
                "ChangeWatcher: signalled \(domainId, privacy: .public)/\(containerId, privacy: .public)"
            )
        } catch {
            // Non-fatal: Finder's own periodic refresh will catch up.
            Self.log.warning(
                "ChangeWatcher: signalEnumerator failed for \(domainId, privacy: .public)/\(containerId, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
        }
    }
}
