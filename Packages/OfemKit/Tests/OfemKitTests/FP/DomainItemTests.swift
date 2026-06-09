import Testing
import Foundation
@testable import OfemKit

// MARK: - DomainItem factory tests

/// Tests for ``DomainItem`` factory methods — workspace mapping, item mapping,
/// and MetadataRecord → DomainItem conversion.
struct DomainItemTests {

    // MARK: - root(alias:)

    @Test func rootItemHasRootIdentifier() {
        let item = DomainItem.root(alias: "work")
        #expect(item.identifier == ItemIdentifier.root)
        #expect(item.parentIdentifier == ItemIdentifier.root)
    }

    @Test func rootItemContainsAlias() {
        let item = DomainItem.root(alias: "work")
        #expect(item.filename.contains("work"))
    }

    @Test func rootItemIsDirectory() {
        #expect(DomainItem.root(alias: "work").isDirectory)
    }

    @Test func rootItemHasEnumerateCapability() {
        #expect(DomainItem.root(alias: "work").capabilities.contains(.enumerate))
    }

    // MARK: - from(workspace:)

    @Test func workspaceMapsIdentifier() {
        let ws = Workspace(id: "ws-42", displayName: "My Workspace", type: "Workspace")
        let item = DomainItem.from(workspace: ws)
        #expect(item.identifier == ItemIdentifier.workspace(workspaceID: "ws-42"))
        #expect(item.parentIdentifier == ItemIdentifier.root)
    }

    @Test func workspaceDisplayNameBecomesFilename() {
        let ws = Workspace(id: "ws-1", displayName: "Prod Analytics", type: "Workspace")
        #expect(DomainItem.from(workspace: ws).filename == "Prod Analytics")
    }

    @Test func workspaceIsDirectory() {
        let ws = Workspace(id: "w", displayName: "W", type: "Workspace")
        #expect(DomainItem.from(workspace: ws).isDirectory)
    }

    // MARK: - from(fabricItem:workspaceID:)

    @Test func fabricItemMapsIdentifier() {
        let fabricItem = Item(id: "item-99", displayName: "Lakehouse", type: "Lakehouse", workspaceID: "ws-1")
        let item = DomainItem.from(fabricItem: fabricItem, workspaceID: "ws-1")
        #expect(item.identifier == ItemIdentifier.item(workspaceID: "ws-1", itemID: "item-99"))
        #expect(item.parentIdentifier == ItemIdentifier.workspace(workspaceID: "ws-1"))
    }

    @Test func fabricItemDisplayNameBecomesFilename() {
        let fabricItem = Item(id: "i", displayName: "My Lakehouse", type: "Lakehouse", workspaceID: "ws-1")
        #expect(DomainItem.from(fabricItem: fabricItem, workspaceID: "ws-1").filename == "My Lakehouse")
    }

    // MARK: - from(record:) — file

    @Test func recordFileMapping() throws {
        let record = MetadataRecord(
            accountAlias: "work",
            workspaceID: "ws-1",
            itemID: "item-2",
            path: "Files/report.csv",
            parentPath: "Files",
            name: "report.csv",
            isDir: false,
            contentLength: 1024,
            etag: "\"abc\""
        )
        let item = try DomainItem.from(record: record)
        #expect(item.identifier == ItemIdentifier.path(workspaceID: "ws-1", itemID: "item-2", path: "Files/report.csv"))
        #expect(item.parentIdentifier == ItemIdentifier.path(workspaceID: "ws-1", itemID: "item-2", path: "Files"))
        #expect(item.filename == "report.csv")
        #expect(!item.isDirectory)
        #expect(item.size == 1024)
        #expect(item.capabilities.contains(.read))
        #expect(item.capabilities.contains(.write))
        #expect(!item.capabilities.contains(.enumerate))
    }

    @Test func recordDirectoryMapping() throws {
        let record = MetadataRecord(
            accountAlias: "work",
            workspaceID: "ws-1",
            itemID: "item-2",
            path: "Files",
            parentPath: "",
            name: "Files",
            isDir: true,
            contentLength: 0,
            etag: ""
        )
        let item = try DomainItem.from(record: record)
        #expect(item.isDirectory)
        #expect(item.capabilities.contains(.enumerate))
        #expect(item.capabilities.contains(.addSubitems))
    }

    @Test func recordRootPathIsItemIdentifier() throws {
        let record = MetadataRecord(
            accountAlias: "work",
            workspaceID: "ws-1",
            itemID: "item-2",
            path: "",
            parentPath: "",
            name: "Lakehouse",
            isDir: true,
            contentLength: 0,
            etag: ""
        )
        let item = try DomainItem.from(record: record)
        #expect(item.identifier == ItemIdentifier.item(workspaceID: "ws-1", itemID: "item-2"))
        #expect(item.parentIdentifier == ItemIdentifier.workspace(workspaceID: "ws-1"))
    }

    @Test func recordWithEtagUsesNonEmptyContentVersion() throws {
        let record = MetadataRecord(
            accountAlias: "work",
            workspaceID: "ws-1",
            itemID: "item-2",
            path: "Files/f.txt",
            parentPath: "Files",
            name: "f.txt",
            isDir: false,
            contentLength: 0,
            etag: "\"etag-value\""
        )
        let item = try DomainItem.from(record: record)
        #expect(!item.contentVersion.isEmpty)
        // Same etag → same content version token (deterministic).
        let record2 = MetadataRecord(
            accountAlias: "work",
            workspaceID: "ws-1",
            itemID: "item-2",
            path: "Files/f.txt",
            parentPath: "Files",
            name: "f.txt",
            isDir: false,
            contentLength: 0,
            etag: "\"etag-value\""
        )
        let item2 = try DomainItem.from(record: record2)
        #expect(item.contentVersion == item2.contentVersion)
    }

    @Test func recordMissingWorkspaceThrows() {
        let record = MetadataRecord(
            accountAlias: "a",
            workspaceID: "",
            itemID: "item-2",
            path: "Files/f.txt",
            parentPath: "Files",
            name: "f.txt",
            isDir: false,
            contentLength: 0,
            etag: ""
        )
        #expect(throws: (any Error).self) {
            try DomainItem.from(record: record)
        }
    }

    // MARK: - FNV version stability

    @Test func fallbackVersionIsDeterministic() {
        let v1 = fallbackVersion(seed: "hello", size: 42, mtime: nil)
        let v2 = fallbackVersion(seed: "hello", size: 42, mtime: nil)
        #expect(v1 == v2)
    }

    @Test func fallbackVersionDiffersOnDifferentSeed() {
        let v1 = fallbackVersion(seed: "hello", size: 42, mtime: nil)
        let v2 = fallbackVersion(seed: "world", size: 42, mtime: nil)
        #expect(v1 != v2)
    }
}
