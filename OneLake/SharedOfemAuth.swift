// SharedOfemAuth.swift
// Process-wide OfemAuth instance for the host app.
//
// The host app needs its own OfemAuth to drive interactive sign-in via
// InteractiveSignIn.acquireToken — MSAL's ASWebAuthenticationSession
// requires a UI window and therefore must run in the host process.
//
// The FPE has its own OfemAuth instance (inside OfemEngine). Both share
// the same MSAL Keychain group (OfemPaths.appGroupIdentifier) and read
// from the same config.toml in the App Group container, so tokens written
// during an interactive login in the host process are immediately visible
// to the FPE's silent-refresh path.

import AppKit
import Foundation
import MSAL
import OfemKit
import os.log

/// Process-wide OfemAuth + OfemConfigStore pair for the host app.
///
/// - The `configStore` reads from the same `config.toml` as the FPE.
/// - The `auth` instance drives interactive sign-in and persists account
///   metadata to the shared config after a successful flow.
///
/// Thread safety: `@MainActor` isolated — matches `OfemAuth`.
@MainActor
final class SharedOfemAuth {
    static let shared = SharedOfemAuth()

    private static let log = Logger(subsystem: "dev.debruyn.ofem", category: "shared-auth")

    let configStore: OfemConfigStore
    let auth: OfemAuth

    // Designated initialiser. `@MainActor` is inherited from the class;
    // `static let shared` therefore runs on the main actor (Swift guarantees
    // this for @MainActor-isolated static stored properties).
    //
    // OfemConfigStore() throws only on TOML parse failure. On a fresh install
    // the file doesn't exist and a default config is returned — never throws.
    // A corrupt TOML is a fatal misconfiguration; crashing early surfaces the
    // root cause in crash logs.
    init() {
        do {
            let store = try OfemConfigStore()
            self.configStore = store
            self.auth = OfemAuth(configStore: store)
        } catch {
            fatalError("SharedOfemAuth: OfemConfigStore init failed: \(error)")
        }
    }

    // MARK: - Interactive sign-in

    /// Runs the full interactive sign-in flow for a new account.
    ///
    /// 1. Calls `InteractiveSignIn.acquireToken` — opens the Microsoft
    ///    login page via ASWebAuthenticationSession in the host process.
    /// 2. Assigns the user-chosen `alias` to the returned account.
    /// 3. Persists the account to config.toml via `OfemAuth.addAccount`.
    ///
    /// Returns an `XPCAccountInfo` the caller can relay to the FPE via XPC
    /// so the FPE can register the domain without re-reading config.
    ///
    /// - Parameters:
    ///   - alias:    User-chosen short name (e.g. "work"). Must be unique.
    ///   - tenant:   Optional Entra tenant GUID or domain; nil or "" = common.
    ///   - clientID: Optional Entra App Registration GUID; nil or "" = built-in.
    ///   - window:   The NSWindow that anchors the ASWebAuthenticationSession sheet.
    func signIn(
        alias: String,
        tenant: String?,
        clientID: String?,
        window: NSWindow
    ) async throws -> XPCAccountInfo {
        let trimmedAlias = alias.trimmingCharacters(in: .whitespaces)
        try AccountAlias.validate(trimmedAlias)

        let effectiveClientID = clientID.flatMap { $0.isEmpty ? nil : $0 } ?? ofemEntraClientID
        let tenantHint: String? = tenant.flatMap { $0.isEmpty ? nil : $0 }

        // MSALWebviewParameters requires a presenting view controller. The
        // "Add Account" window's contentViewController is always non-nil
        // while the sheet is open; force-unwrap is safe here.
        guard let parentVC = window.contentViewController else {
            throw SharedOfemAuthError.noViewController
        }
        let webviewParams = MSALWebviewParameters(authPresentationViewController: parentVC)
        webviewParams.webviewType = .default

        let result = try await InteractiveSignIn.acquireToken(
            clientID: effectiveClientID,
            tenantHint: tenantHint,
            webviewParams: webviewParams,
            cacheStrategy: .msalKeychain
        )

        // Assign the user-chosen alias and optional custom clientID.
        var account = result.account
        account.alias = trimmedAlias
        if let cid = clientID, !cid.isEmpty {
            account.clientID = cid
        }

        // Persist to config.toml (shared with FPE via App Group container).
        try await auth.addAccount(account)

        Self.log.info(
            "SharedOfemAuth.signIn: signed in alias=\(trimmedAlias, privacy: .public) user=\(account.username, privacy: .private)"
        )

        return XPCAccountInfo(
            alias: trimmedAlias,
            username: account.username,
            tenantId: account.tenantID,
            tenantName: account.tenantName ?? ""
        )
    }
}

// MARK: - Errors

enum SharedOfemAuthError: Error, CustomStringConvertible {
    case noViewController

    var description: String {
        switch self {
        case .noViewController:
            return "SharedOfemAuth: no presenting view controller on window"
        }
    }
}
