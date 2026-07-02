import Alamofire
import Foundation
import os.log

// MARK: - SessionPool

/// Process-wide pool of Alamofire sessions, one per `(alias, scope)` key.
///
/// Keying by `(alias, scope)` bounds Alamofire's `AuthenticationInterceptor`
/// refresh-deduplication to the correct granularity: one in-flight token refresh
/// per account and OAuth audience.
///
/// Token refresh runs on the MSAL path (via `TokenProvider`), entirely outside
/// the pooled `Session`.  This avoids the Alamofire authentication-interceptor
/// deadlock that occurs when a refresh call re-enters the same intercepted
/// session (Alamofire issue #3509).
public actor SessionPool {
    // MARK: - Types

    struct Key: Hashable {
        let alias: String
        // periphery:ignore - Hashable field; used as part of Key's Hashable/Equatable identity
        let scope: TokenScope
    }

    // MARK: - Constants

    /// Per-host connection cap for the OneLake DFS endpoint.
    static let oneLakeMaxConnections = 16
    /// Per-host connection cap for the Fabric REST endpoint.
    static let fabricMaxConnections = 8

    // MARK: - State

    private var sessions: [Key: Session] = [:]
    private let tokenProvider: any TokenProvider

    private static let log = Logger(subsystem: "dev.debruyn.ofem", category: "SessionPool")

    // MARK: - Initialisation

    public init(tokenProvider: any TokenProvider) {
        self.tokenProvider = tokenProvider
    }

    // MARK: - Session access

    /// Returns the cached `Session` for the given `(alias, scope)` pair,
    /// creating and caching it on first use.
    func session(alias: String, scope: TokenScope) -> Session {
        let key = Key(alias: alias, scope: scope)
        if let existing = sessions[key] { return existing }
        let s = Self.makeSession(alias: alias, scope: scope, tokenProvider: tokenProvider)
        sessions[key] = s
        return s
    }

    // periphery:ignore
    /// Seeds a pre-built `Session` for a specific `(alias, scope)` pair.
    ///
    /// Intended for unit tests that need to inject a session backed by
    /// `MockURLProtocol`.  Not for use in production code.
    func _setSessionForTesting(_ session: Session, alias: String, scope: TokenScope) {
        sessions[Key(alias: alias, scope: scope)] = session
    }

    // MARK: - Invalidation

    /// Cancels all in-flight requests and removes every `Session` for `alias`
    /// (across all scopes).
    ///
    /// Call this when an account is removed so a stale session cannot reuse a
    /// purged token.
    public func invalidate(alias: String) {
        let toRemove = sessions.keys.filter { $0.alias == alias }
        for key in toRemove {
            sessions[key]?.cancelAllRequests()
            sessions.removeValue(forKey: key)
        }
        if !toRemove.isEmpty {
            Self.log.info(
                "SessionPool: invalidated \(toRemove.count, privacy: .public) session(s) for alias (redacted)"
            )
        }
    }

    // MARK: - Session construction

    private static func makeSession(
        alias: String,
        scope: TokenScope,
        tokenProvider: any TokenProvider
    ) -> Session {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = .infinity
        // Disable the shared URL cache so a stale or negative (404) entry can
        // never be served without a live round-trip.
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        // Per-host concurrency cap to bound parallel in-flight requests per scope.
        config.httpMaximumConnectionsPerHost = scope == .oneLake
            ? oneLakeMaxConnections
            : fabricMaxConnections

        let authenticator = OfemAuthenticator(
            tokenProvider: tokenProvider,
            alias: alias,
            scope: scope
        )
        // The initial credential has an expiry in the past so the authenticator
        // performs a refresh before the very first request.
        let credential = OfemCredential(accessToken: "", expiresAt: .distantPast)
        let authInterceptor = AuthenticationInterceptor(
            authenticator: authenticator,
            credential: credential
        )

        let interceptor = Interceptor(
            adapters: [],
            retriers: [
                RetryAfterRetrier(),
                JitteredRetryPolicy(
                    // Single source of truth shared with RetryAfterRetrier's
                    // own cap — see RetryAfterRetrier.maxRetries.
                    retryLimit: UInt(RetryAfterRetrier.maxRetries),
                    retryableHTTPMethods: [
                        .get, .head, .put, .delete, .options,
                        // PATCH is added for OneLake append/flush: position-addressed
                        // operations are replay-safe and must remain retriable.
                        .patch,
                    ],
                    retryableHTTPStatusCodes: [408, 425, 429, 500, 502, 503, 504]
                ),
            ],
            interceptors: [authInterceptor]
        )

        return Session(configuration: config, interceptor: interceptor)
    }
}

// MARK: - JitteredRetryPolicy

/// A `RetryPolicy` subclass that applies full jitter to the exponential
/// backoff delay.
///
/// Alamofire's stock `RetryPolicy` computes a deterministic delay per
/// `request.retryCount` (`base ^ retryCount * scale`). With up to
/// ``SessionPool/oneLakeMaxConnections`` concurrent requests throttled at
/// once, every one of them computes the identical delay and retries in the
/// same synchronized wave, re-triggering the same throttling response. Full
/// jitter (a uniform random delay in `[0, computedDelay]`) spreads retries
/// out so the waves de-correlate.
///
/// Only the delay computation changes; retry eligibility (`shouldRetry`,
/// `retryLimit`) is inherited unmodified from `RetryPolicy`.
///
/// See: https://aws.amazon.com/blogs/architecture/exponential-backoff-and-jitter/
final class JitteredRetryPolicy: RetryPolicy, @unchecked Sendable {
    override func retry(
        _ request: Request,
        for _: Session,
        dueTo error: Error,
        completion: @escaping @Sendable (RetryResult) -> Void
    ) {
        guard request.retryCount < retryLimit, shouldRetry(request: request, dueTo: error) else {
            completion(.doNotRetry)
            return
        }
        completion(.retryWithDelay(jitteredDelay(forRetryCount: request.retryCount)))
    }

    /// Computes the full-jitter backoff delay for a given retry count.
    ///
    /// Split out from ``retry(_:for:dueTo:completion:)`` so tests can sample
    /// the delay distribution directly, without needing to drive a live
    /// `Request` through several failed round-trips to observe `retryCount`.
    func jitteredDelay(forRetryCount retryCount: Int) -> TimeInterval {
        let delay = pow(Double(exponentialBackoffBase), Double(retryCount)) * exponentialBackoffScale
        return delay > 0 ? Double.random(in: 0 ... delay) : delay
    }
}
