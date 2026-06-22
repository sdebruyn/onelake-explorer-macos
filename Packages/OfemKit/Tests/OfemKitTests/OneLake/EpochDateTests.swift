import Foundation
@testable import OfemKit
import Testing

// MARK: - EpochDateTests

// Regression tests for issue #370: Finder showed 1 Jan 1970 for every item.
// Root causes:
// (a) creationDate was never parsed or stored — all items had nil creationDate.
// (b) Container items (workspace, Fabric item) had modificationDate == nil
//     because their DomainItem factories always passed mtime: nil.

@Suite("EpochDate fixes (#370)")
struct EpochDateTests {
    // MARK: - parseFileTime

    // A realistic FILETIME from a live DFS listing.
    // Ticks = 133_600_000_000_000_000 → (133600000000000000 - 116444736000000000) / 10000000
    //       = 17155264000000000 / 10000000 = 1715526400 Unix seconds
    //       = 2024-05-12T20:53:20Z
    private static let knownTicks: Int64 = 133_600_000_000_000_000
    private static let knownUnixSeconds: TimeInterval = 1_715_526_400

    @Test("parseFileTime: known ticks round-trips correctly")
    func parseFileTimeKnownTicks() {
        let s = String(Self.knownTicks)
        guard let date = parseFileTime(s) else {
            Issue.record("parseFileTime returned nil for valid ticks")
            return
        }
        #expect(abs(date.timeIntervalSince1970 - Self.knownUnixSeconds) < 1,
                "expected ~\(Self.knownUnixSeconds), got \(date.timeIntervalSince1970)")
    }

    @Test("parseFileTime: zero string returns nil")
    func parseFileTimeZeroReturnsNil() {
        #expect(parseFileTime("0") == nil)
    }

    @Test("parseFileTime: empty string returns nil")
    func parseFileTimeEmptyReturnsNil() {
        #expect(parseFileTime("") == nil)
    }

    @Test("parseFileTime: non-numeric returns nil")
    func parseFileTimeGarbageReturnsNil() {
        #expect(parseFileTime("not-a-number") == nil)
    }

    @Test("parseFileTime: negative ticks return nil (below Windows epoch)")
    func parseFileTimeNegativeReturnsNil() {
        #expect(parseFileTime("-1") == nil)
    }

    // MARK: - convertRawEntry: JSON wire-decode round-trip

    /// The original bug manifested on the wire-decode leg: creationTime arrived
    /// as a JSON string but was never decoded.  This test exercises the full
    /// JSONDecoder → RawPathEntry → convertRawEntry path using a realistic DFS
    /// list-response payload.
    @Test("convertRawEntry: JSON wire-decode round-trip preserves creationDate")
    func convertRawEntryJSONRoundTrip() throws {
        // A minimal but realistic DFS paths entry, matching the ADLS Gen2
        // list-path wire format.  The creationTime value maps to 2024-05-12.
        let json = """
        {
            "name": "item-guid/Files/data.csv",
            "isDirectory": "false",
            "contentLength": "1024",
            "etag": "\\"abc\\"",
            "lastModified": "Sun, 12 May 2024 20:53:20 GMT",
            "creationTime": "\(Self.knownTicks)"
        }
        """
        let data = try #require(json.data(using: .utf8))
        let raw = try JSONDecoder().decode(RawPathEntry.self, from: data)
        let entry = convertRawEntry(raw, itemGUID: "item-guid")

        #expect(entry.name == "Files/data.csv", "itemGUID prefix must be stripped")
        guard let created = entry.creationDate else {
            Issue.record("creationDate must not be nil after JSON wire decode")
            return
        }
        #expect(abs(created.timeIntervalSince1970 - Self.knownUnixSeconds) < 1,
                "JSON-decoded creationDate must match the expected Unix timestamp")
    }

    @Test("convertRawEntry: JSON wire-decode with absent creationTime gives nil creationDate")
    func convertRawEntryJSONRoundTripMissingCreationTime() throws {
        let json = """
        {
            "name": "item-guid/Files/data.csv",
            "contentLength": "1024",
            "etag": "\\"abc\\"",
            "lastModified": "Sun, 12 May 2024 20:53:20 GMT"
        }
        """
        let data = try #require(json.data(using: .utf8))
        let raw = try JSONDecoder().decode(RawPathEntry.self, from: data)
        let entry = convertRawEntry(raw, itemGUID: "item-guid")
        #expect(entry.creationDate == nil)
    }

    // MARK: - convertRawEntry creationDate

    @Test("convertRawEntry: parses creationTime into creationDate")
    func convertRawEntryParsesCreationTime() {
        let raw = RawPathEntry(
            name: "item-guid/Files/data.csv",
            isDirectory: nil,
            contentLength: "1024",
            etag: "\"abc\"",
            lastModified: "Sun, 12 May 2024 20:53:20 GMT",
            creationTime: String(Self.knownTicks)
        )
        let entry = convertRawEntry(raw, itemGUID: "item-guid")
        guard let created = entry.creationDate else {
            Issue.record("creationDate should not be nil for valid creationTime")
            return
        }
        #expect(abs(created.timeIntervalSince1970 - Self.knownUnixSeconds) < 1)
    }

    @Test("convertRawEntry: nil creationTime produces nil creationDate")
    func convertRawEntryNilCreationTime() {
        let raw = RawPathEntry(
            name: "item-guid/Files/data.csv",
            isDirectory: nil,
            contentLength: "1024",
            etag: "\"abc\"",
            lastModified: "Sun, 12 May 2024 20:53:20 GMT",
            creationTime: nil
        )
        let entry = convertRawEntry(raw, itemGUID: "item-guid")
        #expect(entry.creationDate == nil)
    }

    @Test("convertRawEntry: zero creationTime produces nil creationDate")
    func convertRawEntryZeroCreationTime() {
        let raw = RawPathEntry(
            name: "item-guid/Files/data.csv",
            isDirectory: nil,
            contentLength: "1024",
            etag: "\"abc\"",
            lastModified: "Sun, 12 May 2024 20:53:20 GMT",
            creationTime: "0"
        )
        let entry = convertRawEntry(raw, itemGUID: "item-guid")
        #expect(entry.creationDate == nil)
    }

    // MARK: - DomainItem.from(record:) — dates survive record round-trip

    @Test("from(record:): non-zero createdNs produces non-nil creationDate")
    func fromRecordCreationDatePresent() throws {
        let createdNs = dateToNs(Date(timeIntervalSince1970: Self.knownUnixSeconds))
        let record = MetadataRecord(
            accountAlias: "work",
            workspaceID: "ws-1",
            itemID: "item-2",
            path: "Files/data.csv",
            parentPath: "Files",
            name: "data.csv",
            isDir: false,
            lastModifiedNs: dateToNs(Date()),
            createdNs: createdNs
        )
        let item = try DomainItem.from(record: record)
        guard let created = item.creationDate else {
            Issue.record("creationDate should be non-nil when createdNs != 0")
            return
        }
        #expect(abs(created.timeIntervalSince1970 - Self.knownUnixSeconds) < 1)
    }

    @Test("from(record:): non-zero lastModifiedNs produces non-nil modificationDate")
    func fromRecordModificationDatePresent() throws {
        let record = MetadataRecord(
            accountAlias: "work",
            workspaceID: "ws-1",
            itemID: "item-2",
            path: "Files/data.csv",
            parentPath: "Files",
            name: "data.csv",
            isDir: false,
            lastModifiedNs: dateToNs(Date(timeIntervalSince1970: Self.knownUnixSeconds))
        )
        let item = try DomainItem.from(record: record)
        #expect(item.modificationDate != nil)
    }

    @Test("from(record:): zero createdNs gives nil creationDate")
    func fromRecordZeroCreatedNs() throws {
        let record = MetadataRecord(
            accountAlias: "work",
            workspaceID: "ws-1",
            itemID: "item-2",
            path: "Files/data.csv",
            parentPath: "Files",
            name: "data.csv",
            isDir: false,
            lastModifiedNs: dateToNs(Date()),
            createdNs: 0
        )
        let item = try DomainItem.from(record: record)
        #expect(item.creationDate == nil)
    }

    // MARK: - Container factories produce non-nil modificationDate

    @Test("from(workspace:): modificationDate is non-nil")
    func workspaceModificationDateNonNil() {
        let ws = Workspace(id: "ws-1", displayName: "My WS", type: "Workspace")
        let item = DomainItem.from(workspace: ws, syncedAt: Date())
        #expect(item.modificationDate != nil)
    }

    @Test("from(fabricItem:): modificationDate is non-nil")
    func fabricItemModificationDateNonNil() {
        let fi = Item(id: "item-1", displayName: "My Lakehouse", type: "Lakehouse", workspaceID: "ws-1")
        let item = DomainItem.from(fabricItem: fi, workspaceID: "ws-1", syncedAt: Date())
        #expect(item.modificationDate != nil)
    }

    // MARK: - dateToNs: distantPast does not trap

    @Test("dateToNs: distantPast returns 0 (no overflow)")
    func dateToNsDistantPastDoesNotTrap() {
        let result = dateToNs(.distantPast)
        #expect(result == 0)
    }

    @Test("dateToNs: distantFuture returns 0 (no overflow)")
    func dateToNsDistantFutureDoesNotTrap() {
        let result = dateToNs(.distantFuture)
        #expect(result == 0)
    }
}
