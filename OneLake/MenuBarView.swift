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
import FileProvider
import SwiftUI
import os.log

struct MenuBarView: View {
    // The model is owned at the App level (OneLakeApp @StateObject) so
    // post-action refreshes are visible in both the icon label and the menu
    // without waiting for the next open. @ObservedObject observes but does
    // NOT take ownership — lifetime is managed by OneLakeApp.
    @ObservedObject var model: MenuStatusModel
    @Environment(\.openWindow) private var openWindow

    private static let log = Logger(subsystem: ofemSubsystem, category: "menubar-view")

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
        openWindow(id: ofemAddAccountWindowID)
        // Bring the window to the front; LSUIElement apps do not activate
        // automatically when a window is opened programmatically.
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Preferences

    /// Opens (or focuses) the Settings window.
    ///
    /// Strategy: `NSApp.sendAction(_:to:from:)` with the private
    /// `showSettingsWindow:` selector is the documented-by-convention way to
    /// trigger the SwiftUI `Settings` scene. SwiftUI creates the window the
    /// first time and reuses it on subsequent calls, so this doubles as a
    /// focus action when the window is already open. Calling
    /// `NSApp.activate(ignoringOtherApps: true)` afterwards ensures the app
    /// comes to the foreground even when it is currently in `.accessory`
    /// policy (LSUIElement) — without this the window appears but stays
    /// behind other apps.
    ///
    /// `SettingsLink` was the previous implementation but it does not
    /// activate the app on an LSUIElement process, so a window that fell
    /// behind other apps could not be raised by clicking "Preferences…" again.
    @ViewBuilder
    private var preferencesItem: some View {
        Button("Preferences…") {
            openPreferences()
        }
        .keyboardShortcut(",", modifiers: .command)
    }

    private func openPreferences() {
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        NSApp.activate(ignoringOtherApps: true)
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
    // @ObservedObject is the correct, safe, observation-aware choice here.
    // SwiftUI Views are structs; AppKit may retain them as part of an open
    // NSMenu, so `unowned` would trap if the model were ever deallocated.
    // The singleton lives for the process lifetime but the semantics are
    // safer and change observation works correctly with @ObservedObject.
    @ObservedObject var model: MenuStatusModel
    @Environment(\.openWindow) private var openWindow

    private static let log = Logger(subsystem: ofemSubsystem, category: "menubar-view")

    var body: some View {
        // Show an auth-error callout when this account's token cannot be
        // acquired silently. Displayed above the action buttons so it is
        // the first thing the user reads when opening the per-account submenu.
        if model.accountNeedsSignIn(alias: account.alias) {
            Text("Sign-in required")
                .foregroundStyle(.orange)
                .disabled(true)
            Divider()
        }

        Button("Open in Finder") {
            openInFinder()
        }

        Divider()

        // "Sign in again" refreshes the MSAL tokens for this account via the
        // same two-step interactive browser flow used at first sign-in. Always
        // shown (harmless when the account is healthy — it just refreshes consent)
        // to avoid menu-state churn from showing/hiding it based on needsSignIn.
        Button("Sign In Again…") {
            signInAgain()
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
        log.info("Opening Finder at \(url.path, privacy: .public)")
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
                    // can retry by clicking "Sign In Again…" once more.
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
        alert.addButton(withTitle: "Cancel")        // default → safe
        alert.addButton(withTitle: "Sign Out")
        alert.alertStyle = .warning
        if alert.runModal() == .alertSecondButtonReturn {
            model.removeAccount(alias: account.alias)
        }
    }
}
