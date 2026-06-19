import Alamofire
import Foundation

// MARK: - OfemCredential

/// An Alamofire `AuthenticationCredential` backed by an MSAL access token.
///
/// The expiry date is sourced directly from `MSALResult.expiresOn`, threaded
/// through `TokenProvider.tokenWithExpiry(alias:scope:)`.  Storage-audience
/// tokens (`https://storage.azure.com/`) are opaque to the client; only
/// the MSAL-provided expiry is used — no JWT parsing.
struct OfemCredential: AuthenticationCredential {
    let accessToken: String
    let expiresAt: Date

    /// Refreshes slightly early so an in-flight request never carries an
    /// about-to-expire token.  The 5-minute safety window matches MSAL's own
    /// early-refresh heuristic.
    var requiresRefresh: Bool {
        Date(timeIntervalSinceNow: 5 * 60) >= expiresAt
    }
}

// MARK: - OfemAuthenticator

/// Bridges `TokenProvider` to Alamofire's `Authenticator` protocol.
///
/// One `OfemAuthenticator` is created per `(alias, scope)` session.  The
/// `refresh` implementation calls `TokenProvider.tokenWithExpiry` which runs on
/// the MSAL path — entirely outside the intercepted Alamofire `Session`, so the
/// Alamofire authentication-interceptor refresh-lock is never involved in the
/// MSAL network call.
final class OfemAuthenticator: Authenticator {
    private let tokenProvider: any TokenProvider
    private let alias: String
    private let scope: TokenScope

    init(tokenProvider: any TokenProvider, alias: String, scope: TokenScope) {
        self.tokenProvider = tokenProvider
        self.alias = alias
        self.scope = scope
    }

    func apply(_ credential: OfemCredential, to urlRequest: inout URLRequest) {
        urlRequest.headers.add(.authorization(bearerToken: credential.accessToken))
    }

    func refresh(
        _ credential: OfemCredential,
        for session: Session,
        completion: @escaping @Sendable (Result<OfemCredential, Error>) -> Void
    ) {
        let provider = tokenProvider
        let alias = alias
        let scope = scope
        Task {
            do {
                let (token, expiry) = try await provider.tokenWithExpiry(alias: alias, scope: scope)
                completion(.success(OfemCredential(accessToken: token, expiresAt: expiry)))
            } catch {
                completion(.failure(error))
            }
        }
    }

    func didRequest(
        _ urlRequest: URLRequest,
        with response: HTTPURLResponse,
        failDueToAuthenticationError error: Error
    ) -> Bool {
        response.statusCode == 401
    }

    func isRequest(
        _ urlRequest: URLRequest,
        authenticatedWith credential: OfemCredential
    ) -> Bool {
        urlRequest.headers["Authorization"] ==
            HTTPHeader.authorization(bearerToken: credential.accessToken).value
    }
}
