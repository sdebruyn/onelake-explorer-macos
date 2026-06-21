import Foundation
@testable import OfemKit
import Testing

// MARK: - OfflineTracker tests

/// Tests for ``OfflineTracker`` — online/offline state transitions.
struct OfflineTrackerTests {
    // MARK: - Initial state

    @Test func startsOnline() async {
        let tracker = OfflineTracker()
        #expect(await tracker.currentlyOffline() == false)
    }

    // MARK: - markOffline / markOnline

    @Test func markOfflineMakesOffline() async {
        let tracker = OfflineTracker()
        await tracker.markOffline()
        #expect(await tracker.currentlyOffline() == true)
    }

    @Test func markOnlineAfterOfflineMakesOnline() async {
        let tracker = OfflineTracker()
        await tracker.markOffline()
        await tracker.markOnline()
        #expect(await tracker.currentlyOffline() == false)
    }

    // MARK: - observe(_:)

    @Test func observeNilClearsOffline() async {
        let tracker = OfflineTracker()
        await tracker.markOffline()
        await tracker.observe(nil)
        #expect(await tracker.currentlyOffline() == false)
    }

    @Test func observeURLErrorNoConnection() async {
        let tracker = OfflineTracker()
        let err = URLError(.notConnectedToInternet)
        await tracker.observe(err)
        #expect(await tracker.currentlyOffline() == true)
    }

    @Test func observeURLErrorTimedOutIsNotOffline() async {
        let tracker = OfflineTracker(cooldown: .seconds(60))
        let err = URLError(.timedOut)
        await tracker.observe(err)
        // Timeout is NOT treated as offline (could be server-side).
        #expect(await tracker.currentlyOffline() == false)
    }

    @Test func observeRandomErrorIsNotOffline() async {
        let tracker = OfflineTracker()
        let err = NSError(domain: "test", code: 99)
        await tracker.observe(err)
        #expect(await tracker.currentlyOffline() == false)
    }

    // MARK: - isOfflineError

    @Test func isOfflineErrorForNetworkErrors() {
        let cases: [URLError.Code] = [
            .notConnectedToInternet,
            .networkConnectionLost,
            .cannotConnectToHost,
            .dnsLookupFailed,
        ]
        for code in cases {
            let err = URLError(code)
            #expect(OfflineTracker.isOfflineError(err), "expected offline for \(code)")
        }
    }

    @Test func isOfflineErrorFalseForTimeout() {
        #expect(!OfflineTracker.isOfflineError(URLError(.timedOut)))
    }

    @Test func isOfflineErrorFalseForNSError() {
        let err = NSError(domain: "any", code: 0)
        #expect(!OfflineTracker.isOfflineError(err))
    }

    // MARK: - isOfflineError: realistic wrapped shapes (fix/offline-shortcircuit)

    //
    // The short-circuit path in HTTPClient throws
    //   HTTPClientError.transport(URLError(.notConnectedToInternet))
    // which OneLakeClient then wraps in OneLakeError.from(_:) as
    //   OneLakeError.httpError(HTTPClientError.transport(...))
    // OfflineTracker.underlyingURLError must unwrap those layers correctly.

    @Test("OneLakeError.httpError wrapping .transport(.notConnectedToInternet) → true")
    func oneLakeHttpErrorTransportNotConnected() {
        let transportErr = HTTPClientError.transport(URLError(.notConnectedToInternet))
        let wrapped = OneLakeError.httpError(transportErr)
        #expect(OfflineTracker.isOfflineError(wrapped))
    }

    @Test("FabricError.httpError wrapping .transport(.networkConnectionLost) → true")
    func fabricHttpErrorTransportConnectionLost() {
        let transportErr = HTTPClientError.transport(URLError(.networkConnectionLost))
        let wrapped = FabricError.httpError(transportErr)
        #expect(OfflineTracker.isOfflineError(wrapped))
    }

    @Test("HTTPClientError.retriesExhausted(last: URLError(.notConnectedToInternet)) → true (defensive)")
    func retriesExhaustedWrappingOfflineURLError() {
        let urlErr = URLError(.notConnectedToInternet)
        let exhausted = HTTPClientError.retriesExhausted(attempts: 6, last: urlErr)
        #expect(OfflineTracker.isOfflineError(exhausted))
    }

    @Test("A raw URLError(.notConnectedToInternet) → true (bare path still works)")
    func bareURLErrorNotConnected() {
        let err = URLError(.notConnectedToInternet)
        #expect(OfflineTracker.isOfflineError(err))
    }

    @Test("OneLakeError.httpError wrapping HTTPClientError.serverError(503) → false (paused capacity is not offline)")
    func oneLakeHttpErrorServerError503IsFalse() {
        let serverErr = HTTPClientError.serverError(503)
        let wrapped = OneLakeError.httpError(serverErr)
        #expect(!OfflineTracker.isOfflineError(wrapped))
    }

    @Test("OneLakeError.notFound → false (HTTP 404 is not offline)")
    func oneLakeNotFoundIsFalse() {
        #expect(!OfflineTracker.isOfflineError(OneLakeError.notFound))
    }

    @Test("OneLakeError.httpError wrapping .transport(.timedOut) → false (timeout is not offline)")
    func oneLakeHttpErrorTimedOutIsFalse() {
        let transportErr = HTTPClientError.transport(URLError(.timedOut))
        let wrapped = OneLakeError.httpError(transportErr)
        #expect(!OfflineTracker.isOfflineError(wrapped))
    }
}
