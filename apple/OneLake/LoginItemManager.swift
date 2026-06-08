// LoginItemManager.swift
// Manages the OneLake host app as a login item via SMAppService.
//
// SMAppService.mainApp registers the .app bundle itself as a login item
// so it launches at every subsequent login. This is the sandbox-compatible
// "Open at Login" mechanism available since macOS 13 Ventura.
//
// After the Swift migration (Fase 7.3b-2) there is no separate daemon
// LaunchAgent. The host app is the only process that needs to start at
// login; it in turn wakes the File Provider Extension via the standard
// NSFileProviderManager domain lifecycle.
//
// Verification note: SMAppService calls can only be runtime-verified in
// a signed, installed app running in a real login session. The CI unsigned
// build (make apple-build-ci) does not exercise these calls.

import AppKit
import Foundation
import ServiceManagement
import os.log

/// Manages the host app as a login item using SMAppService.mainApp.
///
/// The singleton is accessed from the main actor only; all SMAppService
/// calls are synchronous and short (no I/O).
@MainActor
final class LoginItemManager: ObservableObject {
    static let shared = LoginItemManager()

    private static let log = Logger(subsystem: "dev.debruyn.ofem", category: "login-item")

    // MARK: Published

    /// True when the OneLake app is registered as a login item with launchd
    /// (i.e. it will launch at the next login). Refreshed on every action.
    @Published private(set) var isRegistered: Bool = false

    // MARK: Init

    private init() {
        refresh()
    }

    // MARK: - Status

    /// Re-read the SMAppService status and update `isRegistered`.
    /// Call this when the menu opens or after a register/unregister attempt.
    func refresh() {
        isRegistered = (SMAppService.mainApp.status == .enabled)
        Self.log.debug(
            "SMAppService.mainApp status: \(SMAppService.mainApp.status.rawValue, privacy: .public)"
        )
    }

    // MARK: - First-launch bootstrap

    /// UserDefaults key that records whether we have already attempted the
    /// initial login-item registration. Stored in standard (per-app) defaults
    /// because this flag is only meaningful to the host app itself.
    private static let didBootstrapKey = "dev.debruyn.ofem.didAttemptInitialLoginItemRegistration"

    /// Register the app as a login item on the very first launch so it opens
    /// at login automatically after a fresh Homebrew install, without requiring
    /// the user to manually enable "Open at Login" in Settings first.
    ///
    /// The flag is set to `true` regardless of whether `register()` succeeds
    /// so that a user who explicitly denies the Login Items permission is not
    /// re-prompted on every subsequent launch.
    ///
    /// Failures are logged but not surfaced as an alert: this registration
    /// is automatic and unsolicited, so an error dialog would appear before
    /// the user has taken any action.
    ///
    /// After the first launch this is a no-op, so explicit user toggles in
    /// Settings are never overridden.
    func bootstrapIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: Self.didBootstrapKey) else {
            Self.log.debug("Initial login-item bootstrap already attempted — skipping")
            return
        }
        Self.log.info("First launch detected — attempting initial login-item registration")
        do {
            try SMAppService.mainApp.register()
            Self.log.info("SMAppService.mainApp bootstrap registration succeeded")
        } catch {
            // Intentionally silent: the user may have denied the Login Items
            // permission prompt that macOS just showed. No second dialog.
            Self.log.info(
                "SMAppService.mainApp bootstrap registration failed (will not retry): \(error.localizedDescription, privacy: .public)"
            )
        }
        refresh()
        UserDefaults.standard.set(true, forKey: Self.didBootstrapKey)
    }

    // MARK: - Toggle

    /// Register or unregister the app as a login item in one call.
    /// Errors are surfaced as an NSAlert rather than crashing.
    func toggle() {
        if isRegistered {
            unregister()
        } else {
            register()
        }
    }

    // MARK: - Register

    /// Register the app as a login item so it starts at every subsequent login.
    ///
    /// Real-device note: this call throws in two known situations:
    ///   - The app is not signed / not installed (SMError.notFound).
    ///   - The user has denied the Login Items permission in System Settings.
    func register() {
        do {
            try SMAppService.mainApp.register()
            Self.log.info("SMAppService.mainApp registered")
        } catch {
            Self.log.error(
                "SMAppService.mainApp register failed: \(error.localizedDescription, privacy: .public)"
            )
            showAlert(
                title: "Could Not Enable Open at Login",
                message: "OneLake could not be registered as a login item: \(error.localizedDescription)\n\nIf this persists, check System Settings → General → Login Items and ensure OneLake is listed.",
                style: .warning
            )
        }
        refresh()
    }

    // MARK: - Unregister

    /// Remove the app from the login-item set.
    func unregister() {
        do {
            try SMAppService.mainApp.unregister()
            Self.log.info("SMAppService.mainApp unregistered")
        } catch {
            Self.log.error(
                "SMAppService.mainApp unregister failed: \(error.localizedDescription, privacy: .public)"
            )
            showAlert(
                title: "Could Not Disable Open at Login",
                message: "OneLake could not be unregistered as a login item: \(error.localizedDescription)",
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
