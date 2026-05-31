// MenuBarView.swift
// SwiftUI content for the menu-bar-extra dropdown.
//
// The dropdown is the "accounts surface" — pick an account, open it in
// Finder, sign out, add one. Global configuration knobs (cache size,
// telemetry, open at login, log level, parallel network) all live in
// the Settings window now, opened via SettingsLink in this menu.
//
// What used to live here and was moved to the Settings window:
//   • Cache submenu (storage limit Stepper, Clear Cache)
//   • Send Anonymous Telemetry toggle
//   • Open at Login toggle
//   • Open Logs Folder, Open Config File items
//
// "Open Config File" is gone entirely — users must never need to hand-
// edit the TOML file (the daemon owns it; everything actionable now
// lives in the Settings window). The Open Logs Folder affordance moved
// to the Advanced tab, where it's the natural neighbour of the log
// level Picker.

import AppKit
import SwiftUI
import os.log

struct MenuBarView: View {
    // The model is owned at the App level (OneLakeApp @StateObject) so
    // post-action refreshes are visible in both the icon label and the menu
    // without waiting for the next open. @ObservedObject observes but does
    // NOT take ownership — lifetime is managed by OneLakeApp.
    @ObservedObject var model: MenuStatusModel
    @Environment(\.openWindow) private var openWindow

    private static let log = Logger(subsystem: "dev.debruyn.ofem", category: "menubar-view")

    var body: some View {
        // Trigger a fetch every time the menu opens.
        Group {
            statusHeader
            Divider()
            accountRows
            Divider()
            preferencesItem
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

    // MARK: - Preferences

    /// SettingsLink (macOS 14+) is the supported way to open the SwiftUI
    /// `Settings { … }` scene from anywhere in a SwiftUI tree, including
    /// a MenuBarExtra dropdown on an LSUIElement app. The Cmd+, shortcut
    /// matches the system-wide convention.
    @ViewBuilder
    private var preferencesItem: some View {
        SettingsLink {
            Text("Preferences…")
        }
        .keyboardShortcut(",", modifiers: .command)
        // Brought to the front via a simultaneous tap on the SettingsLink:
        // SwiftUI does the open, then we activate the app so the window
        // is in front of whatever the user was looking at. The order is
        // important — activate() before open would target the wrong
        // process. simultaneousGesture fires alongside the underlying tap
        // without consuming it (which an .onTapGesture would).
        .simultaneousGesture(TapGesture().onEnded {
            NSApp.activate(ignoringOtherApps: true)
        })
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
