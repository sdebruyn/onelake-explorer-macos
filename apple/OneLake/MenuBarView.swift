// MenuBarView.swift
// SwiftUI content for the menu-bar-extra dropdown (Phase 2).
//
// Phase 2 additions on top of Phase 0:
//   - Per-account: Set as Default, Sign Out (with confirmation)
//   - Cache submenu: usage header, Free Up Space, Clear Cache (with confirmation)
//   - Send Anonymous Telemetry toggle
//   - Open Logs Folder, Open Config File
//
// Note on Open Logs / Open Config under sandbox:
//   The daemon's status.paths contains absolute paths under
//   ~/Library/Group Containers/group.dev.debruyn.ofem/ — the App Group
//   container the host app is entitled to access. NSWorkspace.shared.open(_:)
//   CAN open these paths from a sandboxed process when the path is inside
//   the app's reachable group container, because the sandbox automatically
//   grants access to App Group container contents (no additional entitlement
//   beyond com.apple.security.application-groups is required). If the path
//   is empty or NSWorkspace fails (daemon not running yet, path doesn't exist),
//   we fall back to copying the path to the clipboard so the user can navigate
//   there manually.

import AppKit
import SwiftUI
import os.log

struct MenuBarView: View {
    @StateObject private var model = MenuStatusModel()

    private static let log = Logger(subsystem: "dev.debruyn.ofem", category: "menubar-view")

    var body: some View {
        // Trigger a fetch every time the menu opens.
        Group {
            statusHeader
            Divider()
            accountRows
            Divider()
            cacheSubmenu
            Divider()
            telemetryToggle
            openLogsItem
            openConfigItem
            Divider()
            aboutItem
            Divider()
            quitItem
        }
        .onAppear {
            model.refresh()
        }
    }

    // MARK: - Header

    @ViewBuilder
    private var statusHeader: some View {
        Text(model.headerLabel)
            .foregroundStyle(.secondary)
            // Disabled so clicking the header closes the menu without action.
            .disabled(true)
    }

    // MARK: - Account rows

    @ViewBuilder
    private var accountRows: some View {
        if model.accounts.isEmpty {
            Text(model.isRunning
                 ? "No accounts — add one with ofem account add"
                 : "Daemon not running")
                .foregroundStyle(.secondary)
                .disabled(true)
        } else {
            ForEach(model.accounts) { account in
                Menu {
                    AccountSubmenu(account: account, model: model)
                } label: {
                    // In a classic menu style, Spacer() has no effect — menu
                    // items don't stretch to fill the menu width. Append the
                    // default marker inline so it appears right after the alias.
                    if account.alias == model.defaultAccount {
                        Label(account.alias, systemImage: "checkmark")
                    } else {
                        Text(account.alias)
                    }
                }
            }
        }
    }

    // MARK: - Cache submenu

    @ViewBuilder
    private var cacheSubmenu: some View {
        Menu("Cache") {
            // Disabled header showing current usage; omit limit when 0.
            Text(cacheUsageLabel)
                .foregroundStyle(.secondary)
                .disabled(true)

            Divider()

            Button("Free Up Space") {
                model.cacheEvict()
            }
            .disabled(!model.isRunning)

            Button("Clear Cache…") {
                confirmCacheClear()
            }
            .disabled(!model.isRunning)
        }
    }

    private var cacheUsageLabel: String {
        guard model.isRunning else { return "Daemon not running" }
        guard model.cacheBytes >= 0 else { return "Measuring…" }
        let used = ByteCountFormatter.string(fromByteCount: model.cacheBytes, countStyle: .binary)
        if model.cacheMaxBytes > 0 {
            let max = ByteCountFormatter.string(fromByteCount: model.cacheMaxBytes, countStyle: .binary)
            return "\(used) of \(max) used"
        }
        return "\(used) used"
    }

    private func confirmCacheClear() {
        NSApplication.shared.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Clear Cache?"
        alert.informativeText = "All locally cached file blobs will be deleted. Files will be re-downloaded from OneLake on next access."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Clear Cache")
        alert.addButton(withTitle: "Cancel")
        // Default button is Cancel (less-intrusive, per project style).
        alert.buttons[1].keyEquivalent = "\r"
        alert.buttons[0].keyEquivalent = ""
        if alert.runModal() == .alertFirstButtonReturn {
            model.cacheClear()
        }
    }

    // MARK: - Telemetry toggle

    @ViewBuilder
    private var telemetryToggle: some View {
        Button {
            model.toggleTelemetry()
        } label: {
            // Checkmark appears when telemetry is enabled (the current state).
            if model.telemetryEnabled {
                Label("Send Anonymous Telemetry", systemImage: "checkmark")
            } else {
                Text("Send Anonymous Telemetry")
            }
        }
        .disabled(!model.isRunning)
    }

    // MARK: - Open Logs / Config

    @ViewBuilder
    private var openLogsItem: some View {
        Button("Open Logs Folder") {
            openPath(model.paths.logDir, isDirectory: true, label: "Logs folder")
        }
        .disabled(model.paths.logDir.isEmpty)
    }

    @ViewBuilder
    private var openConfigItem: some View {
        Button("Open Config File") {
            // Reveal the config file in Finder (selectFile) rather than
            // opening it, so the user sees it in context rather than
            // triggering a TOML file-type association.
            revealPath(model.paths.configFile, label: "Config file")
        }
        .disabled(model.paths.configFile.isEmpty)
    }

    /// Open `path` (a folder) in Finder via NSWorkspace.
    /// Falls back to clipboard if NSWorkspace refuses (sandbox caveat).
    private func openPath(_ path: String, isDirectory: Bool, label: String) {
        guard !path.isEmpty else { return }
        let url = URL(fileURLWithPath: path, isDirectory: isDirectory)
        // The path is inside ~/Library/Group Containers/group.dev.debruyn.ofem/,
        // which is accessible via the App Group entitlement. NSWorkspace can open
        // it directly from the sandbox without a security-scoped bookmark.
        if NSWorkspace.shared.open(url) {
            MenuBarView.log.info("Opened \(label, privacy: .public) at \(path, privacy: .public)")
        } else {
            // Fallback: copy the path to the clipboard so the user can paste
            // it into Finder's Go > Go to Folder… dialog.
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(path, forType: .string)
            MenuBarView.log.warning(
                "NSWorkspace.open failed for \(label, privacy: .public); path copied to clipboard"
            )
        }
    }

    /// Reveal `path` (a file) in Finder using activateFileViewerSelecting.
    /// Falls back to clipboard if the reveal fails.
    private func revealPath(_ path: String, label: String) {
        guard !path.isEmpty else { return }
        let url = URL(fileURLWithPath: path)
        NSWorkspace.shared.activateFileViewerSelecting([url])
        MenuBarView.log.info("Revealing \(label, privacy: .public) at \(path, privacy: .public)")
    }

    // MARK: - About

    @ViewBuilder
    private var aboutItem: some View {
        Button("About OFEM\(model.daemonVersion.isEmpty ? "" : " v\(model.daemonVersion)")…") {
            NSApplication.shared.orderFrontStandardAboutPanel(nil)
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
    }

    // MARK: - Quit

    @ViewBuilder
    private var quitItem: some View {
        Button("Quit OneLake") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q", modifiers: .command)
    }
}

// MARK: - Per-account submenu (Phase 2: Set as Default, Open in Finder, Sign Out)

private struct AccountSubmenu: View {
    let account: AccountInfo
    let model: MenuStatusModel

    private static let log = Logger(subsystem: "dev.debruyn.ofem", category: "menubar-view")

    var body: some View {
        // Set as Default — hidden when this account is already the default.
        if account.alias != model.defaultAccount {
            Button("Set as Default") {
                model.setDefaultAccount(alias: account.alias)
            }
        }

        Button("Open in Finder") {
            openInFinder()
        }

        Divider()

        Button("Sign Out…") {
            confirmSignOut()
        }
    }

    private func openInFinder() {
        // Mount path convention: ~/Library/CloudStorage/OneLake-<alias>/
        // See CLAUDE.md and docs/file-provider-domain-nesting.md.
        let expandedBase = NSString(
            string: "~/Library/CloudStorage/OneLake-\(account.alias)"
        ).expandingTildeInPath
        let url = URL(fileURLWithPath: expandedBase, isDirectory: true)

        // Create on demand — the directory may not exist yet if the File
        // Provider Extension has not registered the domain yet.
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        } catch {
            Self.log.warning(
                "createDirectory for \(url.path, privacy: .public) failed: \(error.localizedDescription, privacy: .public)"
            )
        }

        Self.log.info("Opening Finder at \(url.path, privacy: .public)")
        if !NSWorkspace.shared.open(url) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    private func confirmSignOut() {
        NSApplication.shared.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Sign Out \"\(account.alias)\"?"
        alert.informativeText = "The account's token will be removed from the keychain and the Finder mount will be unregistered."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Sign Out")
        alert.addButton(withTitle: "Cancel")
        // Default button is Cancel (less-intrusive, per project style).
        alert.buttons[1].keyEquivalent = "\r"
        alert.buttons[0].keyEquivalent = ""
        if alert.runModal() == .alertFirstButtonReturn {
            model.removeAccount(alias: account.alias)
        }
    }
}
