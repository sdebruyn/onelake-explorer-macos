// OneLakeApp.swift
// SwiftUI entry point for the OneLake host application.
//
// In addition to hosting the single-window landing UI, the host app
// owns File Provider domain registration. Every time the app
// launches or returns to the foreground it asks the Go core for the
// current account list and calls `DomainSyncManager.reconcile()` so
// macOS's domain table matches.
//
// The reconciliation is best-effort: failures are logged but never
// surfaced as a modal. The user's mental model is "OneLake.app is
// open, my Fabric accounts show up in Finder"; if that breaks, the
// CLI's `ofem account` family is the recovery path.

import SwiftUI
import AppKit
import os.log

/// AppDelegate kept around purely to receive the
/// `applicationDidBecomeActive(_:)` and `applicationWillTerminate(_:)`
/// callbacks. SwiftUI lifecycle methods cover launch but not "user just
/// `Cmd+Tab`'d back into us", and re-running reconcile on focus catches
/// the case where the CLI added or removed an account while the host app
/// was inactive. ChangeWatcher is stopped on termination so the polling
/// loop unwinds cleanly.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let log = Logger(subsystem: "dev.debruyn.ofem", category: "app-delegate")

    func applicationDidBecomeActive(_ notification: Notification) {
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
        // Call stop() directly and synchronously. macOS terminates the process
        // immediately after this callback returns; a Task would never get a
        // chance to execute. ChangeWatcher.stop() is idempotent and
        // non-blocking — it cancels the polling Task and clears the reference.
        ChangeWatcher.shared.stop()
    }
}

/// Root `App` for the OneLake host. Owns a single `WindowGroup`
/// containing `ContentView`. Edit menu commands that don't apply to
/// this read-only landing screen are suppressed.
@main
struct OneLakeApp: App {
    private static let log = Logger(subsystem: "dev.debruyn.ofem", category: "app")

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        OneLakeApp.log.info("OneLake host app launching")
    }

    var body: some Scene {
        WindowGroup("OneLake") {
            ContentView()
                .task {
                    // Boot the Go core and reconcile the domain list
                    // as soon as the window appears. The bootstrap is
                    // idempotent, so calling it from `ContentView` and
                    // from the AppDelegate is harmless.
                    do {
                        try await DomainSyncManager.shared.reconcile()
                    } catch {
                        OneLakeApp.log.error(
                            "Initial domain reconcile failed: \(error.localizedDescription, privacy: .public)"
                        )
                    }
                    // Start polling the daemon for change events so Finder
                    // receives signalEnumerator calls when remote content
                    // changes. The watcher connects lazily; if the daemon is
                    // not yet running it will retry on each poll interval.
                    ChangeWatcher.shared.start()
                }
        }
        .commands {
            // The host app has nothing to undo/redo, paste into, or
            // find within. Hide the menu items so users don't see
            // greyed-out clutter.
            CommandGroup(replacing: .undoRedo) {}
            CommandGroup(replacing: .pasteboard) {}
            CommandGroup(replacing: .textEditing) {}
            CommandGroup(replacing: .textFormatting) {}
        }
    }
}
