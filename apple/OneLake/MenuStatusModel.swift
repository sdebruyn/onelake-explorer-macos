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
// Action methods (setDefault, signOut, cacheEvict, cacheClear, configSet*)
// are called from MenuBarView. They always call refresh() on completion so
// the menu reflects the new state immediately.

import Foundation
import os.log

// MARK: - MenuStatusModel

/// Published state for the menu-bar dropdown.
/// All mutations happen on the main actor; no locking needed.
@MainActor
final class MenuStatusModel: ObservableObject {
    private static let log = Logger(subsystem: "dev.debruyn.ofem", category: "menu-status")

    // MARK: Published

    @Published private(set) var isRunning: Bool = false
    @Published private(set) var daemonVersion: String = ""
    @Published private(set) var offline: Bool = false
    @Published private(set) var cacheBytes: Int64 = -1
    @Published private(set) var cacheMaxBytes: Int64 = 0
    @Published private(set) var pausedWorkspaces: [PausedWorkspaceInfo] = []
    @Published private(set) var accounts: [AccountInfo] = []
    @Published private(set) var defaultAccount: String = ""
    @Published private(set) var telemetryEnabled: Bool = true
    @Published private(set) var paths: StatusPaths = StatusPaths()

    // MARK: Computed conveniences

    var pausedCount: Int { pausedWorkspaces.count }

    var headerLabel: String {
        guard isRunning else { return "○ Not running" }
        if offline { return "⚠ Offline" }
        if pausedCount > 0 { return "⏸ \(pausedCount) paused" }
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

    // MARK: - Refresh

    /// Fetch status + account list + config snapshot. Call this on menu open;
    /// safe to call concurrently — a running fetch is cancelled and restarted.
    func refresh() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            await self?.doRefresh()
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

    /// Run LRU eviction and refresh.
    func cacheEvict() {
        Task { [weak self] in
            guard let self else { return }
            do {
                let after = try await bridge.cacheEvict()
                Self.log.info("cache.evict done; bytes remaining: \(after, privacy: .public)")
            } catch {
                Self.log.error("cache.evict failed: \(error.localizedDescription, privacy: .public)")
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
}
