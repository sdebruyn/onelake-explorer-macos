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

    // MARK: - isMaterializablePathContainer — Delta-depth filter

    // Admitted: depth 1 (top-level virtual dirs)
    func testMaterializablePathTablesTopLevel() {
        XCTAssertTrue(isMaterializablePathContainer("Tables"))
    }

    func testMaterializablePathFilesTopLevel() {
        XCTAssertTrue(isMaterializablePathContainer("Files"))
    }

    // Admitted: depth 2 (schema or Files subdir)
    func testMaterializablePathTablesSchema() {
        XCTAssertTrue(isMaterializablePathContainer("Tables/dbo"))
    }

    func testMaterializablePathFilesSubdir() {
        XCTAssertTrue(isMaterializablePathContainer("Files/reports"))
    }

    // Admitted: depth 3 (the table folder itself — must stay pollable)
    func testMaterializablePathTableFolder() {
        XCTAssertTrue(isMaterializablePathContainer("Tables/dbo/events"))
    }

    // Excluded: _delta_log at depth 4
    func testMaterializablePathDeltaLogExcluded() {
        XCTAssertFalse(isMaterializablePathContainer("Tables/dbo/events/_delta_log"))
    }

    // Excluded: partition GUID dir at depth 4
    func testMaterializablePathPartitionDirExcluded() {
        XCTAssertFalse(isMaterializablePathContainer("Tables/dbo/events/part=2024-01"))
    }

    // Excluded: .parquet file at depth 4 (files are not containers either)
    func testMaterializablePathParquetFileExcluded() {
        XCTAssertFalse(isMaterializablePathContainer("Tables/dbo/events/00001.parquet"))
    }

    // Excluded: anything beneath _delta_log (depth 5)
    func testMaterializablePathDeltaLogContentsExcluded() {
        XCTAssertFalse(isMaterializablePathContainer("Tables/dbo/events/_delta_log/00000000000000000001.json"))
    }

    // Excluded: _delta_log at depth 5 — belt-and-suspenders for unusual layouts
    func testMaterializablePathDeltaLogDeepExcluded() {
        XCTAssertFalse(isMaterializablePathContainer("Files/raw/subdir/_delta_log"))
    }

    // Admitted: Files subdir at depth 3 (deep Files browsing must stay pollable)
    func testMaterializablePathFilesThreeLevels() {
        XCTAssertTrue(isMaterializablePathContainer("Files/reports/2024"))
    }
}
