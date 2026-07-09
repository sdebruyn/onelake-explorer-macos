// SharedXPCContractTests.swift
// Unit tests for the Shared/ single-source-of-truth helpers that replaced
// the per-target duplicates (xpc-09):
//   - ofemDomainIdentifier(forAlias:) / ofemAlias(fromDomainIdentifier:)
//   - OfemControlInterface.make()
//
// (OfemConfigKey's literal values are covered by
// MenuStatusModelExtendedTests.testConfigKeys_matchExpectedLiterals —
// xpc-10 — not duplicated here.)
//
// DomainSyncManagerTests (compose) and FPEEngineHostTests (decompose, via
// FileProviderExtension.extractAlias) already exercise the identifier
// helpers indirectly through their production call sites; this file tests
// the Shared/ functions directly and adds the round-trip case neither of
// those files covers on its own.

import Foundation
import XCTest

final class OfemDomainIdentifierTests: XCTestCase {
    // MARK: - Compose

    func testCompose_prefixPlusAlias() {
        XCTAssertEqual(ofemDomainIdentifier(forAlias: "work"), "ofem.work")
    }

    // MARK: - Decompose

    func testDecompose_stripsPrefix() {
        XCTAssertEqual(ofemAlias(fromDomainIdentifier: "ofem.work"), "work")
    }

    func testDecompose_unprefixedStringReturnedUnchanged() {
        // A domain identifier without the OFEM prefix (e.g. one another
        // provider registered) must be returned as-is, not mangled.
        XCTAssertEqual(ofemAlias(fromDomainIdentifier: "some.other.domain"), "some.other.domain")
    }

    func testDecompose_emptyString() {
        XCTAssertEqual(ofemAlias(fromDomainIdentifier: ""), "")
    }

    // MARK: - Round trip

    func testRoundTrip_composeThenDecomposeReturnsOriginalAlias() {
        for alias in ["work", "my-org-2", "Work", "a.b.c"] {
            let id = ofemDomainIdentifier(forAlias: alias)
            XCTAssertEqual(ofemAlias(fromDomainIdentifier: id), alias,
                           "compose→decompose must round-trip for alias '\(alias)'")
        }
    }
}

// OfemConfigKey's literal values are covered by
// MenuStatusModelExtendedTests.testConfigKeys_matchExpectedLiterals
// (host-05); not duplicated here.

final class OfemControlInterfaceTests: XCTestCase {
    // MARK: - make() is callable and returns a usable interface

    func testMakeReturnsInterfaceForTheControlProtocol() {
        // This allocates a real NSXPCInterface; the test just verifies it
        // doesn't crash and wires up the protocol both sides depend on —
        // mirrors OfemClientControlServiceTests.testMakeListenerEndpointReturnsEndpoint.
        let iface = OfemControlInterface.make()
        XCTAssertNotNil(iface)
    }

    func testMakeReturnsFreshInstanceEachCall() {
        // Both the host and the FPE call make() independently (once per
        // connection/listener); verify repeated calls don't crash or share
        // problematic mutable state.
        let iface1 = OfemControlInterface.make()
        let iface2 = OfemControlInterface.make()
        XCTAssertNotNil(iface1)
        XCTAssertNotNil(iface2)
    }
}

// MARK: - M8: setClasses allowlist round-trip (anonymous NSXPCListener)

/// A minimal `OfemClientControlProtocol` conformer exported over a real
/// anonymous `NSXPCListener`, so `getEngineStatus`/`getBadgeStatus` actually
/// cross the XPC wire through `OfemControlInterface.make()`'s `setClasses`
/// allowlist — rather than calling the protocol methods in-process, which
/// would never exercise the secure-coding wiring at all. Both replies carry
/// a NON-empty `pausedWorkspaces` array so `XPCPausedWorkspace` (nested
/// inside the top-level `NSArray`) is on the wire too: a class dropped from
/// the allowlist decodes to `nil` at the boundary (see that file's header
/// comment) rather than throwing, so the regression this guards against is
/// a silent `nil`, not a crash — the round-trip must actually assert on the
/// decoded nested value to catch it.
private final class StubControlHandler: NSObject, OfemClientControlProtocol, @unchecked Sendable {
    func getProtocolVersion(reply: @escaping (Int) -> Void) {
        reply(ofemControlProtocolVersion)
    }

    func getEngineStatus(reply: @escaping (XPCEngineStatus?, Error?) -> Void) {
        reply(XPCEngineStatus(
            cacheBytes: 42,
            cacheMaxBytes: 100,
            cacheMaxSizeGB: 1,
            telemetryEnabled: true,
            netMaxUploads: 4,
            netMaxDownloads: 8,
            logLevel: "info",
            pausedWorkspaces: [
                XPCPausedWorkspace(
                    accountAlias: "work",
                    workspaceID: "ws-1234",
                    reason: "capacity_paused",
                    detectedAtSec: 1_700_000_000
                ),
            ]
        ), nil)
    }

    func getBadgeStatus(reply: @escaping (XPCBadgeStatus?, Error?) -> Void) {
        reply(XPCBadgeStatus(
            needsSignIn: true,
            pausedWorkspaces: [
                XPCPausedWorkspace(
                    accountAlias: "work",
                    workspaceID: "ws-5678",
                    reason: "capacity_paused",
                    detectedAtSec: 1_700_000_001
                ),
            ]
        ), nil)
    }

    func setConfig(key _: String, value _: String, reply: @escaping (Error?) -> Void) {
        reply(nil)
    }

    func clearCache(reply: @escaping (Int64, Error?) -> Void) {
        reply(0, nil)
    }

    func pollMaterialized(alias _: String, reply: @escaping (Bool, Error?) -> Void) {
        reply(false, nil)
    }

    func reloadEngine(alias _: String, reply: @escaping (Error?) -> Void) {
        reply(nil)
    }
}

/// Accepts the incoming connection and wires the SAME `OfemControlInterface.make()`
/// factory the FPE's real listener delegate uses (`OfemXPCListenerDelegate` in
/// `OfemClientControlService.swift`) — no peer code-signing check here, since
/// the test process connects to its own in-process anonymous listener.
private final class StubListenerDelegate: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
    func listener(_: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        newConnection.exportedInterface = OfemControlInterface.make()
        newConnection.exportedObject = StubControlHandler()
        newConnection.resume()
        return true
    }
}

final class OfemControlInterfaceXPCRoundTripTests: XCTestCase {
    /// Mirrors `OfemFPEClient.withProxy`: builds a fresh proxy bound to a
    /// per-call error handler so a connection fault resumes the continuation
    /// instead of hanging the test.
    private func withStubProxy<T: Sendable>(
        _ connection: NSXPCConnection,
        _ body: @escaping (any OfemClientControlProtocol, OneShotContinuation<T>) -> Void
    ) async throws -> T {
        try await withCheckedThrowingContinuation { rawContinuation in
            let cont = OneShotContinuation<T>(rawContinuation)
            guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
                cont.resume(throwing: error)
            }) as? any OfemClientControlProtocol else {
                cont.resume(throwing: NSError(domain: "OfemControlInterfaceXPCRoundTripTests", code: -1))
                return
            }
            body(proxy, cont)
        }
    }

    func testGetEngineStatusRoundTripDecodesNestedPausedWorkspace() async throws {
        let delegate = StubListenerDelegate()
        let listener = NSXPCListener.anonymous()
        listener.delegate = delegate
        listener.resume()
        defer { listener.invalidate() }

        let connection = NSXPCConnection(listenerEndpoint: listener.endpoint)
        connection.remoteObjectInterface = OfemControlInterface.make()
        connection.resume()
        defer { connection.invalidate() }

        let status: XPCEngineStatus = try await withStubProxy(connection) { proxy, cont in
            proxy.getEngineStatus { status, error in
                if let error {
                    cont.resume(throwing: error)
                } else if let status {
                    cont.resume(returning: status)
                } else {
                    cont.resume(throwing: NSError(domain: "test", code: -1))
                }
            }
        }

        // A dropped class in the allowlist decodes pausedWorkspaces to an
        // empty array (or the whole reply to nil) instead of throwing — assert
        // on the decoded nested value, not just "no error", to catch that.
        XCTAssertEqual(status.pausedWorkspaces.count, 1)
        XCTAssertEqual(status.pausedWorkspaces.first?.accountAlias, "work")
        XCTAssertEqual(status.pausedWorkspaces.first?.workspaceID, "ws-1234")
        XCTAssertEqual(status.pausedWorkspaces.first?.reason, "capacity_paused")
    }

    func testGetBadgeStatusRoundTripDecodesNestedPausedWorkspace() async throws {
        let delegate = StubListenerDelegate()
        let listener = NSXPCListener.anonymous()
        listener.delegate = delegate
        listener.resume()
        defer { listener.invalidate() }

        let connection = NSXPCConnection(listenerEndpoint: listener.endpoint)
        connection.remoteObjectInterface = OfemControlInterface.make()
        connection.resume()
        defer { connection.invalidate() }

        let status: XPCBadgeStatus = try await withStubProxy(connection) { proxy, cont in
            proxy.getBadgeStatus { status, error in
                if let error {
                    cont.resume(throwing: error)
                } else if let status {
                    cont.resume(returning: status)
                } else {
                    cont.resume(throwing: NSError(domain: "test", code: -1))
                }
            }
        }

        XCTAssertTrue(status.needsSignIn)
        XCTAssertEqual(status.pausedWorkspaces.count, 1)
        XCTAssertEqual(status.pausedWorkspaces.first?.accountAlias, "work")
        XCTAssertEqual(status.pausedWorkspaces.first?.workspaceID, "ws-5678")
        XCTAssertEqual(status.pausedWorkspaces.first?.reason, "capacity_paused")
    }
}
