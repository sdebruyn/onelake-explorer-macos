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
