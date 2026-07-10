// MenuStatusModel.swift
// Observable model that fetches account list + engine status
// and publishes the results for the menu-bar dropdown.
//
// CoreBridge has been removed entirely. All state now comes
// from two sources:
//   1. SharedOfemAuth (reads config.toml in-process) — accounts, default.
//   2. OfemFPEClient.getEngineStatus(alias:) over XPC — cache stats, config
//      fields (telemetry, cache limit, net concurrency, log level).
//
// The "daemon version" field is gone; the app version is surfaced instead
// via BuildInfo in SettingsView's Advanced tab.
//
// Write actions (setTelemetry, setCacheLimitGB, setNetMaxUploads,
// setNetMaxDownloads, setLogLevel, cacheClear) go through
// OfemFPEClient so the FPE's in-memory OfemConfigStore is updated
// atomically and persisted to config.toml without any daemon round-trip.
//
// Action methods always call refresh() on completion so the menu
// reflects the new state immediately.
// setCacheLimitGB / setNetMaxUploads / setNetMaxDownloads debounce their
// XPC write (see setCacheLimitDebounce / setNetConcurrencyDebounce) so
// a held-down Stepper does not flood the FPE.
//
// Dependencies injected via protocols (host-13) so tests can verify
// refresh, fence, and action logic without a live FPE/config stack.

import AppKit
@preconcurrency import FileProvider
import Foundation
import OfemKit
import os.log

// MARK: - MenuIconState

/// The three icon states the menu-bar label can represent.
/// Used by both the icon view (OneLakeApp) and tests that verify the model logic.
enum MenuIconState {
    /// FPE is reachable and no workspaces are paused.
    case normal
    /// No accounts registered yet (fresh install / all accounts removed).
    case notRunning
    /// One or more Fabric capacity workspaces are paused.
    case paused
}

// MARK: - Dependency protocols

/// Provides the account list and default account.
/// Implemented by OfemAuth (via extension in OfemFPEClient.swift conformances);
/// faked in tests.
protocol AccountProvider: Sendable {
    /// Returns all known accounts. Returns an empty array if the store is empty.
    func listAccounts() async -> [Account]
    /// Returns the alias of the default account, or nil if none is set.
    func defaultAccount() async -> String?
    func setDefaultAccount(alias: String) async throws
    func removeAccount(alias: String) async throws
}

/// Provides engine status and config writes over XPC.
/// Implemented by OfemFPEClient; faked in tests.
protocol EngineStatusProvider: Sendable {
    func getEngineStatus(alias: String) async throws -> XPCEngineStatus
    /// Slim badge-only status: `needsSignIn` + `pausedWorkspaces`, skipping
    /// the FPE's blobBytes() cache scan and config snapshot that
    /// `getEngineStatus` always pays for. See `OfemFPEClient.getBadgeStatus(alias:)` (#397).
    func getBadgeStatus(alias: String) async throws -> XPCBadgeStatus
    func setConfig(alias: String, key: String, value: String) async throws
    func clearCache(alias: String) async throws -> Int64
    /// Reloads the FPE's engine for `alias` (e.g. after re-authentication).
    /// See `OfemFPEClient.reloadEngine(alias:)` (xpc-11).
    func reloadEngine(alias: String) async throws
}

/// Provides interactive re-authentication for an existing account.
/// Implemented by SharedOfemAuth; faked in tests.
/// The provider must run the same two sequential interactive flows as the
/// first-sign-in path (OneLake storage + Fabric Power BI) so both token
/// audiences are refreshed in the shared App Group Keychain.
protocol ReSignInProvider: Sendable {
    func reSignIn(alias: String, window: NSWindow) async throws
}

/// Provides domain management (add/remove).
/// Implemented by DomainSyncManager; faked in tests.
protocol DomainManager: Sendable {
    func removeDomain(alias: String) async
}

// MARK: - Production conformances

extension OfemAuth: AccountProvider {}

extension OfemFPEClient: EngineStatusProvider {}

extension DomainSyncManager: DomainManager {}

extension SharedOfemAuth: ReSignInProvider {}

// `EngineStatusProvider: Sendable` and `DomainManager: Sendable` require their
// conforming types to be `Sendable`. Both `OfemFPEClient` and `DomainSyncManager`
// are `@MainActor final class`, which is already `Sendable` — the actor
// isolation confines all state, so no explicit `@unchecked Sendable`
// conformance is needed here.

// MARK: - MenuStatusModel

/// Published state for the menu-bar dropdown.
/// All mutations happen on the main actor; no locking needed.
///
/// Owned as a singleton at the App level so both the MenuBarExtra label
/// (icon state) and the menu content read from the same instance. Using a
/// class-level `shared` rather than SwiftUI DI keeps the lifetime explicit
/// and avoids the `@EnvironmentObject` / optional-unwrap dance across scenes.
@MainActor
final class MenuStatusModel: ObservableObject {
    /// Single shared instance. Owned (via @StateObject) by OneLakeApp so it
    /// lives for the full process lifetime. MenuBarView receives it as an
    /// @ObservedObject — it observes but does not own.
    ///
    /// Initialised lazily on the main actor: `@MainActor` static stored
    /// properties are guaranteed by Swift to be initialised on the main actor,
    /// so `MenuStatusModel()` runs on the main actor and can safely touch
    /// `@Published` stored properties.
    @MainActor
    static let shared = MenuStatusModel()

    private static let log = Logger(subsystem: ofemSubsystem, category: "menu-status")

    // MARK: Dependencies

    private let accountProvider: any AccountProvider
    private let engineStatusProvider: any EngineStatusProvider
    private let domainManager: any DomainManager
    private let reSignInProvider: any ReSignInProvider

    // MARK: Init

    /// Production init wires to shared singletons.
    /// Provide non-nil values in tests to inject fakes.
    ///
    /// - Parameter secondaryAccountCheckInterval: Minimum wall-clock gap
    ///   between two needsSignIn sweeps over accounts 2..N (see the
    ///   throttle in doRefresh()). Overridable so tests can exercise both
    ///   the "still within the window" and "window elapsed" branches
    ///   without waiting out the 30 s production default.
    init(
        accountProvider: (any AccountProvider)? = nil,
        engineStatusProvider: (any EngineStatusProvider)? = nil,
        domainManager: (any DomainManager)? = nil,
        reSignInProvider: (any ReSignInProvider)? = nil,
        secondaryAccountCheckInterval: Duration = .seconds(30)
    ) {
        self.accountProvider = accountProvider ?? SharedOfemAuth.shared.auth
        self.engineStatusProvider = engineStatusProvider ?? OfemFPEClient.shared
        self.domainManager = domainManager ?? DomainSyncManager.shared
        self.reSignInProvider = reSignInProvider ?? SharedOfemAuth.shared
        self.secondaryAccountCheckInterval = secondaryAccountCheckInterval
    }

    // MARK: Published

    @Published private(set) var cacheBytes: Int64 = -1
    @Published private(set) var cacheMaxBytes: Int64 = 0
    /// User-editable LRU ceiling in whole gigabytes; the menubar Stepper
    /// reads and writes this. Mirrors `cacheMaxBytes` (the byte-level
    /// counterpart used for the live used/limit math) but kept in GBs
    /// so the Stepper round-trips cleanly without losing precision.
    /// 0 means "unknown / not yet fetched"; once populated stays in [1, 100].
    @Published private(set) var cacheMaxSizeGB: Int = 0
    @Published private(set) var pausedWorkspaces: [PausedWorkspaceInfo] = []
    @Published private(set) var accounts: [AccountInfo] = []
    @Published private(set) var defaultAccount: String = ""
    @Published private(set) var telemetryEnabled: Bool = true
    /// Aliases for accounts whose token can no longer be acquired silently.
    /// Each entry is the account alias. Empty when all accounts are healthy.
    @Published private(set) var accountsNeedingSignIn: Set<String> = []

    /// Max parallel uploads per account (Settings → Network).
    @Published private(set) var netMaxUploads: Int = 0
    /// Max parallel downloads per account (Settings → Network).
    @Published private(set) var netMaxDownloads: Int = 0
    /// FPE log level (Settings → Advanced). One of "debug", "info", "warn", "error".
    @Published private(set) var logLevel: String = ""

    /// Materialized-container poll interval in seconds (Settings → Advanced).
    /// 0 means "not yet fetched"; once populated stays in [30, 600].
    @Published private(set) var materializedPollIntervalS: Int = 0

    /// Self-heal full-refresh interval in minutes (Settings → Advanced).
    /// 0 means "not yet fetched or disabled". Once populated stays in [10, 60]
    /// (enabled) or 0 (disabled).
    @Published private(set) var selfHealIntervalM: Int = 0

    /// True once at least one successful `getEngineStatus` reply has been
    /// applied to this model. Settings rows that can legitimately hold the
    /// disabled-sentinel value (e.g. `selfHealIntervalM == 0`) should gate
    /// their "loaded" state on this flag rather than on a sibling field's
    /// non-zero value, to avoid invisible coupling between unrelated knobs.
    @Published private(set) var engineStatusReceived: Bool = false

    /// Last action error for display to the user. nil if the last action succeeded.
    /// Set by destructive actions (removeAccount, cacheClear, setDefaultAccount)
    /// when they fail so the UI can surface a non-intrusive inline message.
    @Published private(set) var lastActionError: String? = nil

    // MARK: Computed conveniences

    var pausedCount: Int {
        pausedWorkspaces.count
    }

    /// True when at least one account is registered.
    var hasAccounts: Bool {
        !accounts.isEmpty
    }

    /// Icon state for the menu-bar label. Priority: not-running > paused > normal.
    /// Auth errors (`accountsNeedingSignIn` non-empty) are surfaced in the
    /// header label and per-account submenu rather than changing the icon state.
    var menuIconState: MenuIconState {
        if accounts.isEmpty { return .notRunning }
        if pausedCount > 0 { return .paused }
        return .normal
    }

    /// Returns true when the given account alias requires interactive sign-in.
    func accountNeedsSignIn(alias: String) -> Bool {
        accountsNeedingSignIn.contains(alias)
    }

    /// Returns the per-account status label for display in the account submenu.
    ///
    /// When the account needs sign-in the label reflects the auth-error state
    /// ("Sign-in required") so the submenu header conveys the problem even before
    /// the user reads the warning row. A healthy account shows "Running".
    func accountStatusLabel(alias: String) -> String {
        accountNeedsSignIn(alias: alias) ? "Sign-in required" : "Running"
    }

    var headerLabel: String {
        guard hasAccounts else { return "○ Not running" }

        let signInFragment: String?
        if !accountsNeedingSignIn.isEmpty {
            let count = accountsNeedingSignIn.count
            let noun = count == 1 ? "account requires" : "accounts require"
            signInFragment = "⚠ \(count) \(noun) sign-in"
        } else {
            signInFragment = nil
        }

        let pausedFragment: String?
        if pausedCount > 0 {
            let noun = pausedCount == 1 ? "workspace" : "workspaces"
            pausedFragment = "⏸ \(pausedCount) paused \(noun)"
        } else {
            pausedFragment = nil
        }

        // When both conditions hold, surface both so neither is silently dropped.
        if let sf = signInFragment, let pf = pausedFragment {
            return "\(sf) · \(pf)"
        }
        if let sf = signInFragment { return sf }
        if let pf = pausedFragment { return pf }

        if let cache = formattedCache {
            return "● Running · \(cache) cached"
        }
        return "● Running"
    }

    private var formattedCache: String? {
        guard cacheBytes >= 0 else { return nil }
        let used = ByteCountFormatter.string(fromByteCount: cacheBytes, countStyle: .binary)
        if cacheMaxBytes > 0 {
            let max = ByteCountFormatter.string(fromByteCount: cacheMaxBytes, countStyle: .binary)
            return "\(used) / \(max)"
        }
        return used
    }

    // MARK: Private

    private var refreshTask: Task<Void, Never>?
    private var autoRefreshTask: Task<Void, Never>?
    private var backgroundRefreshTask: Task<Void, Never>?
    /// In-flight debounce timer for setCacheLimitGB.
    private var setCacheLimitTask: Task<Void, Never>?
    /// In-flight debounce timer for setNetMaxUploads.
    private var setNetUploadsTask: Task<Void, Never>?
    /// In-flight debounce timer for setNetMaxDownloads.
    private var setNetDownloadsTask: Task<Void, Never>?
    /// In-flight debounce timer for setMaterializedPollInterval.
    private var setMaterializedPollTask: Task<Void, Never>?
    /// In-flight debounce timer for setSelfHealInterval.
    private var setSelfHealIntervalTask: Task<Void, Never>?

    // MARK: - Write fence (snapshot vs setter race)

    ///
    /// Every optimistic setter publishes the new value on `@MainActor`
    /// immediately, then sends the XPC write — either debounced (Steppers)
    /// or straight through. Until the FPE has *seen* that write and a
    /// subsequent refresh round-trip carries the new value back, any status
    /// the auto-refresh timer fetches still reports the *old* value. Landing
    /// such a snapshot would briefly snap the UI back.
    ///
    /// The fix is a per-field write fence. Each setter inserts its field
    /// key into `pendingWrites` before the optimistic publish and removes
    /// it once the XPC call has returned. `doRefresh` skips any field
    /// whose key is currently fenced.
    /// Internal (not private) so tests can verify fence behaviour via @testable import.
    enum WriteKey: Hashable {
        case cacheMaxSize
        case netMaxUploads
        case netMaxDownloads
        case logLevel
        case telemetry
        case materializedPollInterval
        case selfHealInterval
    }

    /// Counted multiset: each concurrent writer for the same key increments the
    /// counter; endWrite decrements. The fence lifts only when the count reaches
    /// zero, so overlapping writes to the same key don't prematurely expose stale
    /// refresh snapshots.
    private var pendingWrites: [WriteKey: Int] = [:]

    /// Internal (not private) so tests can verify fence behaviour via @testable import.
    func beginWrite(_ key: WriteKey) {
        pendingWrites[key, default: 0] += 1
    }

    func endWrite(_ key: WriteKey) {
        let current = pendingWrites[key, default: 0]
        if current <= 1 {
            pendingWrites.removeValue(forKey: key)
        } else {
            pendingWrites[key] = current - 1
        }
    }

    func isFenced(_ key: WriteKey) -> Bool {
        (pendingWrites[key] ?? 0) > 0
    }

    /// Debounce window for setCacheLimitGB writes.
    static let setCacheLimitDebounce: Duration = .milliseconds(750)
    /// Debounce window for parallel uploads/downloads Steppers.
    static let setNetConcurrencyDebounce: Duration = .milliseconds(750)
    /// Debounce window for the poll-interval Stepper.
    static let setPollIntervalDebounce: Duration = .milliseconds(750)
    /// Debounce window for the self-heal interval Stepper.
    static let setSelfHealIntervalDebounce: Duration = .milliseconds(750)

    // MARK: - Refresh

    /// Generation counter incremented on every doRefresh() call. A stale
    /// completion that sees a mismatched generation discards its results
    /// rather than overwriting fresher state.
    private var refreshGeneration: UInt64 = 0

    /// Minimum wall-clock gap between two needsSignIn sweeps over accounts
    /// 2..N. Set via init (defaults to 30 s in production). See the
    /// throttle in doRefresh() (E3).
    private let secondaryAccountCheckInterval: Duration

    /// Wall-clock time of the last needsSignIn sweep over accounts 2..N.
    /// `nil` means "never checked" — the very first doRefresh() always
    /// checks regardless of `secondaryAccountCheckInterval`.
    private var lastSecondaryAccountCheckAt: ContinuousClock.Instant?

    /// Fetch account list + engine status. Call this on menu open;
    /// safe to call concurrently — a running fetch is cancelled and restarted.
    ///
    /// - Parameter full: When true (the default), the primary account's
    ///   status fetch uses the full `getEngineStatus` verb (cache stats +
    ///   config snapshot) — appropriate whenever a UI surface is actually
    ///   showing those numbers. Pass `false` for ambient/background
    ///   refreshes that only ever consume `needsSignIn` + `pausedWorkspaces`;
    ///   this routes the primary fetch through the slim `getBadgeStatus`
    ///   verb instead, skipping the FPE's blobBytes() cache scan (#397).
    ///   The secondary-account sweep (accounts 2..N) always uses the slim
    ///   verb regardless of this flag, since it only ever consumes
    ///   needsSignIn.
    func refresh(full: Bool = true) {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            await self?.doRefresh(full: full)
        }
    }

    /// Refresh now, then repeatedly every `interval` for the whole process
    /// lifetime, independent of dropdown/Settings visibility.
    ///
    /// This is the low-frequency half of the E3 fix: the ambient menu-bar
    /// badge (no-accounts / paused-workspace state) must keep self-healing
    /// even while no UI surface is open — that's the app's normal resting
    /// state. `interval` is deliberately much coarser than the 5 s
    /// high-frequency loop (`startAutoRefresh`). It also passes
    /// `full: false` to `refresh()` (#397): the ambient badge only needs
    /// `needsSignIn` + `pausedWorkspaces`, so this tick uses the slim
    /// `getBadgeStatus` verb instead of `getEngineStatus`, skipping the
    /// FPE's blobBytes() cache scan entirely while nobody is looking.
    /// `surfaceBecameVisible()` layers the 5 s loop — which still fetches
    /// the full status, cache numbers included — on top whenever the
    /// dropdown or Settings window is actually open.
    ///
    /// Call once, at launch; the loop is not meant to be stopped.
    func startBackgroundRefresh(interval: Duration = .seconds(75)) {
        backgroundRefreshTask?.cancel()
        backgroundRefreshTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.refresh(full: false)
                try? await Task.sleep(for: interval)
            }
        }
    }

    /// Refresh now, then repeatedly every `interval` while `autoRefreshTask` is live.
    /// Cancel `autoRefreshTask` (or call `stopAutoRefresh()`) to stop the loop.
    ///
    /// Callers should generally go through `surfaceBecameVisible()` /
    /// `surfaceBecameHidden()` rather than calling this directly, so that
    /// multiple visible surfaces (dropdown + Settings) share one refcounted
    /// session instead of stepping on each other's start/stop.
    func startAutoRefresh(interval: Duration = .seconds(5)) {
        autoRefreshTask?.cancel()
        autoRefreshTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.refresh()
                try? await Task.sleep(for: interval)
            }
        }
    }

    /// Cancel the high-frequency auto-refresh loop.
    func stopAutoRefresh() {
        autoRefreshTask?.cancel()
        autoRefreshTask = nil
    }

    // MARK: - Visible-surface refcounting (E3)

    /// Number of UI surfaces (the dropdown, the Settings window) currently
    /// asking for high-frequency (5 s) refresh. A refcount rather than a
    /// boolean because more than one surface can be visible at once (e.g.
    /// Settings opened from the dropdown while it is still closing) — the
    /// high-frequency loop should only stop once every surface reports
    /// hidden, not whichever happens to close first.
    private var visibleSurfaceCount = 0

    /// Called by a UI surface (`MenuVisibilityController` for the dropdown,
    /// `SettingsView` for the Settings window) when it becomes visible.
    /// Starts the high-frequency loop on the first caller; a second
    /// concurrently-visible surface is a no-op.
    func surfaceBecameVisible() {
        surfaceBecameVisible(interval: .seconds(5))
    }

    /// Overload accepting an explicit `interval`, so tests can exercise the
    /// refcounting logic without waiting out the 5 s production cadence.
    /// Production call sites use the parameterless `surfaceBecameVisible()`.
    func surfaceBecameVisible(interval: Duration) {
        visibleSurfaceCount += 1
        guard visibleSurfaceCount == 1 else { return }
        startAutoRefresh(interval: interval)
    }

    /// Called by a UI surface when it stops being visible. Stops the
    /// high-frequency loop once the last surface has reported hidden.
    /// Clamped at zero so an extra/unpaired call can't underflow the count.
    func surfaceBecameHidden() {
        visibleSurfaceCount = max(0, visibleSurfaceCount - 1)
        guard visibleSurfaceCount == 0 else { return }
        stopAutoRefresh()
    }

    private func doRefresh(full: Bool) async {
        // Stamp this refresh so we can discard stale results when a newer
        // refresh has already completed (generation counter fix for app-07).
        refreshGeneration &+= 1
        let myGeneration = refreshGeneration

        // Primary path: read accounts from the injected AccountProvider.
        // Works whether or not any FPE domain is loaded.
        let nativeAccounts = await accountProvider.listAccounts()
        let nativeDefault = await accountProvider.defaultAccount() ?? ""

        // Check cancellation before publishing (no suspension between read and publish).
        guard !Task.isCancelled else { return }

        accounts = nativeAccounts.map { acc in
            AccountInfo(
                alias: acc.alias,
                username: acc.username,
                tenantId: acc.tenantID,
                tenantName: acc.tenantName ?? ""
            )
        }
        defaultAccount = nativeDefault

        // Secondary path: try the FPE XPC service for engine status.
        // We query the first account's domain; config.toml is shared, so
        // cache stats and config values are consistent across all aliases.
        //
        // This is best-effort: failures are silently ignored so the menu
        // stays functional even if no domains are loaded yet (e.g. on a
        // freshly booted system before the FPE process has started).
        guard let firstAlias = nativeAccounts.first?.alias else { return }

        // Collect auth state across all accounts. The first account is queried
        // as part of the shared-config pass; remaining accounts are queried
        // separately because `needsSignIn` is per-domain (per-alias).
        // Best-effort: a domain not yet loaded is silently skipped (not an
        // auth error). Sequential to avoid hammering the XPC pool on a long
        // account list (typical installations have 1–3 accounts).
        var needsSignInSet: Set<String> = []

        if full {
            do {
                let status = try await engineStatusProvider.getEngineStatus(alias: firstAlias)

                // Discard results if a newer refresh already ran while we were
                // awaiting the XPC reply (stale-snapshot guard for app-07).
                guard myGeneration == refreshGeneration, !Task.isCancelled else { return }

                if !isFenced(.cacheMaxSize) {
                    cacheBytes = status.cacheBytes
                    cacheMaxBytes = status.cacheMaxBytes
                    if status.cacheMaxSizeGB > 0 {
                        cacheMaxSizeGB = status.cacheMaxSizeGB
                    }
                }
                if !isFenced(.telemetry) {
                    telemetryEnabled = status.telemetryEnabled
                }
                if status.netMaxUploads > 0, !isFenced(.netMaxUploads) {
                    netMaxUploads = status.netMaxUploads
                }
                if status.netMaxDownloads > 0, !isFenced(.netMaxDownloads) {
                    netMaxDownloads = status.netMaxDownloads
                }
                if !status.logLevel.isEmpty, !isFenced(.logLevel) {
                    logLevel = status.logLevel
                }
                if status.materializedPollIntervalS > 0, !isFenced(.materializedPollInterval) {
                    materializedPollIntervalS = status.materializedPollIntervalS
                    ChangeWatcher.shared.materializedPollInterval = .seconds(status.materializedPollIntervalS)
                }
                if !isFenced(.selfHealInterval) {
                    // 0 from an older FPE means "not yet available"; preserve the last-known
                    // value so the UI does not snap back. Once populated, publish verbatim
                    // (0 = disabled is a valid user choice).
                    if status.selfHealIntervalM > 0 || selfHealIntervalM == 0 {
                        selfHealIntervalM = status.selfHealIntervalM
                    }
                }

                // Mark that at least one successful status reply has been applied.
                // Settings rows that cannot use a sibling field's non-zero value as
                // a "loaded" proxy (e.g. selfHealIntervalM may be 0 when disabled)
                // should gate on this flag instead. Only the full getEngineStatus
                // reply actually populates the cache/config fields this flag
                // guards, so the badge-only branch below leaves it untouched.
                engineStatusReceived = true

                pausedWorkspaces = mapPausedWorkspaces(status.pausedWorkspaces)

                // Capture auth state from the first account's status reply.
                if status.needsSignIn {
                    needsSignInSet.insert(firstAlias)
                }
            } catch {
                // FPE not yet reachable — fields stay at last-known values or defaults.
                Self.log.debug(
                    "Engine status fetch skipped (FPE not reachable): \(error.localizedDescription, privacy: .public)"
                )
            }
        } else {
            // Ambient/background refresh (#397): only needsSignIn + pausedWorkspaces
            // are needed here, so use the slim verb and skip the FPE's blobBytes()
            // cache scan and config snapshot entirely. Cache/config fields are left
            // at their last-known values — engineStatusReceived is NOT set here,
            // since this branch never actually fetches the fields it gates.
            do {
                let status = try await engineStatusProvider.getBadgeStatus(alias: firstAlias)

                guard myGeneration == refreshGeneration, !Task.isCancelled else { return }

                pausedWorkspaces = mapPausedWorkspaces(status.pausedWorkspaces)

                if status.needsSignIn {
                    needsSignInSet.insert(firstAlias)
                }
            } catch {
                Self.log.debug(
                    "Badge status fetch skipped (FPE not reachable): \(error.localizedDescription, privacy: .public)"
                )
            }
        }

        // Query remaining accounts for their per-domain auth state via the slim
        // getBadgeStatus verb — only needsSignIn is used here, so this never runs
        // the FPE's blobBytes() cache scan (#397; previously every call paid that
        // scan via getEngineStatus for data this sweep never read). Sign-in state
        // doesn't need high-frequency freshness, so this sweep only actually
        // round-trips once every `secondaryAccountCheckInterval` of wall-clock
        // time; skipped calls carry forward the last-known membership instead
        // (E3). Time-based rather than a per-refresh counter: refresh()
        // now fires from two independent loops (the always-on low-frequency
        // background loop and the visibility-gated high-frequency one) plus
        // ad-hoc action refreshes, so "every Nth call" doesn't correspond to
        // any predictable wall-clock cadence and could leave a genuinely
        // stale needsSignIn reading uncorrected across many dropdown opens.
        // `nil`/expired means "due" — the first-ever doRefresh() and every
        // call at least `secondaryAccountCheckInterval` after the last
        // check always re-verify.
        let now = ContinuousClock.now
        let secondaryAccountCheckDue = lastSecondaryAccountCheckAt.map { now - $0 >= secondaryAccountCheckInterval } ?? true
        if secondaryAccountCheckDue {
            for acc in nativeAccounts.dropFirst() {
                guard myGeneration == refreshGeneration, !Task.isCancelled else { return }
                do {
                    let s = try await engineStatusProvider.getBadgeStatus(alias: acc.alias)
                    if s.needsSignIn {
                        needsSignInSet.insert(acc.alias)
                    }
                } catch {
                    Self.log.debug(
                        "needsSignIn check skipped for \(acc.alias, privacy: .public): \(error.localizedDescription, privacy: .public)"
                    )
                }
            }
        } else {
            for acc in nativeAccounts.dropFirst() where accountsNeedingSignIn.contains(acc.alias) {
                needsSignInSet.insert(acc.alias)
            }
        }

        // Stamp (when due) and publish together, both gated by the SAME final
        // guard as `accountsNeedingSignIn` below — not by the per-iteration
        // guard inside the loop above, which only re-checks *before* each
        // iteration's await. A task superseded while awaiting the LAST
        // account has no further iteration left to catch that: it would
        // fall through the loop and reach an unconditional stamp write with
        // a `now` captured before the sweep started, potentially clobbering
        // a fresher stamp already written by the task that superseded it.
        // Gating here instead means a superseded task can write neither the
        // stamp nor accountsNeedingSignIn — matching the earlier stamp-
        // after-sweep fix's intent (a sweep that didn't finish under this
        // task's own generation must count as "didn't happen"), but now
        // covering the tail-of-loop case too, not just the mid-loop one.
        guard myGeneration == refreshGeneration, !Task.isCancelled else { return }
        if secondaryAccountCheckDue {
            lastSecondaryAccountCheckAt = now
        }
        accountsNeedingSignIn = needsSignInSet
    }

    /// Maps `XPCPausedWorkspace` entries to `PausedWorkspaceInfo`. Shared by
    /// both the full (`getEngineStatus`) and badge-only (`getBadgeStatus`)
    /// branches of `doRefresh`, since both carry the same `pausedWorkspaces`
    /// field (#397).
    private func mapPausedWorkspaces(_ xpcWorkspaces: [XPCPausedWorkspace]) -> [PausedWorkspaceInfo] {
        xpcWorkspaces.map { xpc in
            PausedWorkspaceInfo(
                accountAlias: xpc.accountAlias,
                workspaceId: xpc.workspaceID,
                reason: xpc.reason,
                // A zero/negative detectedAtSec means the timestamp is
                // unknown. Use Date.distantPast (Apple's conventional
                // "never / unknown" sentinel) rather than the Unix epoch
                // (1970-01-01), which would format as a nonsensical date
                // in any downstream display.
                detectedAt: xpc.detectedAtSec > 0
                    ? Date(timeIntervalSince1970: xpc.detectedAtSec)
                    : Date.distantPast,
                probedAt: nil
            )
        }
    }

    // MARK: - XPC version mismatch surfacing (xpc-06)

    /// Surfaces a host/FPE protocol version mismatch as a non-intrusive
    /// inline error in the menu bar. Called by OfemFPEClient after each
    /// new connection is established.
    ///
    /// - Parameters:
    ///   - hostVersion: The version constant this host build expects.
    ///   - fpeVersion:  The version the connected FPE reported (1 if pre-v2).
    func setVersionMismatchError(hostVersion: Int, fpeVersion: Int) {
        lastActionError = "Extension version mismatch (host v\(hostVersion), extension v\(fpeVersion)). Restart the app after updating."
    }

    // periphery:ignore
    /// Clears `lastActionError`. Used in tests to reset state between test cases.
    func clearLastActionError() {
        lastActionError = nil
    }

    /// Surfaces a non-intrusive error when no NSWindow was available to anchor
    /// the MSAL re-authentication sheet. The user can dismiss by retrying.
    func setSignInWindowError() {
        lastActionError = "Sign in could not start: no window is available. Please try again."
    }

    // MARK: - Actions

    /// Make `alias` the default account and refresh.
    func setDefaultAccount(alias: String) {
        lastActionError = nil
        Task { [weak self] in
            guard let self else { return }
            do {
                try await accountProvider.setDefaultAccount(alias: alias)
            } catch {
                Self.log.error("setDefaultAccount failed: \(error.localizedDescription, privacy: .public)")
                lastActionError = "Could not set default account: \(error.localizedDescription)"
            }
            refresh()
        }
    }

    /// Remove the account and drop the File Provider domain from Finder.
    func removeAccount(alias: String) {
        lastActionError = nil
        Task { [weak self] in
            guard let self else { return }
            do {
                try await accountProvider.removeAccount(alias: alias)
                await domainManager.removeDomain(alias: alias)
            } catch {
                Self.log.error("removeAccount failed: \(error.localizedDescription, privacy: .public)")
                lastActionError = "Could not sign out '\(alias)': \(error.localizedDescription)"
            }
            refresh()
        }
    }

    /// Re-run the interactive two-step sign-in flow for an existing account.
    ///
    /// Runs the same OneLake + Fabric sequential browser flows used at first sign-in so
    /// both token audiences are refreshed in the shared App Group Keychain. On success:
    ///
    /// 1. The optimistic in-memory badge (`accountsNeedingSignIn`) is cleared immediately
    ///    so the menu bar reflects the resolved state without waiting for the next poll.
    /// 2. A `reloadEngine(alias:)` XPC call clears the FPE's internal `needsSignIn` flag
    ///    and lets the next enumeration start fresh with the newly cached tokens.
    ///
    /// - Parameters:
    ///   - alias:  The existing account alias to re-authenticate.
    ///   - window: The NSWindow that anchors the MSAL ASWebAuthenticationSession sheet.
    func reSignIn(alias: String, window: NSWindow) {
        lastActionError = nil
        Task { [weak self] in
            guard let self else { return }
            do {
                try await reSignInProvider.reSignIn(alias: alias, window: window)
                Self.log.info(
                    "reSignIn: re-auth succeeded for alias=\(alias, privacy: .public); triggering engine reload"
                )
                // Trigger reloadEngine() in the FPE via the dedicated protocol verb
                // (xpc-11). Best-effort: a failure here is logged but does not surface as
                // a UI error — the FPE's auto-refresh timer will clear needsSignIn on
                // the next successful enumeration cycle.
                do {
                    try await engineStatusProvider.reloadEngine(alias: alias)
                } catch {
                    Self.log.warning(
                        "reSignIn: reloadEngine failed for alias=\(alias, privacy: .public) (non-fatal): \(error.localizedDescription, privacy: .public)"
                    )
                }
                // Clear the badge only after the engine reload has been acknowledged
                // so a subsequent poll does not re-add the alias before the FPE has
                // processed the reload (see review thread on state-clear ordering).
                accountsNeedingSignIn.remove(alias)
            } catch {
                // Re-auth failed: keep the needs-sign-in badge set and do NOT signal
                // an engine reload. Unlike first-time signIn, we never remove the
                // account record here — the user retries re-auth; the account stays.
                Self.log.error(
                    "reSignIn failed for alias=\(alias, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
                lastActionError = "Sign in failed: \(error.localizedDescription)"
            }
            refresh()
        }
    }

    /// Wipe all cached blobs and refresh.
    func cacheClear() {
        lastActionError = nil
        Task { [weak self] in
            guard let self else { return }
            // Read directly from AccountProvider so this works even before the first
            // doRefresh() has populated the published `accounts` property — same
            // rationale as writeConfig.
            let currentAccounts = await accountProvider.listAccounts()
            var firstError: Error?
            for acc in currentAccounts {
                do {
                    let remaining = try await engineStatusProvider.clearCache(alias: acc.alias)
                    Self.log.info(
                        "clearCache(\(acc.alias, privacy: .public)): bytes remaining=\(remaining, privacy: .public)"
                    )
                } catch {
                    Self.log.error(
                        "clearCache(\(acc.alias, privacy: .public)) failed: \(error.localizedDescription, privacy: .public)"
                    )
                    if firstError == nil { firstError = error }
                }
            }
            if let error = firstError {
                lastActionError = "Cache clear failed: \(error.localizedDescription)"
            }
            refresh()
        }
    }

    // MARK: - Debounced setter helper (S5)

    /// Shared implementation of the "clamp → fence → optimistic publish →
    /// cancel prior debounce → write → refresh" dance used by every
    /// Stepper-backed config field.
    ///
    /// Previously each of the five debounced setters hand-rolled this
    /// sequence, including its own `defer { endWrite(key) }` — a pattern
    /// that only works if every copy remembers the `defer`. Routing all of
    /// them through this single implementation means that guarantee only
    /// has to hold in one place (S5).
    ///
    /// Callers are still responsible for cancelling their own dedicated
    /// `Task?` slot before calling this (each field needs its own slot so a
    /// second click supersedes the first), and for storing the returned
    /// `Task` back into it.
    ///
    /// - Parameters:
    ///   - key: The write-fence key for this field.
    ///   - debounce: How long to wait, after the optimistic publish, before
    ///     the XPC write actually fires.
    ///   - publish: Applies the optimistic value to the `@Published`
    ///     property (and any synchronous side effect, e.g. updating
    ///     `ChangeWatcher`'s cadence). Runs immediately, before debouncing.
    ///   - write: The XPC write to perform once the debounce settles.
    /// - Returns: The `Task` driving the debounce; store it in the caller's
    ///   own `Task?` slot so a subsequent call can cancel it.
    private func debouncedSet(
        _ key: WriteKey,
        debounce: Duration,
        publish: () -> Void,
        write: @escaping @Sendable () async -> Void
    ) -> Task<Void, Never> {
        beginWrite(key)
        publish()
        return Task { [weak self] in
            defer { Task { @MainActor [weak self] in self?.endWrite(key) } }
            try? await Task.sleep(for: debounce)
            guard let self, !Task.isCancelled else { return }
            await write()
            self.refresh()
        }
    }

    // MARK: - Debounced config setters

    /// Stage a new cache-size limit (in whole gigabytes) for the FPE engine.
    ///
    /// Optimistically updates the published `cacheMaxSizeGB` so the
    /// Stepper visibly tracks every click, then debounces the actual XPC call.
    func setCacheLimitGB(_ gb: Int) {
        // CacheConfig.clampSizeGB preserves 0 (the "no limit" sentinel) and
        // is the same clamp the FPE's setConfig handler validates against,
        // so the expression itself can't drift between the two (M9).
        let clamped = CacheConfig.clampSizeGB(gb)
        setCacheLimitTask?.cancel()
        setCacheLimitTask = debouncedSet(.cacheMaxSize, debounce: MenuStatusModel.setCacheLimitDebounce, publish: {
            cacheMaxSizeGB = clamped
            cacheMaxBytes = Int64(clamped) * 1_073_741_824 // 1 GiB in bytes
        }, write: { [weak self] in
            await self?.writeConfig(key: OfemConfigKey.cacheMaxSizeGB.rawValue, value: String(clamped))
        })
    }

    /// Toggle anonymous telemetry and refresh.
    func setTelemetry(enabled: Bool) {
        beginWrite(.telemetry)
        telemetryEnabled = enabled
        Task { [weak self] in
            defer { Task { @MainActor [weak self] in self?.endWrite(.telemetry) } }
            guard let self else { return }
            await self.writeConfig(
                key: OfemConfigKey.telemetry.rawValue,
                value: enabled ? "on" : "off"
            )
            refresh()
        }
    }

    /// Stage a new "max parallel uploads per account" value.
    func setNetMaxUploads(_ n: Int) {
        // M9: SetConfigLimits.clampUploads is the same clamp the FPE's
        // setConfig handler validates against, so the two never drift.
        let clamped = SetConfigLimits.clampUploads(n)
        setNetUploadsTask?.cancel()
        setNetUploadsTask = debouncedSet(.netMaxUploads, debounce: MenuStatusModel.setNetConcurrencyDebounce, publish: {
            netMaxUploads = clamped
        }, write: { [weak self] in
            await self?.writeConfig(key: OfemConfigKey.netMaxUploads.rawValue, value: String(clamped))
        })
    }

    /// Stage a new "max parallel downloads per account" value.
    func setNetMaxDownloads(_ n: Int) {
        // M9: SetConfigLimits.clampDownloads is the same clamp the FPE's
        // setConfig handler validates against, so the two never drift.
        let clamped = SetConfigLimits.clampDownloads(n)
        setNetDownloadsTask?.cancel()
        setNetDownloadsTask = debouncedSet(.netMaxDownloads, debounce: MenuStatusModel.setNetConcurrencyDebounce, publish: {
            netMaxDownloads = clamped
        }, write: { [weak self] in
            await self?.writeConfig(key: OfemConfigKey.netMaxDownloads.rawValue, value: String(clamped))
        })
    }

    /// Stage a new materialized-container poll interval (in seconds).
    ///
    /// Optimistically updates `materializedPollIntervalS` and the ChangeWatcher
    /// loop cadence immediately, then debounces the actual XPC + TOML write so a
    /// held Stepper does not flood the FPE.
    func setMaterializedPollInterval(_ seconds: Int) {
        let clamped = max(
            SyncConfig.minMaterializedPollIntervalS,
            min(SyncConfig.maxMaterializedPollIntervalS, seconds)
        )
        setMaterializedPollTask?.cancel()
        setMaterializedPollTask = debouncedSet(.materializedPollInterval, debounce: MenuStatusModel.setPollIntervalDebounce, publish: {
            materializedPollIntervalS = clamped
            ChangeWatcher.shared.materializedPollInterval = .seconds(clamped)
        }, write: { [weak self] in
            await self?.writeConfig(key: OfemConfigKey.syncMaterializedPollIntervalS.rawValue, value: String(clamped))
        })
    }

    /// Stage a new self-heal full-refresh interval (in minutes).
    ///
    /// Optimistically updates `selfHealIntervalM` immediately, then debounces the
    /// actual XPC + TOML write so a held Stepper does not flood the FPE.
    /// Pass `0` to disable the self-heal floor.
    func setSelfHealInterval(_ minutes: Int) {
        // 0 is the "disabled" sentinel and is preserved as-is.
        // Non-zero values are clamped to [min, max].
        let clamped = minutes == 0 ? 0 : max(
            SyncConfig.minSelfHealIntervalM,
            min(SyncConfig.maxSelfHealIntervalM, minutes)
        )
        setSelfHealIntervalTask?.cancel()
        setSelfHealIntervalTask = debouncedSet(.selfHealInterval, debounce: MenuStatusModel.setSelfHealIntervalDebounce, publish: {
            selfHealIntervalM = clamped
        }, write: { [weak self] in
            await self?.writeConfig(key: OfemConfigKey.syncSelfHealIntervalM.rawValue, value: String(clamped))
        })
    }

    /// Persist the log level.
    func setLogLevel(_ level: String) {
        beginWrite(.logLevel)
        logLevel = level
        Task { [weak self] in
            defer { Task { @MainActor [weak self] in self?.endWrite(.logLevel) } }
            guard let self else { return }
            await self.writeConfig(key: OfemConfigKey.logLevel.rawValue, value: level)
            refresh()
        }
    }

    // MARK: - Private helpers

    /// Writes a config key/value pair through the first available FPE domain.
    ///
    /// `config.toml` is a single shared file, so one write is sufficient to
    /// persist the change. `setConfig` on the FPE side calls `updateAndSave`
    /// (atomic read-merge-write) and then `reloadEngine()`, so the in-memory
    /// snapshot and the running engine are both updated in one round-trip.
    /// Fanning out to every alias would produce N redundant write-lock-read-
    /// merge-write cycles for the same key/value with no additional benefit.
    private func writeConfig(key: String, value: String) async {
        // Read directly from AccountProvider so this works even before the first
        // doRefresh() has populated the published `accounts` property — e.g. when
        // the user changes a setting immediately after app launch.
        let currentAccounts = await accountProvider.listAccounts()
        guard let first = currentAccounts.first else { return }
        do {
            try await engineStatusProvider.setConfig(
                alias: first.alias,
                key: key,
                value: value
            )
            Self.log.info(
                "setConfig(\(first.alias, privacy: .public)) key='\(key, privacy: .public)' applied"
            )
        } catch {
            Self.log.error(
                "setConfig(\(first.alias, privacy: .public)) key='\(key, privacy: .public)' failed: \(error.localizedDescription, privacy: .public)"
            )
        }
    }
}
