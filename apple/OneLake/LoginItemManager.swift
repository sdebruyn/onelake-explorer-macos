// LoginItemManager.swift
// Manages the daemon LaunchAgent via SMAppService (ServiceManagement).
//
// SMAppService is the sandbox-compatible replacement for legacy launchctl-
// based LaunchAgent management. It requires:
//   1. The daemon plist at Contents/Library/LaunchAgents/<label>.plist.
//   2. The Label in that plist to match the filename without ".plist".
//   3. The host app to be signed with a real Developer ID (or during
//      development, a paid-team provisioned signing identity).
//
// Registration state survives across reboots: once registered, launchd
// starts the daemon at every login without further action from the app.
// Unregistering removes it from launchd's per-login set.
//
// Verification gap: SMAppService.register() and .unregister() can only
// be runtime-verified in a SIGNED, INSTALLED app running in a real login
// session. The compile path (make apple-build-ci) does not run the app
// and cannot exercise these calls. See the PR body for the real-device
// checklist.

import AppKit
import Foundation
import ServiceManagement
import os.log

/// Manages the bundled daemon as a login-item LaunchAgent using SMAppService.
///
/// The singleton is accessed from the main actor only; all SMAppService
/// calls are synchronous and short (no I/O), so dispatching them on the
/// main thread is safe. The status property is refreshed on every call to
/// `refresh()` and on every register/unregister action so the menu item
/// checkmark stays accurate without a background timer.
@MainActor
final class LoginItemManager: ObservableObject {
    static let shared = LoginItemManager()

    private static let log = Logger(subsystem: "dev.debruyn.ofem", category: "login-item")

    /// The plist filename (without .plist) — must match the Label key in
    /// the bundled plist at Contents/Library/LaunchAgents/.
    private static let agentPlistName = "dev.debruyn.ofem.daemon"

    // MARK: Published

    /// True when the daemon LaunchAgent is registered with launchd via
    /// SMAppService (i.e. it will start at login). This is NOT the same as
    /// "daemon is currently running" — use MenuStatusModel.isRunning for that.
    @Published private(set) var isRegistered: Bool = false

    // MARK: Init

    private init() {
        refresh()
    }

    // MARK: - Status

    /// Re-read the SMAppService status and update `isRegistered`.
    /// Call this when the menu opens or after a register/unregister attempt.
    func refresh() {
        let svc = SMAppService.agent(plistName: Self.agentPlistName)
        isRegistered = (svc.status == .enabled)
        Self.log.debug(
            "SMAppService status for \(Self.agentPlistName, privacy: .public): \(svc.status.rawValue, privacy: .public)"
        )
    }

    // MARK: - Toggle

    /// Register or unregister the daemon LaunchAgent in one call.
    /// Errors are surfaced as an NSAlert rather than crashing.
    func toggle() {
        if isRegistered {
            unregister()
        } else {
            register()
        }
    }

    // MARK: - Register

    /// Register the daemon as a login-item LaunchAgent so it starts at
    /// every subsequent login and immediately on the first call.
    ///
    /// Real-device note: this call throws in three known situations:
    ///   • The app is not signed / not installed (SMError.notFound).
    ///   • The app was denied by the user in System Settings → Login Items.
    ///   • The plist Label does not match the filename or the plist is
    ///     missing from the bundle (SMError.invalidSignature / .notFound).
    func register() {
        let svc = SMAppService.agent(plistName: Self.agentPlistName)
        do {
            try svc.register()
            Self.log.info("SMAppService registered \(Self.agentPlistName, privacy: .public)")
        } catch {
            Self.log.error(
                "SMAppService register failed: \(error.localizedDescription, privacy: .public)"
            )
            showAlert(
                title: "Could Not Enable Open at Login",
                message: "The daemon LaunchAgent could not be registered: \(error.localizedDescription)\n\nIf this persists, check System Settings → General → Login Items and ensure OneLake is listed.",
                style: .warning
            )
        }
        refresh()
    }

    // MARK: - Unregister

    /// Remove the daemon from launchd's login-item set.
    /// The daemon process already running is NOT killed; it keeps running
    /// until the user quits the host app or the daemon exits naturally.
    func unregister() {
        let svc = SMAppService.agent(plistName: Self.agentPlistName)
        do {
            try svc.unregister()
            Self.log.info("SMAppService unregistered \(Self.agentPlistName, privacy: .public)")
        } catch {
            Self.log.error(
                "SMAppService unregister failed: \(error.localizedDescription, privacy: .public)"
            )
            showAlert(
                title: "Could Not Disable Open at Login",
                message: "The daemon LaunchAgent could not be unregistered: \(error.localizedDescription)",
                style: .warning
            )
        }
        refresh()
    }

    // MARK: - Alert helper

    private func showAlert(title: String, message: String, style: NSAlert.Style) {
        NSApplication.shared.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = style
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
