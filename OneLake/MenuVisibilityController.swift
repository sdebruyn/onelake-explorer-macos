// MenuVisibilityController.swift
// Drives MenuStatusModel's high-frequency (5s) refresh loop from the
// menu-bar dropdown's actual on-screen state (E3).
//
// Before this fix, MenuStatusModel.startAutoRefresh() ran unconditionally
// for the whole process lifetime: a 5 s timer that calls getEngineStatus
// per account, which runs an unindexed blobBytes() scan on the FPE side —
// paid continuously whether or not anyone was looking at the menu. The
// low-frequency background loop (MenuStatusModel.startBackgroundRefresh,
// started once at launch in OneLakeApp.swift) now covers the "ambient
// badge must keep self-healing" requirement on its own coarse cadence;
// this controller only needs to add the extra 5 s freshness while the
// dropdown is actually open.
//
// In its own file (rather than inline in OneLakeApp.swift) so it can be
// unit tested: OneLakeApp.swift carries @main and is excluded from the
// OneLakeHostTests target, but nothing else under OneLake/ is.

import AppKit
import os.log

// MARK: - Dependency protocol

/// The high-frequency-refresh surface `MenuVisibilityController` drives.
/// Implemented by `MenuStatusModel`; faked in tests so the depth-counter
/// logic (begin/end pairing, submenu nesting, underflow clamp) can be
/// verified without touching `MenuStatusModel.shared`'s real production
/// dependencies (Keychain-backed auth, XPC to the FPE).
@MainActor
protocol HighFrequencySurface: AnyObject {
    func surfaceBecameVisible()
    func surfaceBecameHidden()
}

extension MenuStatusModel: HighFrequencySurface {}

/// Starts/stops `MenuStatusModel`'s high-frequency refresh session based on
/// whether the menu-bar dropdown is actually on screen.
///
/// `MenuBarExtra(.menu)` gives SwiftUI no visibility callback (see the
/// comment in `MenuBarView`), but the dropdown is still a genuine `NSMenu`
/// under the hood, so AppKit's global menu-tracking notifications are the
/// signal used instead. `didBeginTracking`/`didEndTracking` fire for
/// *every* menu, including submenus opened while navigating the dropdown
/// (e.g. an account's submenu) — `trackingDepth` collapses those nested
/// begin/end pairs so the session only ends once the outermost menu has
/// actually closed, not every time a submenu closes back to its parent.
///
/// This app is `LSUIElement` with no traditional menu bar, so in practice
/// almost every tracked menu is our own dropdown or one of its submenus;
/// an incidental false positive (e.g. a text field's right-click menu in
/// Settings) just costs one extra high-frequency poll window, not a
/// correctness problem.
@MainActor
final class MenuVisibilityController {
    static let shared = MenuVisibilityController()

    private static let log = Logger(subsystem: ofemSubsystem, category: "menu-visibility")

    private var observers: [NSObjectProtocol] = []
    private let surface: any HighFrequencySurface

    /// Nesting depth of AppKit menu-tracking sessions currently open.
    /// Internal (not private) so tests can drive/inspect it directly.
    private(set) var trackingDepth = 0

    /// Production init targets the shared `MenuStatusModel`. Tests inject a
    /// fake `HighFrequencySurface` so the depth-counter logic can be
    /// verified in isolation.
    init(surface: (any HighFrequencySurface)? = nil) {
        self.surface = surface ?? MenuStatusModel.shared
    }

    /// Begin observing menu tracking. Call once at launch.
    func start() {
        let nc = NotificationCenter.default

        observers.append(nc.addObserver(
            forName: NSMenu.didBeginTrackingNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.trackingBegan() }
        })

        observers.append(nc.addObserver(
            forName: NSMenu.didEndTrackingNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.trackingEnded() }
        })
    }

    /// A menu (the dropdown or a submenu) started tracking. Internal (not
    /// private) so tests can verify the depth-counter logic directly.
    func trackingBegan() {
        trackingDepth += 1
        // Only the outermost begin (the root dropdown, not a submenu
        // re-entry) should start a new high-frequency session.
        guard trackingDepth == 1 else { return }
        surface.surfaceBecameVisible()
    }

    /// A menu (the dropdown or a submenu) stopped tracking. Internal (not
    /// private) so tests can verify the depth-counter logic directly.
    func trackingEnded() {
        guard trackingDepth > 0 else {
            // AppKit failed to pair this didEndTracking with a prior
            // didBeginTracking — observed around Spaces switches, Mission
            // Control, or screen lock. Clamp at zero rather than going
            // negative (which would silently require an extra begin before
            // the depth ever reaches 0 again). With the low-frequency
            // background loop in place, a depth stuck above 0 only means
            // extra high-frequency polling until the next real close, not a
            // permanent stall — but it's still worth knowing about.
            Self.log.debug("trackingEnded with depth already 0 — ignoring unpaired notification")
            return
        }
        trackingDepth -= 1
        guard trackingDepth == 0 else { return }
        surface.surfaceBecameHidden()
    }
}
