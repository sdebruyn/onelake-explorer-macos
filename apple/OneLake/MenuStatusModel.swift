// MenuStatusModel.swift
// Observable model that fetches daemon status + account list via IPC
// and publishes the results for the menu-bar dropdown.
//
// The wire types (StatusInfo, AccountListInfo, AccountInfo, PausedWorkspaceInfo)
// live in apple/Shared/StatusTypes.swift so they compile into both targets.
//
// Refresh strategy (Phase 0):
//   - Triggered manually when the menu opens (see MenuBarView.onAppear).
//   - A lightweight timer fires every 10 s while the menu is shown so
//     the header line stays fresh without a dedicated push channel.
//   - On daemon-unreachable the model publishes isRunning = false so the
//     menu shows "Not running" instead of stale data.

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

    /// Fetch status + account list. Call this on menu open; safe to call
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
            let (status, list) = try await (statusFetch, listFetch)

            isRunning = true
            daemonVersion = status.daemonVersion
            offline = status.offline
            cacheBytes = status.cacheBytes
            cacheMaxBytes = status.cacheMaxBytes
            pausedWorkspaces = status.pausedWorkspaces
            accounts = list.accounts
            defaultAccount = list.defaultAccount
        } catch {
            // Daemon not running, or IPC failure — show degraded state.
            Self.log.warning("Daemon status fetch failed: \(error.localizedDescription, privacy: .public)")
            isRunning = false
            daemonVersion = ""
            accounts = []
            defaultAccount = ""
        }
    }
}
