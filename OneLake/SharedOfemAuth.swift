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

    let auth: OfemAuth

    /// Designated initialiser. `@MainActor` is inherited from the class;
    /// `static let shared` therefore runs on the main actor (Swift guarantees
    /// this for @MainActor-isolated static stored properties).
    ///
    /// OfemConfigStore() throws only on TOML parse failure. On a fresh install
    /// the file doesn't exist and a default config is returned — never throws.
    /// If the TOML is corrupt, we degrade gracefully: back up the corrupt file,
    /// reinitialise with defaults, and surface a non-blocking alert. We do NOT
    /// crash (host-25): a fatalError here would trap the menu-bar agent in a
    /// crash loop on every login with no recovery path for the user.
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

    // MARK: - Re-authentication for an existing account

    /// Re-runs the two-step interactive sign-in flow for an **already-registered** account.
    ///
    /// Used when the account's refresh token has expired or a Conditional Access policy
    /// has revoked the token (`needsSignIn` flag is set on the FPE). The account metadata
    /// in `config.toml` is unchanged — only the MSAL Keychain tokens are refreshed.
    ///
    /// The same two sequential flows as `signIn(alias:tenant:clientID:window:)` are used
    /// because AADSTS28000 prevents combining OneLake and Fabric scopes in one request:
    ///
    /// 1. OneLake (storage) interactive flow — refreshes the user_impersonation token.
    /// 2. Fabric (Power BI) consent flow — refreshes Workspace.Read.All + Item.Read.All.
    ///
    /// On success the FPE's next silent token acquisition is an immediate cache hit, which
    /// unblocks enumeration. The caller is responsible for signalling the FPE to reload its
    /// engine (clearing `needsSignIn`) via the XPC setConfig channel.
    ///
    /// - Parameters:
    ///   - alias:  The existing account alias to re-authenticate.
    ///   - window: The NSWindow that anchors the ASWebAuthenticationSession sheet.
    /// - Throws: `SharedOfemAuthError.unknownAlias` if the alias is not registered,
    ///           `SharedOfemAuthError.noViewController` if the window has no content VC,
    ///           or MSAL errors on browser-flow failure.
    func reSignIn(alias: String, window: NSWindow) async throws {
        // Look up the registered account to get its tenantID and clientID.
        let accounts = await auth.listAccounts()
        guard let existing = accounts.first(where: { $0.alias == alias }) else {
            throw SharedOfemAuthError.unknownAlias(alias)
        }

        let effectiveClientID = existing.clientID.flatMap { $0.isEmpty ? nil : $0 } ?? ofemEntraClientID
        let tenantID = existing.tenantID

        guard let parentVC = window.contentViewController else {
            throw SharedOfemAuthError.noViewController
        }
        let webviewParams = MSALWebviewParameters(authPresentationViewController: parentVC)
        webviewParams.webviewType = .default

        let expectedHomeAccountID = existing.homeAccountID
        let loginHint = existing.username

        Self.log.info(
            "SharedOfemAuth.reSignIn: starting re-auth for alias=\(alias, privacy: .public)"
        )

        // ── Flow 1: OneLake (storage) interactive re-auth ─────────────────────
        // acquireToken writes fresh tokens to the shared App Group Keychain.
        // We do NOT call commit/addAccount — the account record already exists.
        //
        // loginHint pins the browser prompt to the registered UPN so the user
        // cannot accidentally sign in as a different identity. After the flow
        // returns we validate the homeAccountID as a second defence: if they
        // differ we reject the result and leave the existing account untouched.
        let storageResult: InteractiveSignInResult
        do {
            storageResult = try await InteractiveSignIn.acquireToken(
                clientID: effectiveClientID,
                tenantHint: tenantID.isEmpty ? nil : tenantID,
                loginHint: loginHint.isEmpty ? nil : loginHint,
                webviewParams: webviewParams,
                cacheStrategy: .msalKeychain
            )
        } catch let nsError as NSError where nsError.domain == "MSALErrorDomain" {
            let description = nsError.userInfo[MSALErrorDescriptionKey] as? String ?? "(none)"
            let internalCode = (nsError.userInfo[MSALInternalErrorCodeKey] as? NSNumber)?.stringValue ?? "(none)"
            let oauthError = nsError.userInfo[MSALOAuthErrorKey] as? String ?? "(none)"
            let correlationID = nsError.userInfo[MSALCorrelationIDKey] as? String ?? "(none)"
            Self.log.error(
                "SharedOfemAuth.reSignIn: MSAL error (storage) code=\(nsError.code, privacy: .public) internalCode=\(internalCode, privacy: .public) oauthError=\(oauthError, privacy: .public) correlationID=\(correlationID, privacy: .public) description=\(description, privacy: .public)"
            )
            throw nsError
        }

        // Identity guard: reject any result whose homeAccountID differs from the
        // registered account. This prevents a mismatched SSO cookie (e.g. a second
        // browser profile) from silently writing tokens for the wrong identity into
        // the shared Keychain under this alias. We leave the existing account record
        // intact and do NOT signal an engine reload — the needsSignIn badge stays set
        // so the user sees the error and can retry.
        let returnedHomeAccountID = storageResult.account.homeAccountID
        if !returnedHomeAccountID.isEmpty,
           !expectedHomeAccountID.isEmpty,
           returnedHomeAccountID != expectedHomeAccountID
        {
            Self.log.error(
                "SharedOfemAuth.reSignIn: identity mismatch for alias=\(alias, privacy: .public) — expected homeAccountID=\(expectedHomeAccountID, privacy: .private) got=\(returnedHomeAccountID, privacy: .private)"
            )
            throw InteractiveSignInError.identityMismatch(
                expected: expectedHomeAccountID,
                got: returnedHomeAccountID
            )
        }

        Self.log.info(
            "SharedOfemAuth.reSignIn: OneLake token refreshed for alias=\(alias, privacy: .public)"
        )

        // ── Flow 2: Fabric (Power BI) interactive consent ────────────────────
        // Pass the same loginHint used in Flow 1 to lock the Fabric consent
        // prompt to the same identity. This prevents a mismatched SSO cookie from
        // consenting on behalf of a different UPN between the two flows.
        do {
            try await InteractiveSignIn.acquireFabricConsent(
                clientID: effectiveClientID,
                tenantID: tenantID,
                loginHint: loginHint.isEmpty ? nil : loginHint,
                webviewParams: webviewParams,
                cacheStrategy: .msalKeychain
            )
            Self.log.info("SharedOfemAuth.reSignIn: Fabric consent refreshed for alias=\(alias, privacy: .public)")
        } catch {
            // Fabric consent failure during re-auth: unlike first-time signIn, we do
            // NOT remove the account. The account record remains in config.toml so
            // the user can retry re-auth. The fresh storage token from Flow 1 now sits
            // in the Keychain but the FPE's _needsSignIn flag remains set (the caller
            // must not signal engine reload). The user will see the error badge and can
            // retry the complete re-auth to refresh both token audiences.
            Self.log.error(
                "SharedOfemAuth.reSignIn: Fabric consent failed for alias=\(alias, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            throw SharedOfemAuthError.fabricConsentFailed(error)
        }
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
    /// OneLake storage sign-in succeeded.
    ///
    /// For first-time `signIn`: the committed storage account is rolled back so
    /// the user can retry the complete two-step flow from scratch.
    ///
    /// For `reSignIn`: the existing account record is NOT removed — it remains
    /// registered and the needsSignIn badge stays set. The fresh storage token
    /// from Flow 1 sits in the Keychain but the FPE will not use it until the
    /// user retries re-auth and both flows succeed. No engine reload is signalled.
    case fabricConsentFailed(Error)

    /// The alias passed to `reSignIn(alias:window:)` does not match any
    /// registered account. Indicates a logic error in the caller.
    case unknownAlias(String)

    var description: String {
        switch self {
        case .noViewController:
            "SharedOfemAuth: no presenting view controller on window"
        case .fabricConsentFailed:
            "SharedOfemAuth: Fabric consent could not be obtained — sign in was cancelled or blocked. Please try again."
        case let .unknownAlias(a):
            "SharedOfemAuth: account '\(a)' not found — cannot re-authenticate"
        }
    }
}
