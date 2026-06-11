// MenuStatusModelTests.swift
// Unit tests for MenuStatusModel's pure logic:
//   - menuIconState priority (not-running > paused > normal)
//   - headerLabel formatting
//   - write-fence multiset (beginWrite/endWrite/isFenced)
//
// These tests compile the host-app source directly into the test bundle
// (no host app process, no XPC) and use the @MainActor-isolated model
// by wrapping every test in MainActor.run.

import XCTest

final class MenuStatusModelTests: XCTestCase {

    // MARK: - menuIconState / headerLabel (default state — no accounts)

    func testMenuIconState_noAccounts_notRunning() async {
        await MainActor.run {
            let model = MenuStatusModel()
            XCTAssertEqual(model.menuIconState, .notRunning)
        }
    }

    func testHeaderLabel_noAccounts() async {
        await MainActor.run {
            let model = MenuStatusModel()
            XCTAssertEqual(model.headerLabel, "○ Not running")
        }
    }

    func testHasAccounts_falseByDefault() async {
        await MainActor.run {
            let model = MenuStatusModel()
            XCTAssertFalse(model.hasAccounts)
        }
    }

    // MARK: - Write fence — single write lifecycle

    func testWriteFence_singleWrite_liftsAfterEnd() async {
        await MainActor.run {
            let model = MenuStatusModel()
            XCTAssertFalse(model.isFenced(.cacheMaxSize), "No fence before beginWrite")
            model.beginWrite(.cacheMaxSize)
            XCTAssertTrue(model.isFenced(.cacheMaxSize), "Fence raised after beginWrite")
            model.endWrite(.cacheMaxSize)
            XCTAssertFalse(model.isFenced(.cacheMaxSize), "Fence lifted after endWrite")
        }
    }

    // MARK: - Write fence — overlapping writes to the same key

    func testWriteFence_overlappingWrites_onlyLiftsOnLast() async {
        await MainActor.run {
            let model = MenuStatusModel()
            model.beginWrite(.telemetry)
            model.beginWrite(.telemetry)    // two concurrent writers
            model.endWrite(.telemetry)      // first completes
            XCTAssertTrue(model.isFenced(.telemetry),
                          "Fence must remain while the second write is still in flight")
            model.endWrite(.telemetry)      // second completes
            XCTAssertFalse(model.isFenced(.telemetry),
                           "Fence must lift when the last write completes")
        }
    }

    func testWriteFence_tripleOverlap() async {
        await MainActor.run {
            let model = MenuStatusModel()
            model.beginWrite(.netMaxUploads)
            model.beginWrite(.netMaxUploads)
            model.beginWrite(.netMaxUploads)
            model.endWrite(.netMaxUploads)
            model.endWrite(.netMaxUploads)
            XCTAssertTrue(model.isFenced(.netMaxUploads))
            model.endWrite(.netMaxUploads)
            XCTAssertFalse(model.isFenced(.netMaxUploads))
        }
    }

    // MARK: - Write fence — different keys are independent

    func testWriteFence_differentKeys_areIndependent() async {
        await MainActor.run {
            let model = MenuStatusModel()
            model.beginWrite(.cacheMaxSize)
            model.beginWrite(.logLevel)
            model.endWrite(.cacheMaxSize)
            XCTAssertFalse(model.isFenced(.cacheMaxSize),
                           "cacheMaxSize fence should be gone")
            XCTAssertTrue(model.isFenced(.logLevel),
                          "logLevel fence should still be active")
            model.endWrite(.logLevel)
            XCTAssertFalse(model.isFenced(.logLevel))
        }
    }

    // MARK: - Write fence — endWrite on unfenced key is safe

    func testWriteFence_endWithoutBegin_doesNotCrash() async {
        await MainActor.run {
            let model = MenuStatusModel()
            // Should not crash (gracefully handles under-counted endWrite).
            model.endWrite(.netMaxDownloads)
            XCTAssertFalse(model.isFenced(.netMaxDownloads))
        }
    }
}
