// MenuStatusModel.swift
// Observable model that fetches daemon status + account list + config via IPC
// and publishes the results for the menu-bar dropdown.
//
// Wire types (StatusInfo, AccountListInfo, AccountInfo, ConfigInfo, StatusPaths)
// live in apple/Shared/StatusTypes.swift so they compile into both targets.
//
// Refresh strategy:
//   - Triggered manually when the menu opens (see MenuBarView.onAppear).
//     No background timer: one fetch per open keeps IPC traffic minimal.
//   - On daemon-unreachable the model publishes isRunning = false so the
//     menu shows "Not running" instead of stale data.
//   - Mutating actions (setDefault, signOut, cacheEvict, cacheClear,
//     configSet) always call refresh() after success so the menu reflects
//     the new state immediately.

import AppKit
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
    @Published private(set) var paths: StatusPaths = .empty

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

    /// Fetch status + account list + config. Call on menu open; safe to call
    /// concurrently — a running fetch is cancelled and restarted.
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
            telemetryEnabled = config.telemetry
        } catch {
            // Daemon not running, or IPC failure — show degraded state.
            Self.log.warning("Daemon status fetch failed: \(error.localizedDescription, privacy: .public)")
            isRunning = false
            daemonVersion = ""
            accounts = []
            defaultAccount = ""
        }
    }

    // MARK: - Mutating actions

    /// Mark `alias` as the default account and refresh the menu.
    func setDefaultAccount(alias: String) {
        Task { [weak self] in
            guard let self = self else { return }
            do {
                try await self.bridge.setDefaultAccount(alias: alias)
                self.refresh()
            } catch {
                Self.log.error(
                    "account.setDefault(\(alias, privacy: .public)) failed: \(error.localizedDescription, privacy: .public)"
                )
                Self.showAlert(
                    title: "Could Not Set Default Account",
                    message: error.localizedDescription
                )
            }
        }
    }

    /// Remove the account identified by `alias`. After a successful removal,
    /// reconciles the File Provider domain list so the Finder entry disappears.
    func removeAccount(alias: String) {
        Task { [weak self] in
            guard let self = self else { return }
            do {
                try await self.bridge.removeAccount(alias: alias)
                // Reconcile the domain list so the Finder entry is removed.
                try await DomainSyncManager.shared.reconcile()
                self.refresh()
            } catch {
                Self.log.error(
                    "account.remove(\(alias, privacy: .public)) failed: \(error.localizedDescription, privacy: .public)"
                )
                Self.showAlert(
                    title: "Could Not Sign Out",
                    message: error.localizedDescription
                )
            }
        }
    }

    /// Evict blobs until the cache is within its size limit and refresh.
    func cacheEvict() {
        Task { [weak self] in
            guard let self = self else { return }
            do {
                try await self.bridge.cacheEvict()
                self.refresh()
            } catch {
                Self.log.error("cache.evict failed: \(error.localizedDescription, privacy: .public)")
                Self.showAlert(title: "Could Not Free Up Space", message: error.localizedDescription)
            }
        }
    }

    /// Delete all cached blobs and refresh.
    func cacheClear() {
        Task { [weak self] in
            guard let self = self else { return }
            do {
                try await self.bridge.cacheClear()
                self.refresh()
            } catch {
                Self.log.error("cache.clear failed: \(error.localizedDescription, privacy: .public)")
                Self.showAlert(title: "Could Not Clear Cache", message: error.localizedDescription)
            }
        }
    }

    /// Toggle telemetry and refresh.
    func toggleTelemetry() {
        let newValue = telemetryEnabled ? "off" : "on"
        Task { [weak self] in
            guard let self = self else { return }
            do {
                try await self.bridge.configSet(key: "telemetry", value: newValue)
                self.refresh()
            } catch {
                Self.log.error("config.set(telemetry) failed: \(error.localizedDescription, privacy: .public)")
                Self.showAlert(title: "Could Not Update Setting", message: error.localizedDescription)
            }
        }
    }

    // MARK: - Error presentation

    /// Show a minimal NSAlert. Activates the app first so the alert
    /// appears on top even when the menu is closed.
    private static func showAlert(title: String, message: String) {
        NSApplication.shared.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
