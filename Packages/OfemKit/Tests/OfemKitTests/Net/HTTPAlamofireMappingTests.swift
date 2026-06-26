import Alamofire
import Foundation
@testable import OfemKit
import Testing

// MARK: - HTTPClientError Alamofire-mapping tests (tests-14)

/// Tests for the ``HTTPClientError/init(afError:response:body:retryCount:)``
/// Alamofire path — specifically that body-relevant sentinel statuses
/// (401/403/429/5xx) produce ``HTTPClientError/sentinelWithBody(_:_:)`` with
/// the body intact, while non-body-relevant sentinels keep the bare typed case.
///
/// These tests close the coverage gap identified in issue #385: the mapping
/// was previously untested at the Alamofire boundary, so the body-stripping
/// defect passed all unit tests while breaking production behaviour.
@Suite("HTTPClientError Alamofire mapping")
struct HTTPAlamofireMappingTests {
    // MARK: - Helpers

    private func makeValidationError(status: Int, body: Data) -> HTTPClientError {
        let afErr = AFError.responseValidationFailed(
            reason: .unacceptableStatusCode(code: status)
        )
        let resp = HTTPURLResponse(
            url: URL(string: "https://example.com")!,
            statusCode: status,
            httpVersion: nil,
            headerFields: nil
        )!
        return HTTPClientError(afError: afErr, response: resp, body: body)
    }

    // MARK: - Body-relevant sentinels → sentinelWithBody

    @Test("403 with body produces sentinelWithBody(.forbidden) with body intact")
    func maps403WithBodyToSentinelWithBody() {
        let body = Data(#"{"errorCode":"InsufficientPrivileges"}"#.utf8)
        let err = makeValidationError(status: 403, body: body)
        guard case let .sentinelWithBody(sentinel, ae) = err else {
            Issue.record("Expected .sentinelWithBody(.forbidden, _), got \(err)")
            return
        }
        guard case .forbidden = sentinel else {
            Issue.record("Expected .forbidden as inner sentinel, got \(sentinel)")
            return
        }
        #expect(ae.body == body)
        #expect(ae.statusCode == 403)
    }

    @Test("401 with body produces sentinelWithBody(.unauthorized) with body intact")
    func maps401WithBodyToSentinelWithBody() {
        let body = Data(#"{"errorCode":"TokenExpired"}"#.utf8)
        let err = makeValidationError(status: 401, body: body)
        guard case let .sentinelWithBody(sentinel, ae) = err else {
            Issue.record("Expected .sentinelWithBody(.unauthorized, _), got \(err)")
            return
        }
        guard case .unauthorized = sentinel else {
            Issue.record("Expected .unauthorized as inner sentinel, got \(sentinel)")
            return
        }
        #expect(ae.body == body)
    }

    @Test("429 with body produces sentinelWithBody(.throttled) with body intact")
    func maps429WithBodyToSentinelWithBody() {
        let body = Data(#"{"errorCode":"RequestBlocked"}"#.utf8)
        let err = makeValidationError(status: 429, body: body)
        guard case let .sentinelWithBody(sentinel, ae) = err else {
            Issue.record("Expected .sentinelWithBody(.throttled, _), got \(err)")
            return
        }
        guard case .throttled = sentinel else {
            Issue.record("Expected .throttled as inner sentinel, got \(sentinel)")
            return
        }
        #expect(ae.body == body)
    }

    @Test("503 with body produces sentinelWithBody(.serverError(503)) with body intact")
    func maps503WithBodyToSentinelWithBody() {
        let body = Data(#"{"message":"capacity paused"}"#.utf8)
        let err = makeValidationError(status: 503, body: body)
        guard case let .sentinelWithBody(sentinel, ae) = err else {
            Issue.record("Expected .sentinelWithBody(.serverError(503), _), got \(err)")
            return
        }
        guard case .serverError(503) = sentinel else {
            Issue.record("Expected .serverError(503) as inner sentinel, got \(sentinel)")
            return
        }
        #expect(ae.body == body)
    }

    // MARK: - Non-body-relevant sentinels → bare typed sentinel

    @Test("404 with body produces bare .notFound (body not carried)")
    func maps404WithBodyToBareNotFound() {
        let body = Data(#"{"detail":"not found"}"#.utf8)
        let err = makeValidationError(status: 404, body: body)
        guard case .notFound = err else {
            Issue.record("Expected bare .notFound for 404, got \(err)")
            return
        }
    }

    @Test("412 with body produces bare .preconditionFailed (body not carried)")
    func maps412WithBodyToBarePreconditionFailed() {
        let body = Data(#"{"detail":"etag mismatch"}"#.utf8)
        let err = makeValidationError(status: 412, body: body)
        guard case .preconditionFailed = err else {
            Issue.record("Expected bare .preconditionFailed for 412, got \(err)")
            return
        }
    }

    // MARK: - Body-carrying sentinel → OneLakeError round-trip

    @Test("sentinelWithBody(.forbidden) flows through OneLakeError.from to .httpError(.sentinelWithBody)")
    func oneLakeFromSentinelWithBody() {
        let body = Data(#"{"errorCode":"InsufficientPrivileges"}"#.utf8)
        let ae = APIError(statusCode: 403, status: "403 Forbidden", body: body)
        let input = HTTPClientError.sentinelWithBody(.forbidden, ae)
        let onelakeErr = OneLakeError.from(input)
        guard case let .httpError(inner) = onelakeErr,
              let httpErr = inner as? HTTPClientError,
              case let .sentinelWithBody(sentinel, resultAE) = httpErr
        else {
            Issue.record("Expected .httpError(.sentinelWithBody(.forbidden, _)), got \(onelakeErr)")
            return
        }
        guard case .forbidden = sentinel else {
            Issue.record("Expected .forbidden sentinel, got \(sentinel)")
            return
        }
        #expect(resultAE.body == body)
    }
}
