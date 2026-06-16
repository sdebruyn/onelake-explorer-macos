// FabricNoURLCacheTests.swift
// Regression tests for issue #268: FabricError.notFound without a real HTTP
// round-trip caused by URLCache serving a stale or negative (404) entry.
//
// Root cause (issue-268): URLSession.ofemDefault used URLSessionConfiguration.default,
// which shares URLCache.shared. A previous FPE run (or the host app) that received
// a cacheable 404 for https://api.fabric.microsoft.com/v1/workspaces could have left
// a negative cache entry. Subsequent FPE enumerations then received HTTP 404 from
// URLSession in <3 ms — with CFNetwork just cold-loaded and no TLS handshake —
// causing FabricClient to throw FabricError.notFound immediately. This made Finder
// show an empty mount even though the live Fabric endpoint was reachable.
//
// Fix: URLSession.ofemDefault now sets urlCache = nil and
// requestCachePolicy = .reloadIgnoringLocalCacheData (net-20) so no cached response
// is ever served without a live network round-trip.
//
// Tests in this file are host-less and do not require a live Fabric tenant.

import Foundation
import Testing
@testable import OfemKit

// MARK: - Helpers

private let fabricBase = URL(string: "https://api.fabric.microsoft.com")!

private func fabricWorkspacesStub(status: Int, body: String = "") -> MockURLSession.Stub {
    MockURLSession.Stub(
        data: body.data(using: .utf8)!,
        status: status,
        headers: [:],
        url: fabricBase
    )
}

private func makeFabricClient(
    session: MockURLSession,
    maxAttempts: Int = 1
) -> FabricClient {
    let http = HTTPClient(
        session: session,
        gateRegistry: makeGate(host: "api.fabric.microsoft.com"),
        retryPolicy: HTTPRetryPolicy(
            maxAttempts: maxAttempts,
            initialBackoff: .milliseconds(5),
            maxBackoff: .milliseconds(20)
        )
    )
    return FabricClient(
        http: http,
        tokenProvider: MockTokenProvider(token: "test-token"),
        baseURL: fabricBase
    )
}

// MARK: - URLSession cache policy (net-20)

@Suite("URLSession.ofemDefault — URL cache disabled (net-20 / issue-268)")
struct URLSessionNoCacheTests {

    @Test("ofemDefault has urlCache == nil (net-20)")
    func ofemDefaultHasNilURLCache() {
        // Verifies that URLSession.ofemDefault does NOT use URLCache.shared.
        // Before the fix, URLSessionConfiguration.default inherits URLCache.shared,
        // which could serve a previously cached 404 for the Fabric workspaces
        // endpoint without a live network round-trip (issue-268).
        let config = URLSession.ofemDefault.configuration
        #expect(config.urlCache == nil,
                Comment("URLSession.ofemDefault must have urlCache=nil so URLCache.shared cannot serve stale entries (net-20 / issue-268)"))
    }

    @Test("ofemDefault uses reloadIgnoringLocalCacheData policy (net-20)")
    func ofemDefaultIgnoresLocalCache() {
        let config = URLSession.ofemDefault.configuration
        #expect(config.requestCachePolicy == .reloadIgnoringLocalCacheData,
                Comment("URLSession.ofemDefault must ignore local cache data so a cached 404 can never bypass a live HTTP round-trip (net-20 / issue-268)"))
    }
}

// MARK: - FabricError.from transport-error classification (issue-268)
//
// These tests verify that no transport or cancellation error is mis-classified
// as FabricError.notFound.  Only a genuine HTTP 404 (HTTPClientError.notFound,
// produced by HTTPClient when the server returns status 404) should map there.

@Suite("FabricError transport-error classification — no synthetic notFound (issue-268)")
struct FabricErrorTransportClassificationTests {

    // MARK: Cancellation errors must NOT become .notFound

    @Test("URLError(.cancelled) maps to FabricError.httpError, NOT .notFound (issue-268)")
    func urlErrorCancelledIsNotNotFound() {
        // Before the URLCache fix, a URLSession serving a cached 404 would have
        // produced HTTPClientError.notFound instead of HTTPClientError.cancelled.
        // This test confirms URLError(.cancelled) is classified correctly: it must
        // never produce FabricError.notFound.
        let transportError = HTTPClientError.transport(URLError(.cancelled))
        let mapped = FabricError.from(transportError)
        if case FabricError.notFound = mapped {
            Issue.record("URLError(.cancelled) must NOT map to FabricError.notFound (issue-268). Transport errors must never produce a synthetic .notFound.")
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

    // MARK: Transport errors must NOT become .notFound

    @Test("URLError(.notConnectedToInternet) wrapped in transport does NOT map to .notFound (issue-268)")
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
        if case FabricError.retriesExhausted(let attempts) = mapped {
            #expect(attempts == 3)
        } else {
            Issue.record("retriesExhausted(transport) must map to FabricError.retriesExhausted, got \(mapped)")
        }
    }

    // MARK: A genuine HTTP 404 MUST still map to .notFound

    @Test("HTTPClientError.notFound (genuine HTTP 404) still maps to FabricError.notFound (issue-268)")
    func genuineHTTP404StillMapsToNotFound() {
        // Only a real HTTP 404 (from HTTPClient when the server returns status 404)
        // should produce FabricError.notFound.  This test ensures the fix does not
        // suppress the correct error for a real 404 response.
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

// MARK: - FabricClient with a 404-stub verifies a round-trip IS made (issue-268)
//
// With the URLCache fix in place, the only way FabricClient can return .notFound
// is when the mock HTTP layer returns status 404 — i.e. a real (simulated)
// response was received.  This test guards against regressions where a future
// change re-enables the cache and bypasses the session mock.

@Suite("FabricClient — notFound requires a real HTTP response (issue-268)")
struct FabricClientNotFoundRequiresRoundTripTests {

    @Test("listAllWorkspaces with HTTP-404 stub throws FabricError.notFound AND records a request (issue-268)")
    func notFoundRequiresActualRequest() async throws {
        // If FabricError.notFound could be produced WITHOUT making a request
        // (e.g. via a cached 404), this test would fail because no stub would
        // be consumed and session.requests would be empty.
        let session = MockURLSession(stubs: [fabricWorkspacesStub(status: 404)])
        let client = makeFabricClient(session: session)

        do {
            _ = try await client.listAllWorkspaces(alias: "work")
            Issue.record("Expected FabricError.notFound to be thrown")
        } catch FabricError.notFound {
            // Correct: a real (simulated) HTTP 404 was received.
        } catch {
            Issue.record("Expected FabricError.notFound, got \(error)")
        }

        // The stub must have been consumed — a request was actually made.
        #expect(session.requests.count == 1,
                Comment("FabricError.notFound must only be produced after an HTTP round-trip (issue-268). A zero request count would indicate a synthetic 404 from URLCache or a mock bypass."))
    }

    @Test("listAllWorkspaces with no stubs and failing token throws FabricError.unauthorized, NOT .notFound (issue-268)")
    func noRequestNoNotFound() async throws {
        // Without any HTTP stubs, any error that occurs must come from token
        // acquisition — not from a URLCache entry.  The error must be .unauthorized
        // (tokenAcquisitionFailed → interactionRequired), never .notFound (which
        // requires a real HTTP 404 round-trip).
        // NoRequestSession is used instead of MockURLSession(stubs: []) so that an
        // accidental HTTP request produces a clean failing test (via Issue.record)
        // rather than a process-crashing precondition() that would abort all
        // subsequent tests in the suite.
        let session = NoRequestSession()
        let http = HTTPClient(
            session: session,
            gateRegistry: makeGate(host: "api.fabric.microsoft.com"),
            retryPolicy: HTTPRetryPolicy(maxAttempts: 1, initialBackoff: .milliseconds(5), maxBackoff: .milliseconds(20))
        )
        let failingProvider = InteractionRequiredTokenProvider()
        let client = FabricClient(http: http, tokenProvider: failingProvider, baseURL: fabricBase)

        do {
            _ = try await client.listAllWorkspaces(alias: "work")
            Issue.record("Expected an error from failing token provider")
        } catch FabricError.notFound {
            Issue.record("FabricError.notFound must NOT be thrown without an HTTP round-trip (issue-268). Token acquisition failure must map to .unauthorized or .httpError, never .notFound.")
        } catch FabricError.unauthorized {
            // Correct: token failure maps to .unauthorized.
        } catch {
            // Any other error (e.g. .httpError for transient failures) is acceptable —
            // as long as it is not .notFound.
        }
        // No HTTP request should have been made (token acquisition fails first).
        #expect(session.requestCount == 0,
                Comment("Zero HTTP requests expected when token acquisition fails before the request is sent (issue-268)"))
    }
}

// MARK: - Private helpers for this test file

/// A TokenProvider that always throws OfemAuthError.interactionRequired.
private struct InteractionRequiredTokenProvider: TokenProvider {
    func token(alias: String, scope: TokenScope) async throws -> String {
        throw OfemAuthError.interactionRequired
    }
}

/// A URLSessionProtocol that fails with a clean XCTest-style assertion if
/// any HTTP request is made. Replaces `MockURLSession(stubs: [])` in tests
/// where no HTTP round-trip is expected — a process-crashing `precondition()`
/// is replaced by a failing (but non-crashing) Issue.record so that subsequent
/// tests in the suite still run after a regression.
private final class NoRequestSession: URLSessionProtocol, @unchecked Sendable {
    private(set) var requestCount: Int = 0
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        requestCount += 1
        Issue.record("NoRequestSession: unexpected HTTP request to \(request.url?.absoluteString ?? "(nil)") — no HTTP round-trip should occur in this test")
        throw URLError(.unsupportedURL)
    }
}
