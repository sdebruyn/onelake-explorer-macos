// OfemClientControlServiceTests.swift
// Tests for OfemClientControlService XPC service-source.

@preconcurrency import FileProvider
import Foundation
import XCTest

final class OfemClientControlServiceTests: XCTestCase {
    // MARK: - serviceName is the expected constant

    func testServiceNameMatchesConstant() {
        let host = MockEngineHost(alias: "xpc-test")
        let svc = OfemClientControlService(engineHost: host)
        XCTAssertEqual(svc.serviceName.rawValue, ofemControlServiceName)
    }

    // MARK: - makeListenerEndpoint is callable and returns an endpoint

    func testMakeListenerEndpointReturnsEndpoint() throws {
        let host = MockEngineHost(alias: "xpc-test")
        let svc = OfemClientControlService(engineHost: host)
        // This allocates a real NSXPCListener; the test just verifies it doesn't crash.
        let ep = try svc.makeListenerEndpoint()
        XCTAssertNotNil(ep)
    }

    // MARK: - makeListenerEndpoint is idempotent (does not crash on repeated calls)

    func testMakeListenerEndpointIdempotent() throws {
        let host = MockEngineHost(alias: "xpc-test")
        let svc = OfemClientControlService(engineHost: host)
        // Calling makeListenerEndpoint twice must not crash or throw.
        // NSXPCListenerEndpoint has no value equality so we just verify both calls succeed.
        let ep1 = try svc.makeListenerEndpoint()
        let ep2 = try svc.makeListenerEndpoint()
        XCTAssertNotNil(ep1)
        XCTAssertNotNil(ep2)
    }

    // MARK: - XPC peer requirement constant is syntactically valid

    func testXPCPeerRequirementContainsBundleID() {
        XCTAssertTrue(ofemXPCPeerRequirement.contains("dev.debruyn.ofem"),
                      "XPC peer requirement must reference the host-app bundle ID")
    }

    func testXPCPeerRequirementContainsTeamID() {
        XCTAssertTrue(ofemXPCPeerRequirement.contains("6D79CUWZ4J"),
                      "XPC peer requirement must reference the Developer Team ID")
    }
}

// MARK: - getBadgeStatus (#397)

//
// OfemControlXPCHandler is internal (not private, unlike the other helpers
// in OfemClientControlService.swift) specifically so these tests can drive
// it directly against a MockEngineHost, without an actual XPC connection —
// mirroring the approach in XPCSecureCodingTests.swift for the wire types.

private enum ControlXPCHandlerTestError: Error { case configStoreBoom }

final class OfemControlXPCHandlerGetBadgeStatusTests: XCTestCase {
    func testGetBadgeStatus_needsSignInFalseByDefault() {
        let host = MockEngineHost(alias: "badge-test")
        let handler = OfemControlXPCHandler(engineHost: host)

        let exp = expectation(description: "getBadgeStatus replies")
        handler.getBadgeStatus { status, error in
            XCTAssertNil(error)
            XCTAssertEqual(status?.needsSignIn, false)
            XCTAssertEqual(status?.pausedWorkspaces.count, 0)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 2)
    }

    func testGetBadgeStatus_returnsNeedsSignInTrue_whenMarked() {
        let host = MockEngineHost(alias: "badge-test")
        host.markNeedsSignIn()
        let handler = OfemControlXPCHandler(engineHost: host)

        let exp = expectation(description: "getBadgeStatus replies")
        handler.getBadgeStatus { status, error in
            XCTAssertNil(error)
            XCTAssertEqual(status?.needsSignIn, true)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 2)
    }

    func testGetBadgeStatus_engineOptional_neverBuildsTheEngine() {
        // getBadgeStatus must succeed even when the engine has never been
        // built (mirrors getEngineStatus's existingEngine() branch), and
        // must never trigger a full engine() build to get there — the
        // whole point of this slim verb is to avoid the FPE's cache-usage
        // (blobBytes()) scan, which requires a live engine.
        let host = MockEngineHost(alias: "badge-test")
        let handler = OfemControlXPCHandler(engineHost: host)

        let exp = expectation(description: "getBadgeStatus replies")
        handler.getBadgeStatus { status, error in
            XCTAssertNil(error)
            XCTAssertNotNil(status)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 2)

        XCTAssertEqual(host.engineCallCount, 0,
                       "getBadgeStatus must never call engine() (no engine build, no cache scan)")
    }

    func testGetBadgeStatus_doesNotReadConfigStore() {
        // Unlike getEngineStatus, getBadgeStatus never reads a config
        // snapshot — a broken configStore() must not affect it at all.
        let host = MockEngineHost(alias: "badge-test")
        host.configStoreError = ControlXPCHandlerTestError.configStoreBoom
        let handler = OfemControlXPCHandler(engineHost: host)

        let exp = expectation(description: "getBadgeStatus replies")
        handler.getBadgeStatus { status, error in
            XCTAssertNil(error, "getBadgeStatus must not fail on a broken configStore — it never reads one")
            XCTAssertNotNil(status)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 2)
    }
}
