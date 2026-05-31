// MenuStatusModel.swift
// Observable model that fetches daemon status + account list + config snapshot
// via IPC and publishes the results for the menu-bar dropdown.
//
// The wire types (StatusInfo, AccountListInfo, AccountInfo, PausedWorkspaceInfo,
// ConfigInfo, StatusPaths) live in apple/Shared/StatusTypes.swift so they
// compile into both targets.
//
// Refresh strategy:
//   - Triggered manually when the menu opens (see MenuBarView.onAppear).
//     No background timer: one fetch per open is sufficient for a status
//     display; a polling timer would be added in a later phase if live
//     updates are needed while the menu stays open.
//   - On daemon-unreachable the model publishes isRunning = false so the
//     menu shows "Not running" instead of stale data.
//
// Action methods (setDefault, signOut, cacheClear, setCacheLimitGB,
// setTelemetry) are called from MenuBarView. They always call refresh()
// on completion so the menu reflects the new state immediately.
// setCacheLimitGB additionally debounces its IPC write (see
// setCacheLimitDebounce) so a held-down Stepper does not flood the daemon.

import Foundation
import os.log

// MARK: - MenuIconState

/// The four icon states the menu-bar label can represent.
/// Used by both the icon view (OneLakeApp) and tests that verify the model logic.
enum MenuIconState {
    /// Daemon is reachable, not offline, no paused workspaces.
    case normal
    /// Daemon not reachable over IPC.
    case notRunning
    /// Daemon reachable but reporting offline (no network / token expired).
    case offline
    /// One or more Fabric capacity workspaces are paused.
    case paused
}

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
    static let shared = MenuStatusModel()

    private static let log = Logger(subsystem: "dev.debruyn.ofem", category: "menu-status")

    // MARK: Published

    @Published private(set) var isRunning: Bool = false
    @Published private(set) var daemonVersion: String = ""
    @Published private(set) var offline: Bool = false
    @Published private(set) var cacheBytes: Int64 = -1
    @Published private(set) var cacheMaxBytes: Int64 = 0
    /// User-editable LRU ceiling in whole gigabytes; the menubar Stepper
    /// reads and writes this. Mirrors `cacheMaxBytes` (which is the
    /// daemon's GB → bytes conversion used for the live used/limit math)
    /// but kept in GBs so the Stepper round-trips cleanly without losing
    /// precision through a bytes intermediate. 0 means "unknown / not yet
    /// fetched"; once populated it stays within [1, 100] (matching
    /// `config.MaxCacheSizeGB` on the daemon side).
    @Published private(set) var cacheMaxSizeGB: Int = 0
    @Published private(set) var pausedWorkspaces: [PausedWorkspaceInfo] = []
    @Published private(set) var accounts: [AccountInfo] = []
    @Published private(set) var defaultAccount: String = ""
    @Published private(set) var telemetryEnabled: Bool = true
    @Published private(set) var paths: StatusPaths = StatusPaths()

    /// Max parallel uploads per account (Settings → Network). 0 means
    /// "not yet fetched"; once populated stays in
    /// [config.MinNetConcurrentUploadsPerAccount, config.MaxNetConcurrentUploadsPerAccount].
    @Published private(set) var netMaxUploads: Int = 0
    /// Max parallel downloads per account (Settings → Network).
    @Published private(set) var netMaxDownloads: Int = 0
    /// Daemon log level (Settings → Advanced). One of "debug", "info",
    /// "warn", "error". Empty only before the first refresh.
    @Published private(set) var logLevel: String = ""

    // MARK: Computed conveniences

    var pausedCount: Int { pausedWorkspaces.count }

    /// Icon state for the menu-bar label. Priority: not-running > offline > paused > normal.
    var menuIconState: MenuIconState {
        if !isRunning { return .notRunning }
        if offline    { return .offline }
        if pausedCount > 0 { return .paused }
        return .normal
    }

    var headerLabel: String {
        guard isRunning else { return "○ Not running" }
        if offline { return "⚠ Offline" }
        if pausedCount > 0 {
            // Spell "workspace" out so the bare number doesn't look
            // like an alert badge with no referent ("2 paused" reads
            // as "2 of what?"). Singular/plural follows the count.
            let noun = pausedCount == 1 ? "workspace" : "workspaces"
            return "⏸ \(pausedCount) paused \(noun)"
        }
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

    private let bridge = CoreBridge.shared
    private var refreshTask: Task<Void, Never>?
    private var autoRefreshTask: Task<Void, Never>?
    /// In-flight debounce timer for setCacheLimitGB. Each Stepper tick
    /// cancels the previous timer; only the final value (after the user
    /// stops clicking for SetCacheLimitDebounce) hits the daemon over IPC.
    private var setCacheLimitTask: Task<Void, Never>?
    /// In-flight debounce timer for setNetMaxUploads (Settings slider/stepper).
    private var setNetUploadsTask: Task<Void, Never>?
    /// In-flight debounce timer for setNetMaxDownloads (Settings slider/stepper).
    private var setNetDownloadsTask: Task<Void, Never>?

    /// Debounce window for setCacheLimitGB writes. Sized so a user can
    /// hold the Stepper arrow and rack up many ticks without firing one
    /// IPC call per tick, while staying short enough that letting go
    /// feels immediate.
    static let setCacheLimitDebounce: Duration = .milliseconds(750)
    /// Debounce window for the Network tab's parallel uploads/downloads
    /// Steppers — same 750 ms window as the cache slider so racking up
    /// clicks reaches the daemon as a single IPC call.
    static let setNetConcurrencyDebounce: Duration = .milliseconds(750)

    // MARK: - Refresh

    /// Fetch status + account list + config snapshot. Call this on menu open;
    /// safe to call concurrently — a running fetch is cancelled and restarted.
    func refresh() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            await self?.doRefresh()
        }
    }

    /// Refresh now, then repeatedly every `interval`. MenuBarExtra(.menu) does
    /// not deliver SwiftUI lifecycle callbacks (.onAppear) when the menu opens,
    /// so a light timer is the reliable way to keep both the menu contents and
    /// the menu-bar icon current — and to recover automatically once the daemon
    /// becomes reachable after a transient outage. A status round-trip over the
    /// local unix socket is cheap.
    func startAutoRefresh(interval: Duration = .seconds(5)) {
        autoRefreshTask?.cancel()
        autoRefreshTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.refresh()
                try? await Task.sleep(for: interval)
            }
        }
    }

    private func doRefresh() async {
        do {
            async let statusFetch = bridge.status()
            async let listFetch = bridge.accountList()
            async let configFetch = bridge.configSnapshot()
            let (status, list, config) = try await (statusFetch, listFetch, configFetch)

            isRunning = true
            daemonVersion = status.daemonVersion
            offline = status.offline
            cacheBytes = status.cacheBytes
            cacheMaxBytes = status.cacheMaxBytes
            pausedWorkspaces = status.pausedWorkspaces
            paths = status.paths
            accounts = list.accounts
            defaultAccount = list.defaultAccount
            telemetryEnabled = config.telemetryEnabled
            // Only update the GB-precision value when the daemon answered
            // with one; a transport blip that returns 0 must not snap the
            // Stepper to an out-of-range value the user never asked for.
            if config.cacheMaxSizeGB > 0 {
                cacheMaxSizeGB = config.cacheMaxSizeGB
            }
            // Same reasoning for the Settings tab values — only update
            // when the daemon gave us a non-zero answer. An older daemon
            // (pre-this-PR) returns 0 because the JSON keys are absent,
            // and we'd rather show stale-but-correct numbers than zeroes.
            if config.netMaxConcurrentUploadsPerAccount > 0 {
                netMaxUploads = config.netMaxConcurrentUploadsPerAccount
            }
            if config.netMaxConcurrentDownloadsPerAccount > 0 {
                netMaxDownloads = config.netMaxConcurrentDownloadsPerAccount
            }
            if !config.logLevel.isEmpty {
                logLevel = config.logLevel
            }
        } catch {
            // Daemon not running, or IPC failure — show degraded state.
            Self.log.warning("Daemon status fetch failed: \(error.localizedDescription, privacy: .public)")
            isRunning = false
            daemonVersion = ""
            accounts = []
            defaultAccount = ""
        }
    }

    // MARK: - Actions

    /// Make `alias` the default account and refresh.
    func setDefaultAccount(alias: String) {
        Task { [weak self] in
            guard let self else { return }
            do {
                try await bridge.setDefaultAccount(alias: alias)
            } catch {
                Self.log.error("account.setDefault failed: \(error.localizedDescription, privacy: .public)")
            }
            refresh()
        }
    }

    /// Remove the account and reconcile the File Provider domain list so the
    /// unmounted domain is dropped from Finder immediately.
    func removeAccount(alias: String) {
        Task { [weak self] in
            guard let self else { return }
            do {
                try await bridge.removeAccount(alias: alias)
                // Reconcile drops the now-orphan domain from the Finder sidebar.
                try await DomainSyncManager.shared.reconcile()
            } catch {
                Self.log.error("account.remove/reconcile failed: \(error.localizedDescription, privacy: .public)")
            }
            refresh()
        }
    }

    /// Wipe all cached blobs and refresh.
    func cacheClear() {
        Task { [weak self] in
            guard let self else { return }
            do {
                let after = try await bridge.cacheClear()
                Self.log.info("cache.clear done; bytes remaining: \(after, privacy: .public)")
            } catch {
                Self.log.error("cache.clear failed: \(error.localizedDescription, privacy: .public)")
            }
            refresh()
        }
    }

    /// Stage a new cache-size limit (in whole gigabytes) for the daemon.
    ///
    /// Optimistically updates the published `cacheMaxSizeGB` so the
    /// Stepper visibly tracks every click, then debounces the actual
    /// `config.set cache.max_size_gb=<gb>` IPC call by
    /// `setCacheLimitDebounce`. Holding the Stepper arrow racks up many
    /// in-process ticks but only the last value crosses the socket.
    ///
    /// Out-of-range values are clamped to the allowed window so a future
    /// SwiftUI change that broadens the Stepper's bounds cannot ship an
    /// invalid value to the daemon (which would reject it anyway).
    func setCacheLimitGB(_ gb: Int) {
        let clamped = max(1, min(100, gb))
        // Optimistic UI: reflect the new value immediately so the menu
        // stays consistent while the debounce window runs out.
        cacheMaxSizeGB = clamped
        cacheMaxBytes = Int64(clamped) * 1024 * 1024 * 1024
        setCacheLimitTask?.cancel()
        setCacheLimitTask = Task { [weak self] in
            // Wait for the user to stop clicking. A new call cancels this
            // task; only the final settle reaches the daemon.
            try? await Task.sleep(for: MenuStatusModel.setCacheLimitDebounce)
            guard let self else { return }
            if Task.isCancelled { return }
            do {
                try await bridge.configSet(key: "cache.max_size_gb", value: String(clamped))
                Self.log.info("cache.max_size_gb set to \(clamped, privacy: .public) GB")
            } catch {
                Self.log.error("config.set cache.max_size_gb failed: \(error.localizedDescription, privacy: .public)")
            }
            refresh()
        }
    }

    /// Toggle anonymous telemetry and refresh.
    func setTelemetry(enabled: Bool) {
        Task { [weak self] in
            guard let self else { return }
            do {
                try await bridge.configSet(key: "telemetry", value: enabled ? "on" : "off")
            } catch {
                Self.log.error("config.set telemetry failed: \(error.localizedDescription, privacy: .public)")
            }
            refresh()
        }
    }

    /// Stage a new "max parallel uploads per account" value.
    ///
    /// Optimistically updates the published `netMaxUploads` so a Stepper
    /// in the Settings window tracks every click immediately, then
    /// debounces the IPC write the same way `setCacheLimitGB` does — only
    /// the final value reaches the daemon. Out-of-range values are clamped
    /// so a future UI change cannot ship an invalid value (the daemon
    /// would reject it anyway).
    func setNetMaxUploads(_ n: Int) {
        let clamped = max(1, min(16, n))
        netMaxUploads = clamped
        setNetUploadsTask?.cancel()
        setNetUploadsTask = Task { [weak self] in
            try? await Task.sleep(for: MenuStatusModel.setNetConcurrencyDebounce)
            guard let self else { return }
            if Task.isCancelled { return }
            do {
                try await bridge.configSet(
                    key: "net.max_concurrent_uploads_per_account",
                    value: String(clamped)
                )
                Self.log.info("net.max_concurrent_uploads_per_account set to \(clamped, privacy: .public)")
            } catch {
                Self.log.error("config.set net.max_concurrent_uploads_per_account failed: \(error.localizedDescription, privacy: .public)")
            }
            refresh()
        }
    }

    /// Stage a new "max parallel downloads per account" value. Symmetric
    /// to setNetMaxUploads.
    func setNetMaxDownloads(_ n: Int) {
        let clamped = max(1, min(32, n))
        netMaxDownloads = clamped
        setNetDownloadsTask?.cancel()
        setNetDownloadsTask = Task { [weak self] in
            try? await Task.sleep(for: MenuStatusModel.setNetConcurrencyDebounce)
            guard let self else { return }
            if Task.isCancelled { return }
            do {
                try await bridge.configSet(
                    key: "net.max_concurrent_downloads_per_account",
                    value: String(clamped)
                )
                Self.log.info("net.max_concurrent_downloads_per_account set to \(clamped, privacy: .public)")
            } catch {
                Self.log.error("config.set net.max_concurrent_downloads_per_account failed: \(error.localizedDescription, privacy: .public)")
            }
            refresh()
        }
    }

    /// Persist the daemon log level. The Picker fires this once per
    /// selection (no rapid bursts), so no debounce is needed.
    func setLogLevel(_ level: String) {
        // Optimistic UI: reflect the new value before the IPC round trip.
        logLevel = level
        Task { [weak self] in
            guard let self else { return }
            do {
                try await bridge.configSet(key: "log.level", value: level)
                Self.log.info("log.level set to \(level, privacy: .public)")
            } catch {
                Self.log.error("config.set log.level failed: \(error.localizedDescription, privacy: .public)")
            }
            refresh()
        }
    }
}
