// XPCVersionHandshakeTests.swift
// Unit tests for the xpc-06 host-side version handshake in OfemFPEClient.
//
// Tests call checkProtocolVersion(reportedVersion:domainIdentifier:) directly
// with a plain Int — no fake XPC proxy, no continuation, no real XPC
// connection or NSFileProviderManager needed. This seam replaced an earlier
// proxy-based one that wrapped a non-throwing continuation with no fault
// path; removing the continuation entirely (rather than merely restricting
// who can call it) closes off the xpc-12 hang shape by construction, since a
// synchronous function cannot hang awaiting a reply that never comes.
//
// Cases covered:
//   1. Matching version  → returns the version, no error surfaced
//   2. Mismatched version → returns FPE version, error surfaced in model

import XCTest

@MainActor
final class XPCVersionHandshakeTests: XCTestCase, @unchecked Sendable {
    private var client: OfemFPEClient!
    private var model: MenuStatusModel!

    /// setUp and tearDown override nonisolated XCTestCase methods, so they
    /// cannot be marked @MainActor. XCTest always runs them on the main thread;
    /// MainActor.assumeIsolated asserts this invariant and satisfies Swift 6.
    override func setUp() {
        super.setUp()
        MainActor.assumeIsolated {
            client = OfemFPEClient()
            // Create a fresh model with no real dependencies — version mismatch
            // is surfaced via MenuStatusModel.shared, but we can observe the
            // singleton's lastActionError because setUp runs before each test.
            model = MenuStatusModel.shared
            // Reset any residual error from prior tests.
            model.clearLastActionError()
        }
    }

    // MARK: - Matching version

    func testMatchingVersion_returnsVersion_noErrorSurfaced() {
        let version = client.checkProtocolVersion(
            reportedVersion: ofemControlProtocolVersion,
            domainIdentifier: "test-domain"
        )

        XCTAssertEqual(version, ofemControlProtocolVersion,
                       "Reported version should equal host version")
        XCTAssertNil(model.lastActionError,
                     "No error should be surfaced when versions match")
    }

    // MARK: - Mismatched version

    func testMismatchedVersion_returnsReportedVersion_surfacesError() {
        let fpeVersion = ofemControlProtocolVersion + 1

        // No expectation/fulfillment needed: checkProtocolVersion is fully
        // synchronous now, so lastActionError is set before this call returns.
        let returned = client.checkProtocolVersion(
            reportedVersion: fpeVersion,
            domainIdentifier: "test-domain"
        )

        XCTAssertEqual(returned, fpeVersion,
                       "Should return the FPE-reported version even on mismatch")
        XCTAssertNotNil(model.lastActionError,
                        "Version mismatch must be surfaced to the user")
        if let errMsg = model.lastActionError {
            XCTAssertTrue(errMsg.contains("\(ofemControlProtocolVersion)"),
                          "Error should mention host version: \(errMsg)")
            XCTAssertTrue(errMsg.contains("\(fpeVersion)"),
                          "Error should mention FPE version: \(errMsg)")
        }
    }
}
