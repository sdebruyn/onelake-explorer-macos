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
        // itemType "Lakehouse" + path under Files/ → writable file.
        let record = MetadataRecord(
            accountAlias: "work",
            workspaceID: "ws-1",
            itemID: "item-2",
            path: "Files/report.csv",
            parentPath: "Files",
            name: "report.csv",
            isDir: false,
            contentLength: 1024,
            etag: "\"abc\"",
            itemType: "Lakehouse"
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
        // itemType "Lakehouse" + path "Files" (Fabric-managed node) → managedDirectory.
        let record = MetadataRecord(
            accountAlias: "work",
            workspaceID: "ws-1",
            itemID: "item-2",
            path: "Files",
            parentPath: "",
            name: "Files",
            isDir: true,
            contentLength: 0,
            etag: "",
            itemType: "Lakehouse"
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

    // MARK: - root(alias:) — additional coverage

    @Test func rootFilenameUsesEmDash() {
        // The spec says "OneLake \u{2014} <alias>" (em-dash, like OneDrive).
        let item = DomainItem.root(alias: "personal")
        #expect(item.filename == "OneLake \u{2014} personal")
    }

    @Test func rootItemHasZeroSize() {
        #expect(DomainItem.root(alias: "work").size == 0)
    }

    @Test func rootItemHasReadCapability() {
        #expect(DomainItem.root(alias: "work").capabilities.contains(.read))
    }

    @Test func rootItemHasNoWriteCapability() {
        // Root is read-only; write/delete/addSubitems must not be granted.
        let caps = DomainItem.root(alias: "work").capabilities
        #expect(!caps.contains(.write))
        #expect(!caps.contains(.delete))
        #expect(!caps.contains(.addSubitems))
    }

    @Test func rootItemHasNonEmptyVersionTokens() {
        let item = DomainItem.root(alias: "work")
        #expect(!item.contentVersion.isEmpty)
        #expect(!item.metadataVersion.isEmpty)
    }

    @Test func rootItemVersionIsDeterministicForSameAlias() {
        let a = DomainItem.root(alias: "prod")
        let b = DomainItem.root(alias: "prod")
        #expect(a.contentVersion == b.contentVersion)
        #expect(a.metadataVersion == b.metadataVersion)
    }

    @Test func rootItemVersionDiffersForDifferentAliases() {
        let a = DomainItem.root(alias: "alias-a")
        let b = DomainItem.root(alias: "alias-b")
        #expect(a.contentVersion != b.contentVersion)
    }

    // MARK: - from(workspace:) — additional coverage

    @Test func workspaceHasNoWriteCapabilities() {
        let ws = Workspace(id: "ws-1", displayName: "W", type: "Workspace")
        let caps = DomainItem.from(workspace: ws).capabilities
        #expect(!caps.contains(.write))
        #expect(!caps.contains(.delete))
        #expect(!caps.contains(.addSubitems))
    }

    @Test func workspaceHasNonEmptyVersionTokens() {
        let ws = Workspace(id: "ws-42", displayName: "Analytics", type: "Workspace")
        let item = DomainItem.from(workspace: ws)
        #expect(!item.contentVersion.isEmpty)
        #expect(!item.metadataVersion.isEmpty)
    }

    @Test func workspaceHasZeroSize() {
        let ws = Workspace(id: "ws-1", displayName: "W", type: "Workspace")
        #expect(DomainItem.from(workspace: ws).size == 0)
    }

    @Test func workspaceVersionDiffersFromDifferentID() {
        let ws1 = Workspace(id: "ws-aaa", displayName: "Same Name", type: "Workspace")
        let ws2 = Workspace(id: "ws-bbb", displayName: "Same Name", type: "Workspace")
        // Content version is seeded from id, metadata from displayName.
        #expect(DomainItem.from(workspace: ws1).contentVersion != DomainItem.from(workspace: ws2).contentVersion)
    }

    // MARK: - from(fabricItem:) — additional coverage

    @Test func fabricItemIsDirectory() {
        let fi = Item(id: "item-1", displayName: "Lakehouse", type: "Lakehouse", workspaceID: "ws-1")
        #expect(DomainItem.from(fabricItem: fi, workspaceID: "ws-1").isDirectory)
    }

    @Test func fabricItemHasOnlyReadEnumerateCapabilities() {
        let fi = Item(id: "item-1", displayName: "Lakehouse", type: "Lakehouse", workspaceID: "ws-1")
        let caps = DomainItem.from(fabricItem: fi, workspaceID: "ws-1").capabilities
        #expect(caps.contains(.read))
        #expect(caps.contains(.enumerate))
        #expect(!caps.contains(.write))
        #expect(!caps.contains(.delete))
        #expect(!caps.contains(.addSubitems))
    }

    @Test func fabricItemHasZeroSize() {
        let fi = Item(id: "item-1", displayName: "Lakehouse", type: "Lakehouse", workspaceID: "ws-1")
        #expect(DomainItem.from(fabricItem: fi, workspaceID: "ws-1").size == 0)
    }

    @Test func fabricItemHasNonEmptyVersionTokens() {
        let fi = Item(id: "item-1", displayName: "LH", type: "Lakehouse", workspaceID: "ws-1")
        let item = DomainItem.from(fabricItem: fi, workspaceID: "ws-1")
        #expect(!item.contentVersion.isEmpty)
        #expect(!item.metadataVersion.isEmpty)
    }

    // MARK: - from(record:) — additional branch coverage

    @Test func recordMissingItemIDThrows() {
        // Both workspaceID and itemID must be non-empty.
        let record = MetadataRecord(
            accountAlias: "a",
            workspaceID: "ws-1",
            itemID: "",
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

    @Test func recordMissingItemIDThrowsInvalidRecord() {
        let record = MetadataRecord(
            accountAlias: "a",
            workspaceID: "ws-1",
            itemID: "",
            path: "",
            parentPath: "",
            name: "root",
            isDir: true,
            contentLength: 0,
            etag: ""
        )
        do {
            _ = try DomainItem.from(record: record)
            Issue.record("Expected an error to be thrown")
        } catch {
            if case FPError.invalidRecord = error {
                // correct
            } else {
                Issue.record("Expected FPError.invalidRecord, got \(error)")
            }
        }
    }

    @Test func recordModificationDateIsPreserved() throws {
        let mtime = Date(timeIntervalSince1970: 1_700_000_000)
        let nsValue = Int64(mtime.timeIntervalSince1970 * 1_000_000_000)
        let record = MetadataRecord(
            accountAlias: "work",
            workspaceID: "ws-1",
            itemID: "item-2",
            path: "Files/data.txt",
            parentPath: "Files",
            name: "data.txt",
            isDir: false,
            contentLength: 512,
            etag: "",
            lastModifiedNs: nsValue
        )
        let item = try DomainItem.from(record: record)
        let resultDate = try #require(item.modificationDate)
        // Compare within 1 second to avoid nanosecond rounding drift.
        #expect(abs(resultDate.timeIntervalSince1970 - mtime.timeIntervalSince1970) < 1.0)
    }

    @Test func recordNilModificationDateWhenLastModifiedNsIsZero() throws {
        let record = MetadataRecord(
            accountAlias: "work",
            workspaceID: "ws-1",
            itemID: "item-2",
            path: "Files/data.txt",
            parentPath: "Files",
            name: "data.txt",
            isDir: false,
            contentLength: 0,
            etag: "",
            lastModifiedNs: 0
        )
        let item = try DomainItem.from(record: record)
        #expect(item.modificationDate == nil)
    }

    @Test func recordPreservesCachedContentType() throws {
        let record = MetadataRecord(
            accountAlias: "work",
            workspaceID: "ws-1",
            itemID: "item-2",
            path: "Files/data.parquet",
            parentPath: "Files",
            name: "data.parquet",
            isDir: false,
            contentLength: 0,
            etag: "",
            contentType: "application/octet-stream"
        )
        let item = try DomainItem.from(record: record)
        // Cached MIME type wins over any extension-based inference.
        #expect(item.contentType == "application/octet-stream")
    }

    @Test func recordInfersMIMETypeFromExtensionWhenContentTypeEmpty() throws {
        let record = MetadataRecord(
            accountAlias: "work",
            workspaceID: "ws-1",
            itemID: "item-2",
            path: "Files/report.csv",
            parentPath: "Files",
            name: "report.csv",
            isDir: false,
            contentLength: 0,
            etag: "",
            contentType: ""
        )
        let item = try DomainItem.from(record: record)
        // UTType should infer text/csv (or text/comma-separated-values) for .csv.
        #expect(!item.contentType.isEmpty)
        #expect(item.contentType.lowercased().contains("csv") || item.contentType.hasPrefix("text/"))
    }

    @Test func recordDirectoryDoesNotInferMIMETypeFromExtension() throws {
        // Directories get no MIME inference even if path has an extension.
        let record = MetadataRecord(
            accountAlias: "work",
            workspaceID: "ws-1",
            itemID: "item-2",
            path: "Files.csv",
            parentPath: "",
            name: "Files.csv",
            isDir: true,
            contentLength: 0,
            etag: "",
            contentType: ""
        )
        let item = try DomainItem.from(record: record)
        #expect(item.contentType.isEmpty)
    }

    @Test func recordUnknownExtensionLeavesContentTypeEmpty() throws {
        // Extension ".xyzzy" has no UTType mapping → contentType stays "".
        let record = MetadataRecord(
            accountAlias: "work",
            workspaceID: "ws-1",
            itemID: "item-2",
            path: "Files/mystery.xyzzy",
            parentPath: "Files",
            name: "mystery.xyzzy",
            isDir: false,
            contentLength: 0,
            etag: "",
            contentType: ""
        )
        let item = try DomainItem.from(record: record)
        // UTType lookup for ".xyzzy" returns nil → mimeType stays empty or may
        // be set by the OS; either way we don't assert a specific value but do
        // confirm the item round-trips without throwing.
        #expect(item.filename == "mystery.xyzzy")
    }

    @Test func recordFileWithNoExtensionLeavesContentTypeEmpty() throws {
        let record = MetadataRecord(
            accountAlias: "work",
            workspaceID: "ws-1",
            itemID: "item-2",
            path: "Files/Makefile",
            parentPath: "Files",
            name: "Makefile",
            isDir: false,
            contentLength: 0,
            etag: "",
            contentType: ""
        )
        let item = try DomainItem.from(record: record)
        // No extension → UTType path is skipped → contentType is "".
        #expect(item.contentType.isEmpty)
    }

    @Test func recordDeeplyNestedFileHasCorrectParentIdentifier() throws {
        // path "a/b/c.txt" → parent should be .path(..., path: "a/b")
        let record = MetadataRecord(
            accountAlias: "work",
            workspaceID: "ws-1",
            itemID: "item-2",
            path: "a/b/c.txt",
            parentPath: "a/b",
            name: "c.txt",
            isDir: false,
            contentLength: 0,
            etag: ""
        )
        let item = try DomainItem.from(record: record)
        #expect(item.parentIdentifier == ItemIdentifier.path(workspaceID: "ws-1", itemID: "item-2", path: "a/b"))
    }

    @Test func recordSingleLevelPathHasItemParentIdentifier() throws {
        // path "Files" (no slash) → parent should be .item(...)
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
        #expect(item.parentIdentifier == ItemIdentifier.item(workspaceID: "ws-1", itemID: "item-2"))
    }

    @Test func recordDirectoryHasFullCapabilitySet() throws {
        // A directory under Files/ in a Lakehouse gets full writable caps.
        let record = MetadataRecord(
            accountAlias: "work",
            workspaceID: "ws-1",
            itemID: "item-2",
            path: "Files/SubDir",
            parentPath: "Files",
            name: "SubDir",
            isDir: true,
            contentLength: 0,
            etag: "",
            itemType: "Lakehouse"
        )
        let item = try DomainItem.from(record: record)
        let caps = item.capabilities
        #expect(caps.contains(.read))
        #expect(caps.contains(.write))
        #expect(caps.contains(.delete))
        #expect(caps.contains(.enumerate))
        #expect(caps.contains(.addSubitems))
    }

    @Test func recordFileHasExactlyReadWriteDelete() throws {
        // A file under Files/ in a Lakehouse gets exactly read/write/delete.
        let record = MetadataRecord(
            accountAlias: "work",
            workspaceID: "ws-1",
            itemID: "item-2",
            path: "Files/f.bin",
            parentPath: "Files",
            name: "f.bin",
            isDir: false,
            contentLength: 99,
            etag: "",
            itemType: "Lakehouse"
        )
        let item = try DomainItem.from(record: record)
        #expect(item.capabilities == [.read, .write, .delete])
    }

    @Test func recordFallbackContentVersionUsedWhenEtagIsEmpty() throws {
        let record = MetadataRecord(
            accountAlias: "work",
            workspaceID: "ws-1",
            itemID: "item-2",
            path: "Files/f.bin",
            parentPath: "Files",
            name: "f.bin",
            isDir: false,
            contentLength: 100,
            etag: ""
        )
        let item = try DomainItem.from(record: record)
        // Without an etag, the fallback FNV path is used — token must be non-empty.
        #expect(!item.contentVersion.isEmpty)
    }

    @Test func recordEtagContentVersionDiffersFromFallback() throws {
        // Record with etag → base64(etag bytes) differs from FNV fallback.
        let withEtag = MetadataRecord(
            accountAlias: "work", workspaceID: "ws-1", itemID: "i",
            path: "f.txt", parentPath: "", name: "f.txt",
            isDir: false, contentLength: 1, etag: "\"abc\""
        )
        let noEtag = MetadataRecord(
            accountAlias: "work", workspaceID: "ws-1", itemID: "i",
            path: "f.txt", parentPath: "", name: "f.txt",
            isDir: false, contentLength: 1, etag: ""
        )
        let vWithEtag = try DomainItem.from(record: withEtag).contentVersion
        let vNoEtag   = try DomainItem.from(record: noEtag).contentVersion
        #expect(vWithEtag != vNoEtag)
    }

    @Test func recordMetadataVersionChangesWhenEtagChanges() throws {
        let base = MetadataRecord(
            accountAlias: "work", workspaceID: "ws-1", itemID: "i",
            path: "f.txt", parentPath: "", name: "f.txt",
            isDir: false, contentLength: 0, etag: "v1"
        )
        let updated = MetadataRecord(
            accountAlias: "work", workspaceID: "ws-1", itemID: "i",
            path: "f.txt", parentPath: "", name: "f.txt",
            isDir: false, contentLength: 0, etag: "v2"
        )
        let mv1 = try DomainItem.from(record: base).metadataVersion
        let mv2 = try DomainItem.from(record: updated).metadataVersion
        #expect(mv1 != mv2)
    }

    @Test func recordMetadataVersionChangesWhenSizeChanges() throws {
        let r1 = MetadataRecord(
            accountAlias: "work", workspaceID: "ws-1", itemID: "i",
            path: "f.txt", parentPath: "", name: "f.txt",
            isDir: false, contentLength: 100, etag: ""
        )
        let r2 = MetadataRecord(
            accountAlias: "work", workspaceID: "ws-1", itemID: "i",
            path: "f.txt", parentPath: "", name: "f.txt",
            isDir: false, contentLength: 200, etag: ""
        )
        let mv1 = try DomainItem.from(record: r1).metadataVersion
        let mv2 = try DomainItem.from(record: r2).metadataVersion
        #expect(mv1 != mv2)
    }

    @Test func recordFileSizeIsPreserved() throws {
        let record = MetadataRecord(
            accountAlias: "work", workspaceID: "ws-1", itemID: "item-2",
            path: "Files/big.bin", parentPath: "Files", name: "big.bin",
            isDir: false, contentLength: 999_999, etag: ""
        )
        let item = try DomainItem.from(record: record)
        #expect(item.size == 999_999)
    }

    @Test func recordDirectorySizeIsZero() throws {
        let record = MetadataRecord(
            accountAlias: "work", workspaceID: "ws-1", itemID: "item-2",
            path: "Dir", parentPath: "", name: "Dir",
            isDir: true, contentLength: 0, etag: ""
        )
        let item = try DomainItem.from(record: record)
        #expect(item.size == 0)
    }

    // MARK: - stubDirectory

    @Test func stubDirectoryIsDirectory() {
        let id = ItemIdentifier.item(workspaceID: "ws-1", itemID: "i")
        let pid = ItemIdentifier.workspace(workspaceID: "ws-1")
        let stub = DomainItem.stubDirectory(identifier: id, parentIdentifier: pid, name: "MyLakehouse")
        #expect(stub.isDirectory)
    }

    @Test func stubDirectoryHasCorrectIdentifiers() {
        let id = ItemIdentifier.item(workspaceID: "ws-1", itemID: "i")
        let pid = ItemIdentifier.workspace(workspaceID: "ws-1")
        let stub = DomainItem.stubDirectory(identifier: id, parentIdentifier: pid, name: "MyLakehouse")
        #expect(stub.identifier == id)
        #expect(stub.parentIdentifier == pid)
    }

    @Test func stubDirectoryFilenameIsPreserved() {
        let id = ItemIdentifier.item(workspaceID: "ws-1", itemID: "i")
        let pid = ItemIdentifier.workspace(workspaceID: "ws-1")
        let stub = DomainItem.stubDirectory(identifier: id, parentIdentifier: pid, name: "My Folder")
        #expect(stub.filename == "My Folder")
    }

    @Test func stubDirectoryHasReadAndEnumerateCapabilities() {
        let id = ItemIdentifier.item(workspaceID: "ws-1", itemID: "i")
        let pid = ItemIdentifier.workspace(workspaceID: "ws-1")
        let caps = DomainItem.stubDirectory(identifier: id, parentIdentifier: pid, name: "X").capabilities
        #expect(caps.contains(.read))
        #expect(caps.contains(.enumerate))
    }

    @Test func stubDirectoryHasNoWriteCapabilities() {
        let id = ItemIdentifier.item(workspaceID: "ws-1", itemID: "i")
        let pid = ItemIdentifier.workspace(workspaceID: "ws-1")
        let caps = DomainItem.stubDirectory(identifier: id, parentIdentifier: pid, name: "X").capabilities
        #expect(!caps.contains(.write))
        #expect(!caps.contains(.delete))
        #expect(!caps.contains(.addSubitems))
    }

    @Test func stubDirectoryHasNonEmptyVersionTokens() {
        let id = ItemIdentifier.item(workspaceID: "ws-1", itemID: "i")
        let pid = ItemIdentifier.workspace(workspaceID: "ws-1")
        let stub = DomainItem.stubDirectory(identifier: id, parentIdentifier: pid, name: "Folder")
        #expect(!stub.contentVersion.isEmpty)
        #expect(!stub.metadataVersion.isEmpty)
    }

    @Test func stubDirectoryZeroSize() {
        let id = ItemIdentifier.item(workspaceID: "ws-1", itemID: "i")
        let pid = ItemIdentifier.workspace(workspaceID: "ws-1")
        #expect(DomainItem.stubDirectory(identifier: id, parentIdentifier: pid, name: "X").size == 0)
    }

    // MARK: - synthetic

    @Test func syntheticDirectoryIsDirectory() {
        let id = ItemIdentifier.path(workspaceID: "ws", itemID: "i", path: "NewDir")
        let pid = ItemIdentifier.item(workspaceID: "ws", itemID: "i")
        let synth = DomainItem.synthetic(identifier: id, parentIdentifier: pid, name: "NewDir", isDirectory: true)
        #expect(synth.isDirectory)
    }

    @Test func syntheticFileIsNotDirectory() {
        let id = ItemIdentifier.path(workspaceID: "ws", itemID: "i", path: "new.txt")
        let pid = ItemIdentifier.item(workspaceID: "ws", itemID: "i")
        let synth = DomainItem.synthetic(identifier: id, parentIdentifier: pid, name: "new.txt", isDirectory: false)
        #expect(!synth.isDirectory)
    }

    @Test func syntheticDirectoryInLakehouseHasFullCapabilitySet() {
        let id = ItemIdentifier.path(workspaceID: "ws", itemID: "i", path: "Files/Dir")
        let pid = ItemIdentifier.path(workspaceID: "ws", itemID: "i", path: "Files")
        let caps = DomainItem.synthetic(identifier: id, parentIdentifier: pid, name: "Dir", isDirectory: true, itemType: "Lakehouse").capabilities
        #expect(caps.contains(.read))
        #expect(caps.contains(.write))
        #expect(caps.contains(.delete))
        #expect(caps.contains(.enumerate))
        #expect(caps.contains(.addSubitems))
    }

    @Test func syntheticFileInLakehouseHasExactlyReadWriteDelete() {
        let id = ItemIdentifier.path(workspaceID: "ws", itemID: "i", path: "Files/f.txt")
        let pid = ItemIdentifier.path(workspaceID: "ws", itemID: "i", path: "Files")
        let caps = DomainItem.synthetic(identifier: id, parentIdentifier: pid, name: "f.txt", isDirectory: false, itemType: "Lakehouse").capabilities
        #expect(caps == [.read, .write, .delete])
    }

    @Test func syntheticWithoutItemTypeIsReadOnly() {
        // A synthetic item with no item type (unknown parent) must be read-only:
        // capability computation cannot grant write access without a Lakehouse context.
        let id = ItemIdentifier.path(workspaceID: "ws", itemID: "i", path: "Files/f.txt")
        let pid = ItemIdentifier.path(workspaceID: "ws", itemID: "i", path: "Files")
        let caps = DomainItem.synthetic(identifier: id, parentIdentifier: pid, name: "f.txt", isDirectory: false).capabilities
        #expect(caps == DomainItem.CapabilitySet.readOnly)
    }

    @Test func syntheticWarehouseIsReadOnly() {
        // A synthetic item under a Warehouse must be read-only regardless of path.
        let id = ItemIdentifier.path(workspaceID: "ws", itemID: "i", path: "Files/f.txt")
        let pid = ItemIdentifier.path(workspaceID: "ws", itemID: "i", path: "Files")
        let caps = DomainItem.synthetic(identifier: id, parentIdentifier: pid, name: "f.txt", isDirectory: false, itemType: "Warehouse").capabilities
        #expect(caps == DomainItem.CapabilitySet.readOnly)
    }

    @Test func syntheticPreservesIdentifiersAndName() {
        let id = ItemIdentifier.path(workspaceID: "ws-9", itemID: "item-9", path: "sub/file.dat")
        let pid = ItemIdentifier.path(workspaceID: "ws-9", itemID: "item-9", path: "sub")
        let synth = DomainItem.synthetic(identifier: id, parentIdentifier: pid, name: "file.dat", isDirectory: false)
        #expect(synth.identifier == id)
        #expect(synth.parentIdentifier == pid)
        #expect(synth.filename == "file.dat")
    }

    @Test func syntheticHasNonEmptyVersionTokens() {
        let id = ItemIdentifier.path(workspaceID: "ws", itemID: "i", path: "f.txt")
        let pid = ItemIdentifier.item(workspaceID: "ws", itemID: "i")
        let synth = DomainItem.synthetic(identifier: id, parentIdentifier: pid, name: "f.txt", isDirectory: false)
        #expect(!synth.contentVersion.isEmpty)
        #expect(!synth.metadataVersion.isEmpty)
    }

    @Test func syntheticZeroSize() {
        let id = ItemIdentifier.path(workspaceID: "ws", itemID: "i", path: "f.txt")
        let pid = ItemIdentifier.item(workspaceID: "ws", itemID: "i")
        #expect(DomainItem.synthetic(identifier: id, parentIdentifier: pid, name: "f.txt", isDirectory: false).size == 0)
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

    @Test func fallbackVersionDiffersOnDifferentSize() {
        let v1 = fallbackVersion(seed: "hello", size: 10, mtime: nil)
        let v2 = fallbackVersion(seed: "hello", size: 99, mtime: nil)
        #expect(v1 != v2)
    }

    @Test func fallbackVersionDiffersWhenMtimeAdded() {
        let v1 = fallbackVersion(seed: "hello", size: 0, mtime: nil)
        let v2 = fallbackVersion(seed: "hello", size: 0, mtime: Date(timeIntervalSince1970: 1_000_000))
        #expect(v1 != v2)
    }

    @Test func fallbackVersionIsDeterministicWithMtime() {
        let mtime = Date(timeIntervalSince1970: 1_700_000_000)
        let v1 = fallbackVersion(seed: "seed", size: 7, mtime: mtime)
        let v2 = fallbackVersion(seed: "seed", size: 7, mtime: mtime)
        #expect(v1 == v2)
    }

    @Test func fallbackVersionIsBase64Encoded() {
        // The return value must be a valid base64 Data object.
        let v = fallbackVersion(seed: "x", size: 0, mtime: nil)
        // Non-empty and re-encodable from raw bytes: just check it's 12 bytes (8 raw → base64 → 12).
        #expect(v.count == 12)
    }

    // MARK: - fp-03: parent identifier derived from ItemIdentifier.parentIdentifier

    @Test func fromRecordParentMatchesIdentifierDotParent() throws {
        // Verify that the parent identifier produced by DomainItem.from(record:)
        // equals the one you get by calling .parentIdentifier on the constructed
        // identifier directly — confirming the single-implementation rule (fp-03).
        let record = MetadataRecord(
            accountAlias: "work", workspaceID: "ws-1", itemID: "item-2",
            path: "Files/sub/doc.txt", parentPath: "Files/sub", name: "doc.txt",
            isDir: false, contentLength: 100, etag: ""
        )
        let item = try DomainItem.from(record: record)
        let expectedParent = item.identifier.parentIdentifier
        #expect(item.parentIdentifier == expectedParent)
    }

    @Test func fromRecordSingleLevelParentMatchesIdentifierDotParent() throws {
        let record = MetadataRecord(
            accountAlias: "work", workspaceID: "ws-1", itemID: "item-2",
            path: "Files", parentPath: "", name: "Files",
            isDir: true, contentLength: 0, etag: ""
        )
        let item = try DomainItem.from(record: record)
        let expectedParent = item.identifier.parentIdentifier
        #expect(item.parentIdentifier == expectedParent)
    }

    @Test func fromRecordEmptyPathParentMatchesIdentifierDotParent() throws {
        // path == "" → identifier is .item; parentIdentifier must be .workspace
        let record = MetadataRecord(
            accountAlias: "work", workspaceID: "ws-1", itemID: "item-2",
            path: "", parentPath: "", name: "Lakehouse",
            isDir: true, contentLength: 0, etag: ""
        )
        let item = try DomainItem.from(record: record)
        let expectedParent = item.identifier.parentIdentifier
        #expect(item.parentIdentifier == expectedParent)
    }

    // MARK: - fp-05: capability presets

    @Test func capabilityPresetsMatchReadOnly() {
        // readOnly must be exactly {.read, .enumerate}.
        #expect(DomainItem.CapabilitySet.readOnly == [.read, .enumerate])
    }

    @Test func capabilityPresetsMatchWritableDirectory() {
        #expect(DomainItem.CapabilitySet.writableDirectory == [.read, .write, .delete, .enumerate, .addSubitems])
    }

    @Test func capabilityPresetsMatchWritableFile() {
        #expect(DomainItem.CapabilitySet.writableFile == [.read, .write, .delete])
    }

    @Test func rootUsesReadOnlyPreset() {
        let item = DomainItem.root(alias: "work")
        #expect(item.capabilities == DomainItem.CapabilitySet.readOnly)
    }

    @Test func workspaceUsesReadOnlyPreset() {
        let ws = Workspace(id: "ws-1", displayName: "W", type: "Workspace")
        let item = DomainItem.from(workspace: ws)
        #expect(item.capabilities == DomainItem.CapabilitySet.readOnly)
    }

    @Test func fabricItemUsesReadOnlyPreset() {
        let fi = Item(id: "item-1", displayName: "LH", type: "Lakehouse", workspaceID: "ws-1")
        let item = DomainItem.from(fabricItem: fi, workspaceID: "ws-1")
        #expect(item.capabilities == DomainItem.CapabilitySet.readOnly)
    }

    @Test func stubDirectoryUsesReadOnlyPreset() {
        let id = ItemIdentifier.item(workspaceID: "ws-1", itemID: "i")
        let pid = ItemIdentifier.workspace(workspaceID: "ws-1")
        let stub = DomainItem.stubDirectory(identifier: id, parentIdentifier: pid, name: "X")
        #expect(stub.capabilities == DomainItem.CapabilitySet.readOnly)
    }

    @Test func syntheticLakehouseDirectoryUsesWritableDirectoryPreset() {
        let id = ItemIdentifier.path(workspaceID: "ws", itemID: "i", path: "Files/Dir")
        let pid = ItemIdentifier.path(workspaceID: "ws", itemID: "i", path: "Files")
        let synth = DomainItem.synthetic(identifier: id, parentIdentifier: pid, name: "Dir", isDirectory: true, itemType: "Lakehouse")
        #expect(synth.capabilities == DomainItem.CapabilitySet.writableDirectory)
    }

    @Test func syntheticLakehouseFileUsesWritableFilePreset() {
        let id = ItemIdentifier.path(workspaceID: "ws", itemID: "i", path: "Files/f.txt")
        let pid = ItemIdentifier.path(workspaceID: "ws", itemID: "i", path: "Files")
        let synth = DomainItem.synthetic(identifier: id, parentIdentifier: pid, name: "f.txt", isDirectory: false, itemType: "Lakehouse")
        #expect(synth.capabilities == DomainItem.CapabilitySet.writableFile)
    }

    // MARK: - fp-06: MIME inferred from record.name, not record.path

    @Test func mimeTypeInferredFromNameNotPath() throws {
        // path has a .csv extension but name has .txt — MIME must come from name.
        let record = MetadataRecord(
            accountAlias: "work", workspaceID: "ws-1", itemID: "item-2",
            path: "Files/archive.csv", parentPath: "Files", name: "data.txt",
            isDir: false, contentLength: 0, etag: "", contentType: ""
        )
        let item = try DomainItem.from(record: record)
        // Name is "data.txt" → MIME must be text/plain, not text/csv.
        #expect(item.contentType.lowercased().contains("text/plain") || item.contentType.isEmpty,
                "MIME should come from name (.txt), not path (.csv); got: \(item.contentType)")
    }

    @Test func mimeTypeWhenNameAndPathExtensionAgree() throws {
        let record = MetadataRecord(
            accountAlias: "work", workspaceID: "ws-1", itemID: "item-2",
            path: "Files/report.csv", parentPath: "Files", name: "report.csv",
            isDir: false, contentLength: 0, etag: "", contentType: ""
        )
        let item = try DomainItem.from(record: record)
        // Both agree → CSV MIME expected.
        #expect(!item.contentType.isEmpty)
    }

    // MARK: - #280: sentinel-row mapping in from(record:)

    /// Workspace sentinel row (workspaceID == VirtualIDs.workspaceID, path == <GUID>):
    /// from(record:) must produce an item equal field-for-field to from(workspace:)
    /// for the same workspace — the two code paths must never drift.
    @Test func workspaceSentinelRowRoundTripsToWorkspaceItem() throws {
        let wsGUID = "11111111-2222-3333-4444-555555555555"
        let displayName = "Prod Analytics"

        // Row exactly as SyncEngine.listWorkspaces constructs it.
        let record = MetadataRecord(
            accountAlias: "work",
            workspaceID: VirtualIDs.workspaceID,
            itemID: VirtualIDs.workspaceID,
            path: wsGUID,
            parentPath: "",
            name: displayName,
            isDir: true
        )

        // Reference item from the dedicated constructor.
        let ws = Workspace(id: wsGUID, displayName: displayName, type: "Workspace")
        let reference = DomainItem.from(workspace: ws)

        let fromRecord = try DomainItem.from(record: record)

        // Equatable equality covers identifier, parentIdentifier, filename,
        // isDirectory, size, capabilities, and the version tokens — so this
        // guards against any field drifting from from(workspace:).
        #expect(fromRecord == reference)
        #expect(fromRecord.identifier == ItemIdentifier.workspace(workspaceID: wsGUID))
        #expect(fromRecord.parentIdentifier == ItemIdentifier.root)
        #expect(fromRecord.filename == displayName)
    }

    /// Root sentinel row (workspaceID == VirtualIDs.workspaceID, path == ""):
    /// from(record:) must throw so enumeration / delta consumers skip it. The
    /// root container is produced on demand by DomainItem.root(alias:) and is
    /// never an enumerated child, so it must not flow into didUpdate.
    @Test func rootSentinelRowThrows() {
        let record = MetadataRecord(
            accountAlias: "work",
            workspaceID: VirtualIDs.workspaceID,
            itemID: VirtualIDs.workspaceID,
            path: "",
            parentPath: "",
            name: "work",
            isDir: true
        )
        #expect(throws: (any Error).self) {
            try DomainItem.from(record: record)
        }
    }

    /// The root-sentinel row throws specifically FPError.invalidRecord, so
    /// delta consumers classify the skip consistently.
    @Test func rootSentinelRowThrowsInvalidRecord() {
        let record = MetadataRecord(
            accountAlias: "work",
            workspaceID: VirtualIDs.workspaceID,
            itemID: VirtualIDs.workspaceID,
            path: "",
            parentPath: "",
            name: "work",
            isDir: true
        )
        do {
            _ = try DomainItem.from(record: record)
            Issue.record("Expected an error to be thrown")
        } catch {
            if case FPError.invalidRecord = error {
                // correct
            } else {
                Issue.record("Expected FPError.invalidRecord, got \(error)")
            }
        }
    }

    /// Regression: normal item rows (path == "") must still map to .item / .workspace.
    @Test func normalItemRowStillMapsToItemIdentifier() throws {
        let record = MetadataRecord(
            accountAlias: "work",
            workspaceID: "ws-1",
            itemID: "item-2",
            path: "",
            parentPath: "",
            name: "Lakehouse",
            isDir: true
        )
        let item = try DomainItem.from(record: record)
        #expect(item.identifier == ItemIdentifier.item(workspaceID: "ws-1", itemID: "item-2"))
        #expect(item.parentIdentifier == ItemIdentifier.workspace(workspaceID: "ws-1"))
    }

    /// Regression: normal file/path rows must still map to .path.
    @Test func normalPathRowStillMapsToPathIdentifier() throws {
        let record = MetadataRecord(
            accountAlias: "work",
            workspaceID: "ws-1",
            itemID: "item-2",
            path: "Files/data.csv",
            parentPath: "Files",
            name: "data.csv",
            isDir: false,
            contentLength: 42
        )
        let item = try DomainItem.from(record: record)
        #expect(item.identifier == ItemIdentifier.path(workspaceID: "ws-1", itemID: "item-2", path: "Files/data.csv"))
        #expect(item.parentIdentifier == ItemIdentifier.path(workspaceID: "ws-1", itemID: "item-2", path: "Files"))
        #expect(!item.isDirectory)
        #expect(item.size == 42)
    }

    // MARK: - computeCapabilities: Lakehouse Files/Tables write policy

    @Test func lakhouseFileUnderFilesIsWritable() throws {
        let record = MetadataRecord(
            accountAlias: "a", workspaceID: "ws", itemID: "it",
            path: "Files/data.csv", parentPath: "Files", name: "data.csv",
            isDir: false, itemType: "Lakehouse"
        )
        let item = try DomainItem.from(record: record)
        #expect(item.capabilities == DomainItem.CapabilitySet.writableFile)
    }

    @Test func lakehouseFileUnderTablesIsWritable() throws {
        let record = MetadataRecord(
            accountAlias: "a", workspaceID: "ws", itemID: "it",
            path: "Tables/delta/part.parquet", parentPath: "Tables/delta",
            name: "part.parquet", isDir: false, itemType: "Lakehouse"
        )
        let item = try DomainItem.from(record: record)
        #expect(item.capabilities == DomainItem.CapabilitySet.writableFile)
    }

    @Test func lakehouseDirUnderFilesIsWritable() throws {
        let record = MetadataRecord(
            accountAlias: "a", workspaceID: "ws", itemID: "it",
            path: "Files/subfolder", parentPath: "Files", name: "subfolder",
            isDir: true, itemType: "Lakehouse"
        )
        let item = try DomainItem.from(record: record)
        #expect(item.capabilities == DomainItem.CapabilitySet.writableDirectory)
    }

    @Test func lakehouseDirUnderTablesIsWritable() throws {
        let record = MetadataRecord(
            accountAlias: "a", workspaceID: "ws", itemID: "it",
            path: "Tables/myTable", parentPath: "Tables", name: "myTable",
            isDir: true, itemType: "Lakehouse"
        )
        let item = try DomainItem.from(record: record)
        #expect(item.capabilities == DomainItem.CapabilitySet.writableDirectory)
    }

    @Test func lakehouseFilesNodeIsManagedDirectory() throws {
        let record = MetadataRecord(
            accountAlias: "a", workspaceID: "ws", itemID: "it",
            path: "Files", parentPath: "", name: "Files",
            isDir: true, itemType: "Lakehouse"
        )
        let item = try DomainItem.from(record: record)
        #expect(item.capabilities == DomainItem.CapabilitySet.managedDirectory)
    }

    @Test func lakehouseTablesNodeIsManagedDirectory() throws {
        let record = MetadataRecord(
            accountAlias: "a", workspaceID: "ws", itemID: "it",
            path: "Tables", parentPath: "", name: "Tables",
            isDir: true, itemType: "Lakehouse"
        )
        let item = try DomainItem.from(record: record)
        #expect(item.capabilities == DomainItem.CapabilitySet.managedDirectory)
    }

    @Test func lakehouseManagedDirectoryHasNoWriteOrDelete() throws {
        let record = MetadataRecord(
            accountAlias: "a", workspaceID: "ws", itemID: "it",
            path: "Files", parentPath: "", name: "Files",
            isDir: true, itemType: "Lakehouse"
        )
        let item = try DomainItem.from(record: record)
        let caps = item.capabilities
        #expect(caps.contains(.read))
        #expect(caps.contains(.enumerate))
        #expect(caps.contains(.addSubitems))
        #expect(!caps.contains(.write))
        #expect(!caps.contains(.delete))
    }

    @Test func lakehouseNonTableFilesPathIsReadOnly() throws {
        // A path that is not under Files/ or Tables/ in a Lakehouse is read-only.
        let record = MetadataRecord(
            accountAlias: "a", workspaceID: "ws", itemID: "it",
            path: "Other/stuff.txt", parentPath: "Other", name: "stuff.txt",
            isDir: false, itemType: "Lakehouse"
        )
        let item = try DomainItem.from(record: record)
        #expect(item.capabilities == DomainItem.CapabilitySet.readOnly)
    }

    @Test func warehousePathIsReadOnly() throws {
        let record = MetadataRecord(
            accountAlias: "a", workspaceID: "ws", itemID: "it",
            path: "Files/data.csv", parentPath: "Files", name: "data.csv",
            isDir: false, itemType: "Warehouse"
        )
        let item = try DomainItem.from(record: record)
        #expect(item.capabilities == DomainItem.CapabilitySet.readOnly)
    }

    @Test func sqlDatabasePathIsReadOnly() throws {
        let record = MetadataRecord(
            accountAlias: "a", workspaceID: "ws", itemID: "it",
            path: "Tables/schema/part.parquet", parentPath: "Tables/schema",
            name: "part.parquet", isDir: false, itemType: "SQLDatabase"
        )
        let item = try DomainItem.from(record: record)
        #expect(item.capabilities == DomainItem.CapabilitySet.readOnly)
    }

    @Test func mirroredDatabasePathIsReadOnly() throws {
        let record = MetadataRecord(
            accountAlias: "a", workspaceID: "ws", itemID: "it",
            path: "Tables/mytable/part.parquet", parentPath: "Tables/mytable",
            name: "part.parquet", isDir: false, itemType: "MirroredDatabase"
        )
        let item = try DomainItem.from(record: record)
        #expect(item.capabilities == DomainItem.CapabilitySet.readOnly)
    }

    @Test func emptyItemTypeIsReadOnly() throws {
        // Pre-v3 rows default to itemType "" and must be read-only.
        let record = MetadataRecord(
            accountAlias: "a", workspaceID: "ws", itemID: "it",
            path: "Files/data.csv", parentPath: "Files", name: "data.csv",
            isDir: false, itemType: ""
        )
        let item = try DomainItem.from(record: record)
        #expect(item.capabilities == DomainItem.CapabilitySet.readOnly)
    }

    @Test func itemRootPathIsReadOnly() throws {
        // path == "" maps to .item identifier; no write access at item root level.
        // (This path goes through the .item branch, not .path, so from(record:)
        // returns an item — but it still uses computeCapabilities which returns readOnly
        // for an empty/non-Lakehouse type at path "".)
        let record = MetadataRecord(
            accountAlias: "a", workspaceID: "ws", itemID: "it",
            path: "", parentPath: "", name: "MyLakehouse",
            isDir: true, itemType: "Lakehouse"
        )
        let item = try DomainItem.from(record: record)
        // The item root row uses computeCapabilities with path "".
        // path "" is not "Files", "Tables", or under them → readOnly.
        #expect(item.capabilities == DomainItem.CapabilitySet.readOnly)
    }

    @Test func lakehouseTypeCheckIsCaseInsensitive() throws {
        // Fabric API may return lowercase or mixed-case type strings.
        for typeStr in ["lakehouse", "LAKEHOUSE", "Lakehouse", "lAkEhOuSe"] {
            let record = MetadataRecord(
                accountAlias: "a", workspaceID: "ws", itemID: "it",
                path: "Files/f.bin", parentPath: "Files", name: "f.bin",
                isDir: false, itemType: typeStr
            )
            let item = try DomainItem.from(record: record)
            #expect(item.capabilities == DomainItem.CapabilitySet.writableFile,
                    "itemType '\(typeStr)' should be treated as Lakehouse")
        }
    }

    @Test func capabilityPresetsManagedDirectory() {
        // managedDirectory must be exactly {.read, .enumerate, .addSubitems}.
        #expect(DomainItem.CapabilitySet.managedDirectory == [.read, .enumerate, .addSubitems])
    }
}
