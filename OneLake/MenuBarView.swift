// MenuBarView.swift
// SwiftUI content for the menu-bar-extra dropdown.
//
// The dropdown is the "accounts surface" — pick an account, open it in
// Finder, sign out, add one. Global configuration knobs (cache size,
// telemetry, open at login, log level, parallel network) all live in
// the Settings window now, opened via @Environment(\.openSettings) in
// openPreferences().
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
@preconcurrency import FileProvider
import os.log
import SwiftUI

struct MenuBarView: View {
    // The model is owned at the App level (OneLakeApp @State) so
    // post-action refreshes are visible in both the icon label and the menu
    // without waiting for the next open. This plain `let` observes (via
    // Observation) but does NOT take ownership — lifetime is managed by
    // OneLakeApp.
    let model: MenuStatusModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        // The `.menu` style MenuBarExtra does not fire SwiftUI.onAppear on
        // menu open — onAppear fires once at scene construction only. Periodic
        // refresh is owned by the auto-refresh timer in OneLakeApp. This
        // onAppear is intentionally absent; do not re-add it.
        Group {
            statusHeader
            // Surface the last action error inline so the user can see it
            // without a blocking modal (host-09). The item is only shown when
            // an error is set; it clears on the next successful action or refresh.
            if let error = model.lastActionError {
                Text("Error: \(error)")
                    .foregroundStyle(.red)
                    .font(.caption)
                    .disabled(true)
            }
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
        openWindow(id: ofemAddAccountWindowID)
        // Bring the window to the front; LSUIElement apps do not activate
        // automatically when a window is opened programmatically.
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Preferences

    /// Opens (or focuses) the Settings window.
    ///
    /// Strategy: `openSettings` (available from macOS 14) is the correct
    /// SwiftUI primitive for triggering the `Settings { }` scene. It creates
    /// the window on first use and reuses (focuses) it on subsequent calls,
    /// which satisfies both the "open" and "re-focus existing" requirements.
    ///
    /// `NSApp.sendAction(Selector("showSettingsWindow:"), …)` is unreliable in
    /// LSUIElement (menu-bar-only) processes: the app has no regular activation
    /// context and the action is swallowed before the Settings window is created.
    ///
    /// After calling `openSettings` we explicitly activate the app so the window
    /// comes to the foreground. `DockIconManager` picks up the resulting
    /// `NSWindow.didBecomeKeyNotification` and switches the activation policy to
    /// `.regular`, showing the Dock icon while the window is open.
    private var preferencesItem: some View {
        Button("Preferences…") {
            openPreferences()
        }
        .keyboardShortcut(",", modifiers: .command)
    }

    private func openPreferences() {
        openSettings()
        // Defer activation so it fires after SwiftUI has had a chance to
        // create and display the Settings window. On first open, openSettings()
        // posts through the scene machinery and returns before the window
        // exists; activating immediately would bring the app to the foreground
        // with no ordinary window visible yet. Deferring one main-actor turn
        // gives the window time to appear, ensuring it lands in front.
        // On subsequent calls (window already exists) the behavior is identical
        // to the synchronous form — the window is already visible and the Task
        // body runs at the very next opportunity.
        Task { @MainActor in
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    // MARK: - About

    private var aboutItem: some View {
        Button("About OFEM…") {
            AboutWindowController.shared.show()
        }
    }

    // MARK: - Quit

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
    // A plain `let` is the correct, safe, observation-aware choice here.
    // SwiftUI Views are structs; AppKit may retain them as part of an open
    // NSMenu, so `unowned` would trap if the model were ever deallocated.
    // The singleton lives for the process lifetime and Observation tracks
    // property reads through this reference correctly without @ObservedObject.
    let model: MenuStatusModel
    @Environment(\.openWindow) private var openWindow

    private static let log = Logger(subsystem: ofemSubsystem, category: "menubar-view")

    var body: some View {
        // Per-account status line: shows "Running" when healthy or a warning
        // label when the token cannot be acquired silently. Always rendered so
        // the submenu has a consistent status row regardless of auth state.
        // The warning state uses a leading SF Symbol glyph + primary color so
        // it remains legible in both light and dark mode and on both normal and
        // highlighted/selected rows.
        //
        // .allowsHitTesting(false) is used instead of .disabled(true): disabled
        // items in a MenuBarExtra(.menu) are rendered by AppKit which applies its
        // own dimming on selected rows regardless of the SwiftUI foreground style,
        // defeating the legibility fix. .allowsHitTesting(false) suppresses
        // interaction without triggering AppKit's disabled-item dimming, so
        // .primary/.secondary are respected on highlighted rows too.
        let needsSignIn = model.accountNeedsSignIn(alias: account.alias)
        Label(
            model.accountStatusLabel(alias: account.alias),
            systemImage: needsSignIn ? "exclamationmark.triangle" : ""
        )
        .foregroundStyle(needsSignIn ? .primary : .secondary)
        .allowsHitTesting(false)

        Divider()

        Button("Open in Finder") {
            openInFinder()
        }

        Divider()

        // "Sign In…" is only shown when this account's token cannot be
        // acquired silently. Hidden for healthy accounts to avoid confusion.
        // The ellipsis signals that the action opens an interactive browser flow.
        if needsSignIn {
            Button("Sign In…") {
                signInAgain()
            }
        }

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
        let rawID = DomainSyncManager.shared.domainIdentifier(for: account.alias)
        let domainID = NSFileProviderDomainIdentifier(rawValue: rawID)
        let domain = NSFileProviderDomain(identifier: domainID, displayName: account.alias)
        Task {
            await Self.revealDomain(domain, log: Self.log)
        }
    }

    /// Resolves the Finder-visible URL for `domain` via the File Provider
    /// framework and reveals it in Finder. Runs asynchronously; silently
    /// does nothing if the domain is not yet registered or the URL cannot
    /// be obtained (e.g. the FPE is not running).
    @MainActor
    private static func revealDomain(_ domain: NSFileProviderDomain, log: Logger) async {
        guard let manager = NSFileProviderManager(for: domain) else {
            log.notice("openInFinder: no manager for domain \(domain.identifier.rawValue, privacy: .public) — domain not registered")
            return
        }
        let url: URL
        do {
            url = try await manager.getUserVisibleURL(for: .rootContainer)
        } catch {
            log.notice("openInFinder: getUserVisibleURL failed for \(domain.identifier.rawValue, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return
        }
        log.info("Opening Finder at \(url.path, privacy: .private)")
        let accessed = url.startAccessingSecurityScopedResource()
        defer {
            if accessed { url.stopAccessingSecurityScopedResource() }
        }
        if !NSWorkspace.shared.open(url) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    private func signInAgain() {
        // Bring the app to the foreground so the MSAL browser sheet appears
        // in front (LSUIElement apps do not activate automatically).
        NSApplication.shared.activate(ignoringOtherApps: true)

        // Resolve the presenting window. MSAL's ASWebAuthenticationSession
        // needs a contentViewController from an NSWindow to anchor its sheet.
        // When no window is currently open (typical for a menu-bar-only app),
        // open the Add Account window as an anchor — the MSAL sheet will
        // overlay it immediately, so the user only sees the browser prompt.
        //
        // We try keyWindow first (e.g. Settings or About is already open),
        // then fall back to opening the Add Account window.
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            model.reSignIn(alias: account.alias, window: window)
        } else {
            // Open the Add Account window so there is an anchor NSWindow for MSAL.
            // Poll briefly for the window to become key; a single run-loop turn is
            // not guaranteed to be enough because AppKit window creation involves
            // layout passes and at least one display-link cycle before the window
            // becomes the key window (see NSWindow.didBecomeKeyNotification).
            openWindow(id: ofemAddAccountWindowID)
            let alias = account.alias
            Task { @MainActor in
                // Bounded poll: try up to ~10 × 50 ms = 500 ms for a key window.
                var resolved: NSWindow?
                for _ in 0 ..< 10 {
                    if let w = NSApp.keyWindow ?? NSApp.mainWindow {
                        resolved = w
                        break
                    }
                    try? await Task.sleep(for: .milliseconds(50))
                }
                if let window = resolved {
                    model.reSignIn(alias: alias, window: window)
                } else {
                    // No presenting window within the timeout. Surface a non-intrusive
                    // inline error so the user knows the action did not proceed and
                    // can retry by clicking "Sign In…" once more.
                    Self.log.warning(
                        "signInAgain: no presentable window after openWindow — surfacing error"
                    )
                    model.setSignInWindowError()
                }
            }
        }
    }

    private func confirmSignOut() {
        // Activate so the alert appears in front.
        NSApplication.shared.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Sign out \"\(account.alias)\"?"
        alert.informativeText = "This removes the stored token and cached data for this account and unmounts it from Finder."
        alert.addButton(withTitle: "Cancel") // default → safe
        alert.addButton(withTitle: "Sign Out")
        alert.alertStyle = .warning
        if alert.runModal() == .alertSecondButtonReturn {
            model.removeAccount(alias: account.alias)
        }
    }
}
