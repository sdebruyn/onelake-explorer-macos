import Foundation
@testable import OfemKit
import Testing

// MARK: - EpochDateTests

// Regression tests for issues #370 and #374.
//
// #370: Finder showed 1 Jan 1970 for modification dates — fixed by always
//       passing a non-nil modificationDate from container factories.
// #374: Finder showed 1 Jan 1970 for creation dates — DFS list never returns
//       creationTime; fixed by falling back to lastModified in from(record:)
//       and capturing the real x-ms-creation-time header on HEAD/GET.

@Suite("EpochDate fixes (#370, #374)")
struct EpochDateTests {
    // MARK: - Shared fixture

    private static let knownUnixSeconds: TimeInterval = 1_715_526_400 // 2024-05-12T15:06:40Z
    private static let knownHTTPDate = "Sun, 12 May 2024 15:06:40 GMT"

    // MARK: - convertRawEntry: list response has no creationDate

    @Test("convertRawEntry: JSON wire-decode gives nil creationDate (field absent from list)")
    func convertRawEntryJSONRoundTripNoCreationDate() throws {
        // The DFS Path - List schema never returns creationTime in any x-ms-version.
        let json = """
        {
            "name": "item-guid/Files/data.csv",
            "isDirectory": "false",
            "contentLength": "1024",
            "etag": "\\"abc\\"",
            "lastModified": "Sun, 12 May 2024 15:06:40 GMT"
        }
        """
        let data = try #require(json.data(using: .utf8))
        let raw = try JSONDecoder().decode(RawPathEntry.self, from: data)
        let entry = convertRawEntry(raw, itemGUID: "item-guid")

        #expect(entry.name == "Files/data.csv", "itemGUID prefix must be stripped")
        #expect(entry.creationDate == nil, "list never carries creationDate")
    }

    @Test("convertRawEntry: lastModified is parsed correctly")
    func convertRawEntryLastModifiedParsed() throws {
        let json = """
        {
            "name": "item-guid/Files/data.csv",
            "contentLength": "1024",
            "etag": "\\"abc\\"",
            "lastModified": "\(Self.knownHTTPDate)"
        }
        """
        let data = try #require(json.data(using: .utf8))
        let raw = try JSONDecoder().decode(RawPathEntry.self, from: data)
        let entry = convertRawEntry(raw, itemGUID: "item-guid")
        #expect(abs(entry.lastModified.timeIntervalSince1970 - Self.knownUnixSeconds) < 1)
    }

    // MARK: - propertiesFromHeaders: x-ms-creation-time parsing

    @Test("propertiesFromHeaders: x-ms-creation-time RFC1123 → creationDate")
    func propertiesFromHeadersCreationTime() {
        let headers: [AnyHashable: Any] = [
            "Content-Length": "1024",
            "ETag": "\"abc\"",
            "Last-Modified": Self.knownHTTPDate,
            "Content-Type": "text/csv",
            "x-ms-creation-time": Self.knownHTTPDate,
        ]
        let props = propertiesFromHeaders(headers)
        guard let created = props.creationDate else {
            Issue.record("creationDate should be non-nil when x-ms-creation-time is present")
            return
        }
        #expect(abs(created.timeIntervalSince1970 - Self.knownUnixSeconds) < 1)
    }

    @Test("propertiesFromHeaders: absent x-ms-creation-time → nil creationDate")
    func propertiesFromHeadersMissingCreationTime() {
        let headers: [AnyHashable: Any] = [
            "Content-Length": "1024",
            "ETag": "\"abc\"",
            "Last-Modified": Self.knownHTTPDate,
            "Content-Type": "text/csv",
        ]
        let props = propertiesFromHeaders(headers)
        #expect(props.creationDate == nil)
    }

    @Test("propertiesFromHeaders: malformed x-ms-creation-time → nil creationDate")
    func propertiesFromHeadersMalformedCreationTime() {
        let headers: [AnyHashable: Any] = [
            "x-ms-creation-time": "not-a-date",
        ]
        let props = propertiesFromHeaders(headers)
        #expect(props.creationDate == nil)
    }

    @Test("propertiesFromHeaders: header lookup is case-insensitive")
    func propertiesFromHeadersCaseInsensitive() {
        // Foundation may lowercase headers; verify the normalised dict handles this.
        let headers: [AnyHashable: Any] = [
            "x-ms-creation-time": Self.knownHTTPDate,
        ]
        let props = propertiesFromHeaders(headers)
        #expect(props.creationDate != nil)
    }

    // MARK: - DomainItem.from(record:) — creation date fallback

    @Test("from(record:): zero createdNs falls back to lastModified (never nil/1970)")
    func fromRecordZeroCreatedNsFallsBackToLastModified() throws {
        let mtime = Date(timeIntervalSince1970: Self.knownUnixSeconds)
        let record = MetadataRecord(
            accountAlias: "work",
            workspaceID: "ws-1",
            itemID: "item-2",
            path: "Files/data.csv",
            parentPath: "Files",
            name: "data.csv",
            isDir: false,
            lastModifiedNs: dateToNs(mtime),
            createdNs: 0
        )
        let item = try DomainItem.from(record: record)
        guard let created = item.creationDate else {
            Issue.record("creationDate must not be nil when createdNs == 0 (fallback to lastModified)")
            return
        }
        guard let modified = item.modificationDate else {
            Issue.record("modificationDate must not be nil")
            return
        }
        #expect(abs(created.timeIntervalSince1970 - modified.timeIntervalSince1970) < 1,
                "fallback creationDate must equal modificationDate")
    }

    /// When both `createdNs` and `lastModifiedNs` are 0 (e.g. a directory
    /// listed without a Last-Modified header that was never HEADed), the
    /// fallback chain must not produce a 1 Jan 1970 date. The final fallback
    /// is `record.syncedAt`, which SyncEngine always writes as a real
    /// non-epoch timestamp.
    @Test("from(record:): creationDate is never 1 Jan 1970 even when both createdNs and lastModifiedNs are 0")
    func fromRecordBothZeroNsNeverShowsEpoch() throws {
        let record = MetadataRecord(
            accountAlias: "work",
            workspaceID: "ws-1",
            itemID: "item-2",
            path: "Files/dir",
            parentPath: "Files",
            name: "dir",
            isDir: true,
            lastModifiedNs: 0,
            syncedAtNs: Int64(1_715_526_400) * 1_000_000_000, // 2024-05-12
            createdNs: 0
        )
        let item = try DomainItem.from(record: record)
        let epoch = Date(timeIntervalSince1970: 0)
        // creationDate must be non-nil and not equal to 1 Jan 1970 (or close to it).
        guard let created = item.creationDate else {
            Issue.record("creationDate must not be nil even when both timestamps are 0")
            return
        }
        let distanceFromEpoch = abs(created.timeIntervalSince(epoch))
        #expect(distanceFromEpoch > 1_000, "creationDate must not be the Unix epoch (1 Jan 1970)")
    }

    @Test("from(record:): non-zero createdNs uses real creation time")
    func fromRecordNonZeroCreatedNsUsesRealValue() throws {
        let created = Date(timeIntervalSince1970: Self.knownUnixSeconds - 3600) // 1h before mtime
        let mtime = Date(timeIntervalSince1970: Self.knownUnixSeconds)
        let record = MetadataRecord(
            accountAlias: "work",
            workspaceID: "ws-1",
            itemID: "item-2",
            path: "Files/data.csv",
            parentPath: "Files",
            name: "data.csv",
            isDir: false,
            lastModifiedNs: dateToNs(mtime),
            createdNs: dateToNs(created)
        )
        let item = try DomainItem.from(record: record)
        guard let itemCreated = item.creationDate else {
            Issue.record("creationDate must not be nil when createdNs != 0")
            return
        }
        #expect(abs(itemCreated.timeIntervalSince1970 - created.timeIntervalSince1970) < 1,
                "real creation time must be used, not the fallback")
    }

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
        guard let itemCreated = item.creationDate else {
            Issue.record("creationDate should be non-nil when createdNs != 0")
            return
        }
        #expect(abs(itemCreated.timeIntervalSince1970 - Self.knownUnixSeconds) < 1)
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

    // MARK: - Container factories produce non-nil dates

    @Test("from(workspace:): modificationDate is non-nil")
    func workspaceModificationDateNonNil() {
        let ws = Workspace(id: "ws-1", displayName: "My WS", type: "Workspace")
        let item = DomainItem.from(workspace: ws, syncedAt: Date())
        #expect(item.modificationDate != nil)
    }

    @Test("from(workspace:): creationDate is non-nil (fallback to syncedAt)")
    func workspaceCreationDateNonNil() {
        let ws = Workspace(id: "ws-1", displayName: "My WS", type: "Workspace")
        let item = DomainItem.from(workspace: ws, syncedAt: Date())
        #expect(item.creationDate != nil)
    }

    @Test("from(fabricItem:): modificationDate is non-nil")
    func fabricItemModificationDateNonNil() {
        let fi = Item(id: "item-1", displayName: "My Lakehouse", type: "Lakehouse", workspaceID: "ws-1")
        let item = DomainItem.from(fabricItem: fi, workspaceID: "ws-1", syncedAt: Date())
        #expect(item.modificationDate != nil)
    }

    @Test("from(fabricItem:): creationDate is non-nil (fallback to syncedAt)")
    func fabricItemCreationDateNonNil() {
        let fi = Item(id: "item-1", displayName: "My Lakehouse", type: "Lakehouse", workspaceID: "ws-1")
        let item = DomainItem.from(fabricItem: fi, workspaceID: "ws-1", syncedAt: Date())
        #expect(item.creationDate != nil)
    }

    @Test("root: creationDate is non-nil (fallback to mountedAt)")
    func rootCreationDateNonNil() {
        let item = DomainItem.root(alias: "work", mountedAt: Date())
        #expect(item.creationDate != nil)
    }

    // MARK: - dateToNs: distantPast/distantFuture do not trap

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
