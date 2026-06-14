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
/// Thread safety: `@MainActor` isolated — the interactive sign-in path
/// (`MSALWebviewParameters`, `ASWebAuthenticationSession`) is UI-bound and
/// must stay on the main actor. `OfemAuth` itself is a Swift actor that
/// runs off the main thread; method calls to it from here are `await`ed
/// and hop to its own executor automatically.
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
    /// 2. Uses `InteractiveSignInResult.commit(alias:to:)` to atomically
    ///    transfer any scratch blob and persist the account via `OfemAuth`.
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

        let result: InteractiveSignInResult
        do {
            result = try await InteractiveSignIn.acquireToken(
                clientID: effectiveClientID,
                tenantHint: tenantHint,
                webviewParams: webviewParams,
                cacheStrategy: .msalKeychain
            )
        } catch let nsError as NSError where nsError.domain == "MSALErrorDomain" {
            Self.log.error(
                "SharedOfemAuth.signIn: MSAL error domain=\(nsError.domain, privacy: .public) code=\(nsError.code, privacy: .public) userInfo=\(nsError.userInfo, privacy: .public)"
            )
            throw nsError
        }

        // Assign the optional custom clientID to the account before committing.
        var accountToCommit = result
        if let cid = clientID, !cid.isEmpty {
            accountToCommit.account.clientID = cid
        }

        // commit(alias:to:) atomically transfers any scratch blob (not needed
        // here since we use .msalKeychain) and calls auth.addAccount.
        try await accountToCommit.commit(alias: trimmedAlias, to: auth)

        let account = accountToCommit.account
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
