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
//
// Issue #272: the #260 fix only mapped interactionRequired to .unauthorized;
// other inner errors (including silentTokenFailed) still fell through to
// .httpError → cannotSynchronize. Fix: ALL tokenAcquisitionFailed variants
// map to .unauthorized regardless of inner error.

import Foundation
@testable import OfemKit
import Testing

// MARK: - Token providers

/// A ``TokenProvider`` that throws ``OfemAuthError.interactionRequired``
/// on every call, simulating a Fabric token cache miss.
private struct InteractionRequiredTokenProvider: TokenProvider {
    func token(alias _: String, scope _: TokenScope) async throws -> String {
        throw OfemAuthError.interactionRequired
    }
}

/// A ``TokenProvider`` that sleeps for `delay` before returning a token,
/// simulating a successful but slow silent MSAL refresh for the Fabric scope.
private struct DelayedTokenProvider: TokenProvider {
    let delay: Duration
    let token: String
    var expectedScope: TokenScope = .fabric

    func token(alias _: String, scope: TokenScope) async throws -> String {
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
            "DelayedTokenProvider: expected scope \(expected), got \(got)"
        }
    }
}

// MARK: - Helpers

private let fabricBase = URL(string: "https://api.fabric.microsoft.com")!

// MARK: - FabricTokenPrewarmTests

@Suite("FabricError token-acquisition error mapping (issue-260)")
struct FabricTokenPrewarmTests {
    // MARK: - FabricError.from mapping for tokenAcquisitionFailed

    @Test("tokenAcquisitionFailed(interactionRequired) maps to FabricError.unauthorized")
    func tokenAcquisitionFailedMapsToUnauthorized() {
        let inner = OfemAuthError.interactionRequired
        let httpErr = HTTPClientError.tokenAcquisitionFailed(inner)
        let mapped = FabricError.from(httpErr)
        if case .unauthorized = mapped {
            // Correct: token failure surfaces as an auth error.
        } else {
            Issue.record("Expected FabricError.unauthorized for tokenAcquisitionFailed(interactionRequired), got \(mapped). This regression causes the Finder mount to show an empty folder instead of an auth prompt (issue-260).")
        }
    }

    @Test("tokenAcquisitionFailed(silentTokenFailed) maps to FabricError.unauthorized (#272)")
    func tokenAcquisitionFailedSilentTokenMapsToUnauthorized() {
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
        let inner = OfemAuthError.interactionRequired
        let httpErr = HTTPClientError.tokenAcquisitionFailed(inner)
        let fabricErr = FabricError.from(httpErr)
        let code = FPError.classify(fabricErr)
        #expect(code == .notAuthenticated,
                Comment("Expected .notAuthenticated for Fabric token failure, got \(code). FPError.cannotSynchronize was the pre-fix result that caused the empty Finder mount."))
    }

    @Test("silentTokenFailed classifies as notAuthenticated (#272)")
    func silentTokenFailedClassifiesAsNotAuthenticated() {
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
        let authErr = OfemAuthError.interactionRequired
        let wrapped = HTTPClientError.retriesExhausted(
            attempts: 3,
            last: HTTPClientError.tokenAcquisitionFailed(authErr)
        )
        let mapped = FabricError.from(wrapped)
        if case .unauthorized = mapped {
            // Correct: the auth failure inside retriesExhausted is surfaced.
        } else {
            Issue.record("Expected .unauthorized for retriesExhausted(last: tokenAcquisitionFailed(interactionRequired)), got \(mapped).")
        }
    }

    @Test("retriesExhausted(last: tokenAcquisitionFailed(silentTokenFailed)) maps to .unauthorized (#272)")
    func retriesExhaustedWrappingTransientTokenFailMapsToUnauthorized() {
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

    // MARK: - FabricClient with failing token provider

    @Test("FabricClient with interactionRequired token throws FabricError.unauthorized, not notFound")
    func fabricClientWithFailingTokenThrowsUnauthorized() async throws {
        let pool = SessionPool(tokenProvider: InteractionRequiredTokenProvider())
        let client = FabricClient(sessionPool: pool, baseURL: fabricBase)

        do {
            _ = try await client.listAllWorkspaces(alias: "work")
            Issue.record("Expected FabricError.unauthorized to be thrown")
        } catch FabricError.unauthorized {
            // Correct: auth failure surfaces as .unauthorized, not .notFound / .httpError.
        } catch {
            Issue.record("Expected FabricError.unauthorized, got \(error). If this is FabricError.httpError, the tokenAcquisitionFailed mapping is broken (issue-260).")
        }
    }
}
