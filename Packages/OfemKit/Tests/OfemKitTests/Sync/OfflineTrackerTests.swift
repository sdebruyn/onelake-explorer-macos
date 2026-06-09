import Testing
import Foundation
@testable import OfemKit

// MARK: - OfflineTracker tests

/// Tests for ``OfflineTracker`` — online/offline state transitions.
struct OfflineTrackerTests {

    // MARK: - Initial state

    @Test func startsOnline() async {
        let tracker = OfflineTracker()
        #expect(await tracker.isOffline == false)
    }

    // MARK: - markOffline / markOnline

    @Test func markOfflineMakesOffline() async {
        let tracker = OfflineTracker()
        await tracker.markOffline()
        #expect(await tracker.isOffline == true)
    }

    @Test func markOnlineAfterOfflineMakesOnline() async {
        let tracker = OfflineTracker()
        await tracker.markOffline()
        await tracker.markOnline()
        #expect(await tracker.isOffline == false)
    }

    // MARK: - observe(_:)

    @Test func observeNilClearsOffline() async {
        let tracker = OfflineTracker()
        await tracker.markOffline()
        await tracker.observe(nil)
        #expect(await tracker.isOffline == false)
    }

    @Test func observeURLErrorNoConnection() async {
        let tracker = OfflineTracker()
        let err = URLError(.notConnectedToInternet)
        await tracker.observe(err)
        #expect(await tracker.isOffline == true)
    }

    @Test func observeURLErrorTimedOutIsNotOffline() async {
        let tracker = OfflineTracker(cooldown: .seconds(60))
        let err = URLError(.timedOut)
        await tracker.observe(err)
        // Timeout is NOT treated as offline (could be server-side).
        #expect(await tracker.isOffline == false)
    }

    @Test func observeRandomErrorIsNotOffline() async {
        let tracker = OfflineTracker()
        let err = NSError(domain: "test", code: 99)
        await tracker.observe(err)
        #expect(await tracker.isOffline == false)
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
}
