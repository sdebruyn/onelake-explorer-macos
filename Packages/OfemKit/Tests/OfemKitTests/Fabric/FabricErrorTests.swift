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

    @Test("from(.gone) falls through to .httpError")
    func fromGoneFallsThrough() {
        let result = FabricError.from(HTTPClientError.gone)
        if case .httpError = result { /* correct */ }
        else { Issue.record("expected .httpError for .gone, got \(result)") }
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
}
