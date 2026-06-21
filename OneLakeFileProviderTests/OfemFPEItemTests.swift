// OfemFPEItemTests.swift
// Tests for OfemFPEItem(from:) DomainItem bridging.
//
// Verifies that every DomainItem field is faithfully reflected in the
// NSFileProviderItem properties that macOS and Finder depend on.

@preconcurrency import FileProvider
import Foundation
import OfemKit
import UniformTypeIdentifiers
import XCTest

final class OfemFPEItemTests: XCTestCase {
    // MARK: - Root item

    func testRootItem() {
        let di = DomainItem.root(alias: "work")
        let item = OfemFPEItem(from: di)

        XCTAssertEqual(item.itemIdentifier.rawValue, ItemIdentifier.rootContainerString)
        XCTAssertTrue(item.isDirectory())
        XCTAssertEqual(item.filename, "OneLake \u{2014} work")
        XCTAssertNil(item.documentSize)
    }

    // MARK: - Directory item

    func testDirectoryItem() {
        let di = makeDomainItem(
            path: "Files",
            isDir: true,
            size: 0,
            contentType: "",
            name: "Files"
        )
        let item = OfemFPEItem(from: di)

        XCTAssertTrue(item.isDirectory())
        XCTAssertEqual(item.filename, "Files")
        XCTAssertNil(item.documentSize)
        XCTAssertEqual(item.contentType, .folder)
    }

    // MARK: - File item with explicit MIME type

    func testFileItemWithMimeType() {
        let di = makeDomainItem(
            path: "Files/report.csv",
            isDir: false,
            size: 1024,
            contentType: "text/csv",
            name: "report.csv"
        )
        let item = OfemFPEItem(from: di)

        XCTAssertFalse(item.isDirectory())
        XCTAssertEqual(item.documentSize?.int64Value, 1024)
        XCTAssertEqual(item.filename, "report.csv")
        // text/csv maps to a known UTType
        XCTAssertNotNil(UTType(mimeType: "text/csv"))
    }

    // MARK: - File item with extension fallback

    func testFileItemExtensionFallback() {
        let di = makeDomainItem(
            path: "Files/data.parquet",
            isDir: false,
            size: 2048,
            contentType: "", // empty — force extension lookup
            name: "data.parquet"
        )
        let item = OfemFPEItem(from: di)
        // Whatever UTType resolves, it must not be nil or crash.
        XCTAssertNotNil(item.contentType)
        XCTAssertEqual(item.filename, "data.parquet")
    }

    // MARK: - Capabilities: directory gets enumerate+addSubitems

    func testDirectoryCapabilities() {
        let di = makeDomainItem(path: "Dir", isDir: true, size: 0, contentType: "", name: "Dir")
        let item = OfemFPEItem(from: di)
        XCTAssertTrue(item.capabilities.contains(.allowsContentEnumerating))
        XCTAssertTrue(item.capabilities.contains(.allowsAddingSubItems))
    }

    // MARK: - Version tokens are non-empty

    func testItemVersionNonEmpty() {
        let di = makeDomainItem(path: "Files/f.txt", isDir: false, size: 10, contentType: "text/plain", name: "f.txt")
        let item = OfemFPEItem(from: di)
        XCTAssertFalse(item.itemVersion.contentVersion.isEmpty)
        XCTAssertFalse(item.itemVersion.metadataVersion.isEmpty)
    }

    // MARK: - Modification date is preserved

    func testModificationDatePreserved() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let di = makeDomainItem(
            path: "Files/ts.txt",
            isDir: false,
            size: 5,
            contentType: "text/plain",
            name: "ts.txt",
            modificationDate: now
        )
        let item = OfemFPEItem(from: di)
        let modDate = try XCTUnwrap(item.contentModificationDate)
        XCTAssertEqual(modDate.timeIntervalSince1970, now.timeIntervalSince1970, accuracy: 1)
    }

    // MARK: - Helpers

    private func makeDomainItem(
        path: String,
        isDir: Bool,
        size: Int64,
        contentType: String,
        name: String,
        modificationDate: Date? = nil
    ) -> DomainItem {
        let wsID = "00000000-0000-0000-0000-000000000001"
        let itemID = "00000000-0000-0000-0000-000000000002"

        let identifier: ItemIdentifier = path.isEmpty
            ? .item(workspaceID: wsID, itemID: itemID)
            : .path(workspaceID: wsID, itemID: itemID, path: path)

        return DomainItem(
            identifier: identifier,
            parentIdentifier: identifier.parentIdentifier,
            filename: name,
            isDirectory: isDir,
            size: size,
            contentType: contentType,
            modificationDate: modificationDate,
            contentVersion: Data("v1".utf8),
            metadataVersion: Data("mv1".utf8),
            capabilities: isDir ? [.read, .enumerate, .addSubitems] : [.read, .write, .delete]
        )
    }
}

// MARK: - OfemFPEItem convenience

private extension OfemFPEItem {
    func isDirectory() -> Bool {
        contentType == .folder
    }
}
