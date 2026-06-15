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

    private static let log = Logger(subsystem: ofemSubsystem, category: "shared-auth")

    let configStore: OfemConfigStore
    let auth: OfemAuth

    // Designated initialiser. `@MainActor` is inherited from the class;
    // `static let shared` therefore runs on the main actor (Swift guarantees
    // this for @MainActor-isolated static stored properties).
    //
    // OfemConfigStore() throws only on TOML parse failure. On a fresh install
    // the file doesn't exist and a default config is returned — never throws.
    // If the TOML is corrupt, we degrade gracefully: back up the corrupt file,
    // reinitialise with defaults, and surface a non-blocking alert. We do NOT
    // crash (host-25): a fatalError here would trap the menu-bar agent in a
    // crash loop on every login with no recovery path for the user.
    init() {
        let paths = OfemPaths()
        var loadedStore: OfemConfigStore?
        var configError: Error?

        do {
            loadedStore = try OfemConfigStore()
        } catch {
            configError = error
            Self.log.error(
                "SharedOfemAuth: OfemConfigStore init failed (corrupt config.toml?): \(error.localizedDescription, privacy: .public)"
            )
            // Back up the corrupt file so data is not silently discarded.
            let configFile = paths.configFile
            let timestamp = Int(Date.now.timeIntervalSince1970)
            let backupURL = configFile.deletingLastPathComponent()
                .appendingPathComponent("config.toml.corrupt-\(timestamp)")
            do {
                try FileManager.default.moveItem(at: configFile, to: backupURL)
                Self.log.info(
                    "Moved corrupt config to \(backupURL.path(percentEncoded: false), privacy: .public)"
                )
            } catch {
                Self.log.warning(
                    "Could not back up corrupt config: \(error.localizedDescription, privacy: .public)"
                )
            }
            // Re-try: with the file gone OfemConfigStore returns defaults.
            loadedStore = try? OfemConfigStore()
        }

        // If the retry after backing up the corrupt file also fails, this is an
        // unrecoverable I/O state (e.g. the App Group container is missing
        // entirely). Log a fault and crash — this is fundamentally different from
        // a parse error and indicates a system-level misconfiguration that the
        // user needs professional help to diagnose. The common corrupt-TOML case
        // (host-25) is handled above by the move-and-retry path.
        let finalStore: OfemConfigStore
        if let s = loadedStore {
            finalStore = s
        } else {
            fatalError("SharedOfemAuth: cannot initialise OfemConfigStore even after removing corrupt file — App Group container may be inaccessible")
        }
        self.configStore = finalStore
        self.auth = OfemAuth(configStore: finalStore)

        // Surface the problem non-modally after init so the app can finish launching.
        if let err = configError {
            let description = err.localizedDescription
            Task { @MainActor in
                SharedOfemAuth.showCorruptConfigAlert(description: description)
            }
        }
    }

    // MARK: - Interactive sign-in

    /// Runs the full interactive sign-in flow for a new account.
    ///
    /// Two sequential interactive browser flows are required because the
    /// Microsoft Entra v2 endpoint (AADSTS28000) rejects a single interactive
    /// request whose scopes span more than one resource:
    ///
    /// 1. OneLake (storage) flow — acquires `user_impersonation` for
    ///    `https://storage.azure.com/` and commits the account to `OfemAuth`.
    /// 2. Fabric (Power BI) consent flow — acquires interactive consent for
    ///    `Workspace.Read.All` + `Item.Read.All`. No admin pre-consent is
    ///    assumed or required; the user consents via the second browser prompt.
    ///
    /// Returns an `XPCAccountInfo` the caller can relay to the FPE via XPC
    /// so the FPE can register the domain without re-reading config.
    ///
    /// Failure in the Fabric consent step (e.g. the user closes the browser
    /// prompt, or Conditional Access blocks consent) is surfaced as a thrown
    /// error so the coordinator can show an error UI. Sign-in does not
    /// silently succeed with half the required consent.
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

        // ── Flow 1: OneLake (storage) interactive sign-in ──────────────────
        let result: InteractiveSignInResult
        do {
            result = try await InteractiveSignIn.acquireToken(
                clientID: effectiveClientID,
                tenantHint: tenantHint,
                webviewParams: webviewParams,
                cacheStrategy: .msalKeychain
            )
        } catch let nsError as NSError where nsError.domain == "MSALErrorDomain" {
            // Log only non-PII diagnostic fields. MSAL's userInfo also carries
            // MSALDisplayableUserIdKey (the user's UPN) and MSALHomeAccountIdKey,
            // which must never reach the log — see docs/auth.md "No token printing".
            let description = nsError.userInfo[MSALErrorDescriptionKey] as? String ?? "(none)"
            let internalCode = (nsError.userInfo[MSALInternalErrorCodeKey] as? NSNumber)?.stringValue ?? "(none)"
            let oauthError = nsError.userInfo[MSALOAuthErrorKey] as? String ?? "(none)"
            let correlationID = nsError.userInfo[MSALCorrelationIDKey] as? String ?? "(none)"
            Self.log.error(
                "SharedOfemAuth.signIn: MSAL error code=\(nsError.code, privacy: .public) internalCode=\(internalCode, privacy: .public) oauthError=\(oauthError, privacy: .public) correlationID=\(correlationID, privacy: .public) description=\(description, privacy: .public)"
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
        let resolvedTenantID = account.tenantID
        Self.log.info(
            "SharedOfemAuth.signIn: OneLake sign-in succeeded alias=\(trimmedAlias, privacy: .public) user=\(account.username, privacy: .private)"
        )

        // ── Flow 2: Fabric (Power BI) interactive consent ──────────────────
        //
        // The OneLake interactive flow above uses TokenScope.loginScopes
        // (OneLake only). Entra AADSTS28000 prevents combining both resource
        // audiences in a single interactive request, so Fabric consent must
        // be obtained in a second browser flow. Without this step the Fabric
        // token is absent from the MSAL Keychain and every FPE enumeration
        // would fail with tokenAcquisitionFailed → FabricError.unauthorized →
        // NSFileProviderError(.notAuthenticated).
        //
        // This is user-consent, not admin-consent. Workspace.Read.All and
        // Item.Read.All are standard delegated permissions that individual
        // end users can grant themselves through the browser prompt — no
        // tenant admin is involved.
        //
        // MSAL writes the resulting Fabric access + refresh token to the
        // shared App Group Keychain so the FPE's first tokenForScope(.fabric)
        // call is an immediate silent cache hit.
        do {
            try await InteractiveSignIn.acquireFabricConsent(
                clientID: effectiveClientID,
                tenantID: resolvedTenantID,
                webviewParams: webviewParams,
                cacheStrategy: .msalKeychain
            )
            Self.log.info("SharedOfemAuth.signIn: Fabric consent obtained for alias=\(trimmedAlias, privacy: .public)")
        } catch {
            // Fabric consent failure is a hard failure: the Finder mount would
            // be broken (every enumeration hits notAuthenticated) and the user
            // has no prompt to fix it. Surface the error so the coordinator
            // can show an actionable UI and the user knows they need to retry.
            //
            // We still need to clean up the already-committed storage account
            // so the user can re-run the complete two-step sign-in when they
            // retry — a partial account (storage only, no Fabric consent) is
            // not a usable state.
            Self.log.error(
                "SharedOfemAuth.signIn: Fabric consent failed for alias=\(trimmedAlias, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            try? await auth.removeAccount(alias: trimmedAlias)
            throw SharedOfemAuthError.fabricConsentFailed(error)
        }

        return XPCAccountInfo(
            alias: trimmedAlias,
            username: account.username,
            tenantId: account.tenantID,
            tenantName: account.tenantName ?? ""
        )
    }

    // MARK: - Private helpers

    /// Shows a non-blocking alert informing the user that the config file could
    /// not be parsed and the app started with defaults.
    private static func showCorruptConfigAlert(description: String) {
        NSApplication.shared.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "OneLake Configuration Error"
        alert.informativeText = "The OneLake configuration file was corrupt and has been backed up. The app started with defaults — you will need to sign in again.\n\nError: \(description)"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

// MARK: - Errors

enum SharedOfemAuthError: Error, CustomStringConvertible {
    case noViewController

    /// The Fabric (Power BI) interactive consent flow failed after the
    /// OneLake storage sign-in succeeded. The committed storage account has
    /// been rolled back so the user can retry the complete sign-in flow.
    case fabricConsentFailed(Error)

    var description: String {
        switch self {
        case .noViewController:
            return "SharedOfemAuth: no presenting view controller on window"
        case .fabricConsentFailed:
            return "SharedOfemAuth: Fabric consent could not be obtained — sign in was cancelled or blocked. Please try again."
        }
    }
}
