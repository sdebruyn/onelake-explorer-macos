import Foundation
@preconcurrency import MSAL
import os.log

// MARK: - OfemAuth

/// Top-level authentication façade for OFEM.
///
/// `OfemAuth` is the single entry point for token acquisition. It mirrors
/// the Go `Registry` type (`internal/auth/registry.go`) in terms of
/// responsibility:
///
///  - Manages the set of signed-in accounts via ``OfemConfigStore``.
///  - Persists per-account secrets (token cache) via MSAL's Keychain backend.
///  - Acquires tokens silently from MSAL, returning ``OfemAuthError/interactionRequired``
///    when the refresh token has expired or a Conditional Access policy fires.
///  - One `MSALPublicClientApplication` per `(clientID, tenantID)` pair,
///    cached in-process for fast silent acquisition.
///
/// ## Thread safety
///
/// `OfemAuth` is `@MainActor` isolated to keep it simple. Token acquisition
/// dispatches to MSAL's own concurrency model via `async/await`. The client
/// cache dictionary is read and written only on the main actor.
///
/// Mirrors `internal/auth/registry.go` — `Registry`.
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
    ///
    /// Mirrors `internal/auth/msal.go` — `ErrInteractionRequired`.
    public static let interactionRequired = OfemAuthError.interactionRequired

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
    ///
    /// Mirrors `internal/auth/registry.go` — `Registry.List()`.
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
    /// Mirrors `internal/auth/registry.go` — `Registry.Add()`.
    public func addAccount(_ account: Account) throws {
        guard !account.alias.isEmpty else {
            throw OfemAuthError.emptyAlias
        }
        try AccountAlias.validate(account.alias)
        let snap = configStore.snapshot()
        if snap.accounts[account.alias] != nil {
            throw OfemAuthError.duplicateAlias(account.alias)
        }
        try configStore.updateAndSave { config in
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
    ///
    /// Mirrors `internal/auth/registry.go` — `Registry.Remove()`.
    public func removeAccount(alias: String) throws {
        let snap = configStore.snapshot()
        guard snap.accounts[alias] != nil else {
            throw OfemAuthError.unknownAlias(alias)
        }
        try configStore.updateAndSave { config in
            config.accounts.removeValue(forKey: alias)
            if config.defaultAccount == alias {
                config.defaultAccount = ""
            }
        }
        // Evict all cached MSAL clients for this alias.
        evictClients(for: alias)
    }

    /// Returns the alias of the configured default account.
    ///
    /// Mirrors `internal/auth/registry.go` — `Registry.Default()`.
    public func defaultAccount() -> String? {
        let snap = configStore.snapshot()
        let d = snap.defaultAccount
        return d.isEmpty ? nil : d
    }

    /// Sets the default account alias.
    ///
    /// Mirrors `internal/auth/registry.go` — `Registry.SetDefault()`.
    public func setDefaultAccount(alias: String) throws {
        let snap = configStore.snapshot()
        guard snap.accounts[alias] != nil else {
            throw OfemAuthError.unknownAlias(alias)
        }
        try configStore.updateAndSave { config in
            config.defaultAccount = alias
        }
    }

    // MARK: - Token acquisition

    /// Acquires an access token for the OneLake ADLS Gen2 DFS audience.
    ///
    /// Mirrors `internal/auth/registry.go` — `Registry.Token()`.
    public func token(alias: String) async throws -> String {
        try await tokenForScope(alias: alias, scope: .oneLake)
    }

    /// Acquires an access token for the given audience scope.
    ///
    /// Mirrors `internal/auth/registry.go` — `Registry.TokenForScopes()`.
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
    ///
    /// Mirrors `internal/auth/registry.go` — `Registry.clientFor()`.
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
    ///
    /// Mirrors `internal/auth/registry.go` — `Registry.findMSALAccount()`.
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
    ///
    /// Mirrors `internal/auth/msal.go` — `SilentToken`.
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
    ///
    /// Mirrors `internal/auth/msal.go` — `isInteractionRequired`.
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
        // MSAL Swift reports interaction-required via MSALError codes.
        let nsError = error as NSError
        if nsError.domain == MSALErrorDomain {
            switch nsError.code {
            case MSALError.interactionRequired.rawValue,
                 MSALError.serverDeclinedScopes.rawValue:
                return true
            default:
                break
            }
        }
        return false
    }

    /// Evicts all cached MSAL clients for the given alias suffix.
    ///
    /// Mirrors `internal/auth/registry.go` — eviction in `Registry.Remove()`.
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
    /// than blocking. Mirrors `internal/auth/msal.go` — `ErrInteractionRequired`.
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
