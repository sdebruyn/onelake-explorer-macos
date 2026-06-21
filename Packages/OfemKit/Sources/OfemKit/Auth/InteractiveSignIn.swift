import Foundation
import MSAL
import os.log

// MARK: - InteractiveSignIn

/// Drives MSAL's interactive browser sign-in flow for OFEM.
///
/// Interactive sign-in runs inside the host app, which has a UI window for
/// `ASWebAuthenticationSession`. The host app calls
/// ``acquireToken(clientID:tenantHint:webviewParams:cacheStrategy:fileTokenStore:)``
/// from the main actor (required for `MSALWebviewParameters`), then
/// commits the result to ``OfemAuth`` via ``InteractiveSignInResult/commit(alias:to:)``.
///
/// ## Usage
///
/// 1. Obtain an `NSWindow` or parent view.
/// 2. Call ``acquireToken(clientID:tenantHint:webviewParams:cacheStrategy:fileTokenStore:)``
///    from the main actor (required for `MSALWebviewParameters`).
/// 3. Assign the user-chosen alias and call
///    ``InteractiveSignInResult/commit(alias:to:)`` to persist the result.
///    This API atomically transfers the file-backed scratch blob (if any) and
///    calls `OfemAuth.addAccount` — no manual blob management is needed.
public enum InteractiveSignIn {
    private static let log = Logger(subsystem: "dev.debruyn.ofem", category: "InteractiveSignIn")

    // MARK: - Public API

    /// Runs the interactive MSAL sign-in flow.
    ///
    /// - Parameters:
    ///   - clientID: The OFEM Entra App Registration client GUID. Pass
    ///     ``ofemEntraClientID`` for the built-in registration.
    ///   - tenantHint: Optional tenant GUID or verified domain (e.g.
    ///     `"contoso.onmicrosoft.com"`). Pass `nil` or `""` to use
    ///     `"organizations"` (home-tenant routing).
    ///   - loginHint: Optional UPN (e.g. `"user@contoso.com"`) to pre-select the
    ///     account in the browser prompt. Pass this during re-authentication to
    ///     pin the identity and prevent the user from accidentally signing in as
    ///     a different account. `nil` for first-sign-in (no pre-selection).
    ///   - webviewParams: MSAL webview configuration including the parent
    ///     `NSWindow`. Must be constructed on the main thread.
    ///   - cacheStrategy: Token cache backend. Default: `.msalKeychain`.
    ///   - fileTokenStore: Required when `cacheStrategy == .fileBackedFallback`.
    /// - Returns: ``InteractiveSignInResult`` containing the extracted
    ///   `OfemConfig.Account` ready for persistence via `commit(alias:to:)`.
    /// - Throws: `NSError` from MSAL on sign-in failure, or
    ///   ``InteractiveSignInError`` for configuration problems.
    @MainActor
    public static func acquireToken(
        clientID: String = ofemEntraClientID,
        tenantHint: String? = nil,
        loginHint: String? = nil,
        webviewParams: MSALWebviewParameters,
        cacheStrategy: TokenCacheStrategy = .msalKeychain,
        fileTokenStore: FileTokenStore? = nil
    ) async throws -> InteractiveSignInResult {
        guard !clientID.isEmpty else {
            throw InteractiveSignInError.missingClientID
        }

        // Validate the tenant hint before interpolating into the authority URL
        // so callers get a clear, actionable error rather than an opaque MSAL
        // failure deep inside the stack.
        if let hint = tenantHint, !hint.isEmpty {
            try EntraAuthorityResolver.validateTenantHint(hint)
        }

        // Interactive logins use a temporary scratch alias so the cache bytes
        // can be read back after the flow completes and transferred to the real
        // alias when the user names the account. This is handled inside
        // InteractiveSignInResult.commit(alias:to:).
        var scratchAlias: String? = nil
        if cacheStrategy == .fileBackedFallback {
            guard fileTokenStore != nil else {
                throw InteractiveSignInError.missingFileTokenStore
            }
            scratchAlias = temporaryAlias()
        }

        let config = try MsalApplicationConfig.make(
            clientID: clientID,
            tenantID: tenantHint ?? "",
            cacheStrategy: cacheStrategy,
            fileTokenStore: fileTokenStore,
            alias: scratchAlias
        )
        let app = try MSALPublicClientApplication(configuration: config)

        log.info("InteractiveSignIn: starting interactive flow tenantHint=\(tenantHint ?? "(none)", privacy: .public)")

        let params = MSALInteractiveTokenParameters(
            scopes: TokenScope.loginScopes,
            webviewParameters: webviewParams
        )
        // The redirect URI (msauth.<bundleid>://auth) is set on the config,
        // not on the token parameters. ASWebAuthenticationSession presents
        // the Microsoft sign-in page and captures the callback to the
        // app's custom scheme; no local web server is involved.
        params.promptType = .selectAccount
        // When re-authenticating an existing account, pre-select the known
        // identity to prevent the user from accidentally signing in as a
        // different UPN. The loginHint narrows the account picker to the
        // specified UPN but still allows the user to cancel.
        if let hint = loginHint, !hint.isEmpty {
            params.loginHint = hint
        }

        let msalResult = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<MSALResult, Error>) in
            app.acquireToken(with: params) { result, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let result {
                    continuation.resume(returning: result)
                } else {
                    continuation.resume(throwing: InteractiveSignInError.nilResult)
                }
            }
        }

        // Extract only the plain Sendable values we need from MSALResult so
        // InteractiveSignInResult does not carry the non-Sendable MSAL object
        // across actor boundaries.
        let account = accountFromMSALResult(msalResult)
        log.info("InteractiveSignIn: succeeded username=\(msalResult.account.username ?? "(nil)", privacy: .private)")
        return InteractiveSignInResult(
            account: account,
            scratchAlias: scratchAlias,
            fileTokenStore: fileTokenStore
        )
    }

    // MARK: - Fabric interactive consent

    /// Runs an interactive browser flow to obtain user consent for the Fabric
    /// (Power BI) scopes.
    ///
    /// This is the second of two sequential interactive flows that are required
    /// to complete OFEM sign-in:
    ///
    /// 1. ``acquireToken(clientID:tenantHint:webviewParams:cacheStrategy:fileTokenStore:)``
    ///    — interactive storage (OneLake) sign-in.
    /// 2. ``acquireFabricConsent(clientID:tenantID:webviewParams:cacheStrategy:)``
    ///    — this method — interactive Fabric (Power BI) consent.
    ///
    /// AADSTS28000 prevents combining both resources in a single interactive
    /// request, so two sequential flows are required. The user sees two browser
    /// prompts; the second is scoped to `TokenScope.fabricScopes`.
    ///
    /// Consent is written by MSAL directly to the shared App Group Keychain so
    /// the FPE's subsequent `tokenForScope(.fabric)` is a fast silent cache hit.
    /// No ``InteractiveSignInResult`` is returned — the purpose is Keychain hydration,
    /// not a new account record.
    ///
    /// - Parameters:
    ///   - clientID: The OFEM Entra App Registration client GUID. Pass
    ///     ``ofemEntraClientID`` for the built-in registration.
    ///   - tenantID: The user's home tenant GUID, obtained from the first
    ///     interactive result. Must not be empty.
    ///   - loginHint: Optional UPN to lock the Fabric consent prompt to the
    ///     same identity used in the OneLake storage flow. Pass the `username`
    ///     from the Flow 1 result during re-authentication. `nil` for first
    ///     sign-in (no pre-selection needed).
    ///   - webviewParams: MSAL webview configuration including the parent
    ///     `NSWindow`. Must be constructed on the main thread.
    ///   - cacheStrategy: Token cache backend. Must match the strategy used for
    ///     the first interactive flow so MSAL writes to the same Keychain group.
    /// - Throws: `NSError` from MSAL on user cancellation or consent failure.
    @MainActor
    public static func acquireFabricConsent(
        clientID: String = ofemEntraClientID,
        tenantID: String,
        loginHint: String? = nil,
        webviewParams: MSALWebviewParameters,
        cacheStrategy: TokenCacheStrategy = .msalKeychain
    ) async throws {
        guard !clientID.isEmpty else {
            throw InteractiveSignInError.missingClientID
        }
        guard !tenantID.isEmpty else {
            throw InteractiveSignInError.missingTenantID
        }

        // Use the resolved tenant authority (not "organizations") so the
        // interactive prompt is pre-scoped to the user's home tenant and MSAL
        // writes the refresh-token entry under the correct authority key in the
        // shared Keychain — matching what OfemAuth.tokenForScope looks up during
        // silent acquisition.
        let config = try MsalApplicationConfig.make(
            clientID: clientID,
            tenantID: tenantID,
            cacheStrategy: cacheStrategy,
            fileTokenStore: nil,
            alias: nil
        )
        let app = try MSALPublicClientApplication(configuration: config)

        log.info("InteractiveSignIn: starting Fabric consent flow tenantID=\(tenantID, privacy: .public)")

        let params = MSALInteractiveTokenParameters(
            scopes: TokenScope.fabricScopes,
            webviewParameters: webviewParams
        )
        // .consent forces the browser prompt even if a cached entry exists, so
        // the user explicitly sees and accepts the Fabric scopes. Without this,
        // MSAL might skip the browser if it finds an old cached SSO cookie.
        params.promptType = .consent
        // When re-authenticating, lock the consent prompt to the same identity
        // used in the OneLake storage flow so mismatched SSO cookies cannot
        // silently consent as a different UPN.
        if let hint = loginHint, !hint.isEmpty {
            params.loginHint = hint
        }

        let msalResult = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<MSALResult, Error>) in
            app.acquireToken(with: params) { result, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let result {
                    continuation.resume(returning: result)
                } else {
                    continuation.resume(throwing: InteractiveSignInError.nilResult)
                }
            }
        }

        log.info("InteractiveSignIn: Fabric consent succeeded username=\(msalResult.account.username ?? "(nil)", privacy: .private)")
    }

    // MARK: - Private helpers

    /// Shared `ISO8601DateFormatter` instance. `ISO8601DateFormatter` is
    /// expensive to allocate; reusing a `static let` follows the standard
    /// Apple guideline for date formatters. All callers of `accountFromMSALResult`
    /// are `@MainActor`, so the formatter is always accessed on the main actor.
    @MainActor
    private static let iso8601Formatter = ISO8601DateFormatter()

    /// Builds an `OfemConfig.Account` from an `MSALResult`.
    @MainActor
    private static func accountFromMSALResult(_ result: MSALResult) -> Account {
        Account(
            alias: "", // Caller assigns the alias via commit(alias:to:).
            tenantID: result.tenantProfile.tenantId ?? "",
            tenantName: nil,
            homeAccountID: result.account.identifier ?? "",
            username: result.account.username ?? "",
            addedAt: iso8601Formatter.string(from: Date()),
            clientID: nil
        )
    }

    /// Returns a unique temporary alias used as the scratch key in the
    /// file-backed cache during interactive login.
    ///
    /// Uses a UUID alone (without a timestamp prefix) — the UUID is already
    /// collision-safe and the timestamp adds no value. The leading `.` is a
    /// deliberate internal-only key marker not intended to pass user-facing
    /// `AccountAlias.validate`, so it is kept separate from the real alias
    /// validation path.
    static func temporaryAlias() -> String {
        ".ofem-login-tmp-\(UUID().uuidString.lowercased())"
    }
}

// MARK: - InteractiveSignInResult

/// Result of a successful ``InteractiveSignIn`` flow.
///
/// Holds only plain `Sendable` values extracted at the MSAL boundary; the
/// raw `MSALResult` is not retained. Call ``commit(alias:to:)`` to persist
/// the account and clean up any scratch blobs.
public struct InteractiveSignInResult: Sendable {
    /// The `OfemConfig.Account` extracted from the MSAL result, with an
    /// empty `alias`. The caller assigns the alias via ``commit(alias:to:)``.
    public var account: Account

    /// The temporary FileTokenStore alias under which the MSAL cache bytes
    /// were written during the interactive flow. Non-nil only when
    /// `cacheStrategy == .fileBackedFallback`.
    let scratchAlias: String?

    /// Reference to the FileTokenStore for blob transfer inside `commit`.
    let fileTokenStore: FileTokenStore?

    // MARK: - Commit

    /// Assigns `alias` to the account, transfers any scratch blob, and
    /// persists the account to ``OfemAuth``.
    ///
    /// This is the only supported way to finalise an interactive sign-in:
    /// - If `cacheStrategy == .fileBackedFallback`, transfers the scratch blob
    ///   from the temporary alias to `alias` and deletes the scratch entry.
    ///   If the transfer fails, the scratch blob is cleaned up and the error
    ///   is rethrown so the caller can retry.
    /// - Calls `auth.addAccount(_:)` to persist the account metadata.
    ///
    /// - Parameters:
    ///   - alias: The user-chosen account short name. Must be valid per
    ///     ``AccountAlias/validate(_:)``.
    ///   - auth: The ``OfemAuth`` instance to persist the account into.
    public func commit(alias: String, to auth: OfemAuth) async throws {
        var finalAccount = account
        finalAccount.alias = alias

        // Transfer the file-backed scratch blob to the real alias.
        if let scratch = scratchAlias, let store = fileTokenStore {
            do {
                let data = try store.read(alias: scratch)
                try await store.write(alias: alias, data: data)
            } catch {
                // Clean up the scratch blob even if the transfer failed.
                try? await store.delete(alias: scratch)
                throw error
            }
            // Delete the scratch blob after a successful transfer.
            try? await store.delete(alias: scratch)
        }

        // Persist the account. If addAccount throws (e.g. duplicateAlias or
        // alias validation failure), roll back the committed blob at the real
        // alias so no orphaned refresh-token data remains on disk.
        do {
            try await auth.addAccount(finalAccount)
        } catch {
            if let store = fileTokenStore {
                try? await store.delete(alias: alias)
            }
            throw error
        }
    }

    // periphery:ignore
    /// Discards this sign-in result and cleans up any scratch blob.
    ///
    /// Call when the user cancels the account-naming step after a successful
    /// sign-in, to avoid leaving orphaned refresh-token blobs on disk.
    public func discard() async {
        if let scratch = scratchAlias, let store = fileTokenStore {
            try? await store.delete(alias: scratch)
        }
    }
}

// MARK: - InteractiveSignInError

/// Errors thrown by ``InteractiveSignIn``.
public enum InteractiveSignInError: Error, CustomStringConvertible {
    case missingClientID
    case missingFileTokenStore
    case missingTenantID
    case nilResult
    /// The account returned by the interactive flow does not match the expected
    /// `homeAccountID`. Thrown by ``SharedOfemAuth.reSignIn`` when the user
    /// completes the re-auth prompt as a different identity than the one
    /// registered for the alias.
    case identityMismatch(expected: String, got: String)

    public var description: String {
        switch self {
        case .missingClientID:
            "InteractiveSignIn: clientID is required"
        case .missingFileTokenStore:
            "InteractiveSignIn: fileTokenStore is required when cacheStrategy is .fileBackedFallback"
        case .missingTenantID:
            "InteractiveSignIn: tenantID is required for Fabric consent flow"
        case .nilResult:
            "InteractiveSignIn: MSAL returned neither a result nor an error"
        case let .identityMismatch(expected, got):
            "InteractiveSignIn: identity mismatch — expected account '\(expected)' but got '\(got)'. Sign in was rejected to protect the existing account."
        }
    }
}
