// OfemClientControlServiceTests.swift
// Tests for OfemClientControlService XPC service-source.

@preconcurrency import FileProvider
import Foundation
import OfemKit
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

        // configStoreError alone doesn't prove configStore() was never called
        // (try? would silently swallow it too) — assert the call count directly
        // so a future regression that reads-and-discards the config store
        // can't slip past this test.
        XCTAssertEqual(host.configStoreCallCount, 0,
                       "getBadgeStatus must never call configStore(), not even under a try?")
    }

    // MARK: - getBadgeStatus with a warm engine (steady-state path)

    func testGetBadgeStatus_engineWarm_returnsPausedWorkspacesFromCache() async throws {
        // The tests above only exercise the engine-optional (cold) branch.
        // The actual steady-state scenario this verb optimizes is the WARM
        // branch: an engine already built, paused workspaces already
        // recorded in the cache — verify that path populates
        // pausedWorkspaces correctly and, being backed by a real CacheStore
        // (via a real OfemEngine) rather than the mock, never touches
        // configStore() here either.
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("ofem-badge-status-warm-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let paths = OfemPaths(root: tmp)
        try paths.ensureDirectories()
        let configStore = try OfemConfigStore(paths: paths)
        let engine = try OfemEngine(configStore: configStore, paths: paths)

        try await engine.cache.setWorkspaceStatus(WorkspaceStatusRecord(
            accountAlias: "work",
            workspaceID: "ws-1111",
            state: .paused,
            reason: "capacity_paused",
            detectedAtNs: 1_700_000_000_000_000_000
        ))

        let host = MockEngineHost(alias: "badge-test")
        host.engineResult = .success(engine)
        let handler = OfemControlXPCHandler(engineHost: host)

        let exp = expectation(description: "getBadgeStatus replies")
        handler.getBadgeStatus { status, error in
            XCTAssertNil(error)
            XCTAssertEqual(status?.pausedWorkspaces.count, 1)
            XCTAssertEqual(status?.pausedWorkspaces.first?.accountAlias, "work")
            XCTAssertEqual(status?.pausedWorkspaces.first?.workspaceID, "ws-1111")
            XCTAssertEqual(status?.pausedWorkspaces.first?.reason, "capacity_paused")
            exp.fulfill()
        }
        await fulfillment(of: [exp], timeout: 5)

        XCTAssertEqual(host.configStoreCallCount, 0,
                       "getBadgeStatus must never call configStore(), warm engine or not")

        await engine.shutdown()
    }
}
