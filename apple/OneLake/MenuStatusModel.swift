// MenuStatusModel.swift
// Observable model that fetches account list + engine status
// and publishes the results for the menu-bar dropdown.
//
// Fase 7.3b-1: CoreBridge has been removed entirely. All state now comes
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

    /// `nonisolated` because `static let shared` initializers run on
    /// whatever thread first touches them — not guaranteed to be the
    /// main actor. The body only assigns literal defaults to stored
    /// properties, so no MainActor work is required at construction.
    nonisolated init() {}

    private static let log = Logger(subsystem: "dev.debruyn.ofem", category: "menu-status")

    // MARK: Published

    @Published private(set) var isRunning: Bool = false
    @Published private(set) var cacheBytes: Int64 = -1
    @Published private(set) var cacheMaxBytes: Int64 = 0
    /// User-editable LRU ceiling in whole gigabytes; the menubar Stepper
    /// reads and writes this. Mirrors `cacheMaxBytes` (which is the
    /// GB → bytes conversion used for the live used/limit math) but kept
    /// in GBs so the Stepper round-trips cleanly without losing precision.
    /// 0 means "unknown / not yet fetched"; once populated stays in [1, 100].
    @Published private(set) var cacheMaxSizeGB: Int = 0
    @Published private(set) var pausedWorkspaces: [PausedWorkspaceInfo] = []
    @Published private(set) var accounts: [AccountInfo] = []
    @Published private(set) var defaultAccount: String = ""
    @Published private(set) var telemetryEnabled: Bool = true

    /// Max parallel uploads per account (Settings → Network).
    @Published private(set) var netMaxUploads: Int = 0
    /// Max parallel downloads per account (Settings → Network).
    @Published private(set) var netMaxDownloads: Int = 0
    /// FPE log level (Settings → Advanced). One of "debug", "info", "warn", "error".
    @Published private(set) var logLevel: String = ""

    // MARK: Computed conveniences

    var pausedCount: Int { pausedWorkspaces.count }

    /// Icon state for the menu-bar label. Priority: not-running > paused > normal.
    var menuIconState: MenuIconState {
        if !isRunning { return .notRunning }
        if pausedCount > 0 { return .paused }
        return .normal
    }

    var headerLabel: String {
        guard isRunning else { return "○ Not running" }
        if pausedCount > 0 {
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
    private enum WriteKey: Hashable {
        case cacheMaxSize
        case netMaxUploads
        case netMaxDownloads
        case logLevel
        case telemetry
    }
    private var pendingWrites: Set<WriteKey> = []

    private func beginWrite(_ key: WriteKey) { pendingWrites.insert(key) }
    private func endWrite(_ key: WriteKey) { pendingWrites.remove(key) }

    /// Debounce window for setCacheLimitGB writes.
    static let setCacheLimitDebounce: Duration = .milliseconds(750)
    /// Debounce window for parallel uploads/downloads Steppers.
    static let setNetConcurrencyDebounce: Duration = .milliseconds(750)

    // MARK: - Refresh

    /// Fetch account list + engine status. Call this on menu open;
    /// safe to call concurrently — a running fetch is cancelled and restarted.
    func refresh() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            await self?.doRefresh()
        }
    }

    /// Refresh now, then repeatedly every `interval`.
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
        // Primary path: read accounts from SharedOfemAuth (config.toml).
        // Works whether or not any FPE domain is loaded.
        let nativeAccounts = SharedOfemAuth.shared.auth.listAccounts()
        let nativeDefault = SharedOfemAuth.shared.auth.defaultAccount() ?? ""
        isRunning = true
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

        do {
            let status = try await OfemFPEClient.shared.getEngineStatus(alias: firstAlias)

            if !pendingWrites.contains(.cacheMaxSize) {
                cacheBytes = status.cacheBytes
                cacheMaxBytes = status.cacheMaxBytes
                if status.cacheMaxSizeGB > 0 {
                    cacheMaxSizeGB = status.cacheMaxSizeGB
                }
            }
            if !pendingWrites.contains(.telemetry) {
                telemetryEnabled = status.telemetryEnabled
            }
            if status.netMaxUploads > 0, !pendingWrites.contains(.netMaxUploads) {
                netMaxUploads = status.netMaxUploads
            }
            if status.netMaxDownloads > 0, !pendingWrites.contains(.netMaxDownloads) {
                netMaxDownloads = status.netMaxDownloads
            }
            if !status.logLevel.isEmpty, !pendingWrites.contains(.logLevel) {
                logLevel = status.logLevel
            }
        } catch {
            // FPE not yet reachable — fields stay at last-known values or defaults.
            Self.log.debug(
                "Engine status fetch skipped (FPE not reachable): \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    // MARK: - Actions

    /// Make `alias` the default account and refresh.
    func setDefaultAccount(alias: String) {
        Task { [weak self] in
            guard let self else { return }
            do {
                try SharedOfemAuth.shared.auth.setDefaultAccount(alias: alias)
            } catch {
                Self.log.error("setDefaultAccount failed: \(error.localizedDescription, privacy: .public)")
            }
            refresh()
        }
    }

    /// Remove the account and drop the File Provider domain from Finder.
    func removeAccount(alias: String) {
        Task { [weak self] in
            guard let self else { return }
            do {
                try SharedOfemAuth.shared.auth.removeAccount(alias: alias)
                await DomainSyncManager.shared.removeDomain(alias: alias)
            } catch {
                Self.log.error("removeAccount failed: \(error.localizedDescription, privacy: .public)")
            }
            refresh()
        }
    }

    /// Wipe all cached blobs and refresh.
    func cacheClear() {
        Task { [weak self] in
            guard let self else { return }
            // Clear cache on each registered account's FPE domain.
            // Each domain has its own CacheStore keyed by its alias.
            for acc in accounts {
                do {
                    let remaining = try await OfemFPEClient.shared.clearCache(alias: acc.alias)
                    Self.log.info(
                        "clearCache(\(acc.alias, privacy: .public)): bytes remaining=\(remaining, privacy: .public)"
                    )
                } catch {
                    Self.log.error(
                        "clearCache(\(acc.alias, privacy: .public)) failed: \(error.localizedDescription, privacy: .public)"
                    )
                }
            }
            refresh()
        }
    }

    /// Stage a new cache-size limit (in whole gigabytes) for the FPE engine.
    ///
    /// Optimistically updates the published `cacheMaxSizeGB` so the
    /// Stepper visibly tracks every click, then debounces the actual XPC call.
    func setCacheLimitGB(_ gb: Int) {
        let clamped = max(1, min(100, gb))
        beginWrite(.cacheMaxSize)
        cacheMaxSizeGB = clamped
        cacheMaxBytes = Int64(clamped) * 1024 * 1024 * 1024
        setCacheLimitTask?.cancel()
        setCacheLimitTask = Task { [weak self] in
            try? await Task.sleep(for: MenuStatusModel.setCacheLimitDebounce)
            guard let self else { return }
            if Task.isCancelled { return }
            await self.writeConfigToAllAliases(key: "cache.max_size_gb", value: String(clamped))
            endWrite(.cacheMaxSize)
            refresh()
        }
    }

    /// Toggle anonymous telemetry and refresh.
    func setTelemetry(enabled: Bool) {
        beginWrite(.telemetry)
        telemetryEnabled = enabled
        Task { [weak self] in
            guard let self else { return }
            await writeConfigToAllAliases(
                key: "telemetry",
                value: enabled ? "on" : "off"
            )
            endWrite(.telemetry)
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
            try? await Task.sleep(for: MenuStatusModel.setNetConcurrencyDebounce)
            guard let self else { return }
            if Task.isCancelled { return }
            await writeConfigToAllAliases(
                key: "net.max_concurrent_uploads_per_account",
                value: String(clamped)
            )
            endWrite(.netMaxUploads)
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
            try? await Task.sleep(for: MenuStatusModel.setNetConcurrencyDebounce)
            guard let self else { return }
            if Task.isCancelled { return }
            await writeConfigToAllAliases(
                key: "net.max_concurrent_downloads_per_account",
                value: String(clamped)
            )
            endWrite(.netMaxDownloads)
            refresh()
        }
    }

    /// Persist the log level.
    func setLogLevel(_ level: String) {
        beginWrite(.logLevel)
        logLevel = level
        Task { [weak self] in
            guard let self else { return }
            await writeConfigToAllAliases(key: "log.level", value: level)
            endWrite(.logLevel)
            refresh()
        }
    }

    // MARK: - Private helpers

    /// Writes a config key/value pair through each account's FPE domain.
    ///
    /// Config is stored in a single config.toml, so writing through any
    /// one domain is sufficient. We fan out to all aliases anyway so the
    /// in-memory OfemConfigStore inside each FPE process is updated
    /// without waiting for the next time it reads the file from disk.
    private func writeConfigToAllAliases(key: String, value: String) async {
        // Read directly from SharedOfemAuth so this works even before the first
        // doRefresh() has populated the published `accounts` property — e.g. when
        // the user changes a setting immediately after app launch.
        let currentAccounts = SharedOfemAuth.shared.auth.listAccounts()
        for acc in currentAccounts {
            do {
                try await OfemFPEClient.shared.setConfig(
                    alias: acc.alias,
                    key: key,
                    value: value
                )
                Self.log.info(
                    "setConfig(\(acc.alias, privacy: .public)) key='\(key, privacy: .public)' applied"
                )
            } catch {
                Self.log.error(
                    "setConfig(\(acc.alias, privacy: .public)) key='\(key, privacy: .public)' failed: \(error.localizedDescription, privacy: .public)"
                )
            }
        }
    }
}
