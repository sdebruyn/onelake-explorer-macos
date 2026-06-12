import Foundation
@preconcurrency import MSAL
import os.log

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
public actor OfemAuth {
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
    public func addAccount(_ account: Account) async throws {
        guard !account.alias.isEmpty else {
            throw OfemAuthError.emptyAlias
        }
        try AccountAlias.validate(account.alias)
        let snap = configStore.snapshot()
        if snap.accounts[account.alias] != nil {
            throw OfemAuthError.duplicateAlias(account.alias)
        }
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
    public func removeAccount(alias: String) async throws {
        let snap = configStore.snapshot()
        guard let cfg = snap.accounts[alias] else {
            throw OfemAuthError.unknownAlias(alias)
        }

        // Purge the MSAL Keychain refresh token before removing the config
        // entry so the client is still available for the lookup.
        if cacheStrategy == .msalKeychain, !cfg.homeAccountID.isEmpty {
            let effectiveClientID = cfg.clientID.flatMap { $0.isEmpty ? nil : $0 } ?? clientID
            if let msalClient = try? clientFor(clientID: effectiveClientID, tenantID: cfg.tenantID, alias: alias) {
                do {
                    try msalClient.removeAccount(homeAccountID: cfg.homeAccountID)
                } catch let MsalAuthClientError.accountNotFound(id) {
                    // Already absent from the MSAL cache — benign.
                    Self.log.debug("OfemAuth: removeAccount: homeAccountID=\(id, privacy: .public) not in MSAL cache (already purged)")
                } catch {
                    Self.log.error("OfemAuth: removeAccount: MSAL remove failed for alias=\(alias, privacy: .public): \(error)")
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
                try store.delete(alias: alias)
            } catch FileTokenStoreError.deleteFailed(let a, let e) {
                Self.log.error("OfemAuth: failed to delete token blob for alias=\(a, privacy: .public): \(e)")
            } catch {
                // notFound is benign (no file-backed cache was used for this alias).
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
    public func tokenForScope(alias: String, scope: TokenScope) async throws -> String {
        let snap = configStore.snapshot()
        guard let cfg = snap.accounts[alias] else {
            throw OfemAuthError.unknownAlias(alias)
        }
        guard !cfg.homeAccountID.isEmpty else {
            Self.log.warning("OfemAuth: account \(alias, privacy: .public) has no homeAccountID; re-auth required")
            throw OfemAuthError.interactionRequired
        }

        let effectiveClientID = cfg.clientID.flatMap { $0.isEmpty ? nil : $0 } ?? clientID
        let client = try clientFor(clientID: effectiveClientID, tenantID: cfg.tenantID, alias: alias)

        return try await silentToken(
            client: client,
            homeAccountID: cfg.homeAccountID,
            scopes: scope.scopes,
            alias: alias
        )
    }

    // MARK: - Private helpers

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
        let key = "\(clientID)|\(tenantID)"
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
    /// errors to ``OfemAuthError/interactionRequired``.
    ///
    /// Account lookup is handled inside ``MsalAuthClientProtocol/acquireTokenSilent(scopes:homeAccountID:)``.
    /// `MsalAuthClientError.accountNotFound` maps to ``OfemAuthError/interactionRequired``
    /// because a missing cache entry means the user must sign in again.
    private func silentToken(
        client: any MsalAuthClientProtocol,
        homeAccountID: String,
        scopes: [String],
        alias: String
    ) async throws -> String {
        do {
            return try await client.acquireTokenSilent(scopes: scopes, homeAccountID: homeAccountID)
        } catch {
            if isInteractionRequired(error) {
                Self.log.info("OfemAuth: silent acquisition for \(alias, privacy: .public) requires interaction: \(error.localizedDescription, privacy: .public)")
                throw OfemAuthError.interactionRequired
            }
            if case MsalAuthClientError.accountNotFound = error {
                Self.log.warning("OfemAuth: account \(alias, privacy: .public) not in MSAL cache; re-auth required")
                throw OfemAuthError.interactionRequired
            }
            throw OfemAuthError.silentTokenFailed(alias, error)
        }
    }

    /// Returns `true` when the MSAL error indicates the user must interact
    /// again (Conditional Access challenge, MFA re-prompt, expired refresh
    /// token, consent required, etc.).
    ///
    /// Detection is based on the **typed** MSAL error code and domain rather
    /// than substring-matching `localizedDescription`, which is a user-facing,
    /// potentially localized string with no contractual guarantee to contain
    /// OAuth error codes.
    ///
    /// `MSALError.interactionRequired` covers expired refresh tokens, Conditional
    /// Access challenges, MFA re-prompts, and similar cases.
    /// `MSALError.serverDeclinedScopes` is intentionally excluded: it means the
    /// server issued tokens for a subset of the requested scopes — a partial-
    /// success case callers should handle at a higher level rather than forcing
    /// a full re-auth.
    func isInteractionRequired(_ error: Error) -> Bool {
        let nsError = error as NSError
        guard nsError.domain == MSALErrorDomain else {
            // Non-MSAL errors (network timeouts, etc.) are not interaction-required.
            return false
        }
        return nsError.code == MSALError.interactionRequired.rawValue
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
            let effectiveClientID = cfg.clientID.flatMap { $0.isEmpty ? nil : $0 } ?? clientID
            let key = "\(effectiveClientID)|\(cfg.tenantID)"
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
        case (.interactionRequired, .interactionRequired): return true
        case (.emptyAlias, .emptyAlias): return true
        case let (.duplicateAlias(a), .duplicateAlias(b)): return a == b
        case let (.unknownAlias(a), .unknownAlias(b)): return a == b
        case (.emptyScopes, .emptyScopes): return true
        case let (.silentTokenFailed(a, _), .silentTokenFailed(b, _)): return a == b
        default: return false
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

    case silentTokenFailed(String, Error)

    public var description: String {
        switch self {
        case .interactionRequired:
            return "auth: interaction required"
        case .emptyAlias:
            return "auth: alias must not be empty"
        case let .duplicateAlias(alias):
            return "auth: account \"\(alias)\" already exists"
        case let .unknownAlias(alias):
            return "auth: account \"\(alias)\" not found"
        case .emptyScopes:
            return "auth: no scopes configured"
        case let .silentTokenFailed(alias, error):
            return "auth: silent token for \"\(alias)\" failed: \(error)"
        }
    }
}
