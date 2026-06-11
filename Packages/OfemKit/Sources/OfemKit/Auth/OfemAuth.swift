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
/// `OfemAuth` is `@MainActor` isolated to keep it simple. Token acquisition
/// dispatches to MSAL's own concurrency model via `async/await`. The client
/// cache dictionary is read and written only on the main actor.
@MainActor
public final class OfemAuth {
    // MARK: - Properties

    private let configStore: OfemConfigStore
    private let clientID: String
    private let cacheStrategy: TokenCacheStrategy
    private let fileTokenStore: FileTokenStore?

    /// In-process MSAL client cache: key = `"<tenantID>|<alias>"`.
    /// Cleared when an account is removed.
    private var clients: [String: MsalAuthClient] = [:]

    private static let log = Logger(subsystem: "dev.debruyn.ofem", category: "OfemAuth")

    // MARK: - ErrInteractionRequired

    /// Sentinel thrown when MSAL cannot silently acquire a token and the
    /// user must sign in interactively again.
    public static let interactionRequired = OfemAuthError.interactionRequired

    // MARK: - Initialisation

    /// Creates an `OfemAuth` instance.
    ///
    /// - Parameters:
    /// - configStore: Loaded `OfemConfigStore` (accounts are read from
    /// here and written back after `addAccount`/`removeAccount`).
    /// - clientID: The Entra App Registration GUID. Default:
    /// ``ofemEntraClientID`` (built-in OFEM registration).
    /// - cacheStrategy: Token cache backend. Default: `.msalKeychain`.
    /// - fileTokenStore: Required when `cacheStrategy ==.fileBackedFallback`.
    public init(
        configStore: OfemConfigStore,
        clientID: String = ofemEntraClientID,
        cacheStrategy: TokenCacheStrategy = .msalKeychain,
        fileTokenStore: FileTokenStore? = nil
    ) {
        self.configStore = configStore
        self.clientID = clientID
        self.cacheStrategy = cacheStrategy
        self.fileTokenStore = fileTokenStore
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

    /// Removes the account with the given alias from the config.
    ///
    /// Also evicts the cached MSAL client for that alias so a subsequent
    /// add-then-remove-then-add cycle does not reuse a stale client.
    ///
    /// Note: the MSAL Keychain cache entry is NOT removed here because MSAL
    /// manages its own cache lifecycle. If the alias is re-added, MSAL will
    /// try the existing cache first, which is the correct behaviour.
    public func removeAccount(alias: String) async throws {
        let snap = configStore.snapshot()
        guard snap.accounts[alias] != nil else {
            throw OfemAuthError.unknownAlias(alias)
        }
        try await configStore.updateAndSave { config in
            config.accounts.removeValue(forKey: alias)
            if config.defaultAccount == alias {
                config.defaultAccount = ""
            }
        }
        // Evict all cached MSAL clients for this alias.
        evictClients(for: alias)
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

        let effectiveClientID = cfg.clientID.flatMap { $0.isEmpty ? nil : $0 } ?? clientID
        let client = try clientFor(alias: alias, tenantID: cfg.tenantID, effectiveClientID: effectiveClientID)

        let msalAccount = try msalAccount(for: client, homeAccountID: cfg.homeAccountID, alias: alias)
        return try await silentToken(
            client: client,
            account: msalAccount,
            scopes: scope.scopes,
            alias: alias
        )
    }

    // MARK: - Private helpers

    /// Returns the cached MSAL client for the `(alias, tenantID, clientID)`
    /// triple, building it lazily on first use.
    private func clientFor(
        alias: String,
        tenantID: String,
        effectiveClientID: String
    ) throws -> MsalAuthClient {
        let key = "\(tenantID)|\(alias)"
        if let cached = clients[key] { return cached }
        let client = try MsalAuthClient(
            clientID: effectiveClientID,
            tenantID: tenantID,
            cacheStrategy: cacheStrategy,
            fileTokenStore: fileTokenStore,
            alias: alias
        )
        clients[key] = client
        return client
    }

    /// Finds the `MSALAccount` in the client's cache whose identifier
    /// matches `homeAccountID`.
    private func msalAccount(
        for client: MsalAuthClient,
        homeAccountID: String,
        alias: String
    ) throws -> MSALAccount {
        guard !homeAccountID.isEmpty else {
            Self.log.warning("OfemAuth: account \(alias, privacy: .public) has no homeAccountID; re-auth required")
            throw OfemAuthError.interactionRequired
        }
        let allAccounts = try client.accounts()
        for account in allAccounts {
            guard let identifier = account.identifier, !identifier.isEmpty else { continue }
            if identifier == homeAccountID {
                return account
            }
        }
        Self.log.warning("OfemAuth: account \(alias, privacy: .public) not in MSAL cache; re-auth required")
        throw OfemAuthError.interactionRequired
    }

    /// Runs MSAL silent token acquisition and maps interaction-required
    /// errors to ``OfemAuthError/interactionRequired``.
    ///
    /// The `account` parameter is passed with `nonisolated(unsafe)` to
    /// cross the `@MainActor` isolation boundary into the MSAL async call.
    /// `MSALAccount` is an Objective-C class that MSAL treats as thread-safe
    /// for read operations; we only pass it in and never mutate it.
    private func silentToken(
        client: MsalAuthClient,
        account: MSALAccount,
        scopes: [String],
        alias: String
    ) async throws -> String {
        guard !scopes.isEmpty else {
            throw OfemAuthError.emptyScopes
        }
        // Capture account in a nonisolated(unsafe) wrapper so it can cross
        // the actor boundary without a Sendable warning. MSALAccount is an
        // Objective-C class; MSAL guarantees it is safe to read from any
        // thread after it is fully initialised.
        nonisolated(unsafe) let msalAccount = account
        do {
            let result = try await client.acquireTokenSilent(scopes: scopes, account: msalAccount)
            return result.accessToken
        } catch {
            if isInteractionRequired(error) {
                Self.log.info("OfemAuth: silent acquisition for \(alias, privacy: .public) requires interaction: \(error.localizedDescription, privacy: .public)")
                throw OfemAuthError.interactionRequired
            }
            throw OfemAuthError.silentTokenFailed(alias, error)
        }
    }

    /// Returns `true` when the MSAL error indicates the user must interact
    /// again (Conditional Access challenge, MFA re-prompt, expired refresh
    /// token, consent required, etc.).
    private func isInteractionRequired(_ error: Error) -> Bool {
        let msg = error.localizedDescription.lowercased()
        let signals = [
            "interaction_required",
            "login_required",
            "consent_required",
            "invalid_grant",
            "mfa_required",
            "password_change_required",
            "aadsts50076",
            "aadsts50079",
            "aadsts50158",
            "aadsts50173",
            "aadsts65001",
            "aadsts70043",
            "aadsts700082",
        ]
        for signal in signals {
            if msg.contains(signal) { return true }
        }
        // MSAL Swift also reports interaction-required via a typed error code.
        // MSALError.interactionRequired covers expired refresh tokens, Conditional
        // Access challenges, MFA re-prompts, and similar cases that require the
        // user to interact again. MSALError.serverDeclinedScopes is intentionally
        // excluded here: it means the server issued tokens for a subset of the
        // requested scopes (e.g. OneLake granted but Fabric admin-consent missing).
        // That is a partial-success case that callers should handle at a higher
        // level (e.g. disable Fabric discovery) rather than forcing a full re-auth.
        let nsError = error as NSError
        if nsError.domain == MSALErrorDomain {
            if nsError.code == MSALError.interactionRequired.rawValue {
                return true
            }
        }
        return false
    }

    /// Evicts all cached MSAL clients for the given alias suffix.
    private func evictClients(for alias: String) {
        let suffix = "|\(alias)"
        clients.keys
            .filter { $0.hasSuffix(suffix) }
            .forEach { clients.removeValue(forKey: $0) }
    }
}

// MARK: - OfemAuthError

/// Errors thrown by ``OfemAuth``.
public enum OfemAuthError: Error, CustomStringConvertible {
    /// The user must interact again to complete authentication.
    ///
    /// Callers should surface a "click to re-authenticate" indicator rather
    /// than blocking.
    case interactionRequired

    case emptyAlias
    case duplicateAlias(String)
    case unknownAlias(String)
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
            return "auth: at least one scope is required"
        case let .silentTokenFailed(alias, error):
            return "auth: silent token for \"\(alias)\" failed: \(error)"
        }
    }
}
