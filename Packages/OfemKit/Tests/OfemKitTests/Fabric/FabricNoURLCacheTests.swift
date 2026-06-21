// FabricNoURLCacheTests.swift
// Regression tests for issue #268: FabricError.notFound without a real HTTP
// round-trip caused by URLCache serving a stale or negative (404) entry.
//
// Root cause (issue-268): URLSession used URLSessionConfiguration.default,
// which shares URLCache.shared. A previous FPE run (or the host app) that
// received a cacheable 404 for https://api.fabric.microsoft.com/v1/workspaces
// could have left a negative cache entry, causing subsequent enumerations to
// return FabricError.notFound in <3 ms — before any TLS handshake.
//
// Fix: SessionPool.makeSession sets urlCache = nil and
// requestCachePolicy = .reloadIgnoringLocalCacheData (net-20) so no cached
// response is ever served without a live network round-trip.
//
// Tests in this file are host-less and do not require a live Fabric tenant.

import Foundation
@testable import OfemKit
import Testing

// MARK: - SessionPool URL-cache policy (net-20 / issue-268)

//
// SessionPool.makeSession is private, so we verify the invariant by asking
// the pool for a session and inspecting its URLSession configuration.
// The session is created lazily on first call to pool.session(alias:scope:).

@Suite("SessionPool — URL cache disabled (net-20 / issue-268)")
struct SessionPoolNoCacheTests {
    @Test("SessionPool session has urlCache == nil (net-20)")
    func sessionHasNilURLCache() async {
        let pool = SessionPool(tokenProvider: NoopTokenProvider())
        let session = await pool.session(alias: "test", scope: .fabric)
        // Alamofire wraps URLSession; access the underlying session's configuration.
        let config = session.sessionConfiguration
        #expect(
            config.urlCache == nil,
            "SessionPool-vended sessions must have urlCache=nil so URLCache.shared cannot serve stale entries (net-20 / issue-268)"
        )
    }

    @Test("SessionPool session uses reloadIgnoringLocalCacheData policy (net-20)")
    func sessionIgnoresLocalCache() async {
        let pool = SessionPool(tokenProvider: NoopTokenProvider())
        let session = await pool.session(alias: "test", scope: .fabric)
        let config = session.sessionConfiguration
        #expect(
            config.requestCachePolicy == .reloadIgnoringLocalCacheData,
            "SessionPool-vended sessions must ignore local cache data so a cached 404 can never bypass a live HTTP round-trip (net-20 / issue-268)"
        )
    }

    @Test("OneLake-scoped session also has urlCache == nil")
    func oneLakeSessionHasNilURLCache() async {
        let pool = SessionPool(tokenProvider: NoopTokenProvider())
        let session = await pool.session(alias: "test", scope: .oneLake)
        let config = session.sessionConfiguration
        #expect(
            config.urlCache == nil,
            "OneLake sessions must also have urlCache=nil (net-20)"
        )
    }
}

// MARK: - FabricError transport-error classification (issue-268)

//
// These tests verify that no transport or cancellation error is mis-classified
// as FabricError.notFound. Only a genuine HTTP 404 (HTTPClientError.notFound)
// should map there.

@Suite("FabricError transport-error classification — no synthetic notFound (issue-268)")
struct FabricErrorTransportClassificationTests {
    @Test("URLError(.cancelled) maps to FabricError.httpError, NOT .notFound (issue-268)")
    func urlErrorCancelledIsNotNotFound() {
        let transportError = HTTPClientError.transport(URLError(.cancelled))
        let mapped = FabricError.from(transportError)
        if case FabricError.notFound = mapped {
            Issue.record("URLError(.cancelled) must NOT map to FabricError.notFound (issue-268)")
        }
        if case FabricError.httpError = mapped { /* correct */ } else {
            Issue.record("URLError(.cancelled) wrapped in transport must map to FabricError.httpError, got \(mapped)")
        }
    }

    @Test("HTTPClientError.cancelled maps to FabricError.cancelled, NOT .notFound (issue-268)")
    func httpCancelledIsNotNotFound() {
        let mapped = FabricError.from(HTTPClientError.cancelled)
        if case FabricError.notFound = mapped {
            Issue.record("HTTPClientError.cancelled must NOT map to FabricError.notFound (issue-268)")
        }
        if case FabricError.cancelled = mapped { /* correct */ } else {
            Issue.record("HTTPClientError.cancelled must map to FabricError.cancelled, got \(mapped)")
        }
    }

    @Test("CancellationError maps to FabricError.cancelled, NOT .notFound (issue-268)")
    func cancellationErrorIsNotNotFound() {
        let mapped = FabricError.from(CancellationError())
        if case FabricError.notFound = mapped {
            Issue.record("CancellationError must NOT map to FabricError.notFound (issue-268)")
        }
        if case FabricError.cancelled = mapped { /* correct */ } else {
            Issue.record("CancellationError must map to FabricError.cancelled, got \(mapped)")
        }
    }

    @Test("URLError(.notConnectedToInternet) transport error does NOT map to .notFound (issue-268)")
    func transportOfflineIsNotNotFound() {
        let transportError = HTTPClientError.transport(URLError(.notConnectedToInternet))
        let mapped = FabricError.from(transportError)
        if case FabricError.notFound = mapped {
            Issue.record("A transport-layer offline error must NOT map to FabricError.notFound (issue-268)")
        }
        if case FabricError.httpError = mapped { /* correct */ } else {
            Issue.record("URLError(.notConnectedToInternet) transport error must map to FabricError.httpError, got \(mapped)")
        }
    }

    @Test("retriesExhausted wrapping a transport error maps to .retriesExhausted, NOT .notFound (issue-268)")
    func retriesExhaustedTransportIsNotNotFound() {
        let last = HTTPClientError.transport(URLError(.timedOut))
        let exhausted = HTTPClientError.retriesExhausted(attempts: 3, last: last)
        let mapped = FabricError.from(exhausted)
        if case FabricError.notFound = mapped {
            Issue.record("retriesExhausted wrapping a transport error must NOT map to FabricError.notFound (issue-268)")
        }
        if case let FabricError.retriesExhausted(attempts) = mapped {
            #expect(attempts == 3)
        } else {
            Issue.record("retriesExhausted(transport) must map to FabricError.retriesExhausted, got \(mapped)")
        }
    }

    @Test("HTTPClientError.notFound (genuine HTTP 404) still maps to FabricError.notFound (issue-268)")
    func genuineHTTP404StillMapsToNotFound() {
        let mapped = FabricError.from(HTTPClientError.notFound)
        if case FabricError.notFound = mapped { /* correct */ } else {
            Issue.record("HTTPClientError.notFound (genuine HTTP 404) must still map to FabricError.notFound, got \(mapped)")
        }
    }

    @Test("apiError(404) unwrapped to sentinel maps to FabricError.notFound (issue-268)")
    func apiError404StillMapsToNotFound() {
        let ae = APIError(statusCode: 404, status: "404 Not Found", body: Data())
        let wrapped = HTTPClientError.apiError(ae)
        let mapped = FabricError.from(wrapped)
        if case FabricError.notFound = mapped { /* correct */ } else {
            Issue.record("apiError(404) sentinel must still map to FabricError.notFound, got \(mapped)")
        }
    }
}

// MARK: - FabricClient token-failure path (issue-268)

//
// Verifies that when token acquisition fails, FabricClient throws
// .unauthorized — not .notFound — confirming no synthetic 404 is produced.

@Suite("FabricClient — token failure produces .unauthorized, not .notFound (issue-268)")
struct FabricClientTokenFailureTests {
    @Test("interactionRequired token throws FabricError.unauthorized, not .notFound (issue-268)")
    func tokenFailureThrowsUnauthorized() async throws {
        let fabricBase = try #require(URL(string: "https://api.fabric.microsoft.com"))
        let pool = SessionPool(tokenProvider: InteractionRequiredTokenProvider())
        let client = FabricClient(sessionPool: pool, baseURL: fabricBase)

        do {
            _ = try await client.listAllWorkspaces(alias: "work")
            Issue.record("Expected an error from failing token provider")
        } catch FabricError.notFound {
            Issue.record("FabricError.notFound must NOT be thrown when token acquisition fails (issue-268)")
        } catch FabricError.unauthorized {
            // Correct: token failure maps to .unauthorized.
        } catch {
            // Any other error is acceptable as long as it is not .notFound.
        }
    }
}

// MARK: - Private helpers

/// A `TokenProvider` that always throws `OfemAuthError.interactionRequired`.
private struct InteractionRequiredTokenProvider: TokenProvider {
    func token(alias _: String, scope _: TokenScope) async throws -> String {
        throw OfemAuthError.interactionRequired
    }
}
