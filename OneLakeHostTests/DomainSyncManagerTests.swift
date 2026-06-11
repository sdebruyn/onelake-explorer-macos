// DomainSyncManagerTests.swift
// Unit tests for DomainSyncManager's identifier composition logic.
//
// We test only the pure identifier-building logic (domainIdentifier(for:))
// which is the shared helper that deduplicated the four previous copies of
// "\(identifierPrefix)\(alias)" across the class.

import XCTest

@MainActor
final class DomainSyncManagerTests: XCTestCase {

    // MARK: - Domain identifier composition

    func testDomainIdentifier_prefixPlusAlias() {
        let manager = DomainSyncManager()
        let id = manager.domainIdentifier(for: "work")
        XCTAssertEqual(id, "ofem.work")
    }

    func testDomainIdentifier_emptyAlias() {
        let manager = DomainSyncManager()
        let id = manager.domainIdentifier(for: "")
        XCTAssertEqual(id, "ofem.", "Empty alias should produce 'ofem.' (callers must validate)")
    }

    func testDomainIdentifier_hyphenatedAlias() {
        let manager = DomainSyncManager()
        let id = manager.domainIdentifier(for: "my-org-2")
        XCTAssertEqual(id, "ofem.my-org-2")
    }

    func testDomainIdentifier_preservesCase() {
        let manager = DomainSyncManager()
        // Alias case is preserved as-is (callers normalise before passing here).
        let id = manager.domainIdentifier(for: "Work")
        XCTAssertEqual(id, "ofem.Work")
    }

    func testIdentifierPrefix_matchesFPESideConstant() {
        // The FPE independently defines the same prefix constant.
        // This test catches drift between the two.
        let manager = DomainSyncManager()
        XCTAssertEqual(manager.identifierPrefix, "ofem.")
    }
}
