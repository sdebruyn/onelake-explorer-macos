// MenuBarView.swift
// SwiftUI content for the menu-bar-extra dropdown.
//
// Phase 0: status header + per-account submenus (Open in Finder), About, Quit.
// Phase 2 additions: Set as Default, Sign Out, Cache submenu, Telemetry toggle,
//                    Open Logs Folder, Open Config File.
// Phase 1 addition: Open at Login toggle (SMAppService daemon LaunchAgent).

import AppKit
import SwiftUI
import os.log

struct MenuBarView: View {
    // The model is owned at the App level (OneLakeApp @StateObject) so
    // post-action refreshes are visible in both the icon label and the menu
    // without waiting for the next open. @ObservedObject observes but does
    // NOT take ownership — lifetime is managed by OneLakeApp.
    @ObservedObject var model: MenuStatusModel
    // LoginItemManager is a pre-existing singleton — @ObservedObject does not
    // own its lifetime, @StateObject would redundantly wrap the shared ref.
    @ObservedObject private var loginItem = LoginItemManager.shared
    @Environment(\.openWindow) private var openWindow

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
            openAtLoginToggle
            Divider()
            openLogsItem
            openConfigItem
            Divider()
            aboutItem
            Divider()
            quitItem
        }
        .onAppear {
            model.refresh()
            loginItem.refresh()
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
            if model.isRunning {
                // Empty state: guide the user to add their first account.
                Button("Add Account…") {
                    openAddAccountWindow()
                }
            } else {
                Text("Daemon not running")
                    .foregroundStyle(.secondary)
                    .disabled(true)
            }
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
            // Always-visible item so existing users can add more
            // accounts at any time.
            Button("Add Account…") {
                openAddAccountWindow()
            }
            .disabled(!model.isRunning)
        }
    }

    private func openAddAccountWindow() {
        openWindow(id: "add-account")
        // Bring the window to the front; LSUIElement apps do not activate
        // automatically when a window is opened programmatically.
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Cache submenu

    @ViewBuilder
    private var cacheSubmenu: some View {
        Menu("Cache") {
            // Disabled informational header — shows current usage vs limit.
            Text(cacheUsageLabel)
                .foregroundStyle(.secondary)
                .disabled(true)

            Divider()

            // Editable upper bound. Stepper (rather than TextField) keeps
            // input constrained to a valid whole-GB integer — users cannot
            // type "asdf" or "-5" — and matches the natural mental model
            // for a disk-size knob. Writes are debounced inside the model
            // so racking up many clicks fires only one IPC call.
            Stepper(
                value: Binding(
                    get: { model.cacheMaxSizeGB > 0 ? model.cacheMaxSizeGB : 10 },
                    set: { model.setCacheLimitGB($0) }
                ),
                in: 1...100,
                step: 1
            ) {
                Text("Limit: \(model.cacheMaxSizeGB > 0 ? "\(model.cacheMaxSizeGB) GB" : "—")")
            }
            .disabled(!model.isRunning)

            Button("Clear Cache…") {
                confirmCacheClear()
            }
            .disabled(!model.isRunning)
        }
    }

    /// "3.2 GB of 10 GB used". Falls back to "Cache size unknown" until
    /// the first refresh lands.
    ///
    /// Uses ByteCountFormatter with `.useGB` for the "used" side because
    /// the live cache size is byte-precision (the daemon reports it via
    /// `du`-style math, fractional). The limit side reads directly from
    /// the user's GB setting so it never wobbles between rounding modes.
    private var cacheUsageLabel: String {
        guard model.cacheBytes >= 0 else { return "Cache size unknown" }
        let usedFormatter = ByteCountFormatter()
        usedFormatter.allowedUnits = [.useGB]
        usedFormatter.countStyle = .binary
        usedFormatter.allowsNonnumericFormatting = false
        let used = usedFormatter.string(fromByteCount: model.cacheBytes)
        if model.cacheMaxSizeGB > 0 {
            return "\(used) of \(model.cacheMaxSizeGB) GB used"
        }
        return "\(used) used"
    }

    private func confirmCacheClear() {
        // Activate the app so the alert appears in front of everything.
        NSApplication.shared.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Clear all cached data?"
        alert.informativeText = "This removes all locally cached OneLake blobs. Files will be re-downloaded from OneLake on next access."
        alert.addButton(withTitle: "Cancel")          // default → safe
        alert.addButton(withTitle: "Clear Cache")
        alert.alertStyle = .warning
        if alert.runModal() == .alertSecondButtonReturn {
            model.cacheClear()
        }
    }

    // MARK: - Telemetry toggle

    @ViewBuilder
    private var telemetryToggle: some View {
        Button {
            model.setTelemetry(enabled: !model.telemetryEnabled)
        } label: {
            // A checkmark next to the label replicates an NSMenuItem's state
            // toggle in SwiftUI menu style — Label with "checkmark" is the
            // idiomatic way to show a checked state.
            if model.telemetryEnabled {
                Label("Send Anonymous Telemetry", systemImage: "checkmark")
            } else {
                Text("Send Anonymous Telemetry")
            }
        }
        .disabled(!model.isRunning)
    }

    // MARK: - Open at Login

    /// Toggle the daemon LaunchAgent registration via SMAppService.
    /// The checkmark reflects whether the daemon is registered for login
    /// (not whether it is currently running — isRunning tracks that separately).
    @ViewBuilder
    private var openAtLoginToggle: some View {
        Button {
            loginItem.toggle()
        } label: {
            if loginItem.isRegistered {
                Label("Open at Login", systemImage: "checkmark")
            } else {
                Text("Open at Login")
            }
        }
    }

    // MARK: - Open Logs / Config

    @ViewBuilder
    private var openLogsItem: some View {
        Button("Open Logs Folder") {
            openPath(model.paths.logDir, fallbackDescription: "logs directory")
        }
        .disabled(!model.isRunning || model.paths.logDir.isEmpty)
    }

    @ViewBuilder
    private var openConfigItem: some View {
        Button("Open Config File") {
            openConfigFile(model.paths.configFile)
        }
        .disabled(!model.isRunning || model.paths.configFile.isEmpty)
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

    // MARK: - Path helpers

    /// Open a directory path in Finder via NSWorkspace.
    /// The path lives under the App Group container
    /// (~/Library/Group Containers/<ofemAppGroupIdentifier>/) so the sandboxed
    /// app is entitled to open it. If the directory does not yet exist (e.g.
    /// the daemon has not written any logs yet) fall back to copying the path
    /// to the clipboard so the user can navigate there manually.
    private func openPath(_ path: String, fallbackDescription: String) {
        guard !path.isEmpty else { return }
        let url = URL(fileURLWithPath: path, isDirectory: true)
        if NSWorkspace.shared.open(url) {
            Self.log.info("Opened \(fallbackDescription) at \(path, privacy: .public)")
            return
        }
        // Directory does not exist yet — copy path to clipboard as fallback.
        Self.log.warning("\(fallbackDescription) not found at \(path, privacy: .public); copying to clipboard")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
    }

    /// Open the config file. Unlike a directory, NSWorkspace.open on a file
    /// launches the associated editor (e.g. TextEdit for .toml). If the file
    /// does not exist yet, fall back to opening its parent directory instead.
    private func openConfigFile(_ path: String) {
        guard !path.isEmpty else { return }
        let url = URL(fileURLWithPath: path)
        if NSWorkspace.shared.open(url) {
            Self.log.info("Opened config file at \(path, privacy: .public)")
            return
        }
        // File may not exist if the daemon hasn't written it yet; open parent.
        let parentURL = url.deletingLastPathComponent()
        if NSWorkspace.shared.open(parentURL) {
            Self.log.info("Config file absent; opened parent dir \(parentURL.path, privacy: .public)")
            return
        }
        // Last resort — copy path to clipboard.
        Self.log.warning("Config file not accessible at \(path, privacy: .public); copying to clipboard")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
    }
}

// MARK: - Per-account submenu

private struct AccountSubmenu: View {
    let account: AccountInfo
    // Unowned reference to the shared singleton; its lifetime is tied to the
    // app process (owned by OneLakeApp via @StateObject), so unowned is safe.
    unowned let model: MenuStatusModel

    private static let log = Logger(subsystem: "dev.debruyn.ofem", category: "menubar-view")

    var body: some View {
        Button("Open in Finder") {
            openInFinder()
        }

        Divider()

        // "Set as Default" is hidden (replaced by the checkmark in the
        // parent label) when this account is already the default.
        if account.alias != model.defaultAccount {
            Button("Set as Default") {
                model.setDefaultAccount(alias: account.alias)
            }
        }

        Button("Sign Out…") {
            confirmSignOut()
        }
    }

    private func openInFinder() {
        // Mount path convention: ~/Library/CloudStorage/OneLake-<alias>/
        // See CLAUDE.md and docs/file-provider-domain-nesting.md.
        //
        // We cannot use `expandingTildeInPath` or `NSHomeDirectory()`
        // here: this app is sandboxed, so both resolve to the App
        // Sandbox container (~/Library/Containers/dev.debruyn.ofem/…),
        // not the real user home. Finder then opens an empty container
        // path that has nothing to do with the File Provider mount.
        // `getpwuid(getuid())->pw_dir` reads the passwd record directly
        // and returns the real $HOME, regardless of the sandbox.
        let realHome: String
        if let pw = getpwuid(getuid()), let cstr = pw.pointee.pw_dir {
            realHome = String(cString: cstr)
        } else {
            realHome = NSHomeDirectory()
        }
        let url = URL(
            fileURLWithPath: "\(realHome)/Library/CloudStorage/OneLake-\(account.alias)",
            isDirectory: true
        )

        Self.log.info("Opening Finder at \(url.path, privacy: .public)")
        // Skip createDirectory: the File Provider Extension owns the
        // mount path and the sandbox blocks us from writing there
        // anyway. NSWorkspace.shared.open hands off to Finder (a
        // separate, non-sandboxed process), which can read the mount
        // directly even when our app cannot.
        if !NSWorkspace.shared.open(url) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    private func confirmSignOut() {
        // Activate so the alert appears in front.
        NSApplication.shared.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Sign out \"\(account.alias)\"?"
        alert.informativeText = "This removes the stored token and cached data for this account and unmounts it from Finder."
        alert.addButton(withTitle: "Cancel")        // default → safe
        alert.addButton(withTitle: "Sign Out")
        alert.alertStyle = .warning
        if alert.runModal() == .alertSecondButtonReturn {
            model.removeAccount(alias: account.alias)
        }
    }
}
