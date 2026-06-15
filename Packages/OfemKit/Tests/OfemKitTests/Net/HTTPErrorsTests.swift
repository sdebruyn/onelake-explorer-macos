import Testing
import Foundation
@testable import OfemKit

// MARK: - HTTPErrorsTests

/// Tests for ``HTTPClientError`` and ``APIError`` that are NOT already covered
/// by HTTPRetryTests.swift (which covers `sentinel(for:)` for a subset of codes)
/// or HTTPClientTests.swift (which covers the client behaviour).
///
/// This file focuses on:
/// - sentinel(for:) for the remaining unmapped / edge-case codes
/// - isRetriableStatus(_:) for all documented retriable and non-retriable codes
/// - APIError.description formatting (body truncation, empty body, attemptsSuffix)
/// - APIError.sentinel computed property
/// - Cases that are untested elsewhere: .conflict, .gone, .preconditionFailed,
///   .payloadTooLarge, .unsupportedMediaType, .rangeNotSatisfiable,
///   .unprocessableEntity, .serverError(_:), cases without sentinels
@Suite("HTTPClientError")
struct HTTPClientErrorTests {

    // MARK: - sentinel(for:) — cases not covered in HTTPRetryTests

    @Test("413 maps to .payloadTooLarge")
    func maps413() {
        guard case .payloadTooLarge = HTTPClientError.sentinel(for: 413) else {
            Issue.record("expected .payloadTooLarge for 413"); return
        }
    }

    @Test("415 maps to .unsupportedMediaType")
    func maps415() {
        guard case .unsupportedMediaType = HTTPClientError.sentinel(for: 415) else {
            Issue.record("expected .unsupportedMediaType for 415"); return
        }
    }

    @Test("416 maps to .rangeNotSatisfiable")
    func maps416() {
        guard case .rangeNotSatisfiable = HTTPClientError.sentinel(for: 416) else {
            Issue.record("expected .rangeNotSatisfiable for 416"); return
        }
    }

    @Test("422 maps to .unprocessableEntity")
    func maps422() {
        guard case .unprocessableEntity = HTTPClientError.sentinel(for: 422) else {
            Issue.record("expected .unprocessableEntity for 422"); return
        }
    }

    @Test("500 maps to .serverError(500)")
    func mapsServerError500() {
        if case .serverError(let code) = HTTPClientError.sentinel(for: 500) {
            #expect(code == 500)
        } else {
            Issue.record("expected .serverError(500)")
        }
    }

    @Test("503 maps to .serverError(503)")
    func mapsServerError503() {
        if case .serverError(let code) = HTTPClientError.sentinel(for: 503) {
            #expect(code == 503)
        } else {
            Issue.record("expected .serverError(503)")
        }
    }

    @Test("599 maps to .serverError(599)")
    func mapsServerError599() {
        if case .serverError(let code) = HTTPClientError.sentinel(for: 599) {
            #expect(code == 599)
        } else {
            Issue.record("expected .serverError(599)")
        }
    }

    @Test("300 has no sentinel (redirects are not typed)")
    func maps300() {
        #expect(HTTPClientError.sentinel(for: 300) == nil)
    }

    @Test("201 has no sentinel")
    func maps201() {
        #expect(HTTPClientError.sentinel(for: 201) == nil)
    }

    @Test("408 has no named sentinel (not one of the typed cases)")
    func maps408() {
        // 408 is retriable but has no named sentinel — it falls through to nil
        // because the switch only handles the named cases and 500+.
        // If this changes in future, the test will fail and need updating.
        #expect(HTTPClientError.sentinel(for: 408) == nil)
    }

    // MARK: - isRetriableStatus(_:)

    @Test("408 is retriable")
    func retriable408() {
        #expect(HTTPClientError.isRetriableStatus(408))
    }

    @Test("425 is retriable")
    func retriable425() {
        #expect(HTTPClientError.isRetriableStatus(425))
    }

    @Test("429 is retriable")
    func retriable429() {
        #expect(HTTPClientError.isRetriableStatus(429))
    }

    @Test("500 is retriable")
    func retriable500() {
        #expect(HTTPClientError.isRetriableStatus(500))
    }

    @Test("502 is retriable")
    func retriable502() {
        #expect(HTTPClientError.isRetriableStatus(502))
    }

    @Test("503 is retriable")
    func retriable503() {
        #expect(HTTPClientError.isRetriableStatus(503))
    }

    @Test("504 is retriable")
    func retriable504() {
        #expect(HTTPClientError.isRetriableStatus(504))
    }

    @Test("200 is NOT retriable")
    func notRetriable200() {
        #expect(!HTTPClientError.isRetriableStatus(200))
    }

    @Test("401 is NOT retriable")
    func notRetriable401() {
        #expect(!HTTPClientError.isRetriableStatus(401))
    }

    @Test("403 is NOT retriable")
    func notRetriable403() {
        #expect(!HTTPClientError.isRetriableStatus(403))
    }

    @Test("404 is NOT retriable")
    func notRetriable404() {
        #expect(!HTTPClientError.isRetriableStatus(404))
    }

    @Test("412 is NOT retriable")
    func notRetriable412() {
        #expect(!HTTPClientError.isRetriableStatus(412))
    }

    @Test("501 is NOT retriable")
    func notRetriable501() {
        #expect(!HTTPClientError.isRetriableStatus(501))
    }
}

// MARK: - APIErrorTests

@Suite("APIError")
struct APIErrorTests {

    // MARK: - description: body present, single attempt

    @Test("description with body and one attempt omits attempt suffix")
    func descriptionBodyNoAttemptSuffix() {
        let err = APIError(
            statusCode: 404,
            status: "404 Not Found",
            body: "resource missing".data(using: .utf8)!,
            attempts: 1
        )
        #expect(err.description == "HTTP 404 Not Found: resource missing")
    }

    @Test("description with body and multiple attempts includes attempt suffix")
    func descriptionBodyWithAttemptSuffix() {
        let err = APIError(
            statusCode: 503,
            status: "503 Service Unavailable",
            body: "overloaded".data(using: .utf8)!,
            attempts: 3
        )
        #expect(err.description == "HTTP 503 Service Unavailable after 3 attempts: overloaded")
    }

    // MARK: - description: empty body

    @Test("description with empty body omits body segment")
    func descriptionEmptyBody() {
        let err = APIError(
            statusCode: 429,
            status: "429 Too Many Requests",
            body: Data(),
            attempts: 1
        )
        #expect(err.description == "HTTP 429 Too Many Requests")
    }

    @Test("description with empty body and multiple attempts includes suffix but no body segment")
    func descriptionEmptyBodyMultipleAttempts() {
        let err = APIError(
            statusCode: 500,
            status: "500 Internal Server Error",
            body: Data(),
            attempts: 2
        )
        #expect(err.description == "HTTP 500 Internal Server Error after 2 attempts")
    }

    // MARK: - description: body truncation at 256 bytes

    @Test("description truncates body to 256 bytes")
    func descriptionBodyTruncatedAt256() {
        // Build a 300-character ASCII body.
        let longBody = String(repeating: "A", count: 300)
        let err = APIError(
            statusCode: 400,
            status: "400 Bad Request",
            body: longBody.data(using: .utf8)!,
            attempts: 1
        )
        // The resulting description should contain at most 256 'A's.
        let desc = err.description
        let aCount = desc.filter { $0 == "A" }.count
        #expect(aCount == 256)
    }

    // MARK: - description: whitespace trimming

    @Test("description trims leading/trailing whitespace from body")
    func descriptionTrimsWhitespace() {
        let err = APIError(
            statusCode: 422,
            status: "422 Unprocessable Entity",
            body: "  trimmed  ".data(using: .utf8)!,
            attempts: 1
        )
        #expect(err.description == "HTTP 422 Unprocessable Entity: trimmed")
    }

    @Test("description treats whitespace-only body as empty (no body segment)")
    func descriptionWhitespaceOnlyBody() {
        let err = APIError(
            statusCode: 503,
            status: "503 Service Unavailable",
            body: "   \n\t  ".data(using: .utf8)!,
            attempts: 1
        )
        #expect(err.description == "HTTP 503 Service Unavailable")
    }

    // MARK: - sentinel computed property

    @Test("APIError.sentinel returns .unauthorized for statusCode 401")
    func sentinelUnauthorized() {
        let err = APIError(statusCode: 401, status: "401 Unauthorized", body: Data())
        if case .unauthorized = err.sentinel {
            // correct
        } else {
            Issue.record("expected .unauthorized, got \(String(describing: err.sentinel))")
        }
    }

    @Test("APIError.sentinel returns .notFound for statusCode 404")
    func sentinelNotFound() {
        let err = APIError(statusCode: 404, status: "404 Not Found", body: Data())
        if case .notFound = err.sentinel {
            // correct
        } else {
            Issue.record("expected .notFound, got \(String(describing: err.sentinel))")
        }
    }

    @Test("APIError.sentinel returns nil for statusCode 400")
    func sentinelNilFor400() {
        let err = APIError(statusCode: 400, status: "400 Bad Request", body: Data())
        #expect(err.sentinel == nil)
    }

    @Test("APIError.sentinel returns nil for statusCode 200")
    func sentinelNilFor200() {
        let err = APIError(statusCode: 200, status: "200 OK", body: Data())
        #expect(err.sentinel == nil)
    }

    @Test("APIError.sentinel returns .serverError for statusCode 500")
    func sentinelServerError() {
        let err = APIError(statusCode: 500, status: "500 Internal Server Error", body: Data())
        if case .serverError(let code) = err.sentinel {
            #expect(code == 500)
        } else {
            Issue.record("expected .serverError(500)")
        }
    }

    // MARK: - Default parameter values

    @Test("APIError init defaults retryAfter to .zero")
    func defaultRetryAfter() {
        let err = APIError(statusCode: 200, status: "200 OK", body: Data())
        #expect(err.retryAfter == .zero)
    }

    @Test("APIError init defaults attempts to 1")
    func defaultAttempts() {
        let err = APIError(statusCode: 200, status: "200 OK", body: Data())
        #expect(err.attempts == 1)
    }

    @Test("APIError stores all provided fields")
    func storedFields() {
        let body = "body text".data(using: .utf8)!
        let err = APIError(
            statusCode: 503,
            status: "503 Service Unavailable",
            body: body,
            retryAfter: .seconds(5),
            attempts: 4
        )
        #expect(err.statusCode == 503)
        #expect(err.status == "503 Service Unavailable")
        #expect(err.body == body)
        #expect(err.retryAfter == .seconds(5))
        #expect(err.attempts == 4)
    }
}
