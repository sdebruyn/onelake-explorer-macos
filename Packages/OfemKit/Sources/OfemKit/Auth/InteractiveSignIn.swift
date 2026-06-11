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
        // The redirect URI is set on the config, not on the token parameters.
        // MSAL intercepts the `http://localhost` redirect via
        // ASWebAuthenticationSession; no localhost server is required.
        params.promptType = .selectAccount

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

    // MARK: - Private helpers

    /// Builds an `OfemConfig.Account` from an `MSALResult`.
    private static func accountFromMSALResult(_ result: MSALResult) -> Account {
        Account(
            alias: "", // Caller assigns the alias via commit(alias:to:).
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
                try store.write(alias: alias, data: data)
            } catch {
                // Clean up the scratch blob even if the transfer failed.
                try? store.delete(alias: scratch)
                throw error
            }
            // Delete the scratch blob after a successful transfer.
            try? store.delete(alias: scratch)
        }

        try await auth.addAccount(finalAccount)
    }

    /// Discards this sign-in result and cleans up any scratch blob.
    ///
    /// Call when the user cancels the account-naming step after a successful
    /// sign-in, to avoid leaving orphaned refresh-token blobs on disk.
    public func discard() {
        if let scratch = scratchAlias, let store = fileTokenStore {
            try? store.delete(alias: scratch)
        }
    }
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
