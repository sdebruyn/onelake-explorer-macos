// SyncAnchorTests.swift
// Tests for sync-anchor encode/decode round-trips and edge cases.

import FileProvider
import Foundation
import XCTest

final class SyncAnchorTests: XCTestCase {

    // MARK: - Round-trip

    func testRoundTripZero() {
        let ns: Int64 = 0
        XCTAssertEqual(decodeSyncAnchor(encodeSyncAnchor(ns)), ns)
    }

    func testRoundTripPositive() {
        let ns: Int64 = 1_700_000_000_000_000_000
        XCTAssertEqual(decodeSyncAnchor(encodeSyncAnchor(ns)), ns)
    }

    func testRoundTripMaxInt64() {
        let ns = Int64.max
        XCTAssertEqual(decodeSyncAnchor(encodeSyncAnchor(ns)), ns)
    }

    func testRoundTripNegative() {
        // Negative timestamps are unusual but the codec must be lossless.
        let ns: Int64 = -1
        XCTAssertEqual(decodeSyncAnchor(encodeSyncAnchor(ns)), ns)
    }

    // MARK: - Encode produces 8 bytes (big-endian)

    func testEncodedLength() {
        let anchor = encodeSyncAnchor(42)
        XCTAssertEqual(anchor.rawValue.count, 8)
    }

    func testEncodedBigEndian() {
        // 1 as Int64 big-endian = 0x00 00 00 00 00 00 00 01
        let anchor = encodeSyncAnchor(1)
        let bytes = [UInt8](anchor.rawValue)
        XCTAssertEqual(bytes, [0, 0, 0, 0, 0, 0, 0, 1])
    }

    // MARK: - Malformed anchor returns 0

    func testEmptyAnchorReturnsZero() {
        let anchor = NSFileProviderSyncAnchor(Data())
        XCTAssertEqual(decodeSyncAnchor(anchor), 0)
    }

    func testShortAnchorReturnsZero() {
        let anchor = NSFileProviderSyncAnchor(Data([0, 1, 2]))
        XCTAssertEqual(decodeSyncAnchor(anchor), 0)
    }

    func testLongAnchorReturnsZero() {
        let anchor = NSFileProviderSyncAnchor(Data(repeating: 0xFF, count: 16))
        XCTAssertEqual(decodeSyncAnchor(anchor), 0)
    }
}
