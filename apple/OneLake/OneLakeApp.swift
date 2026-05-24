// OneLakeApp.swift
// SwiftUI entry point for the OneLake host application.
//
// The host app's job in Phase 1 is to provide a place for the user to
// land after launching from /Applications. It will grow into the
// account-management UI in Phase 2; for now it is a single window
// confirming the bundle is wired correctly and pointing users at the
// `~/Library/CloudStorage/` parent where each account's File Provider
// domain (`OneLake — <alias>`) will eventually appear.

import SwiftUI
import os.log

/// Root `App` for the OneLake host. Owns a single `WindowGroup`
/// containing `ContentView`. Edit menu commands that don't apply to
/// this read-only landing screen are suppressed.
@main
struct OneLakeApp: App {
    private static let log = Logger(subsystem: "dev.debruyn.ofem", category: "app")

    init() {
        OneLakeApp.log.info("OneLake host app launching")
    }

    var body: some Scene {
        WindowGroup("OneLake") {
            ContentView()
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
