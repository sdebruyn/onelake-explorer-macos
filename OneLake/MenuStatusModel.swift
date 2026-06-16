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
import FileProvider
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
protocol AccountProvider {
    /// Returns all known accounts. Returns an empty array if the store is empty.
    func listAccounts() async -> [Account]
    /// Returns the alias of the default account, or nil if none is set.
    func defaultAccount() async -> String?
    func setDefaultAccount(alias: String) async throws
    func removeAccount(alias: String) async throws
}

/// Provides engine status and config writes over XPC.
/// Implemented by OfemFPEClient; faked in tests.
protocol EngineStatusProvider {
    func getEngineStatus(alias: String) async throws -> XPCEngineStatus
    func setConfig(alias: String, key: String, value: String) async throws
    func clearCache(alias: String) async throws -> Int64
}

/// Provides interactive re-authentication for an existing account.
/// Implemented by SharedOfemAuth; faked in tests.
/// The provider must run the same two sequential interactive flows as the
/// first-sign-in path (OneLake storage + Fabric Power BI) so both token
/// audiences are refreshed in the shared App Group Keychain.
protocol ReSignInProvider {
    func reSignIn(alias: String, window: NSWindow) async throws
}

/// Provides domain management (add/remove).
/// Implemented by DomainSyncManager; faked in tests.
protocol DomainManager {
    func removeDomain(alias: String) async
}

// MARK: - Production conformances

extension OfemAuth: AccountProvider {}

extension OfemFPEClient: EngineStatusProvider {}

extension DomainSyncManager: DomainManager {}

extension SharedOfemAuth: ReSignInProvider {}

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
    init(
        accountProvider: (any AccountProvider)? = nil,
        engineStatusProvider: (any EngineStatusProvider)? = nil,
        domainManager: (any DomainManager)? = nil,
        reSignInProvider: (any ReSignInProvider)? = nil
    ) {
        self.accountProvider = accountProvider ?? SharedOfemAuth.shared.auth
        self.engineStatusProvider = engineStatusProvider ?? OfemFPEClient.shared
        self.domainManager = domainManager ?? DomainSyncManager.shared
        self.reSignInProvider = reSignInProvider ?? SharedOfemAuth.shared
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

    /// Last action error for display to the user. nil if the last action succeeded.
    /// Set by destructive actions (removeAccount, cacheClear, setDefaultAccount)
    /// when they fail so the UI can surface a non-intrusive inline message.
    @Published private(set) var lastActionError: String? = nil

    // MARK: Computed conveniences

    var pausedCount: Int { pausedWorkspaces.count }

    /// True when at least one account is registered.
    var hasAccounts: Bool { !accounts.isEmpty }

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
    /// In-flight debounce timer for setCacheLimitGB.
    private var setCacheLimitTask: Task<Void, Never>?
    /// In-flight debounce timer for setNetMaxUploads.
    private var setNetUploadsTask: Task<Void, Never>?
    /// In-flight debounce timer for setNetMaxDownloads.
    private var setNetDownloadsTask: Task<Void, Never>?

    // MARK: - Write fence (snapshot vs setter race)
    //
    // Every optimistic setter publishes the new value on `@MainActor`
    // immediately, then sends the XPC write — either debounced (Steppers)
    // or straight through. Until the FPE has *seen* that write and a
    // subsequent refresh round-trip carries the new value back, any status
    // the auto-refresh timer fetches still reports the *old* value. Landing
    // such a snapshot would briefly snap the UI back.
    //
    // The fix is a per-field write fence. Each setter inserts its field
    // key into `pendingWrites` before the optimistic publish and removes
    // it once the XPC call has returned. `doRefresh` skips any field
    // whose key is currently fenced.
    // Internal (not private) so tests can verify fence behaviour via @testable import.
    enum WriteKey: Hashable {
        case cacheMaxSize
        case netMaxUploads
        case netMaxDownloads
        case logLevel
        case telemetry
    }
    // Counted multiset: each concurrent writer for the same key increments the
    // counter; endWrite decrements. The fence lifts only when the count reaches
    // zero, so overlapping writes to the same key don't prematurely expose stale
    // refresh snapshots.
    private var pendingWrites: [WriteKey: Int] = [:]

    // Internal (not private) so tests can verify fence behaviour via @testable import.
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

    // MARK: - Refresh

    /// Generation counter incremented on every doRefresh() call. A stale
    /// completion that sees a mismatched generation discards its results
    /// rather than overwriting fresher state.
    private var refreshGeneration: UInt64 = 0

    /// Fetch account list + engine status. Call this on menu open;
    /// safe to call concurrently — a running fetch is cancelled and restarted.
    func refresh() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            await self?.doRefresh()
        }
    }

    /// Refresh now, then repeatedly every `interval` while `autoRefreshTask` is live.
    /// Cancel `autoRefreshTask` (or call `stopAutoRefresh()`) to stop the loop.
    func startAutoRefresh(interval: Duration = .seconds(5)) {
        autoRefreshTask?.cancel()
        autoRefreshTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.refresh()
                try? await Task.sleep(for: interval)
            }
        }
    }

    /// Cancel the auto-refresh loop. Call this when no surface is visible
    /// (currently unused — the host keeps the loop alive for the process
    /// lifetime, but `stopAutoRefresh` is the correct hook if that changes).
    func stopAutoRefresh() {
        autoRefreshTask?.cancel()
        autoRefreshTask = nil
    }

    private func doRefresh() async {
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

            // Map XPCPausedWorkspace entries to PausedWorkspaceInfo.
            pausedWorkspaces = status.pausedWorkspaces.map { xpc in
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

        // Query remaining accounts for their per-domain auth state.
        for acc in nativeAccounts.dropFirst() {
            guard myGeneration == refreshGeneration, !Task.isCancelled else { return }
            do {
                let s = try await engineStatusProvider.getEngineStatus(alias: acc.alias)
                if s.needsSignIn {
                    needsSignInSet.insert(acc.alias)
                }
            } catch {
                Self.log.debug(
                    "needsSignIn check skipped for \(acc.alias, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
            }
        }

        guard myGeneration == refreshGeneration, !Task.isCancelled else { return }
        accountsNeedingSignIn = needsSignInSet
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
    /// 2. A `setConfig` round-trip triggers `reloadEngine()` in the FPE, which clears the
    ///    FPE's internal `needsSignIn` flag and lets the next enumeration start fresh with
    ///    the newly cached tokens.
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
                // Trigger a reloadEngine() in the FPE by sending a no-op setConfig.
                // The FPE's setConfig handler always calls reloadEngine() on success,
                // which clears _needsSignIn so the next enumeration uses the fresh tokens.
                await signalEngineReload(alias: alias)
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

    // MARK: - Debounced config setters

    /// Stage a new cache-size limit (in whole gigabytes) for the FPE engine.
    ///
    /// Optimistically updates the published `cacheMaxSizeGB` so the
    /// Stepper visibly tracks every click, then debounces the actual XPC call.
    func setCacheLimitGB(_ gb: Int) {
        let clamped = max(1, min(100, gb))
        beginWrite(.cacheMaxSize)
        cacheMaxSizeGB = clamped
        cacheMaxBytes = Int64(clamped) * 1_073_741_824  // 1 GiB in bytes
        setCacheLimitTask?.cancel()
        setCacheLimitTask = Task { [weak self] in
            defer { Task { @MainActor [weak self] in self?.endWrite(.cacheMaxSize) } }
            try? await Task.sleep(for: MenuStatusModel.setCacheLimitDebounce)
            guard let self, !Task.isCancelled else { return }
            await self.writeConfig(key: OfemConfigKey.cacheMaxSizeGB, value: String(clamped))
            refresh()
        }
    }

    /// Toggle anonymous telemetry and refresh.
    func setTelemetry(enabled: Bool) {
        beginWrite(.telemetry)
        telemetryEnabled = enabled
        Task { [weak self] in
            defer { Task { @MainActor [weak self] in self?.endWrite(.telemetry) } }
            guard let self else { return }
            await self.writeConfig(
                key: OfemConfigKey.telemetry,
                value: enabled ? "on" : "off"
            )
            refresh()
        }
    }

    /// Stage a new "max parallel uploads per account" value.
    func setNetMaxUploads(_ n: Int) {
        let clamped = max(1, min(16, n))
        beginWrite(.netMaxUploads)
        netMaxUploads = clamped
        setNetUploadsTask?.cancel()
        setNetUploadsTask = Task { [weak self] in
            defer { Task { @MainActor [weak self] in self?.endWrite(.netMaxUploads) } }
            try? await Task.sleep(for: MenuStatusModel.setNetConcurrencyDebounce)
            guard let self, !Task.isCancelled else { return }
            await self.writeConfig(
                key: OfemConfigKey.netMaxUploads,
                value: String(clamped)
            )
            refresh()
        }
    }

    /// Stage a new "max parallel downloads per account" value.
    func setNetMaxDownloads(_ n: Int) {
        let clamped = max(1, min(32, n))
        beginWrite(.netMaxDownloads)
        netMaxDownloads = clamped
        setNetDownloadsTask?.cancel()
        setNetDownloadsTask = Task { [weak self] in
            defer { Task { @MainActor [weak self] in self?.endWrite(.netMaxDownloads) } }
            try? await Task.sleep(for: MenuStatusModel.setNetConcurrencyDebounce)
            guard let self, !Task.isCancelled else { return }
            await self.writeConfig(
                key: OfemConfigKey.netMaxDownloads,
                value: String(clamped)
            )
            refresh()
        }
    }

    /// Persist the log level.
    func setLogLevel(_ level: String) {
        beginWrite(.logLevel)
        logLevel = level
        Task { [weak self] in
            defer { Task { @MainActor [weak self] in self?.endWrite(.logLevel) } }
            guard let self else { return }
            await self.writeConfig(key: OfemConfigKey.logLevel, value: level)
            refresh()
        }
    }

    // MARK: - Private helpers

    /// Sends a `setConfig` call to the FPE to trigger `reloadEngine()`.
    ///
    /// The FPE's `setConfig` handler always calls `reloadEngine()` on success, which
    /// clears `_needsSignIn` so the next enumeration gets fresh Keychain tokens. We
    /// reuse the existing XPC surface (no new protocol method needed) by sending a
    /// benign log-level write. If the current `logLevel` is unknown (""), "info" is
    /// used as a safe default — the FPE accepts any of the four allowed values.
    ///
    /// The write is serialised under the `.logLevel` fence (same as `setLogLevel`)
    /// so a concurrent user-initiated log-level change cannot race against this
    /// reload signal and clobber the user's chosen level. Unlike the debounced
    /// setters (which use a Task-based defer for the endWrite), we call endWrite
    /// directly here because `signalEngineReload` is itself `async` and always
    /// runs on the main actor — no secondary dispatch is needed.
    ///
    /// Best-effort: a failure here is logged but does not surface as a UI error —
    /// the FPE's auto-refresh timer will clear `needsSignIn` on the next successful
    /// enumeration cycle.
    private func signalEngineReload(alias: String) async {
        let level = logLevel.isEmpty ? "info" : logLevel
        beginWrite(.logLevel)
        do {
            try await engineStatusProvider.setConfig(
                alias: alias,
                key: OfemConfigKey.logLevel,
                value: level
            )
        } catch {
            Self.log.warning(
                "signalEngineReload(\(alias, privacy: .public)) setConfig failed (non-fatal): \(error.localizedDescription, privacy: .public)"
            )
        }
        endWrite(.logLevel)
    }

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
