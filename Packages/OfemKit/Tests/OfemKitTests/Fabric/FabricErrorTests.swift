import Testing
import Foundation
@testable import OfemKit

// MARK: - FabricErrorTests

/// Tests for ``FabricError``: all cases are throwable/catchable, and the
/// `FabricError.from(_:)` mapping covers every HTTPClientError branch plus
/// the default fallback.
///
/// NOTE: FabricClient integration tests live in FabricClientTests.swift.
/// This file focuses exclusively on the error type itself and the static
/// mapping helper.
@Suite("FabricError")
struct FabricErrorTests {

    // MARK: - All cases: throwable and catchable

    @Test("missingArgument can be thrown and caught")
    func missingArgumentThrowCatch() {
        func throwIt() throws { throw FabricError.missingArgument("workspaceID") }
        do {
            try throwIt()
            Issue.record("expected throw")
        } catch {
            if case FabricError.missingArgument(let name) = error {
                #expect(name == "workspaceID")
            } else {
                Issue.record("unexpected error: \(error)")
            }
        }
    }

    @Test("paginationExceeded can be thrown and caught")
    func paginationExceededThrowCatch() {
        func throwIt() throws { throw FabricError.paginationExceeded(500) }
        do {
            try throwIt()
            Issue.record("expected throw")
        } catch {
            if case FabricError.paginationExceeded(let limit) = error {
                #expect(limit == 500)
            } else {
                Issue.record("unexpected error: \(error)")
            }
        }
    }

    @Test("unauthorized can be thrown and caught")
    func unauthorizedThrowCatch() {
        func throwIt() throws { throw FabricError.unauthorized }
        do {
            try throwIt()
            Issue.record("expected throw")
        } catch {
            if case FabricError.unauthorized = error { /* correct */ }
            else { Issue.record("unexpected error: \(error)") }
        }
    }

    @Test("forbidden can be thrown and caught")
    func forbiddenThrowCatch() {
        func throwIt() throws { throw FabricError.forbidden }
        do {
            try throwIt()
            Issue.record("expected throw")
        } catch {
            if case FabricError.forbidden = error { /* correct */ }
            else { Issue.record("unexpected error: \(error)") }
        }
    }

    @Test("notFound can be thrown and caught")
    func notFoundThrowCatch() {
        func throwIt() throws { throw FabricError.notFound }
        do {
            try throwIt()
            Issue.record("expected throw")
        } catch {
            if case FabricError.notFound = error { /* correct */ }
            else { Issue.record("unexpected error: \(error)") }
        }
    }

    @Test("rateLimited can be thrown and caught")
    func rateLimitedThrowCatch() {
        func throwIt() throws { throw FabricError.rateLimited }
        do {
            try throwIt()
            Issue.record("expected throw")
        } catch {
            if case FabricError.rateLimited = error { /* correct */ }
            else { Issue.record("unexpected error: \(error)") }
        }
    }

    @Test("serverError preserves status code through throw/catch")
    func serverErrorThrowCatch() {
        func throwIt() throws { throw FabricError.serverError(502) }
        do {
            try throwIt()
            Issue.record("expected throw")
        } catch {
            if case FabricError.serverError(let code) = error {
                #expect(code == 502)
            } else {
                Issue.record("unexpected error: \(error)")
            }
        }
    }

    @Test("retriesExhausted preserves attempts count through throw/catch")
    func retriesExhaustedThrowCatch() {
        func throwIt() throws { throw FabricError.retriesExhausted(attempts: 7) }
        do {
            try throwIt()
            Issue.record("expected throw")
        } catch {
            if case FabricError.retriesExhausted(let attempts) = error {
                #expect(attempts == 7)
            } else {
                Issue.record("unexpected error: \(error)")
            }
        }
    }

    @Test("cancelled can be thrown and caught")
    func cancelledThrowCatch() {
        func throwIt() throws { throw FabricError.cancelled }
        do {
            try throwIt()
            Issue.record("expected throw")
        } catch {
            if case FabricError.cancelled = error { /* correct */ }
            else { Issue.record("unexpected error: \(error)") }
        }
    }

    @Test("httpError wraps an arbitrary error")
    func httpErrorThrowCatch() {
        struct Inner: Error {}
        func throwIt() throws { throw FabricError.httpError(Inner()) }
        do {
            try throwIt()
            Issue.record("expected throw")
        } catch {
            if case FabricError.httpError = error { /* correct */ }
            else { Issue.record("unexpected error: \(error)") }
        }
    }

    @Test("decodeFailed wraps an arbitrary error")
    func decodeFailedThrowCatch() {
        struct Inner: Error {}
        func throwIt() throws { throw FabricError.decodeFailed(Inner()) }
        do {
            try throwIt()
            Issue.record("expected throw")
        } catch {
            if case FabricError.decodeFailed = error { /* correct */ }
            else { Issue.record("unexpected error: \(error)") }
        }
    }

    @Test("loopingPagination preserves the token string")
    func loopingPaginationThrowCatch() {
        func throwIt() throws { throw FabricError.loopingPagination("STUCK-TOKEN") }
        do {
            try throwIt()
            Issue.record("expected throw")
        } catch {
            if case FabricError.loopingPagination(let token) = error {
                #expect(token == "STUCK-TOKEN")
            } else {
                Issue.record("unexpected error: \(error)")
            }
        }
    }

    @Test("continuationURIHostMismatch preserves the host string")
    func continuationURIHostMismatchThrowCatch() {
        func throwIt() throws { throw FabricError.continuationURIHostMismatch("evil.example.com") }
        do {
            try throwIt()
            Issue.record("expected throw")
        } catch {
            if case FabricError.continuationURIHostMismatch(let host) = error {
                #expect(host == "evil.example.com")
            } else {
                Issue.record("unexpected error: \(error)")
            }
        }
    }

    // MARK: - FabricError.from(_:) — HTTPClientError mapping

    @Test("from(.unauthorized) → .unauthorized")
    func fromUnauthorized() {
        let result = FabricError.from(HTTPClientError.unauthorized)
        if case .unauthorized = result { /* correct */ }
        else { Issue.record("expected .unauthorized, got \(result)") }
    }

    @Test("from(.forbidden) → .forbidden")
    func fromForbidden() {
        let result = FabricError.from(HTTPClientError.forbidden)
        if case .forbidden = result { /* correct */ }
        else { Issue.record("expected .forbidden, got \(result)") }
    }

    @Test("from(.notFound) → .notFound")
    func fromNotFound() {
        let result = FabricError.from(HTTPClientError.notFound)
        if case .notFound = result { /* correct */ }
        else { Issue.record("expected .notFound, got \(result)") }
    }

    @Test("from(.throttled) → .rateLimited")
    func fromThrottled() {
        let result = FabricError.from(HTTPClientError.throttled)
        if case .rateLimited = result { /* correct */ }
        else { Issue.record("expected .rateLimited, got \(result)") }
    }

    @Test("from(.cancelled) → .cancelled")
    func fromCancelled() {
        let result = FabricError.from(HTTPClientError.cancelled)
        if case .cancelled = result { /* correct */ }
        else { Issue.record("expected .cancelled, got \(result)") }
    }

    @Test("from(.serverError(502)) → .serverError(502)")
    func fromServerError() {
        let result = FabricError.from(HTTPClientError.serverError(502))
        if case .serverError(let code) = result {
            #expect(code == 502)
        } else {
            Issue.record("expected .serverError(502), got \(result)")
        }
    }

    @Test("from(.serverError(503)) → .serverError(503)")
    func fromServerError503() {
        let result = FabricError.from(HTTPClientError.serverError(503))
        if case .serverError(let code) = result {
            #expect(code == 503)
        } else {
            Issue.record("expected .serverError(503), got \(result)")
        }
    }

    @Test("from(.retriesExhausted(attempts:3, last:)) → .retriesExhausted(attempts:3)")
    func fromRetriesExhausted() {
        struct Sentinel: Error {}
        let result = FabricError.from(HTTPClientError.retriesExhausted(attempts: 3, last: Sentinel()))
        if case .retriesExhausted(let attempts) = result {
            #expect(attempts == 3)
        } else {
            Issue.record("expected .retriesExhausted(attempts:3), got \(result)")
        }
    }

    @Test("from(unrecognised error) → .httpError wrapping that error")
    func fromUnrecognisedError() {
        struct RandomError: Error {}
        let inner = RandomError()
        let result = FabricError.from(inner)
        if case .httpError = result { /* correct */ }
        else { Issue.record("expected .httpError, got \(result)") }
    }

    @Test("from(.conflict) falls through to .httpError (not a named mapping)")
    func fromConflictFallsThrough() {
        // .conflict is not explicitly mapped — it should fall through to httpError.
        let result = FabricError.from(HTTPClientError.conflict)
        if case .httpError = result { /* correct */ }
        else { Issue.record("expected .httpError for .conflict, got \(result)") }
    }

    @Test("from(.gone) → .gone (NIT-2: symmetry with OneLakeError)")
    func fromGone() {
        let result = FabricError.from(HTTPClientError.gone)
        if case .gone = result { /* correct */ }
        else { Issue.record("expected .gone, got \(result)") }
    }

    @Test("from(.payloadTooLarge) → .payloadTooLarge (NIT-2: symmetry with OneLakeError)")
    func fromPayloadTooLarge() {
        let result = FabricError.from(HTTPClientError.payloadTooLarge)
        if case .payloadTooLarge = result { /* correct */ }
        else { Issue.record("expected .payloadTooLarge, got \(result)") }
    }

    @Test("from(.rangeNotSatisfiable) → .rangeNotSatisfiable (NIT-2: symmetry with OneLakeError)")
    func fromRangeNotSatisfiable() {
        let result = FabricError.from(HTTPClientError.rangeNotSatisfiable)
        if case .rangeNotSatisfiable = result { /* correct */ }
        else { Issue.record("expected .rangeNotSatisfiable, got \(result)") }
    }

    @Test("from(.preconditionFailed) falls through to .httpError")
    func fromPreconditionFailedFallsThrough() {
        let result = FabricError.from(HTTPClientError.preconditionFailed)
        if case .httpError = result { /* correct */ }
        else { Issue.record("expected .httpError for .preconditionFailed, got \(result)") }
    }

    // MARK: - FabricError.from(_:) — non-HTTPClientError errors

    @Test("from(URLError) → .httpError wrapping URLError")
    func fromURLError() {
        let urlErr = URLError(.notConnectedToInternet)
        let result = FabricError.from(urlErr)
        if case .httpError = result { /* correct */ }
        else { Issue.record("expected .httpError for URLError, got \(result)") }
    }

    @Test("from(CancellationError) → .cancelled (fabric-02: bare Swift cancellation maps to .cancelled)")
    func fromCancellationError() {
        // fabric-02: a bare CancellationError from Swift Concurrency (thrown
        // between http.execute boundaries) must map to .cancelled, not .httpError,
        // so SyncEngine can silently discard user-initiated cancellation.
        let result = FabricError.from(CancellationError())
        if case .cancelled = result { /* correct */ }
        else { Issue.record("expected .cancelled for CancellationError (fabric-02), got \(result)") }
    }

    // MARK: - Fix #272: tokenAcquisitionFailed always maps to .unauthorized

    @Test("from(.tokenAcquisitionFailed(interactionRequired)) → .unauthorized (#272 regression)")
    func fromTokenAcquisitionFailedInteractionRequired() {
        // Regression for #272: previously only the interactionRequired inner
        // case mapped to .unauthorized; all other inner errors fell through to
        // .httpError, causing silent empty Finder mounts.
        let result = FabricError.from(HTTPClientError.tokenAcquisitionFailed(OfemAuthError.interactionRequired))
        if case .unauthorized = result { /* correct */ }
        else { Issue.record("expected .unauthorized for tokenAcquisitionFailed(interactionRequired), got \(result)") }
    }

    @Test("from(.tokenAcquisitionFailed(silentTokenFailed)) → .unauthorized (#272 regression: MSAL config error path)")
    func fromTokenAcquisitionFailedSilentTokenFailed() {
        // Regression for #272: the FPE bundle-ID mismatch (MSAL -42011) causes
        // silentToken to throw OfemAuthError.silentTokenFailed, which becomes
        // tokenAcquisitionFailed(silentTokenFailed). This MUST map to .unauthorized
        // so Finder shows an auth-required indicator rather than a silent empty folder.
        let result = FabricError.from(HTTPClientError.tokenAcquisitionFailed(OfemAuthError.silentTokenFailed("test")))
        if case .unauthorized = result { /* correct */ }
        else { Issue.record("expected .unauthorized for tokenAcquisitionFailed(silentTokenFailed), got \(result)") }
    }

    @Test("from(.tokenAcquisitionFailed(arbitrary error)) → .unauthorized (#272 regression: any token failure)")
    func fromTokenAcquisitionFailedArbitraryError() {
        // Regression for #272: any tokenAcquisitionFailed, including wrapping an
        // arbitrary NSError (e.g. raw MSAL -42011), must map to .unauthorized.
        struct ArbitraryError: Error {}
        let result = FabricError.from(HTTPClientError.tokenAcquisitionFailed(ArbitraryError()))
        if case .unauthorized = result { /* correct */ }
        else { Issue.record("expected .unauthorized for tokenAcquisitionFailed(arbitrary), got \(result)") }
    }

    @Test("from(.tokenAcquisitionFailed) does NOT map to .notFound (#272: misclassification regression)")
    func fromTokenAcquisitionFailedNotNotFound() {
        // Regression for #272: tokenAcquisitionFailed must NEVER map to .notFound.
        // Prior to the fix the silentTokenFailed path fell through to .httpError;
        // this test ensures the .notFound case is never reached for auth failures.
        let result = FabricError.from(HTTPClientError.tokenAcquisitionFailed(OfemAuthError.silentTokenFailed("alias")))
        if case .notFound = result {
            Issue.record("tokenAcquisitionFailed must NOT map to .notFound (#272 misclassification)")
        }
        // Any case other than .notFound is acceptable; .unauthorized is expected.
    }

    @Test("from(.notFound) still maps to .notFound after #272 fix (genuine 404 unaffected)")
    func fromNotFoundUnchangedAfter272Fix() {
        // Regression guard: the #272 fix must not affect genuine HTTP 404 mapping.
        let result = FabricError.from(HTTPClientError.notFound)
        if case .notFound = result { /* correct */ }
        else { Issue.record("genuine .notFound must still map to .notFound, got \(result)") }
    }

    @Test("from(.retriesExhausted with tokenAcquisitionFailed last) → .unauthorized (#272: broadened fabric-04)")
    func fromRetriesExhaustedWithTokenAcquisitionFailed() {
        // fabric-04 broadened by #272: a retry loop whose last error is ANY
        // tokenAcquisitionFailed (not just interactionRequired) must surface as
        // .unauthorized. Covers the FPE bundle-ID mismatch case where every
        // attempt in the retry loop fails with the same MSAL -42011 error.
        struct ArbitraryTokenError: Error {}
        let lastErr = HTTPClientError.tokenAcquisitionFailed(ArbitraryTokenError())
        let result = FabricError.from(HTTPClientError.retriesExhausted(attempts: 3, last: lastErr))
        if case .unauthorized = result { /* correct */ }
        else { Issue.record("retriesExhausted(last: tokenAcquisitionFailed) must map to .unauthorized, got \(result)") }
    }

    // MARK: - Transient-outage tradeoff (fabric-03-fix-272 comment regression)

    @Test("from(.tokenAcquisitionFailed(silentTokenFailed)) → .unauthorized: tradeoff regression guard")
    func fromTokenAcquisitionFailedTransientOutageTradeoff() {
        // Regression guard for the transient-outage tradeoff documented in
        // FabricError.from's comment: OfemAuth strips the underlying MSAL error
        // into OfemAuthError.silentTokenFailed before it reaches this mapper, so
        // transient network failures (Entra DNS timeout, TLS reset) and local
        // MSAL config errors (bundle-ID mismatch, -42011) both arrive here as
        // tokenAcquisitionFailed(silentTokenFailed). The broad .unauthorized
        // mapping is intentional — a false "Sign-in required" prompt is strictly
        // better than the previous silent empty Finder mount (.httpError path).
        // This test documents the chosen behaviour; if the inner-error distinction
        // is ever added, update this test to reflect the narrowed mapping.
        let result = FabricError.from(
            HTTPClientError.tokenAcquisitionFailed(OfemAuthError.silentTokenFailed("work"))
        )
        if case .unauthorized = result { /* correct — broad mapping is intentional */ }
        else { Issue.record("tokenAcquisitionFailed(silentTokenFailed) must map to .unauthorized (tradeoff); got \(result)") }
    }
}
