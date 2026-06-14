import Testing
import Foundation
@testable import OfemKit

// MARK: - CacheErrorTests

/// Tests for ``CacheError``: all cases, `LocalizedError.errorDescription`,
/// and the `Equatable` conformance including the case-only comparison for
/// `.blobIOError`.
@Suite("CacheError")
struct CacheErrorTests {

    // MARK: - errorDescription: notFound

    @Test("notFound errorDescription contains the description string")
    func notFoundErrorDescription() {
        let err = CacheError.notFound("ws1/item1/Files/data.csv")
        #expect(err.errorDescription == "Cache entry not found: ws1/item1/Files/data.csv")
    }

    @Test("notFound errorDescription with empty string")
    func notFoundEmptyDescription() {
        let err = CacheError.notFound("")
        #expect(err.errorDescription == "Cache entry not found: ")
    }

    // MARK: - errorDescription: invalidSHA

    @Test("invalidSHA errorDescription wraps the bad digest in quotes")
    func invalidSHAErrorDescription() {
        let err = CacheError.invalidSHA("tooshort")
        #expect(err.errorDescription == "Invalid SHA-256 digest: 'tooshort'")
    }

    @Test("invalidSHA errorDescription with empty string")
    func invalidSHAEmptyString() {
        let err = CacheError.invalidSHA("")
        #expect(err.errorDescription == "Invalid SHA-256 digest: ''")
    }

    // MARK: - errorDescription: missingArgument

    @Test("missingArgument errorDescription contains the argument name")
    func missingArgumentErrorDescription() {
        let err = CacheError.missingArgument("workspaceID")
        #expect(err.errorDescription == "Missing required argument: workspaceID")
    }

    // MARK: - errorDescription: blobIOError

    @Test("blobIOError errorDescription contains blob I/O prefix")
    func blobIOErrorDescriptionPrefix() {
        let inner = CocoaError(.fileNoSuchFile)
        let err = CacheError.blobIOError(inner)
        // The prefix is fixed; only the suffix (localizedDescription of the inner
        // error) may vary by platform locale.
        #expect(err.errorDescription?.hasPrefix("Blob I/O error:") == true)
    }

    @Test("blobIOError errorDescription embeds the inner error's localizedDescription")
    func blobIOErrorDescriptionEmbedsInner() {
        struct FixedError: Error, LocalizedError {
            var errorDescription: String? { "disk read failed" }
        }
        let err = CacheError.blobIOError(FixedError())
        #expect(err.errorDescription?.contains("disk read failed") == true)
    }

    // MARK: - Equatable: same-case with equal values

    @Test("notFound equal when descriptions match")
    func notFoundEqual() {
        #expect(CacheError.notFound("a") == CacheError.notFound("a"))
    }

    @Test("notFound not equal when descriptions differ")
    func notFoundNotEqual() {
        #expect(CacheError.notFound("a") != CacheError.notFound("b"))
    }

    @Test("invalidSHA equal when digests match")
    func invalidSHAEqual() {
        #expect(CacheError.invalidSHA("x") == CacheError.invalidSHA("x"))
    }

    @Test("invalidSHA not equal when digests differ")
    func invalidSHANotEqual() {
        #expect(CacheError.invalidSHA("x") != CacheError.invalidSHA("y"))
    }

    @Test("missingArgument equal when names match")
    func missingArgumentEqual() {
        #expect(CacheError.missingArgument("a") == CacheError.missingArgument("a"))
    }

    @Test("missingArgument not equal when names differ")
    func missingArgumentNotEqual() {
        #expect(CacheError.missingArgument("a") != CacheError.missingArgument("b"))
    }

    // MARK: - Equatable: blobIOError compares case only

    @Test("blobIOError equals another blobIOError regardless of wrapped error")
    func blobIOErrorEqualCaseOnly() {
        struct ErrA: Error {}
        struct ErrB: Error {}
        // Per the Equatable implementation, wrapped errors are not compared.
        #expect(CacheError.blobIOError(ErrA()) == CacheError.blobIOError(ErrB()))
    }

    // MARK: - Equatable: cross-case inequality

    @Test("notFound is not equal to invalidSHA")
    func crossCaseNotFoundVsInvalidSHA() {
        #expect(CacheError.notFound("x") != CacheError.invalidSHA("x"))
    }

    @Test("missingArgument is not equal to notFound")
    func crossCaseMissingVsNotFound() {
        #expect(CacheError.missingArgument("x") != CacheError.notFound("x"))
    }

    @Test("blobIOError is not equal to notFound")
    func crossCaseBlobIOVsNotFound() {
        #expect(CacheError.blobIOError(CocoaError(.fileNoSuchFile)) != CacheError.notFound("x"))
    }

    // MARK: - CacheError conforms to Error (throwable)

    @Test("CacheError can be thrown and caught by case")
    func cacheErrorIsThrowable() {
        func throwIt() throws { throw CacheError.notFound("missing-key") }
        do {
            try throwIt()
            Issue.record("expected throw")
        } catch {
            if case CacheError.notFound(let desc) = error {
                #expect(desc == "missing-key")
            } else {
                Issue.record("unexpected error: \(error)")
            }
        }
    }

    @Test("invalidSHA preserves associated value through throw/catch")
    func invalidSHAThrowCatch() {
        func throwIt() throws { throw CacheError.invalidSHA("bad-sha") }
        do {
            try throwIt()
            Issue.record("expected throw")
        } catch {
            if case CacheError.invalidSHA(let sha) = error {
                #expect(sha == "bad-sha")
            } else {
                Issue.record("unexpected error: \(error)")
            }
        }
    }
}
