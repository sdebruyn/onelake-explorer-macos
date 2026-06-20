import Testing
import Foundation
@testable import OfemKit

// MARK: - OneLakeErrorTests

/// Tests for ``OneLakeError``: all cases are throwable/catchable, and the
/// `OneLakeError.from(_:)` mapping covers every HTTPClientError branch plus
/// the default fallback.
///
/// NOTE: OneLakeClient integration tests live in OneLakeClientTests.swift.
/// This file focuses exclusively on the error type itself and the static
/// mapping helper.
@Suite("OneLakeError")
struct OneLakeErrorTests {

    // MARK: - All cases: throwable and catchable

    @Test("missingArgument can be thrown and caught")
    func missingArgumentThrowCatch() {
        func throwIt() throws { throw OneLakeError.missingArgument("workspaceID") }
        do {
            try throwIt()
            Issue.record("expected throw")
        } catch {
            if case OneLakeError.missingArgument(let name) = error {
                #expect(name == "workspaceID")
            } else {
                Issue.record("unexpected error: \(error)")
            }
        }
    }

    @Test("paginationExceeded can be thrown and caught")
    func paginationExceededThrowCatch() {
        func throwIt() throws { throw OneLakeError.paginationExceeded(500) }
        do {
            try throwIt()
            Issue.record("expected throw")
        } catch {
            if case OneLakeError.paginationExceeded(let limit) = error {
                #expect(limit == 500)
            } else {
                Issue.record("unexpected error: \(error)")
            }
        }
    }

    @Test("unauthorized can be thrown and caught")
    func unauthorizedThrowCatch() {
        func throwIt() throws { throw OneLakeError.unauthorized }
        do {
            try throwIt()
            Issue.record("expected throw")
        } catch {
            if case OneLakeError.unauthorized = error { /* correct */ }
            else { Issue.record("unexpected error: \(error)") }
        }
    }

    @Test("forbidden can be thrown and caught")
    func forbiddenThrowCatch() {
        func throwIt() throws { throw OneLakeError.forbidden }
        do {
            try throwIt()
            Issue.record("expected throw")
        } catch {
            if case OneLakeError.forbidden = error { /* correct */ }
            else { Issue.record("unexpected error: \(error)") }
        }
    }

    @Test("notFound can be thrown and caught")
    func notFoundThrowCatch() {
        func throwIt() throws { throw OneLakeError.notFound }
        do {
            try throwIt()
            Issue.record("expected throw")
        } catch {
            if case OneLakeError.notFound = error { /* correct */ }
            else { Issue.record("unexpected error: \(error)") }
        }
    }

    @Test("rateLimited can be thrown and caught")
    func rateLimitedThrowCatch() {
        func throwIt() throws { throw OneLakeError.rateLimited }
        do {
            try throwIt()
            Issue.record("expected throw")
        } catch {
            if case OneLakeError.rateLimited = error { /* correct */ }
            else { Issue.record("unexpected error: \(error)") }
        }
    }

    @Test("serverError preserves status code through throw/catch")
    func serverErrorThrowCatch() {
        func throwIt() throws { throw OneLakeError.serverError(502) }
        do {
            try throwIt()
            Issue.record("expected throw")
        } catch {
            if case OneLakeError.serverError(let code) = error {
                #expect(code == 502)
            } else {
                Issue.record("unexpected error: \(error)")
            }
        }
    }

    @Test("retriesExhausted preserves attempts count through throw/catch")
    func retriesExhaustedThrowCatch() {
        func throwIt() throws { throw OneLakeError.retriesExhausted(attempts: 7) }
        do {
            try throwIt()
            Issue.record("expected throw")
        } catch {
            if case OneLakeError.retriesExhausted(let attempts) = error {
                #expect(attempts == 7)
            } else {
                Issue.record("unexpected error: \(error)")
            }
        }
    }

    @Test("cancelled can be thrown and caught")
    func cancelledThrowCatch() {
        func throwIt() throws { throw OneLakeError.cancelled }
        do {
            try throwIt()
            Issue.record("expected throw")
        } catch {
            if case OneLakeError.cancelled = error { /* correct */ }
            else { Issue.record("unexpected error: \(error)") }
        }
    }

    @Test("httpError wraps an arbitrary error")
    func httpErrorThrowCatch() {
        struct Inner: Error {}
        func throwIt() throws { throw OneLakeError.httpError(Inner()) }
        do {
            try throwIt()
            Issue.record("expected throw")
        } catch {
            if case OneLakeError.httpError = error { /* correct */ }
            else { Issue.record("unexpected error: \(error)") }
        }
    }

    @Test("decodeFailed wraps an arbitrary error")
    func decodeFailedThrowCatch() {
        struct Inner: Error {}
        func throwIt() throws { throw OneLakeError.decodeFailed(Inner()) }
        do {
            try throwIt()
            Issue.record("expected throw")
        } catch {
            if case OneLakeError.decodeFailed = error { /* correct */ }
            else { Issue.record("unexpected error: \(error)") }
        }
    }

    // MARK: - OneLakeError.from(_:) — HTTPClientError mapping

    @Test("from(.unauthorized) → .unauthorized")
    func fromUnauthorized() {
        let result = OneLakeError.from(HTTPClientError.unauthorized)
        if case .unauthorized = result { /* correct */ }
        else { Issue.record("expected .unauthorized, got \(result)") }
    }

    @Test("from(.forbidden) → .forbidden")
    func fromForbidden() {
        let result = OneLakeError.from(HTTPClientError.forbidden)
        if case .forbidden = result { /* correct */ }
        else { Issue.record("expected .forbidden, got \(result)") }
    }

    @Test("from(.notFound) → .notFound")
    func fromNotFound() {
        let result = OneLakeError.from(HTTPClientError.notFound)
        if case .notFound = result { /* correct */ }
        else { Issue.record("expected .notFound, got \(result)") }
    }

    @Test("from(.throttled) → .rateLimited")
    func fromThrottled() {
        let result = OneLakeError.from(HTTPClientError.throttled)
        if case .rateLimited = result { /* correct */ }
        else { Issue.record("expected .rateLimited, got \(result)") }
    }

    @Test("from(.cancelled) → .cancelled")
    func fromCancelled() {
        let result = OneLakeError.from(HTTPClientError.cancelled)
        if case .cancelled = result { /* correct */ }
        else { Issue.record("expected .cancelled, got \(result)") }
    }

    @Test("from(.serverError(502)) → .serverError(502)")
    func fromServerError() {
        let result = OneLakeError.from(HTTPClientError.serverError(502))
        if case .serverError(let code) = result {
            #expect(code == 502)
        } else {
            Issue.record("expected .serverError(502), got \(result)")
        }
    }

    @Test("from(.retriesExhausted(attempts:3, last:)) → .retriesExhausted(attempts:3)")
    func fromRetriesExhausted() {
        struct Sentinel: Error {}
        let result = OneLakeError.from(HTTPClientError.retriesExhausted(attempts: 3, last: Sentinel()))
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
        let result = OneLakeError.from(inner)
        if case .httpError = result { /* correct */ }
        else { Issue.record("expected .httpError, got \(result)") }
    }

    // MARK: - OneLakeError.from(_:) — non-HTTPClientError errors

    @Test("from(URLError) → .httpError wrapping URLError")
    func fromURLError() {
        let urlErr = URLError(.notConnectedToInternet)
        let result = OneLakeError.from(urlErr)
        if case .httpError = result { /* correct */ }
        else { Issue.record("expected .httpError for URLError, got \(result)") }
    }

    @Test("from(CancellationError) → .cancelled (bare Swift cancellation maps to .cancelled)")
    func fromCancellationError() {
        // A bare CancellationError from Swift Concurrency (thrown between http.execute
        // boundaries) must map to .cancelled, not .httpError, so SyncEngine can
        // silently discard user-initiated cancellation.
        let result = OneLakeError.from(CancellationError())
        if case .cancelled = result { /* correct */ }
        else { Issue.record("expected .cancelled for CancellationError, got \(result)") }
    }

    // MARK: - Fix #276: tokenAcquisitionFailed always maps to .unauthorized

    @Test("from(.tokenAcquisitionFailed(interactionRequired)) → .unauthorized (#276 regression)")
    func fromTokenAcquisitionFailedInteractionRequired() {
        // Regression for #276: tokenAcquisitionFailed must map to .unauthorized
        // so Finder shows an auth-required indicator rather than a silent empty folder.
        let result = OneLakeError.from(HTTPClientError.tokenAcquisitionFailed(OfemAuthError.interactionRequired))
        if case .unauthorized = result { /* correct */ }
        else { Issue.record("expected .unauthorized for tokenAcquisitionFailed(interactionRequired), got \(result)") }
    }

    @Test("from(.tokenAcquisitionFailed(silentTokenFailed)) → .unauthorized (#276 regression: MSAL config error path)")
    func fromTokenAcquisitionFailedSilentTokenFailed() {
        // Regression for #276: the FPE bundle-ID mismatch (MSAL -42011) causes
        // silentToken to throw OfemAuthError.silentTokenFailed, which becomes
        // tokenAcquisitionFailed(silentTokenFailed). This MUST map to .unauthorized
        // so Finder shows an auth-required indicator rather than a silent empty folder.
        let result = OneLakeError.from(HTTPClientError.tokenAcquisitionFailed(OfemAuthError.silentTokenFailed("test")))
        if case .unauthorized = result { /* correct */ }
        else { Issue.record("expected .unauthorized for tokenAcquisitionFailed(silentTokenFailed), got \(result)") }
    }

    @Test("from(.tokenAcquisitionFailed(arbitrary error)) → .unauthorized (#276 regression: any token failure)")
    func fromTokenAcquisitionFailedArbitraryError() {
        // Regression for #276: any tokenAcquisitionFailed, including wrapping an
        // arbitrary NSError (e.g. raw MSAL -42011), must map to .unauthorized.
        struct ArbitraryError: Error {}
        let result = OneLakeError.from(HTTPClientError.tokenAcquisitionFailed(ArbitraryError()))
        if case .unauthorized = result { /* correct */ }
        else { Issue.record("expected .unauthorized for tokenAcquisitionFailed(arbitrary), got \(result)") }
    }

    @Test("from(.tokenAcquisitionFailed) does NOT map to .notFound (#276: misclassification regression)")
    func fromTokenAcquisitionFailedNotNotFound() {
        // Regression for #276: tokenAcquisitionFailed must NEVER map to .notFound.
        let result = OneLakeError.from(HTTPClientError.tokenAcquisitionFailed(OfemAuthError.silentTokenFailed("alias")))
        if case .notFound = result {
            Issue.record("tokenAcquisitionFailed must NOT map to .notFound (#276 misclassification)")
        }
        // Any case other than .notFound is acceptable; .unauthorized is expected.
    }

    @Test("from(.notFound) still maps to .notFound after #276 fix (genuine 404 unaffected)")
    func fromNotFoundUnchangedAfter276Fix() {
        // Regression guard: the #276 fix must not affect genuine HTTP 404 mapping.
        let result = OneLakeError.from(HTTPClientError.notFound)
        if case .notFound = result { /* correct */ }
        else { Issue.record("genuine .notFound must still map to .notFound, got \(result)") }
    }

    @Test("from(.retriesExhausted with tokenAcquisitionFailed last) → .unauthorized (#276: onelake-02)")
    func fromRetriesExhaustedWithTokenAcquisitionFailed() {
        // onelake-02-fix-276: a retry loop whose last error is ANY tokenAcquisitionFailed
        // must surface as .unauthorized. Covers the FPE bundle-ID mismatch case where
        // every attempt in the retry loop fails with the same MSAL -42011 error.
        struct ArbitraryTokenError: Error {}
        let lastErr = HTTPClientError.tokenAcquisitionFailed(ArbitraryTokenError())
        let result = OneLakeError.from(HTTPClientError.retriesExhausted(attempts: 3, last: lastErr))
        if case .unauthorized = result { /* correct */ }
        else { Issue.record("retriesExhausted(last: tokenAcquisitionFailed) must map to .unauthorized, got \(result)") }
    }

    // MARK: - Fix #276: .unauthorized surfaces as FPError.notAuthenticated

    @Test(".unauthorized maps to FPError.notAuthenticated via FPError.classify")
    func unauthorizedMapsToNotAuthenticated() {
        // End-to-end regression: a tokenAcquisitionFailed reaching OneLakeError.from
        // must ultimately surface as FPError.notAuthenticated (the auth indicator
        // in Finder), not as .cannotSynchronize (silent sync failure).
        struct ArbitraryError: Error {}
        let oneLakeErr = OneLakeError.from(HTTPClientError.tokenAcquisitionFailed(ArbitraryError()))
        let code = FPError.classify(oneLakeErr)
        #expect(code == .notAuthenticated)
    }

    @Test(".unauthorized from retriesExhausted(tokenAcquisitionFailed) maps to FPError.notAuthenticated")
    func retriesExhaustedTokenAcquisitionFailedMapsToNotAuthenticated() {
        // End-to-end regression: a retriesExhausted wrapping tokenAcquisitionFailed
        // must also surface as FPError.notAuthenticated.
        struct ArbitraryError: Error {}
        let lastErr = HTTPClientError.tokenAcquisitionFailed(ArbitraryError())
        let oneLakeErr = OneLakeError.from(HTTPClientError.retriesExhausted(attempts: 2, last: lastErr))
        let code = FPError.classify(oneLakeErr)
        #expect(code == .notAuthenticated)
    }
}
