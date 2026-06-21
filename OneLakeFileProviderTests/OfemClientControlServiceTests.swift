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
