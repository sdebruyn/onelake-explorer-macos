// FabricTokenPrewarmTests.swift
// Regression tests for issue #260 and issue #272.
//
// Issue #260: root enumeration fast-failed with FabricError before the HTTP
// response arrived because the Fabric (Power BI) token was not in MSAL's
// cache after an OneLake-only interactive login.
//
// Two defects were fixed in #260:
//
// 1. FabricError.from mis-mapped HTTPClientError.tokenAcquisitionFailed to
//    .httpError (→ cannotSynchronize) instead of .unauthorized (→ notAuthenticated).
//
// 2. SharedOfemAuth.signIn now runs a second interactive browser flow for the
//    Fabric (Power BI) scopes immediately after the OneLake interactive login.
//    AADSTS28000 prevents combining both resource audiences in one interactive
//    request; two sequential flows are required. No admin pre-consent is assumed.
//
// Issue #272: the #260 fix only mapped interactionRequired to .unauthorized;
// other inner errors (including silentTokenFailed, which wraps MSAL -42011 local
// bundle-ID config errors in the FPE) still fell through to .httpError →
// cannotSynchronize, leaving the Finder mount silently empty. Fix: ALL
// tokenAcquisitionFailed variants map to .unauthorized regardless of inner error.
//
// These tests cover the error-mapping path (host-less, unit-testable) and verify
// that a FabricClient wired with a delayed TokenProvider correctly awaits the
// token and returns workspaces — ensuring the enumerate path does not fast-fail.

import Foundation
import Testing
@testable import OfemKit

// MARK: - Error-throwing TokenProvider (simulates Fabric token cache miss)

/// A ``TokenProvider`` that throws ``OfemAuthError.interactionRequired``
/// on every call, simulating the state immediately after an OneLake-only
/// interactive login when no Fabric token is in MSAL's Keychain.
private struct InteractionRequiredTokenProvider: TokenProvider {
    func token(alias: String, scope: TokenScope) async throws -> String {
        throw OfemAuthError.interactionRequired
    }
}

/// A ``TokenProvider`` that sleeps for `delay` before returning a token,
/// simulating a successful but slow silent MSAL refresh for the Fabric scope.
///
/// `expectedScope` guards against `FabricClient` accidentally requesting a
/// token for the wrong audience (e.g. `.oneLake` instead of `.fabric`).
private struct DelayedTokenProvider: TokenProvider {
    let delay: Duration
    let token: String
    var expectedScope: TokenScope = .fabric

    func token(alias: String, scope: TokenScope) async throws -> String {
        guard scope == expectedScope else {
            throw DelayedTokenProviderError.wrongScope(expected: expectedScope, got: scope)
        }
        try await Task.sleep(for: delay)
        return token
    }
}

private enum DelayedTokenProviderError: Error, CustomStringConvertible {
    case wrongScope(expected: TokenScope, got: TokenScope)

    var description: String {
        switch self {
        case let .wrongScope(expected, got):
            return "DelayedTokenProvider: expected scope \(expected), got \(got)"
        }
    }
}

// MARK: - Helpers

private let fabricBase = URL(string: "https://api.fabric.microsoft.com")!

private func fabricStubBody(_ workspaces: [(id: String, name: String)]) -> String {
    let items = workspaces
        .map { #"{"id":"\#($0.id)","displayName":"\#($0.name)"}"# }
        .joined(separator: ",")
    return #"{"value":[\#(items)]}"#
}

private func stubResponse(status: Int, body: String = "") -> MockURLSession.Stub {
    MockURLSession.Stub(
        data: body.data(using: .utf8)!,
        status: status,
        headers: [:],
        url: fabricBase
    )
}

// MARK: - FabricTokenPrewarmTests

@Suite("FabricError token-acquisition error mapping (issue-260)")
struct FabricTokenPrewarmTests {

    // MARK: - FabricError.from mapping for tokenAcquisitionFailed

    @Test("tokenAcquisitionFailed(interactionRequired) maps to FabricError.unauthorized")
    func tokenAcquisitionFailedMapsToUnauthorized() {
        // Before the fix, HTTPClientError.tokenAcquisitionFailed fell through to
        // the default branch in FabricError.from and returned .httpError(...),
        // which FPError.classify then mapped to .cannotSynchronize — leaving the
        // Finder mount silently empty instead of surfacing an auth prompt.
        let inner = OfemAuthError.interactionRequired
        let httpErr = HTTPClientError.tokenAcquisitionFailed(inner)
        let mapped = FabricError.from(httpErr)
        if case .unauthorized = mapped {
            // Correct: token failure surfaces as an auth error.
        } else {
            Issue.record("Expected FabricError.unauthorized for tokenAcquisitionFailed(interactionRequired), got \(mapped). This regression causes the Finder mount to show an empty folder instead of an auth prompt (issue-260).")
        }
    }

    @Test("tokenAcquisitionFailed(silentTokenFailed) maps to FabricError.unauthorized (#272: all token failures → .unauthorized)")
    func tokenAcquisitionFailedSilentTokenMapsToUnauthorized() {
        // Issue #272: OfemAuthError.silentTokenFailed is now also mapped to
        // .unauthorized. This covers the FPE bundle-ID mismatch case (MSAL -42011)
        // where MSAL rejects the redirect URI locally — it surfaces as silentTokenFailed
        // but is a permanent configuration error, not a transient network failure.
        // Mapping all tokenAcquisitionFailed variants to .unauthorized ensures Finder
        // shows an auth-required indicator rather than a silent empty folder.
        //
        // Note: the previous behavior (silentTokenFailed → .httpError → cannotSynchronize)
        // was intended to avoid prompting re-auth during transient network outages. However,
        // the -42011 MSAL local validation failure is indistinguishable from a transient
        // MSAL network failure at this layer, and surfacing .unauthorized (which Finder
        // renders as an auth prompt) is always preferable to a silent empty folder.
        let inner = OfemAuthError.silentTokenFailed("work")
        let httpErr = HTTPClientError.tokenAcquisitionFailed(inner)
        let mapped = FabricError.from(httpErr)
        if case .unauthorized = mapped {
            // Correct: all token acquisition failures surface as .unauthorized (#272).
        } else {
            Issue.record("Expected .unauthorized for tokenAcquisitionFailed(silentTokenFailed) after #272 fix, got \(mapped).")
        }
    }

    @Test("tokenAcquisitionFailed maps to FPError.Code.notAuthenticated via FPError.classify")
    func tokenAcquisitionFailedClassifiesAsNotAuthenticated() {
        // End-to-end classification: the error bubbles up through FabricClient,
        // SyncEngine.listWorkspaces (rethrows), and OfemFPEEnumerator, which
        // calls FPError.classify to decide which NSFileProviderError to return.
        // After the fix, the chain is:
        //   tokenAcquisitionFailed → FabricError.unauthorized → FPError.notAuthenticated
        // instead of:
        //   tokenAcquisitionFailed → FabricError.httpError   → FPError.cannotSynchronize
        let inner = OfemAuthError.interactionRequired
        let httpErr = HTTPClientError.tokenAcquisitionFailed(inner)
        let fabricErr = FabricError.from(httpErr)
        let code = FPError.classify(fabricErr)
        #expect(code == .notAuthenticated,
                Comment("Expected .notAuthenticated for Fabric token failure, got \(code). FPError.cannotSynchronize was the pre-fix result that caused the empty Finder mount."))
    }

    @Test("silentTokenFailed classifies as notAuthenticated (#272: all token failures → notAuthenticated)")
    func silentTokenFailedClassifiesAsNotAuthenticated() {
        // Issue #272: silentTokenFailed now maps to .unauthorized → notAuthenticated.
        // This covers the FPE bundle-ID mismatch (MSAL -42011) which surfaces as
        // silentTokenFailed. An auth indicator in Finder is always preferable to a
        // silent empty folder, even if the underlying cause is a transient failure.
        // Correct path after #272:
        //   silentTokenFailed → tokenAcquisitionFailed → FabricError.unauthorized
        //   → FPError.notAuthenticated
        let inner = OfemAuthError.silentTokenFailed("work")
        let httpErr = HTTPClientError.tokenAcquisitionFailed(inner)
        let fabricErr = FabricError.from(httpErr)
        let code = FPError.classify(fabricErr)
        #expect(code == .notAuthenticated,
                Comment("Expected .notAuthenticated for silentTokenFailed after #272 fix, got \(code)."))
    }

    // MARK: - retriesExhausted wrapping tokenAcquisitionFailed

    @Test("retriesExhausted(last: tokenAcquisitionFailed(interactionRequired)) maps to .unauthorized")
    func retriesExhaustedWrappingInteractionRequiredMapsToUnauthorized() {
        // fabric-04: HTTPClient's 401-refresh path can store tokenAcquisitionFailed
        // as the `last` error inside retriesExhausted. Without explicit unwrapping,
        // FabricError.from would match the retriesExhausted arm and return
        // .retriesExhausted → FPError.serverUnreachable, hiding the auth failure
        // behind an offline indicator.
        let authErr = OfemAuthError.interactionRequired
        let wrapped = HTTPClientError.retriesExhausted(
            attempts: 3,
            last: HTTPClientError.tokenAcquisitionFailed(authErr)
        )
        let mapped = FabricError.from(wrapped)
        if case .unauthorized = mapped {
            // Correct: the auth failure inside retriesExhausted is surfaced.
        } else {
            Issue.record("Expected .unauthorized for retriesExhausted(last: tokenAcquisitionFailed(interactionRequired)), got \(mapped). .retriesExhausted → serverUnreachable would hide an auth failure.")
        }
    }

    @Test("retriesExhausted(last: tokenAcquisitionFailed(silentTokenFailed)) maps to .unauthorized (#272)")
    func retriesExhaustedWrappingTransientTokenFailMapsToUnauthorized() {
        // Issue #272 broadens fabric-04: ANY tokenAcquisitionFailed wrapped as the
        // last error inside retriesExhausted must map to .unauthorized, not
        // .retriesExhausted. This covers the FPE bundle-ID mismatch (MSAL -42011)
        // where every retry attempt fails with the same local MSAL config error.
        let authErr = OfemAuthError.silentTokenFailed("work")
        let wrapped = HTTPClientError.retriesExhausted(
            attempts: 3,
            last: HTTPClientError.tokenAcquisitionFailed(authErr)
        )
        let mapped = FabricError.from(wrapped)
        if case .unauthorized = mapped {
            // Correct: any token failure inside retriesExhausted → .unauthorized (#272).
        } else {
            Issue.record("Expected .unauthorized for retriesExhausted(last: tokenAcquisitionFailed(silentTokenFailed)) after #272 fix, got \(mapped).")
        }
    }

    // MARK: - Existing non-auth error mappings remain unchanged

    @Test("HTTPClientError.notFound still maps to FabricError.notFound")
    func notFoundUnchanged() {
        let mapped = FabricError.from(HTTPClientError.notFound)
        if case .notFound = mapped { /* pass */ } else {
            Issue.record("Expected .notFound, got \(mapped)")
        }
    }

    @Test("HTTPClientError.unauthorized still maps to FabricError.unauthorized")
    func unauthorizedUnchanged() {
        let mapped = FabricError.from(HTTPClientError.unauthorized)
        if case .unauthorized = mapped { /* pass */ } else {
            Issue.record("Expected .unauthorized, got \(mapped)")
        }
    }

    @Test("HTTPClientError.cancelled still maps to FabricError.cancelled")
    func cancelledUnchanged() {
        let mapped = FabricError.from(HTTPClientError.cancelled)
        if case .cancelled = mapped { /* pass */ } else {
            Issue.record("Expected .cancelled, got \(mapped)")
        }
    }

    // MARK: - Awaiting the token: FabricClient with a delayed TokenProvider

    @Test("FabricClient awaits a slow token and returns workspaces (no premature notFound)")
    func fabricClientAwaitsSlowTokenAndSucceeds() async throws {
        // Regression guard for the timing race: a TokenProvider that resolves after
        // a short delay (simulating a silent MSAL refresh for the Fabric scope)
        // must NOT cause the enumeration to fail with notFound or any other error.
        // FabricClient must await token acquisition before it even sends the request.
        let body = fabricStubBody([
            (id: "ws-abc", name: "My Workspace"),
            (id: "ws-def", name: "Another Workspace"),
        ])
        let session = MockURLSession(stubs: [stubResponse(status: 200, body: body)])
        let http = HTTPClient(
            session: session,
            gateRegistry: makeGate(host: "api.fabric.microsoft.com"),
            retryPolicy: HTTPRetryPolicy(maxAttempts: 1, initialBackoff: .milliseconds(5), maxBackoff: .milliseconds(20))
        )
        // 50 ms delay simulates the silent Entra /token round-trip latency.
        let tokenProvider = DelayedTokenProvider(delay: .milliseconds(50), token: "delayed-fab-tok")
        let client = FabricClient(http: http, tokenProvider: tokenProvider, baseURL: fabricBase)

        // This must NOT throw — the client waits for the token and then succeeds.
        let workspaces = try await client.listAllWorkspaces(alias: "work")
        #expect(workspaces.count == 2)
        #expect(workspaces[0].id == "ws-abc")
        #expect(workspaces[1].id == "ws-def")
        // Verify the Authorization header carried the delayed token.
        let authHeader = session.requests.first?.value(forHTTPHeaderField: "Authorization")
        #expect(authHeader == "Bearer delayed-fab-tok")
    }

    @Test("FabricClient with interactionRequired token throws FabricError.unauthorized, not notFound")
    func fabricClientWithFailingTokenThrowsUnauthorized() async throws {
        // The core regression from issue #260: when the Fabric token is not available
        // (interactionRequired), FabricClient must throw .unauthorized (→ notAuthenticated),
        // NOT .notFound or .httpError (→ cannotSynchronize). The empty stubs list
        // ensures the test fails fast if the HTTP request is made despite the token error.
        let session = MockURLSession(stubs: [])
        let http = HTTPClient(
            session: session,
            gateRegistry: makeGate(host: "api.fabric.microsoft.com"),
            retryPolicy: HTTPRetryPolicy(maxAttempts: 1, initialBackoff: .milliseconds(5), maxBackoff: .milliseconds(20))
        )
        let client = FabricClient(
            http: http,
            tokenProvider: InteractionRequiredTokenProvider(),
            baseURL: fabricBase
        )

        do {
            _ = try await client.listAllWorkspaces(alias: "work")
            Issue.record("Expected FabricError.unauthorized to be thrown")
        } catch FabricError.unauthorized {
            // Correct: auth failure surfaces as .unauthorized, not .notFound / .httpError.
        } catch {
            Issue.record("Expected FabricError.unauthorized, got \(error). If this is FabricError.httpError, the tokenAcquisitionFailed mapping is broken (issue-260).")
        }
        // The HTTP session must NOT have received any requests — the error
        // must be raised from token acquisition, before the network call.
        #expect(session.requests.isEmpty,
                Comment("Expected zero HTTP requests: token failure must prevent the Fabric API call"))
    }
}
