import Foundation
@testable import OfemKit
import Testing

// MARK: - FPError.classify tests (tests-07)

//
// `FPError.classify(_:)` is the FPE's single error boundary — every engine
// error becomes an NSFileProviderError through this mapping. A misrouted case
// silently changes Finder behaviour for every user, so we test the full matrix.

struct FPErrorClassifyTests {
    // MARK: - FPError domain errors

    @Test func noSuchItemMapsToNoSuchItem() {
        #expect(FPError.classify(FPError.noSuchItem("x")) == .noSuchItem)
    }

    @Test func invalidIdentifierMapsToNoSuchItem() {
        #expect(FPError.classify(FPError.invalidIdentifier("bad")) == .noSuchItem)
    }

    @Test func wrongItemKindMapsToNoSuchItem() {
        #expect(FPError.classify(FPError.wrongItemKind("dir for file")) == .noSuchItem)
    }

    @Test func invalidRecordMapsToCannotSynchronize() {
        #expect(FPError.classify(FPError.invalidRecord("missing field")) == .cannotSynchronize)
    }

    // MARK: - URLError transport errors

    @Test func urlErrorNotConnectedMapsToServerUnreachable() {
        let err = URLError(.notConnectedToInternet)
        #expect(FPError.classify(err) == .serverUnreachable)
    }

    @Test func urlErrorNetworkConnectionLostMapsToServerUnreachable() {
        let err = URLError(.networkConnectionLost)
        #expect(FPError.classify(err) == .serverUnreachable)
    }

    @Test func urlErrorTimedOutMapsToServerUnreachable() {
        let err = URLError(.timedOut)
        #expect(FPError.classify(err) == .serverUnreachable)
    }

    @Test func urlErrorCannotFindHostMapsToServerUnreachable() {
        let err = URLError(.cannotFindHost)
        #expect(FPError.classify(err) == .serverUnreachable)
    }

    @Test func urlErrorCannotConnectToHostMapsToServerUnreachable() {
        let err = URLError(.cannotConnectToHost)
        #expect(FPError.classify(err) == .serverUnreachable)
    }

    @Test func urlErrorDnsLookupFailedMapsToServerUnreachable() {
        let err = URLError(.dnsLookupFailed)
        #expect(FPError.classify(err) == .serverUnreachable)
    }

    @Test func urlErrorOtherMapsToCannotSynchronize() {
        let err = URLError(.badURL)
        #expect(FPError.classify(err) == .cannotSynchronize)
    }

    // MARK: - HTTPClientError

    @Test func httpUnauthorizedMapsToNotAuthenticated() {
        #expect(FPError.classify(HTTPClientError.unauthorized) == .notAuthenticated)
    }

    @Test func httpForbiddenMapsToCannotSynchronize() {
        // HTTP 403: authenticated-but-not-authorised — must not trigger markNeedsSignIn.
        #expect(FPError.classify(HTTPClientError.forbidden) == .cannotSynchronize)
    }

    @Test func httpNotFoundMapsToNoSuchItem() {
        #expect(FPError.classify(HTTPClientError.notFound) == .noSuchItem)
    }

    @Test func httpGoneMapsToNoSuchItem() {
        #expect(FPError.classify(HTTPClientError.gone) == .noSuchItem)
    }

    @Test func httpThrottledMapsToServerBusy() {
        #expect(FPError.classify(HTTPClientError.throttled) == .serverBusy)
    }

    @Test func httpTransportMapsToServerUnreachable() {
        #expect(FPError.classify(HTTPClientError.transport(URLError(.timedOut))) == .serverUnreachable)
    }

    @Test func httpRetriesExhaustedMapsToServerUnreachable() {
        #expect(FPError.classify(HTTPClientError.retriesExhausted(attempts: 3, last: URLError(.timedOut))) == .serverUnreachable)
    }

    // MARK: - OneLakeError

    @Test func oneLakeUnauthorizedMapsToNotAuthenticated() {
        #expect(FPError.classify(OneLakeError.unauthorized) == .notAuthenticated)
    }

    @Test func oneLakeForbiddenMapsToCannotSynchronize() {
        // HTTP 403: authenticated-but-not-authorised — must not trigger markNeedsSignIn.
        #expect(FPError.classify(OneLakeError.forbidden) == .cannotSynchronize)
    }

    @Test func oneLakeNotFoundMapsToNoSuchItem() {
        #expect(FPError.classify(OneLakeError.notFound) == .noSuchItem)
    }

    @Test func oneLakeRetriesExhaustedMapsToServerUnreachable() {
        #expect(FPError.classify(OneLakeError.retriesExhausted(attempts: 3)) == .serverUnreachable)
    }

    // MARK: - FabricError

    @Test func fabricUnauthorizedMapsToNotAuthenticated() {
        #expect(FPError.classify(FabricError.unauthorized) == .notAuthenticated)
    }

    @Test func fabricForbiddenMapsToCannotSynchronize() {
        // HTTP 403: authenticated-but-not-authorised — must not trigger markNeedsSignIn.
        #expect(FPError.classify(FabricError.forbidden) == .cannotSynchronize)
    }

    @Test func fabricNotFoundMapsToNoSuchItem() {
        #expect(FPError.classify(FabricError.notFound) == .noSuchItem)
    }

    // MARK: - fp-07: previously default: → explicit cases

    /// HTTPClientError — newly explicit
    @Test func httpTokenAcquisitionFailedMapsToNotAuthenticated() {
        #expect(FPError.classify(HTTPClientError.tokenAcquisitionFailed(URLError(.badURL))) == .notAuthenticated)
    }

    @Test func httpCancelledMapsToServerUnreachable() {
        #expect(FPError.classify(HTTPClientError.cancelled) == .serverUnreachable)
    }

    /// OneLakeError — newly explicit
    @Test func oneLakeGoneMapsToNoSuchItem() {
        #expect(FPError.classify(OneLakeError.gone) == .noSuchItem)
    }

    @Test func oneLakeRateLimitedMapsToServerBusy() {
        #expect(FPError.classify(OneLakeError.rateLimited) == .serverBusy)
    }

    @Test func oneLakeCancelledMapsToServerUnreachable() {
        #expect(FPError.classify(OneLakeError.cancelled) == .serverUnreachable)
    }

    /// FabricError — newly explicit
    @Test func fabricGoneMapsToNoSuchItem() {
        #expect(FPError.classify(FabricError.gone) == .noSuchItem)
    }

    @Test func fabricRateLimitedMapsToServerBusy() {
        #expect(FPError.classify(FabricError.rateLimited) == .serverBusy)
    }

    @Test func fabricCancelledMapsToServerUnreachable() {
        #expect(FPError.classify(FabricError.cancelled) == .serverUnreachable)
    }

    @Test func fabricRetriesExhaustedMapsToServerUnreachable() {
        #expect(FPError.classify(FabricError.retriesExhausted(attempts: 2)) == .serverUnreachable)
    }

    // MARK: - 401 / tokenAcquisitionFailed guard: must still map to notAuthenticated

    @Test func httpUnauthorizedStillMapsToNotAuthenticated() {
        // Regression guard: 401 must always produce notAuthenticated, regardless of the
        // 403-reclassification in this change.
        #expect(FPError.classify(HTTPClientError.unauthorized) == .notAuthenticated)
    }

    @Test func tokenAcquisitionFailedStillMapsToNotAuthenticated() {
        // Regression guard: a token-acquisition failure is an auth problem.
        #expect(FPError.classify(HTTPClientError.tokenAcquisitionFailed(URLError(.badURL))) == .notAuthenticated)
    }

    @Test func oneLakeUnauthorizedStillMapsToNotAuthenticated() {
        #expect(FPError.classify(OneLakeError.unauthorized) == .notAuthenticated)
    }

    @Test func fabricUnauthorizedStillMapsToNotAuthenticated() {
        #expect(FPError.classify(FabricError.unauthorized) == .notAuthenticated)
    }

    // MARK: - sentinelWithBody: non-paused 403 must not trigger markNeedsSignIn

    @Test("HTTPClientError.sentinelWithBody(.forbidden) maps to cannotSynchronize")
    func httpSentinelWithBodyForbiddenMapsToCannotSynchronize() {
        let ae = APIError(
            statusCode: 403,
            status: "403 Forbidden",
            body: Data(#"{"errorCode":"InsufficientPrivileges"}"#.utf8)
        )
        let err = HTTPClientError.sentinelWithBody(.forbidden, ae)
        // A non-paused 403 body: PauseManager will not intercept this (InsufficientPrivileges
        // is not in pausedErrorCodes), so FPError.classify must return cannotSynchronize —
        // never notAuthenticated, which would call markNeedsSignIn.
        #expect(FPError.classify(err) == .cannotSynchronize)
    }

    @Test("OneLakeError.httpError(.sentinelWithBody(.forbidden)) maps to cannotSynchronize")
    func oneLakeHttpErrorSentinelWithBodyForbiddenMapsToCannotSynchronize() {
        let ae = APIError(
            statusCode: 403,
            status: "403 Forbidden",
            body: Data(#"{"errorCode":"InsufficientPrivileges"}"#.utf8)
        )
        let err = OneLakeError.httpError(HTTPClientError.sentinelWithBody(.forbidden, ae))
        #expect(FPError.classify(err) == .cannotSynchronize)
    }

    // MARK: - Unknown error falls back to cannotSynchronize

    @Test func unknownErrorMapsToCannotSynchronize() {
        let err = NSError(domain: "com.example.custom", code: 42)
        #expect(FPError.classify(err) == .cannotSynchronize)
    }

    // tests-12: moved here from SyncEngineTests (OneLakeError.httpError wrapping
    // HTTPClientError.throttled must map to .serverBusy, not .cannotSynchronize).
    @Test("OneLakeError.httpError(.throttled) maps to serverBusy")
    func oneLakeThrottledMapsToServerBusy() {
        let wrapped = OneLakeError.httpError(HTTPClientError.throttled)
        #expect(FPError.classify(wrapped) == .serverBusy)
    }
}
