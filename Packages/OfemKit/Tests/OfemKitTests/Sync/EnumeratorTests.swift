import Testing
import Foundation
@testable import OfemKit

// MARK: - Enumerator helper tests

/// Tests for the stateless ``Enumerator`` helper functions.
struct EnumeratorTests {

    // MARK: - stripItemPrefix

    @Test func stripItemPrefixBasicMatch() {
        let result = Enumerator.stripItemPrefix(name: "/item-1/Files/report.csv", itemGUID: "item-1")
        #expect(result == "Files/report.csv")
    }

    @Test func stripItemPrefixRootOfItem() {
        let result = Enumerator.stripItemPrefix(name: "/item-1", itemGUID: "item-1")
        #expect(result == "")
    }

    @Test func stripItemPrefixRootOfItemWithTrailingSlash() {
        let result = Enumerator.stripItemPrefix(name: "/item-1/", itemGUID: "item-1")
        #expect(result == "")
    }

    @Test func stripItemPrefixWrongItem() {
        let result = Enumerator.stripItemPrefix(name: "/other-item/Files/report.csv", itemGUID: "item-1")
        #expect(result == nil)
    }

    @Test func stripItemPrefixNoLeadingSlash() {
        let result = Enumerator.stripItemPrefix(name: "item-1/Files/report.csv", itemGUID: "item-1")
        #expect(result == "Files/report.csv")
    }

    // MARK: - isDirectChild

    @Test func isDirectChildAtRoot() {
        #expect(Enumerator.isDirectChild(parent: "", child: "Files"))
    }

    @Test func isDirectChildNotAtRootRejectsDeepChild() {
        // "Files/sub" has depth 2 from root, not a direct child of root.
        #expect(!Enumerator.isDirectChild(parent: "", child: "Files/sub"))
    }

    @Test func isDirectChildOneLevel() {
        #expect(Enumerator.isDirectChild(parent: "Files", child: "Files/report.csv"))
    }

    @Test func isDirectChildTwoLevelsDeep() {
        // "Files/a/b.txt" is NOT a direct child of "Files".
        #expect(!Enumerator.isDirectChild(parent: "Files", child: "Files/a/b.txt"))
    }

    @Test func isDirectChildWrongParent() {
        #expect(!Enumerator.isDirectChild(parent: "Tables", child: "Files/report.csv"))
    }

    @Test func isDirectChildEmptyChild() {
        #expect(!Enumerator.isDirectChild(parent: "", child: ""))
    }

    // MARK: - parentPath

    @Test func parentPathRootPath() {
        #expect(Enumerator.parentPath("Files") == "")
    }

    @Test func parentPathOneLevel() {
        #expect(Enumerator.parentPath("Files/report.csv") == "Files")
    }

    @Test func parentPathTwoLevels() {
        #expect(Enumerator.parentPath("Files/a/b.txt") == "Files/a")
    }

    @Test func parentPathEmpty() {
        #expect(Enumerator.parentPath("") == "")
    }

    @Test func parentPathTrailingSlash() {
        #expect(Enumerator.parentPath("Files/a/") == "Files")
    }

    // MARK: - baseName

    @Test func baseNameWithSlash() {
        #expect(Enumerator.baseName("Files/report.csv") == "report.csv")
    }

    @Test func baseNameWithoutSlash() {
        #expect(Enumerator.baseName("Files") == "Files")
    }

    @Test func baseNameEmpty() {
        #expect(Enumerator.baseName("") == "")
    }

    // MARK: - page (cursor-based pagination)

    private func makeItems(count: Int) -> [DomainItem] {
        (0..<count).map { i in
            DomainItem.root(alias: "alias-\(i)")
        }
    }

    @Test func pageFirstPageNoCursor() throws {
        let items = makeItems(count: 10)
        let result = try Enumerator.page(items: items, cursor: nil)
        #expect(result.items.count == 10)
        #expect(result.nextCursor == nil)
    }

    @Test func pageFirstPageCursorAtStart() throws {
        let items = makeItems(count: 10)
        let result = try Enumerator.page(items: items, cursor: "")
        #expect(result.items.count == 10)
        #expect(result.nextCursor == nil)
    }

    @Test func pageCursorOffset() throws {
        let items = makeItems(count: 5)
        let cursor = Data("3".utf8).base64EncodedString()
        let result = try Enumerator.page(items: items, cursor: cursor)
        #expect(result.items.count == 2)
        #expect(result.nextCursor == nil)
    }

    @Test func pageReturnsNextCursorWhenMore() throws {
        let items = makeItems(count: enumeratePageSize + 1)
        let result = try Enumerator.page(items: items, cursor: nil)
        #expect(result.items.count == enumeratePageSize)
        #expect(result.nextCursor != nil)
    }

    @Test func pageInvalidCursorThrows() {
        let items = makeItems(count: 3)
        #expect(throws: (any Error).self) {
            try Enumerator.page(items: items, cursor: "not-base64!!!")
        }
    }

    // MARK: - isFresh (tests-17: deterministic via injectable clock)

    private func makeDir(childrenSyncedAt: Date?) -> MetadataRecord {
        MetadataRecord(
            accountAlias: "test",
            workspaceID: "ws",
            itemID: "item",
            path: "Files",
            parentPath: "",
            name: "Files",
            isDir: true,
            childrenSyncedAtNs: childrenSyncedAt.map { Int64($0.timeIntervalSince1970 * 1_000_000_000) } ?? 0
        )
    }

    @Test func isFreshNilChildrenSyncedAtIsAlwaysStale() {
        let record = makeDir(childrenSyncedAt: nil)
        #expect(!Enumerator.isFresh(record: record, ttl: 300))
    }

    @Test func isFreshWithinTTLReturnsFresh() {
        let anchor = Date(timeIntervalSince1970: 1_000_000)
        let record = makeDir(childrenSyncedAt: anchor)
        // "now" is 60 s after anchor, TTL = 300 s → still fresh.
        let now = anchor.addingTimeInterval(60)
        #expect(Enumerator.isFresh(record: record, ttl: 300, now: now))
    }

    @Test func isFreshExactlyAtTTLBoundaryReturnsFresh() {
        let anchor = Date(timeIntervalSince1970: 1_000_000)
        let record = makeDir(childrenSyncedAt: anchor)
        // "now" is exactly TTL seconds after anchor — boundary: still fresh.
        let now = anchor.addingTimeInterval(300)
        #expect(Enumerator.isFresh(record: record, ttl: 300, now: now))
    }

    @Test func isFreshOneSecondOverTTLReturnsStale() {
        let anchor = Date(timeIntervalSince1970: 1_000_000)
        let record = makeDir(childrenSyncedAt: anchor)
        // "now" is one second past TTL — stale.
        let now = anchor.addingTimeInterval(301)
        #expect(!Enumerator.isFresh(record: record, ttl: 300, now: now))
    }

    @Test func isFreshZeroTTLAlwaysStale() {
        let anchor = Date(timeIntervalSince1970: 1_000_000)
        let record = makeDir(childrenSyncedAt: anchor)
        // TTL = 0 and now is after anchor → stale.
        let now = anchor.addingTimeInterval(1)
        #expect(!Enumerator.isFresh(record: record, ttl: 0, now: now))
    }

    // MARK: - entryChanged (tests-17: diff predicate coverage)

    private func makeRecord(
        isDir: Bool = false,
        contentLength: Int64 = 100,
        etag: String = "abc",
        lastModifiedNs: Int64 = 1000,
        name: String = "file.txt",
        parentPath: String = "Files"
    ) -> MetadataRecord {
        MetadataRecord(
            accountAlias: "test",
            workspaceID: "ws",
            itemID: "item",
            path: "Files/file.txt",
            parentPath: parentPath,
            name: name,
            isDir: isDir,
            contentLength: contentLength,
            etag: etag,
            lastModifiedNs: lastModifiedNs
        )
    }

    @Test func entryChangedIdenticalRecordsReturnsFalse() {
        let r = makeRecord()
        #expect(!Enumerator.entryChanged(current: r, next: r))
    }

    @Test func entryChangedIsDirChange() {
        let current = makeRecord(isDir: false)
        let next = makeRecord(isDir: true)
        #expect(Enumerator.entryChanged(current: current, next: next))
    }

    @Test func entryChangedContentLengthChange() {
        let current = makeRecord(contentLength: 100)
        let next = makeRecord(contentLength: 200)
        #expect(Enumerator.entryChanged(current: current, next: next))
    }

    @Test func entryChangedEtagChange() {
        let current = makeRecord(etag: "abc")
        let next = makeRecord(etag: "def")
        #expect(Enumerator.entryChanged(current: current, next: next))
    }

    @Test func entryChangedLastModifiedChange() {
        let current = makeRecord(lastModifiedNs: 1000)
        let next = makeRecord(lastModifiedNs: 2000)
        #expect(Enumerator.entryChanged(current: current, next: next))
    }

    @Test func entryChangedNameChange() {
        let current = makeRecord(name: "old.txt")
        let next = makeRecord(name: "new.txt")
        #expect(Enumerator.entryChanged(current: current, next: next))
    }

    @Test func entryChangedParentPathChange() {
        let current = makeRecord(parentPath: "Files")
        let next = makeRecord(parentPath: "Tables")
        #expect(Enumerator.entryChanged(current: current, next: next))
    }
}
