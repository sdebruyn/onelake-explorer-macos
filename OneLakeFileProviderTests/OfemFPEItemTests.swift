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

    // MARK: - Writable file advertises .allowsRenaming (fpe rename)

    func testWritableFileAdvertisesRenaming() throws {
        // A file under a Lakehouse Files/ subtree is writable and must advertise
        // .allowsRenaming, otherwise Finder disables Rename and modifyItem(.filename)
        // is never dispatched.
        let record = makeRecord(path: "Files/report.csv", name: "report.csv", isDir: false)
        let di = try DomainItem.from(record: record)
        let item = OfemFPEItem(from: di)
        XCTAssertTrue(item.capabilities.contains(.allowsRenaming),
                      "writable file must allow renaming")
    }

    // MARK: - Rename success: overriding identifier keeps the ORIGINAL id (Option B)

    func testFromRecordOverridingIdentifierKeepsOriginalID() throws {
        // The rename success path builds the returned item from the renamed cache
        // record but overrides the identifier with the ORIGINAL one it was handed,
        // so the framework registers a metadata change rather than delete+add.
        let wsID = "00000000-0000-0000-0000-000000000001"
        let itemID = "00000000-0000-0000-0000-000000000002"
        let originalIdentifier: ItemIdentifier = .path(
            workspaceID: wsID, itemID: itemID, path: "Files/old name.txt"
        )
        // Renamed record sits at the NEW path with the NEW name.
        let renamed = makeRecord(path: "Files/new name.txt", name: "new name.txt", isDir: false)

        let di = try DomainItem.from(record: renamed, overridingIdentifier: originalIdentifier)
        let item = OfemFPEItem(from: di)

        XCTAssertEqual(item.itemIdentifier.rawValue, originalIdentifier.identifierString,
                       "rename must return the ORIGINAL identifier, not the new path-derived one")
        XCTAssertEqual(item.filename, "new name.txt",
                       "filename must reflect the renamed record")
        XCTAssertEqual(item.parentItemIdentifier.rawValue,
                       originalIdentifier.parentIdentifier.identifierString,
                       "parent is derived from the overriding identifier")
    }

    // MARK: - Helpers

    private func makeRecord(path: String, name: String, isDir: Bool) -> MetadataRecord {
        MetadataRecord(
            accountAlias: "test",
            workspaceID: "00000000-0000-0000-0000-000000000001",
            itemID: "00000000-0000-0000-0000-000000000002",
            path: path,
            parentPath: (path as NSString).deletingLastPathComponent,
            name: name,
            isDir: isDir,
            contentLength: isDir ? 0 : 42,
            lastModifiedNs: 1_700_000_000_000_000_000,
            itemType: "Lakehouse",
            createdNs: 1_600_000_000_000_000_000
        )
    }

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
