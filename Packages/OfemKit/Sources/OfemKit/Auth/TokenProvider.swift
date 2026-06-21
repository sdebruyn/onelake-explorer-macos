import Foundation

// MARK: - AccessToken

/// A bearer token with its MSAL-provided expiry date.
///
/// The expiry is sourced from `MSALResult.expiresOn` and is not derived by
/// parsing the token string.  Storage-audience tokens
/// (`https://storage.azure.com/`) are opaque to the client; only the date
/// MSAL returns must be used.
public struct AccessToken: Sendable {
    /// The raw bearer token string.
    public let value: String
    /// The expiry instant reported by MSAL (`MSALResult.expiresOn`).
    public let expiresOn: Date

    public init(value: String, expiresOn: Date) {
        self.value = value
        self.expiresOn = expiresOn
    }
}

// MARK: - TokenProvider

/// Supplies access tokens for a named account alias.
///
/// `OneLakeClient` and `FabricClient` receive a `TokenProvider` at
/// construction time.  The concrete implementation (`OfemAuth`) is wired
/// in the engine.  Test code uses stub implementations.
public protocol TokenProvider: Sendable {
    /// Returns a valid bearer token for the given account alias and scope.
    ///
    /// - Parameters:
    ///   - alias: The account alias (e.g. `"work"`).
    ///   - scope: The OAuth audience to target.
    /// - Returns: A bearer token string.
    /// - Throws: Any error from the underlying auth implementation.
    func token(alias: String, scope: TokenScope) async throws -> String

    /// Returns a valid bearer token together with its MSAL-provided expiry date.
    ///
    /// The expiry is used by `OfemCredential.requiresRefresh` to pre-emptively
    /// refresh the token before it expires.  The default implementation
    /// delegates to `token(alias:scope:)` and falls back to a 50-minute
    /// expiry window.  Concrete implementations should return the real
    /// `MSALResult.expiresOn` for accurate early-refresh behaviour.
    func tokenWithExpiry(alias: String, scope: TokenScope) async throws -> (String, Date)

    /// Forces a token refresh (discards any cached token) and returns a fresh one.
    ///
    /// The default implementation delegates to `token(alias:scope:)`.
    // periphery:ignore
    func refreshedToken(alias: String, scope: TokenScope) async throws -> String
}

public extension TokenProvider {
    /// Default: delegates to `token(alias:scope:)`.
    // periphery:ignore
    func refreshedToken(alias: String, scope: TokenScope) async throws -> String {
        try await token(alias: alias, scope: scope)
    }

    /// Default: calls `token` and applies a conservative 50-minute fallback
    /// expiry.  Override in concrete types to return the real MSAL expiry.
    func tokenWithExpiry(alias: String, scope: TokenScope) async throws -> (String, Date) {
        let tok = try await token(alias: alias, scope: scope)
        // 50 minutes is conservative relative to MSAL's typical ~1h token lifetime;
        // concrete implementations should supply the real MSALResult.expiresOn.
        let expiry = Date(timeIntervalSinceNow: 50 * 60)
        return (tok, expiry)
    }
}
