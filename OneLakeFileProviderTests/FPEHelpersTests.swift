// FPEHelpersTests.swift
// Tests for FPEHelpers: cacheKey construction and parentPath arithmetic.

import Foundation
import OfemKit
import XCTest

final class FPEHelpersTests: XCTestCase {
    // MARK: - cacheKey (components variant)

    func testCacheKeyRoundTrip() {
        let key = cacheKey(alias: "work", workspaceID: "ws1", itemID: "item1", path: "Files/data.csv")
        XCTAssertEqual(key.accountAlias, "work")
        XCTAssertEqual(key.workspaceID, "ws1")
        XCTAssertEqual(key.itemID, "item1")
        XCTAssertEqual(key.path, "Files/data.csv")
    }

    func testCacheKeyEmptyPathForItemRoot() {
        let key = cacheKey(alias: "work", workspaceID: "ws", itemID: "item", path: "")
        XCTAssertEqual(key.path, "")
    }

    // MARK: - cacheKey (identifier variant)

    func testCacheKeyFromItemIdentifier() throws {
        let id = ItemIdentifier.item(workspaceID: "ws", itemID: "item")
        let key = try cacheKey(alias: "work", identifier: id)
        XCTAssertEqual(key.path, "")
        XCTAssertEqual(key.workspaceID, "ws")
        XCTAssertEqual(key.itemID, "item")
    }

    func testCacheKeyFromPathIdentifier() throws {
        let id = ItemIdentifier.path(workspaceID: "ws", itemID: "item", path: "a/b/c")
        let key = try cacheKey(alias: "work", identifier: id)
        XCTAssertEqual(key.path, "a/b/c")
    }

    func testCacheKeyFromRootIdentifierThrows() {
        XCTAssertThrowsError(try cacheKey(alias: "work", identifier: .root))
    }

    func testCacheKeyFromWorkspaceIdentifierThrows() {
        XCTAssertThrowsError(try cacheKey(alias: "work", identifier: .workspace(workspaceID: "ws")))
    }

    // MARK: - parentPath

    func testParentPathDeepFile() {
        XCTAssertEqual(parentPath(of: "Files/raw/2024/sales.csv"), "Files/raw/2024")
    }

    func testParentPathTopLevelFile() {
        XCTAssertEqual(parentPath(of: "Files"), "")
    }

    func testParentPathEmpty() {
        XCTAssertEqual(parentPath(of: ""), "")
    }

    func testParentPathSingleSlash() {
        XCTAssertEqual(parentPath(of: "a/b"), "a")
    }

    func testParentPathMultipleSegments() {
        XCTAssertEqual(parentPath(of: "a/b/c/d"), "a/b/c")
    }
}
