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

    init() {
        OneLakeApp.log.info("OneLake host app launching")
    }

    var body: some Scene {
        // Classic dropdown style: renders SwiftUI content as a native menu.
        // Available from macOS 14 (our deployment target).
        MenuBarExtra {
            MenuBarView()
        } label: {
            // .template rendering mode tells macOS to tint the image to
            // match the menu-bar appearance (white in dark mode, black in
            // light mode). This is the SwiftUI equivalent of setting
            // isTemplate = true on an NSImage.
            Image(systemName: "externaldrive.connected.to.line.below")
                .renderingMode(.template)
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
