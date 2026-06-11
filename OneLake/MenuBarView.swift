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
// Account list and status are sourced from SharedOfemAuth (config.toml).
// The menu shows account-scoped actions; hasAccounts drives controls.

import AppKit
import SwiftUI
import os.log

// MARK: - MountPathResolver

/// Resolves the on-disk mount path for a File Provider domain by alias.
///
/// The host app is sandboxed, so `NSHomeDirectory()` and `expandingTildeInPath`
/// return the App Sandbox container path, not the real user home. We read the
/// passwd record directly via `getpwuid(getuid())` to get the real `$HOME`.
/// This logic is extracted here (away from the View) so it can be unit-tested.
enum MountPathResolver {
    /// Returns the real user home directory, bypassing the App Sandbox.
    static func realHomeDirectory() -> String {
        if let pw = getpwuid(getuid()), let cstr = pw.pointee.pw_dir {
            return String(cString: cstr)
        }
        return NSHomeDirectory()
    }

    /// Returns the Finder-visible mount path for the given alias.
    ///
    /// Convention: `~/Library/CloudStorage/OneLake-<alias>/`
    /// (see CLAUDE.md mount-path section).
    static func mountURL(alias: String) -> URL {
        let home = realHomeDirectory()
        return URL(
            fileURLWithPath: "\(home)/Library/CloudStorage/OneLake-\(alias)",
            isDirectory: true
        )
    }
}

struct MenuBarView: View {
    // The model is owned at the App level (OneLakeApp @StateObject) so
    // post-action refreshes are visible in both the icon label and the menu
    // without waiting for the next open. @ObservedObject observes but does
    // NOT take ownership — lifetime is managed by OneLakeApp.
    @ObservedObject var model: MenuStatusModel
    @Environment(\.openWindow) private var openWindow

    private static let log = Logger(subsystem: "dev.debruyn.ofem", category: "menubar-view")

    var body: some View {
        // The `.menu` style MenuBarExtra does not fire SwiftUI.onAppear on
        // menu open — onAppear fires once at scene construction only. Periodic
        // refresh is owned by the auto-refresh timer in OneLakeApp. This
        // onAppear is intentionally absent; do not re-add it.
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
            // Empty state (no accounts yet): guide the user to add the first.
            Button("Add Account…") {
                openAddAccountWindow()
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
            // Always-visible item so existing users can add more accounts.
            Button("Add Account…") {
                openAddAccountWindow()
            }
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
    ///
    /// Note: `simultaneousGesture` is intentionally absent. With
    /// `menuBarExtraStyle(.menu)` the content is rendered as NSMenuItems and
    /// SwiftUI gesture recognisers are not delivered — the gesture was dead
    /// in practice. Settings activation is handled by the scene machinery.
    @ViewBuilder
    private var preferencesItem: some View {
        SettingsLink {
            Text("Preferences…")
        }
        .keyboardShortcut(",", modifiers: .command)
    }

    // MARK: - About

    @ViewBuilder
    private var aboutItem: some View {
        Button("About OFEM…") {
            AboutWindowController.shared.show()
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
        // Delegate path resolution to MountPathResolver so the logic is
        // testable and the sandbox-safe getpwuid trick lives in one place.
        let url = MountPathResolver.mountURL(alias: account.alias)
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
