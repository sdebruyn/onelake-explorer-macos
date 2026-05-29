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
//   - applicationDidBecomeActive: re-reconcile so CLI-added accounts
//     appear in Finder without a restart.
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
        // Initial reconcile + start the change-watcher poll loop. Mirrors
        // what the old ContentView .task did; now lives here so it fires
        // regardless of whether any window/scene becomes visible.
        Task { @MainActor in
            do {
                try await DomainSyncManager.shared.reconcile()
            } catch {
                AppDelegate.log.error(
                    "Initial domain reconcile failed: \(error.localizedDescription, privacy: .public)"
                )
            }
            ChangeWatcher.shared.start()
        }

        // Kick off an initial status fetch so the icon reflects state
        // immediately on launch rather than waiting for the first menu open.
        Task { @MainActor in
            MenuStatusModel.shared.refresh()
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        // Re-reconcile whenever the app comes to the foreground so accounts
        // added or removed via the CLI while the host was inactive are
        // reflected in the Finder sidebar promptly.
        AppDelegate.log.debug("applicationDidBecomeActive — triggering domain reconcile")
        Task { @MainActor in
            do {
                try await DomainSyncManager.shared.reconcile()
            } catch {
                AppDelegate.log.error(
                    "Domain reconcile (becameActive) failed: \(error.localizedDescription, privacy: .public)"
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
    }
}

// MARK: - MenuBarIconView

/// Menu-bar label that shows the brand template image and overlays a small
/// SF Symbol badge when the daemon state is not normal.
///
/// States:
///   - normal      → plain brand icon (macOS tints it automatically)
///   - notRunning  → brand icon at reduced opacity (muted / disabled look)
///   - offline     → brand icon + wifi.slash badge (bottom-trailing)
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
        case .offline:             return "wifi.slash"
        case .paused:              return "pause.fill"
        }
    }

    private var accessibilityLabel: String {
        switch state {
        case .normal:      return "OneLake"
        case .notRunning:  return "OneLake — not running"
        case .offline:     return "OneLake — offline"
        case .paused:      return "OneLake — paused"
        }
    }
}
