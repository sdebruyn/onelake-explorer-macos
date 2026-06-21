import Foundation
@preconcurrency import MSAL
import os.log

/// `MSALErrorInternal` (-50000) is the ObjC enum case for the top-level
/// "internal error" code that MSAL uses when the specific failure is stored
/// in MSALInternalErrorCodeKey. In Swift the bridged name would be
/// `MSALError.internal`, but `internal` is a reserved keyword so the case
/// is not directly accessible as a typed value. Use this constant instead.
private let msalErrorInternalCode: Int = -50000

// MARK: - OfemAuth

/// Top-level authentication façade for OFEM.
///
/// `OfemAuth` is the single entry point for token acquisition. It mirrors
/// responsibility:
///
/// - Manages the set of signed-in accounts via ``OfemConfigStore``.
/// - Persists per-account secrets (token cache) via MSAL's Keychain backend.
/// - Acquires tokens silently from MSAL, returning ``OfemAuthError/interactionRequired``
/// when the refresh token has expired or a Conditional Access policy fires.
/// - One `MSALPublicClientApplication` per `(clientID, tenantID)` pair,
/// cached in-process for fast silent acquisition.
///
/// ## Thread safety
///
/// `OfemAuth` is a Swift `actor`. Token acquisition runs on the actor's own
/// executor — not the main actor — so the FPE's concurrent Finder I/O calls
/// do not serialize through the main thread. The in-process MSAL client cache
/// dictionary is accessed only within the actor.
///
/// The genuinely UI-bound part of authentication — interactive sign-in via
/// `ASWebAuthenticationSession` — lives in the host app's `SharedOfemAuth`
/// and remains `@MainActor` isolated as a leaf, separate from this actor.
public actor OfemAuth: TokenProvider {
    // MARK: - Properties

    private let configStore: OfemConfigStore
    private let clientID: String
    private let cacheStrategy: TokenCacheStrategy
    private let fileTokenStore: FileTokenStore?
    private let msalClientFactory: MsalAuthClientFactory

    /// In-process MSAL client cache: key = `"<clientID>|<tenantID>"`.
    ///
    /// Keyed on `(clientID, tenantID)` per the class contract: one
    /// `MSALPublicClientApplication` per app-registration+tenant pair,
    /// shared across aliases that use the same pair. The key includes
    /// `clientID` so a config change that updates the client ID for an
    /// account correctly builds a fresh client rather than reusing a stale one.
    private var clients: [String: any MsalAuthClientProtocol] = [:]

    /// In-flight silent token acquisition tasks, keyed on `"<alias>|<scope>"`.
    ///
    /// When N concurrent callers request a token for the same `(alias, scope)`
    /// pair, only the *first* caller starts a real MSAL refresh; all subsequent
    /// callers `await` the same `Task` and share its result (or error). The task
    /// is evicted from the map when it completes. This prevents a "refresh
    /// stampede" under Finder's bursty concurrent enumeration.
    private var inFlightTokenTasks: [String: Task<AccessToken, Error>] = [:]

    private static let log = Logger(subsystem: "dev.debruyn.ofem", category: "OfemAuth")

    // MARK: - Initialisation

    /// Creates an `OfemAuth` instance.
    ///
    /// - Parameters:
    ///   - configStore: Loaded `OfemConfigStore` (accounts are read from
    ///     here and written back after `addAccount`/`removeAccount`).
    ///   - clientID: The Entra App Registration GUID. Default:
    ///     ``ofemEntraClientID`` (built-in OFEM registration).
    ///   - cacheStrategy: Token cache backend. Default: `.msalKeychain`.
    ///   - fileTokenStore: Required when `cacheStrategy == .fileBackedFallback`.
    ///   - msalClientFactory: Factory for creating MSAL client instances.
    ///     Default: ``DefaultMsalAuthClientFactory`` (real MSAL). Inject a
    ///     test double to cover the token-acquisition path in unit tests.
    public init(
        configStore: OfemConfigStore,
        clientID: String = ofemEntraClientID,
        cacheStrategy: TokenCacheStrategy = .msalKeychain,
        fileTokenStore: FileTokenStore? = nil,
        msalClientFactory: MsalAuthClientFactory = DefaultMsalAuthClientFactory()
    ) {
        self.configStore = configStore
        self.clientID = clientID
        self.cacheStrategy = cacheStrategy
        self.fileTokenStore = fileTokenStore
        self.msalClientFactory = msalClientFactory
    }

    // MARK: - Account management

    /// Returns all known accounts sorted by alias.
    public func listAccounts() -> [Account] {
        let snap = configStore.snapshot()
        return snap.accounts.values.sorted { $0.alias < $1.alias }
    }

    /// Adds a signed-in account and persists it to the config store.
    ///
    /// The MSAL token cache is already in the Keychain at this point
    /// (written by `MsalAuthClient` during the interactive flow). This
    /// method only updates the TOML config with the account metadata.
    ///
    /// If a cached MSAL client already exists for the same `(clientID, tenantID)`
    /// pair (e.g. because a previous account with the same pair was removed and
    /// re-added), it is evicted so the next token call builds a fresh client
    /// that picks up the new Keychain state.
    public func addAccount(_ account: Account) async throws {
        guard !account.alias.isEmpty else {
            throw OfemAuthError.emptyAlias
        }
        try AccountAlias.validate(account.alias)
        let snap = configStore.snapshot()
        if snap.accounts[account.alias] != nil {
            throw OfemAuthError.duplicateAlias(account.alias)
        }
        // Evict any stale cached client for this (clientID, tenantID) pair
        // so a re-added alias doesn't inherit a client whose MSAL cache was
        // just purged by the preceding removeAccount call.
        let eClientID = account.clientID.flatMap { $0.isEmpty ? nil : $0 } ?? clientID
        let cacheKey = clientKey(clientID: eClientID, tenantID: account.tenantID)
        clients.removeValue(forKey: cacheKey)

        try await configStore.updateAndSave { config in
            config.accounts[account.alias] = account
        }
    }

    /// Removes the account with the given alias from the config, purges its
    /// MSAL Keychain refresh token, and deletes the on-disk token blob
    /// (`.fileBackedFallback` only) so refresh tokens do not survive account
    /// removal or resurrect under a re-added alias.
    ///
    /// Per `docs/auth.md` logout step 1, the MSAL Keychain item must be
    /// explicitly removed via `MSALPublicClientApplication.remove(_:)` — MSAL
    /// does not do this automatically when the app removes the account from its
    /// own config. Skipping this step leaves the refresh token in the macOS
    /// Keychain under the App Group, where a subsequent `addAccount` for the
    /// same alias (different user) would pick it up via `willAccessCache`.
    ///
    /// If MSAL Keychain removal fails (other than account-not-found), the error
    /// is surfaced as a thrown ``OfemAuthError`` so the caller knows the refresh
    /// token has not been purged and can take corrective action.
    public func removeAccount(alias: String) async throws {
        let snap = configStore.snapshot()
        guard let cfg = snap.accounts[alias] else {
            throw OfemAuthError.unknownAlias(alias)
        }

        // Purge the MSAL Keychain refresh token before removing the config
        // entry so the client is still available for the lookup.
        if cacheStrategy == .msalKeychain, !cfg.homeAccountID.isEmpty {
            let eClientID = effectiveClientID(for: cfg)
            if let msalClient = try? clientFor(clientID: eClientID, tenantID: cfg.tenantID, alias: alias) {
                do {
                    try msalClient.removeAccount(homeAccountID: cfg.homeAccountID)
                } catch let MsalAuthClientError.accountNotFound(id) {
                    // Already absent from the MSAL cache — benign.
                    Self.log.debug("OfemAuth: removeAccount: homeAccountID=\(id, privacy: .public) not in MSAL cache (already purged)")
                } catch {
                    // A failed Keychain purge means the refresh token survives
                    // logout — surface this rather than silently proceeding.
                    // The host-app coordinator surfaces a sign-out error banner
                    // (no retry affordance) when this is thrown. A retry path
                    // (e.g. "Try again" button on the error sheet) is a UX
                    // improvement tracked for the WP-Host work package; it is
                    // out of scope for auth-WP.
                    throw OfemAuthError.msalRemoveFailed(alias, error)
                }
            }
        }

        try await configStore.updateAndSave { config in
            config.accounts.removeValue(forKey: alias)
            if config.defaultAccount == alias {
                config.defaultAccount = ""
            }
        }
        // Delete the file-backed token blob so re-adding the same alias for a
        // different user does not resurrect the previous user's refresh token.
        if let store = fileTokenStore {
            do {
                try await store.delete(alias: alias)
            } catch let FileTokenStoreError.deleteFailed(a, e) {
                Self.log.error("OfemAuth: failed to delete token blob for alias=\(a, privacy: .public): \(e)")
            } catch FileTokenStoreError.notFound {
                // No file-backed cache was used for this alias — benign.
            } catch {
                // Surface unexpected errors (lockTimeout, lockFailed, etc.) so
                // a failed token-blob purge is not silently ignored.
                Self.log.error("OfemAuth: unexpected error deleting token blob for alias=\(alias, privacy: .public): \(error)")
                throw error
            }
        }
        // Evict the cached MSAL client for the removed account's (clientID, tenantID) pair.
        evictClients(for: alias, in: snap)
    }

    /// Returns the alias of the configured default account.
    public func defaultAccount() -> String? {
        let snap = configStore.snapshot()
        let d = snap.defaultAccount
        return d.isEmpty ? nil : d
    }

    /// Sets the default account alias.
    public func setDefaultAccount(alias: String) async throws {
        let snap = configStore.snapshot()
        guard snap.accounts[alias] != nil else {
            throw OfemAuthError.unknownAlias(alias)
        }
        try await configStore.updateAndSave { config in
            config.defaultAccount = alias
        }
    }

    // MARK: - Token acquisition

    /// Acquires an access token for the OneLake ADLS Gen2 DFS audience.
    public func token(alias: String) async throws -> String {
        try await tokenForScope(alias: alias, scope: .oneLake)
    }

    /// Acquires an access token for the given audience scope.
    ///
    /// Concurrent callers for the same `(alias, scope)` pair share a single
    /// in-flight refresh `Task`. The first caller starts the MSAL refresh; all
    /// subsequent callers `await` the same task and receive its result or error.
    /// This prevents a "refresh stampede" under Finder's bursty I/O pattern.
    public func tokenForScope(alias: String, scope: TokenScope) async throws -> String {
        try await accessTokenForScope(alias: alias, scope: scope).value
    }

    /// Acquires an `AccessToken` (bearer string + MSAL expiry) for the given scope.
    ///
    /// Used by `OfemAuthenticator` via `TokenProvider.tokenWithExpiry` to supply
    /// accurate expiry dates to the Alamofire credential without JWT parsing.
    private func accessTokenForScope(alias: String, scope: TokenScope) async throws -> AccessToken {
        let snap = configStore.snapshot()
        guard let cfg = snap.accounts[alias] else {
            throw OfemAuthError.unknownAlias(alias)
        }
        guard !cfg.homeAccountID.isEmpty else {
            Self.log.warning("OfemAuth: account \(alias, privacy: .public) has no homeAccountID; re-auth required")
            throw OfemAuthError.interactionRequired
        }
        guard !scope.scopes.isEmpty else {
            throw OfemAuthError.emptyScopes
        }

        let eClientID = effectiveClientID(for: cfg)
        let client = try clientFor(clientID: eClientID, tenantID: cfg.tenantID, alias: alias)

        // Per-account in-flight coalescing: if a refresh is already underway for
        // this (alias, scope), await the existing Task rather than starting another.
        // Ordering assumption: `TokenScope.scopes` is `[String]` (a stable-ordered
        // array), so joined(separator:) is deterministic for the same logical scope.
        // If scopes were ever backed by a Set, two calls for the same scope could
        // produce different keys and miss coalescing. Keep scopes as [String].
        let dedupKey = "\(alias)|\(scope.scopes.joined(separator: ","))"
        if let existing = inFlightTokenTasks[dedupKey] {
            return try await existing.value
        }

        let task = Task<AccessToken, Error> {
            try await silentToken(
                client: client,
                homeAccountID: cfg.homeAccountID,
                scopes: scope.scopes,
                alias: alias
            )
        }
        inFlightTokenTasks[dedupKey] = task

        defer {
            // Evict on completion regardless of success or failure so the next
            // call always starts a fresh refresh rather than awaiting a failed task.
            inFlightTokenTasks.removeValue(forKey: dedupKey)
        }

        return try await task.value
    }

    // MARK: - TokenProvider

    /// Returns the bearer token string for the given alias and scope.
    ///
    /// Satisfies the `TokenProvider` protocol so `OfemAuth` can be passed
    /// directly to `SessionPool` without an intermediate adapter.
    public func token(alias: String, scope: TokenScope) async throws -> String {
        try await tokenForScope(alias: alias, scope: scope)
    }

    /// Returns the bearer token and its MSAL-provided expiry for the given scope.
    ///
    /// Used by `OfemAuthenticator` to populate `OfemCredential.expiresAt`
    /// with the real `MSALResult.expiresOn` date, enabling the 5-minute
    /// early-refresh window without JWT parsing.
    public func tokenWithExpiry(alias: String, scope: TokenScope) async throws -> (String, Date) {
        let t = try await accessTokenForScope(alias: alias, scope: scope)
        return (t.value, t.expiresOn)
    }

    // MARK: - Private helpers

    /// Returns the effective client ID for the given account config.
    ///
    /// Prefers the per-account `clientID` override (non-nil, non-empty) over the
    /// module-level default. Extracted as a single helper so the three call sites
    /// (`removeAccount`, `tokenForScope`, `evictClients`) cannot drift.
    private func effectiveClientID(for cfg: Account) -> String {
        cfg.clientID.flatMap { $0.isEmpty ? nil : $0 } ?? clientID
    }

    /// Returns the cache key for a `(clientID, tenantID)` pair.
    ///
    /// All read and write sites use this helper so the key format is defined
    /// once and cannot drift between the build site and the eviction site.
    private func clientKey(clientID: String, tenantID: String) -> String {
        "\(clientID)|\(tenantID)"
    }

    /// Returns the cached MSAL client for the `(clientID, tenantID)` pair,
    /// building it lazily on first use.
    ///
    /// Cache key is `"<clientID>|<tenantID>"` — one `MSALPublicClientApplication`
    /// per app-registration+tenant pair, shared across aliases that authenticate
    /// against the same pair. Including `clientID` in the key ensures that an
    /// account whose `clientID` changes in config rebuilds the client rather than
    /// reusing a stale instance.
    private func clientFor(
        clientID: String,
        tenantID: String,
        alias: String
    ) throws -> any MsalAuthClientProtocol {
        let key = clientKey(clientID: clientID, tenantID: tenantID)
        if let cached = clients[key] { return cached }
        let client = try msalClientFactory.makeClient(
            clientID: clientID,
            tenantID: tenantID,
            cacheStrategy: cacheStrategy,
            fileTokenStore: fileTokenStore,
            alias: alias
        )
        clients[key] = client
        return client
    }

    /// Runs MSAL silent token acquisition and maps interaction-required
    /// errors to ``OfemAuthError/interactionRequired``, config/credential
    /// rejections to ``OfemAuthError/configRejection(_:)``, and all other
    /// failures to ``OfemAuthError/silentTokenFailed(_:)``.
    ///
    /// Account lookup is handled inside ``MsalAuthClientProtocol/acquireTokenSilent(scopes:homeAccountID:)``.
    /// `MsalAuthClientError.accountNotFound` maps to ``OfemAuthError/interactionRequired``
    /// because a missing cache entry means the user must sign in again.
    private func silentToken(
        client: any MsalAuthClientProtocol,
        homeAccountID: String,
        scopes: [String],
        alias: String
    ) async throws -> AccessToken {
        do {
            return try await client.acquireTokenSilent(scopes: scopes, homeAccountID: homeAccountID)
        } catch {
            if isInteractionRequired(error) {
                Self.log.info("OfemAuth: silent acquisition for \(alias, privacy: .public) requires interaction")
                throw OfemAuthError.interactionRequired
            }
            if case MsalAuthClientError.accountNotFound = error {
                Self.log.warning("OfemAuth: account \(alias, privacy: .public) not in MSAL cache; re-auth required")
                throw OfemAuthError.interactionRequired
            }
            // invalid_grant (-42004) arrives under MSALErrorInternal (-50000), not
            // under MSALError.interactionRequired (-50002), so isInteractionRequired
            // does not catch it. It means the refresh token was revoked or the grant
            // is no longer valid (admin password reset, MFA re-enrollment, Conditional
            // Access policy change). The user can self-recover by signing in again.
            if isInvalidGrant(error) {
                Self.log.info("OfemAuth: invalid_grant for \(alias, privacy: .public); re-auth required")
                throw OfemAuthError.interactionRequired
            }
            // Distinguish a permanent config rejection (invalid_client -42003) from
            // an ordinary transient failure. A config rejection cannot be fixed by
            // re-auth — it indicates a misconfigured Entra app registration (e.g.
            // missing FPE redirect URI). Surface it distinctly so operators can
            // diagnose the root cause without looping users through "Sign in again".
            if isConfigRejection(error) {
                Self.log.critical(
                    "OfemAuth: config/credential rejection for \(alias, privacy: .public) — check Entra app registration redirect URIs and client credentials: \(error, privacy: .private)"
                )
                throw OfemAuthError.configRejection(alias)
            }
            // Log the underlying error before stripping it from the thrown case.
            // The error is .private so UPN / tenant detail stays out of unredacted
            // logs; alias is .public (not PII).
            Self.log.error("OfemAuth: silent token for \(alias, privacy: .public) failed: \(error, privacy: .private)")
            throw OfemAuthError.silentTokenFailed(alias)
        }
    }

    /// Returns `true` when the MSAL error indicates the user must interact
    /// again (Conditional Access challenge, MFA re-prompt, expired refresh
    /// token, consent required, etc.).
    ///
    /// Detection is based on:
    /// 1. The **typed** MSAL error code `MSALError.interactionRequired`.
    /// 2. Server-side AADSTS numeric codes that `docs/auth.md` explicitly
    ///    calls out: 50076 (MFA required), 50079 (Conditional Access), 50078,
    ///    50158. These surface under MSAL as an `MSALErrorDomain` error with
    ///    the integer STS codes in `MSALSTSErrorCodesKey` (`NSArray<NSNumber *>`
    ///    in MSAL's userInfo — see MSALError.h). String-keyed `MSALOAuthErrorKey`
    ///    and `MSALOAuthSubErrorKey` carry OAuth error and sub-error tokens
    ///    (e.g. `"invalid_grant"`, `"mfa_required"`) and are also checked as a
    ///    secondary signal.
    ///
    /// Locale note: `NSLocalizedDescriptionKey` substring matching was
    /// intentionally removed — it is fragile on non-English OS locales and
    /// over-matches if the AADSTS code appears in a description for a different
    /// error. All detection here is on machine-readable, locale-stable keys.
    ///
    /// Not matched: `MSALError.serverDeclinedScopes` — a partial-success case
    /// where the server issued tokens for a subset of the requested scopes.
    /// Callers should handle scope downgrade at a higher level.
    func isInteractionRequired(_ error: Error) -> Bool {
        let nsError = error as NSError
        guard nsError.domain == MSALErrorDomain else {
            // Non-MSAL errors (network timeouts, etc.) are not interaction-required.
            return false
        }
        // Primary: the typed MSAL interaction-required code.
        if nsError.code == MSALError.interactionRequired.rawValue {
            return true
        }
        // Secondary: AADSTS numeric STS codes in MSALSTSErrorCodesKey.
        // MSAL populates this as NSArray<NSNumber *> (see MSALErrorConverter.m).
        // Per docs/auth.md:79: 50076 (MFA required), 50079 (CA), 50078, 50158.
        let aadstsIntCodes: Set = [50076, 50079, 50078, 50158]
        if let stsCodes = nsError.userInfo["MSALSTSErrorCodesKey"] as? [NSNumber] {
            if stsCodes.contains(where: { aadstsIntCodes.contains($0.intValue) }) {
                return true
            }
        }
        // Tertiary: OAuth error / sub-error string tokens in MSALOAuthErrorKey
        // and MSALOAuthSubErrorKey. These are locale-stable machine-readable
        // strings (e.g. "invalid_grant", "mfa_required") that MSAL sets from
        // the STS JSON response regardless of OS locale.
        let oauthError = nsError.userInfo["MSALOAuthErrorKey"] as? String ?? ""
        let subError = nsError.userInfo["MSALOAuthSubErrorKey"] as? String ?? ""
        // Check for the OAuth/sub-error token strings that AADSTS MFA/CA errors produce.
        // These are checked via exact/substring match on the structured userInfo fields,
        // NOT on NSLocalizedDescriptionKey (which is locale-translated).
        let aadstsCodeStrings: Set = ["AADSTS50076", "AADSTS50079", "AADSTS50078", "AADSTS50158"]
        for code in aadstsCodeStrings {
            if oauthError.contains(code) || subError.contains(code) {
                return true
            }
        }
        return false
    }

    /// Returns `true` when the MSAL error is `invalid_grant` (-42004) — a
    /// revoked or expired refresh token that the user can fix by signing in
    /// again (admin password reset, MFA re-enrollment, Conditional Access
    /// policy change).
    ///
    /// This arrives under the MSAL top-level code `MSALErrorInternal` (-50000)
    /// with `MSALInternalErrorCodeKey` = -42004. Because the top-level code is
    /// not `MSALError.interactionRequired` (-50002), ``isInteractionRequired(_:)``
    /// does not detect it; this helper bridges the gap so the caller can route
    /// it to the ``OfemAuthError/interactionRequired`` path.
    func isInvalidGrant(_ error: Error) -> Bool {
        let nsError = error as NSError
        guard nsError.domain == MSALErrorDomain,
              nsError.code == msalErrorInternalCode
        else {
            return false
        }
        guard let internalCode = nsError.userInfo[MSALInternalErrorCodeKey] as? NSNumber else {
            return false
        }
        // MSALInternalErrorInvalidGrant = -42004
        return internalCode.intValue == -42004
    }

    /// Returns `true` when the MSAL error indicates a permanent server-side
    /// config rejection that re-authentication cannot fix.
    ///
    /// Detected internal error code (in `MSALInternalErrorCodeKey`):
    /// - `-42003` (`MSALInternalErrorInvalidClient`): the redirect URI or
    ///   client ID was rejected by Entra. The canonical cause in OFEM is a
    ///   missing FPE redirect URI in the app registration — once `invalid_client`
    ///   is returned by the token endpoint, re-auth with the same credentials
    ///   will also fail. The fix is an out-of-band registration update.
    ///
    /// The code arrives under the MSAL top-level code `MSALErrorInternal`
    /// (-50000) with the specific internal code in `MSALInternalErrorCodeKey`
    /// (`NSNumber`).
    ///
    /// Note: `invalid_grant` (-42004) is handled separately by
    /// ``isInvalidGrant(_:)`` and routes to ``OfemAuthError/interactionRequired``
    /// because a revoked refresh token is recoverable by interactive re-auth.
    func isConfigRejection(_ error: Error) -> Bool {
        let nsError = error as NSError
        guard nsError.domain == MSALErrorDomain,
              nsError.code == msalErrorInternalCode
        else {
            return false
        }
        guard let internalCode = nsError.userInfo[MSALInternalErrorCodeKey] as? NSNumber else {
            return false
        }
        // MSALInternalErrorInvalidClient = -42003
        // (See MSALInternalError enum in MSALError.h)
        return internalCode.intValue == -42003
    }

    /// Evicts the cached MSAL client for the `(clientID, tenantID)` pair
    /// associated with the given alias, using the account snapshot taken
    /// before removal.
    ///
    /// The cache key is `"<clientID>|<tenantID>"`. Evicting it here means
    /// the next token request for any alias sharing the same pair will
    /// rebuild the client lazily — picking up the correct Keychain state
    /// after the MSAL remove call in ``removeAccount(alias:)``.
    private func evictClients(for alias: String, in snap: OfemConfig) {
        if let cfg = snap.accounts[alias] {
            let key = clientKey(clientID: effectiveClientID(for: cfg), tenantID: cfg.tenantID)
            clients.removeValue(forKey: key)
        }
    }
}

// MARK: - MsalAuthClientFactory

/// Factory protocol for creating ``MsalAuthClientProtocol`` instances.
///
/// Inject a test double via ``OfemAuth/init(configStore:clientID:cacheStrategy:fileTokenStore:msalClientFactory:)``
/// to cover the token-acquisition path in unit tests without a real MSAL transport.
public protocol MsalAuthClientFactory: Sendable {
    func makeClient(
        clientID: String,
        tenantID: String,
        cacheStrategy: TokenCacheStrategy,
        fileTokenStore: FileTokenStore?,
        alias: String
    ) throws -> any MsalAuthClientProtocol
}

// MARK: - DefaultMsalAuthClientFactory

/// Production factory: builds real ``MsalAuthClient`` instances.
public struct DefaultMsalAuthClientFactory: MsalAuthClientFactory, Sendable {
    public init() {}

    public func makeClient(
        clientID: String,
        tenantID: String,
        cacheStrategy: TokenCacheStrategy,
        fileTokenStore: FileTokenStore?,
        alias: String
    ) throws -> any MsalAuthClientProtocol {
        try MsalAuthClient(
            clientID: clientID,
            tenantID: tenantID,
            cacheStrategy: cacheStrategy,
            fileTokenStore: fileTokenStore,
            alias: alias
        )
    }
}

// MARK: - OfemAuthError

/// Errors thrown by ``OfemAuth``.
public enum OfemAuthError: Error, CustomStringConvertible, Equatable {
    public static func == (lhs: OfemAuthError, rhs: OfemAuthError) -> Bool {
        switch (lhs, rhs) {
        case (.interactionRequired, .interactionRequired): true
        case (.emptyAlias, .emptyAlias): true
        case let (.duplicateAlias(a), .duplicateAlias(b)): a == b
        case let (.unknownAlias(a), .unknownAlias(b)): a == b
        case (.emptyScopes, .emptyScopes): true
        case let (.silentTokenFailed(a), .silentTokenFailed(b)): a == b
        case let (.configRejection(a), .configRejection(b)): a == b
        case let (.msalRemoveFailed(a, _), .msalRemoveFailed(b, _)): a == b
        default: false
        }
    }

    /// The user must interact again to complete authentication.
    ///
    /// Callers should surface a "click to re-authenticate" indicator rather
    /// than blocking.
    case interactionRequired

    /// The alias provided for the account was empty.
    case emptyAlias

    case duplicateAlias(String)
    case unknownAlias(String)

    /// No OAuth scopes were configured for the token request.
    case emptyScopes

    /// Silent token acquisition failed with a non-interaction-required error.
    ///
    /// Only the alias is stored — not the underlying MSAL error — to prevent
    /// UPN or other PII from escaping the `.private` log discipline applied
    /// at the sign-in site. The underlying error is logged separately before
    /// this case is thrown.
    case silentTokenFailed(String)

    /// MSAL rejected the token request with `invalid_client` (-42003) or
    /// `invalid_grant` (-42004) — a permanent config or credential rejection
    /// that re-authentication cannot fix.
    ///
    /// The most common cause in OFEM is a missing FPE redirect URI in the
    /// Entra app registration. See `docs/auth.md` for the required redirect
    /// URI list. The full MSAL error (including `MSALInternalErrorCodeKey`)
    /// is logged at `.critical` level before this case is thrown so the
    /// misconfiguration is diagnosable from logs without needing a debugger.
    case configRejection(String)

    /// MSAL Keychain refresh-token removal failed during logout.
    ///
    /// The refresh token has not been purged. The caller should surface an
    /// error to the user so they can retry sign-out.
    case msalRemoveFailed(String, Error)

    public var description: String {
        switch self {
        case .interactionRequired:
            "auth: interaction required"
        case .emptyAlias:
            "auth: alias must not be empty"
        case let .duplicateAlias(alias):
            "auth: account \"\(alias)\" already exists"
        case let .unknownAlias(alias):
            "auth: account \"\(alias)\" not found"
        case .emptyScopes:
            "auth: no scopes configured"
        case let .silentTokenFailed(alias):
            // The underlying error is logged with .private before this is thrown;
            // the description intentionally omits it to prevent PII propagation
            // via .public log calls on this error's description.
            "auth: silent token for \"\(alias)\" failed (see log for details)"
        case let .configRejection(alias):
            // The full MSAL error is logged at .critical before this is thrown.
            // The description omits it to prevent PII propagation; callers should
            // treat this as a permanent misconfiguration, not a transient failure.
            "auth: config/credential rejection for \"\(alias)\" — check Entra app registration (see log)"
        case let .msalRemoveFailed(alias, _):
            // Underlying error is not interpolated to avoid leaking PII from
            // MSAL error descriptions.
            "auth: MSAL Keychain remove failed for \"\(alias)\" — refresh token may persist"
        }
    }
}
