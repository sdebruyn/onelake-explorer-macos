import Foundation
import MSAL
import os.log

// MARK: - InteractiveSignIn

/// Drives MSAL's interactive browser sign-in flow for OFEM.
///
/// In the FPE-only architecture (Option 3) the entire interactive sign-in
/// runs inside the host app. The host app starts token acquisition via
/// `MSALPublicClientApplication.acquireToken(with:)`, which internally
/// uses `ASWebAuthenticationSession` (or MSAL's embedded webview as fallback)
/// to complete the OAuth authorisation-code + PKCE flow.
///
/// No subprocess is spawned and no localhost redirect server is needed;
/// MSAL handles the redirect URI interception entirely within the process.
///
/// ## Usage
///
/// 1. Obtain an `NSWindow` or parent view.
/// 2. Call ``acquireToken(clientID:tenantHint:webviewParams:cacheStrategy:fileTokenStore:)``
/// from the main actor (required for `MSALWebviewParameters`).
/// 3. Persist the returned ``InteractiveSignInResult`` via `OfemAuth`.
public enum InteractiveSignIn {
    private static let log = Logger(subsystem: "dev.debruyn.ofem", category: "InteractiveSignIn")

    // MARK: - Public API

    /// Runs the interactive MSAL sign-in flow.
    ///
    /// - Parameters:
    /// - clientID: The OFEM Entra App Registration client GUID. Pass
    /// ``ofemEntraClientID`` for the built-in registration.
    /// - tenantHint: Optional tenant GUID or verified domain (e.g.
    /// `"contoso.onmicrosoft.com"`). Pass `nil` or `""` to use
    /// `"organizations"` (home-tenant routing).
    /// - webviewParams: MSAL webview configuration including the parent
    /// `NSWindow`. Must be constructed on the main thread.
    /// - cacheStrategy: Token cache backend. Default: `.msalKeychain`.
    /// - fileTokenStore: Required when `cacheStrategy ==.fileBackedFallback`.
    /// - Returns: ``InteractiveSignInResult`` containing the MSAL result and
    /// the extracted `OfemConfig.Account` ready for persistence.
    /// - Throws: `NSError` from MSAL on sign-in failure, or
    /// ``InteractiveSignInError`` for configuration problems.
    @MainActor
    public static func acquireToken(
        clientID: String = ofemEntraClientID,
        tenantHint: String? = nil,
        webviewParams: MSALWebviewParameters,
        cacheStrategy: TokenCacheStrategy = .msalKeychain,
        fileTokenStore: FileTokenStore? = nil
    ) async throws -> InteractiveSignInResult {
        guard !clientID.isEmpty else {
            throw InteractiveSignInError.missingClientID
        }

        let authorityURL = try EntraAuthorityResolver.authority(tenantHint: tenantHint)
        let authority = try MSALAADAuthority(url: authorityURL)

        let config = MSALPublicClientApplicationConfig(
            clientId: clientID,
            redirectUri: "http://localhost",
            authority: authority
        )
        config.cacheConfig.keychainSharingGroup = OfemPaths.appGroupIdentifier

        // Wire the file-backed fallback cache if requested.
        // The scratch alias is returned to the caller so it can copy (rename)
        // the token bytes to the real alias after the user names the account.
        // Without this round-trip the MsalAuthClient created by OfemAuth would
        // look for the real alias in the FileTokenStore and find nothing, making
        // every silent token acquisition fail with interaction-required.
        var scratchAlias: String? = nil
        if cacheStrategy == .fileBackedFallback {
            guard let store = fileTokenStore else {
                throw InteractiveSignInError.missingFileTokenStore
            }
            // Interactive logins use a temporary alias so the cache bytes
            // can be read back after the flow completes — then transferred
            // to the real alias when the user names the account.
            let tempAlias = temporaryAlias()
            scratchAlias = tempAlias
            let delegate = FileTokenStoreCacheDelegate(store: store, alias: tempAlias)
            let serializedCache = try MSALSerializedADALCacheProvider(delegate: delegate)
            config.cacheConfig.serializedADALCache = serializedCache
        }

        let app = try MSALPublicClientApplication(configuration: config)

        log.info("InteractiveSignIn: starting interactive flow tenantHint=\(tenantHint ?? "(none)", privacy: .public)")

        let params = MSALInteractiveTokenParameters(
            scopes: TokenScope.loginScopes,
            webviewParameters: webviewParams
        )
        // The redirect URI is set on the config, not on the token parameters.
        // MSAL intercepts the `http://localhost` redirect via
        // ASWebAuthenticationSession; no localhost server is required.
        params.promptType = .selectAccount

        let result = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<MSALResult, Error>) in
            app.acquireToken(with: params) { msalResult, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let msalResult {
                    continuation.resume(returning: msalResult)
                } else {
                    continuation.resume(throwing: InteractiveSignInError.nilResult)
                }
            }
        }

        let account = accountFromMSALResult(result)
        log.info("InteractiveSignIn: succeeded username=\(result.account.username ?? "(nil)", privacy: .private)")
        return InteractiveSignInResult(msalResult: result, account: account, scratchAlias: scratchAlias)
    }

    // MARK: - Private helpers

    /// Builds an `OfemConfig.Account` from an `MSALResult`.
    private static func accountFromMSALResult(_ result: MSALResult) -> Account {
        Account(
            alias: "", // Caller assigns the alias.
            tenantID: result.tenantProfile.tenantId ?? "",
            tenantName: nil,
            homeAccountID: result.account.identifier ?? "",
            username: result.account.username ?? "",
            addedAt: ISO8601DateFormatter().string(from: Date()),
            clientID: nil
        )
    }

    /// Returns a unique temporary alias used as the scratch key in the
    /// file-backed cache during interactive login.
    private static func temporaryAlias() -> String {
        ".ofem-login-tmp-\(Int(Date().timeIntervalSince1970 * 1_000_000))-\(UUID().uuidString.prefix(8).lowercased())"
    }
}

// MARK: - InteractiveSignInResult

/// Result of a successful ``InteractiveSignIn`` flow.
public struct InteractiveSignInResult: Sendable {
    /// The raw MSAL result. Contains the access token and the MSAL account
    /// handle needed for subsequent silent acquisitions.
    public let msalResult: MSALResult

    /// The `OfemConfig.Account` extracted from the MSAL result, with an
    /// empty `alias`. The caller must set the alias before persisting.
    public let account: Account

    /// The temporary FileTokenStore alias under which the MSAL cache bytes
    /// were written during the interactive flow. Non-nil only when
    /// `cacheStrategy ==.fileBackedFallback`.
    ///
    /// The caller **must** transfer the bytes to the real alias before calling
    /// `OfemAuth.addAccount`:
    ///
    /// ```swift
    /// if let scratch = result.scratchAlias {
    /// let data = try fileTokenStore.read(alias: scratch)
    /// try fileTokenStore.write(alias: realAlias, data: data)
    /// try fileTokenStore.delete(alias: scratch)
    /// }
    /// ```
    ///
    /// Without this transfer, ``MsalAuthClient`` (created by ``OfemAuth``
    /// with the real alias) cannot find the cached tokens and every silent
    /// acquisition will fail with ``OfemAuthError/interactionRequired``.
    public let scratchAlias: String?
}

// MARK: - InteractiveSignInError

/// Errors thrown by ``InteractiveSignIn``.
public enum InteractiveSignInError: Error, CustomStringConvertible {
    case missingClientID
    case missingFileTokenStore
    case nilResult

    public var description: String {
        switch self {
        case .missingClientID:
            return "InteractiveSignIn: clientID is required"
        case .missingFileTokenStore:
            return "InteractiveSignIn: fileTokenStore is required when cacheStrategy is .fileBackedFallback"
        case .nilResult:
            return "InteractiveSignIn: MSAL returned neither a result nor an error"
        }
    }
}
