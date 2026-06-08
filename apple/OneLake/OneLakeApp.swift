// OneLakeApp.swift
// Menu-bar-only SwiftUI entry point for the OneLake host application.
//
// The app runs as a true agent (LSUIElement = true): no Dock icon, no
// window. The single scene is a MenuBarExtra using the classic dropdown
// style (menuBarExtraStyle(.menu)), available from macOS 14 Sonoma.
//
// Lifecycle:
//   - applicationDidFinishLaunching: initial domain reconcile + start
//     ChangeWatcher (moved here from the old ContentView .task).
//   - applicationDidBecomeActive: re-reconcile so accounts added while
//     the host was inactive appear in Finder without a restart.
//   - applicationWillTerminate: stop the ChangeWatcher poll loop.

import SwiftUI
import AppKit
import os.log

/// AppDelegate kept around to receive lifecycle callbacks that SwiftUI
/// scenes do not surface (becomeActive, willTerminate) and to perform
/// the initial boot sequence at launch.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let log = Logger(subsystem: "dev.debruyn.ofem", category: "app-delegate")

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.log.info("OneLake host app did finish launching")

        // One-shot login-item bootstrap: register the app as a login item
        // on the very first launch so it opens at login automatically after
        // a fresh Homebrew install. The Settings "Open at Login" toggle
        // remains the authoritative control for every subsequent launch.
        Task { @MainActor in
            LoginItemManager.shared.bootstrapIfNeeded()
        }

        // Initial reconcile + start the change-watcher poll loop. Mirrors
        // what the old ContentView .task did; now lives here so it fires
        // regardless of whether any window/scene becomes visible.
        Task { @MainActor in
            do {
                try await DomainSyncManager.shared.reconcile()
            } catch {
                let nsErr = error as NSError
                AppDelegate.log.error(
                    "Initial domain reconcile failed: \(error.localizedDescription, privacy: .public) [\(nsErr.domain, privacy: .public) \(nsErr.code)]"
                )
            }
            ChangeWatcher.shared.start()
        }

        // Start periodic status polling so the icon + menu reflect daemon
        // state immediately on launch and stay current — MenuBarExtra(.menu)
        // does not fire SwiftUI .onAppear on menu open, so a timer (not the
        // menu lifecycle) is what keeps the state fresh and self-healing.
        Task { @MainActor in
            MenuStatusModel.shared.startAutoRefresh()
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        // Re-reconcile whenever the app comes to the foreground so accounts
        // added or removed while the host was inactive are reflected in
        // the Finder sidebar promptly.
        AppDelegate.log.debug("applicationDidBecomeActive — triggering domain reconcile")
        Task { @MainActor in
            do {
                try await DomainSyncManager.shared.reconcile()
            } catch {
                let nsErr = error as NSError
                AppDelegate.log.error(
                    "Domain reconcile (becameActive) failed: \(error.localizedDescription, privacy: .public) [\(nsErr.domain, privacy: .public) \(nsErr.code)]"
                )
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // stop() is synchronous and non-blocking; a Task would never run
        // because macOS terminates the process immediately after this returns.
        ChangeWatcher.shared.stop()
    }
}

/// Root SwiftUI app — menu-bar agent only, no window, no Dock icon.
@main
struct OneLakeApp: App {
    private static let log = Logger(subsystem: "dev.debruyn.ofem", category: "app")

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    // Single shared model owned here (app lifetime). MenuBarView receives it
    // as @ObservedObject so it observes without taking ownership. Owning it
    // at the App level also lets the MenuBarExtra label view below read the
    // same published state, so the icon updates live after every action.
    @StateObject private var statusModel = MenuStatusModel.shared

    init() {
        OneLakeApp.log.info("OneLake host app launching")
    }

    var body: some Scene {
        // Classic dropdown style: renders SwiftUI content as a native menu.
        // Available from macOS 14 (our deployment target).
        MenuBarExtra {
            MenuBarView(model: statusModel)
        } label: {
            MenuBarIconView(state: statusModel.menuIconState)
        }
        .menuBarExtraStyle(.menu)

        // Add Account window — opened from MenuBarView via openWindow(id:).
        // The Window scene produces a single floating panel; the id matches
        // the string passed to openWindow. WindowStyle.titleBar is default
        // (non-resizable by the user); we constrain the frame in the view.
        Window("Add OneLake Account", id: "add-account") {
            AddAccountView()
        }
        .windowResizability(.contentSize)

        // The Settings scene: Cmd+, target, hosts the four config tabs
        // that replaced the per-knob menu items the dropdown used to
        // carry (Cache, Telemetry, Open at Login, Open Logs / Config).
        // SwiftUI generates the Preferences… menu item under the app
        // menu automatically; LSUIElement apps don't have an app menu,
        // so MenuBarView surfaces its own "Preferences…" entry via
        // SettingsLink — the macOS 14+ primitive that opens this scene
        // from anywhere in a SwiftUI tree, including a MenuBarExtra.
        Settings {
            SettingsView()
        }
    }
}

// MARK: - MenuBarIconView

/// Menu-bar label that shows the brand template image and overlays a small
/// SF Symbol badge when the daemon state is not normal.
///
/// States:
///   - normal      → plain brand icon (macOS tints it automatically)
///   - notRunning  → brand icon at reduced opacity (muted / disabled look)
///   - paused      → brand icon + pause.fill badge  (bottom-trailing)
///
/// The brand image is declared as a Template image in the asset catalogue
/// (template-rendering-intent = template) so macOS auto-tints it for
/// light/dark menu bars — no manual color handling needed here.
private struct MenuBarIconView: View {
    let state: MenuIconState

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            // Brand mono silhouette — template image, macOS tints it.
            Image("MenuBarIcon")
                .renderingMode(.template)
                .opacity(state == .notRunning ? 0.4 : 1.0)

            // Small badge overlaid at the bottom-trailing corner.
            // Visible only when the daemon reports a non-normal state.
            if let badge = badgeSystemName {
                Image(systemName: badge)
                    .font(.system(size: 7, weight: .bold))
                    // Solid fill so the badge reads clearly against the
                    // menu-bar background in both light and dark mode.
                    .symbolRenderingMode(.monochrome)
                    // Shift slightly so the badge overlaps the icon edge
                    // rather than sitting fully outside it.
                    .offset(x: 3, y: 3)
            }
        }
        // Accessibility label read by VoiceOver for the menu-bar button.
        .accessibilityLabel(accessibilityLabel)
    }

    private var badgeSystemName: String? {
        switch state {
        case .normal, .notRunning: return nil
        case .paused:              return "pause.fill"
        }
    }

    private var accessibilityLabel: String {
        switch state {
        case .normal:      return "OneLake"
        case .notRunning:  return "OneLake — not running"
        case .paused:      return "OneLake — paused"
        }
    }
}
