// XPCVersionHandshakeTests.swift
// Unit tests for the xpc-06 host-side version handshake in OfemFPEClient.
//
// Tests use an ObjC-compatible fake proxy injected directly into
// checkProtocolVersion(proxy:domainIdentifier:) so no real XPC connection
// or NSFileProviderManager is needed.
//
// Cases covered:
//   1. Matching version  → returns the version, no error surfaced
//   2. Mismatched version → returns FPE version, error surfaced in model

import XCTest
import Foundation
import Combine

// MARK: - Mock proxies

// `OfemClientControlProtocol` is @objc so conforming types must be ObjC-compatible.

/// Fake proxy that implements getProtocolVersion and returns a configurable value.
@objc private final class FakeVersionedProxy: NSObject, OfemClientControlProtocol {
    let reportedVersion: Int
    init(version: Int) { self.reportedVersion = version }

    func getProtocolVersion(reply: @escaping (Int) -> Void) {
        reply(reportedVersion)
    }

    // Required protocol stubs — not exercised by version tests.
    func getEngineStatus(reply: @escaping (XPCEngineStatus?, Error?) -> Void) {
        reply(nil, NSError(domain: "test", code: 0))
    }
    func setConfig(key: String, value: String, reply: @escaping (Error?) -> Void) {
        reply(nil)
    }
    func clearCache(reply: @escaping (Int64, Error?) -> Void) {
        reply(0, nil)
    }
}

// MARK: - Tests

@MainActor
final class XPCVersionHandshakeTests: XCTestCase {

    private var client: OfemFPEClient!
    private var model: MenuStatusModel!
    private var cancellables = Set<AnyCancellable>()

    @MainActor override func setUp() {
        super.setUp()
        client = OfemFPEClient()
        // Create a fresh model with no real dependencies — version mismatch
        // is surfaced via MenuStatusModel.shared, but we can observe the
        // singleton's lastActionError because setUp runs before each test.
        model = MenuStatusModel.shared
        // Reset any residual error from prior tests.
        model.clearLastActionError()
    }

    @MainActor override func tearDown() {
        cancellables.removeAll()
        super.tearDown()
    }

    // MARK: - Matching version

    func testMatchingVersion_returnsVersion_noErrorSurfaced() async {
        let proxy = FakeVersionedProxy(version: ofemControlProtocolVersion)

        let version = await client.checkProtocolVersion(
            proxy: proxy,
            domainIdentifier: "test-domain"
        )

        XCTAssertEqual(version, ofemControlProtocolVersion,
                       "Reported version should equal host version")
        XCTAssertNil(model.lastActionError,
                     "No error should be surfaced when versions match")
    }

    // MARK: - Mismatched version

    func testMismatchedVersion_returnsReportedVersion_surfacesError() async {
        let fpeVersion = ofemControlProtocolVersion + 1
        let proxy = FakeVersionedProxy(version: fpeVersion)

        let exp = expectation(description: "lastActionError set")
        model.$lastActionError.dropFirst().sink { error in
            if error != nil { exp.fulfill() }
        }.store(in: &cancellables)

        let returned = await client.checkProtocolVersion(
            proxy: proxy,
            domainIdentifier: "test-domain"
        )
        await fulfillment(of: [exp], timeout: 2)

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
