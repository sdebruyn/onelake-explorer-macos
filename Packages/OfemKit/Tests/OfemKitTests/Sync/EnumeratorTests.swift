import Foundation
@testable import OfemKit
import Testing

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
        (0 ..< count).map { i in
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

    // isDir: false is explicit — the guard added in #378 suppresses these
    // comparisons for directories; these tests must remain file-specific.
    @Test func entryChangedContentLengthChange() {
        let current = makeRecord(isDir: false, contentLength: 100)
        let next = makeRecord(isDir: false, contentLength: 200)
        #expect(Enumerator.entryChanged(current: current, next: next))
    }

    @Test func entryChangedEtagChange() {
        let current = makeRecord(isDir: false, etag: "abc")
        let next = makeRecord(isDir: false, etag: "def")
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

    // MARK: - entryChanged: createdNs backfill (issue-370)

    /// After the v5 migration all existing rows have created_ns = 0.  The first
    /// sync after upgrade produces a PathEntry whose creationDate is non-nil.
    /// entryChanged must return true in that case so the row is re-upserted and
    /// the creation timestamp is written into the cache.
    @Test func entryChangedCreatedNsBackfillFromZero() {
        var current = makeRecord()
        var next = makeRecord()
        current.createdNs = 0
        next.createdNs = 1_715_526_400_000_000_000
        #expect(Enumerator.entryChanged(current: current, next: next),
                "must detect backfill when current.createdNs == 0 and next.createdNs != 0")
    }

    /// Once backfilled, a subsequent poll with the same createdNs must not
    /// produce a spurious update.
    @Test func entryChangedCreatedNsUnchangedReturnsFalse() {
        var current = makeRecord()
        var next = makeRecord()
        current.createdNs = 1_715_526_400_000_000_000
        next.createdNs = 1_715_526_400_000_000_000
        #expect(!Enumerator.entryChanged(current: current, next: next),
                "must not produce phantom update when createdNs is unchanged")
    }

    /// next.createdNs == 0 means the server returned no creation time; the row
    /// must not be dirtied in that case (rule: only write when next.createdNs != 0).
    @Test func entryChangedNextCreatedNsZeroReturnsFalse() {
        var current = makeRecord()
        var next = makeRecord()
        current.createdNs = 0
        next.createdNs = 0
        #expect(!Enumerator.entryChanged(current: current, next: next),
                "must not dirty the row when the server returns no creation time")
    }

    /// Phantom-delta guard (issue #374 / quiescentBackendProducesZeroDeltas):
    /// when both current and next have a non-zero createdNs that differ — e.g.
    /// because successive polls derive createdNs from different sources (the
    /// modified-date fallback vs a later x-ms-creation-time header) — entryChanged
    /// must return FALSE. Allowing non-zero → different-non-zero to fire would
    /// produce a phantom diff.updated on every poll, pegging the working-set signal
    /// even when nothing on the backend has changed.
    @Test func entryChangedNonZeroToNonZeroDifferentCreatedNsReturnsFalse() {
        var current = makeRecord()
        var next = makeRecord()
        current.createdNs = 1_715_526_400_000_000_000
        next.createdNs = 1_715_526_400_000_000_001 // different non-zero
        #expect(!Enumerator.entryChanged(current: current, next: next),
                "non-zero → different-non-zero createdNs must NOT trigger an update (phantom-delta guard)")
    }

    /// Sanity: a real content change (etag) still fires even when createdNs is stable.
    @Test func entryChangedRealChangeStillFiresWhenCreatedNsStable() {
        var current = makeRecord(etag: "v1")
        var next = makeRecord(etag: "v2")
        current.createdNs = 1_715_526_400_000_000_000
        next.createdNs = 1_715_526_400_000_000_000
        #expect(Enumerator.entryChanged(current: current, next: next),
                "real content change (etag) must still trigger an update")
    }

    // MARK: - entryChanged: directory metadata noise guard (issue #378)

    /// Since DFS API version 2023-11-03, directory list entries carry a non-empty
    /// etag that advances with lastModified on any descendant write.  A directory
    /// whose only change from the cached record is the etag must NOT produce a
    /// phantom diff.updated (the "directory metadata is noise" invariant from #361).
    @Test func entryChangedDirectoryEtagOnlyChangeReturnsFalse() {
        let current = makeRecord(isDir: true, etag: "etag-before")
        let next = makeRecord(isDir: true, etag: "etag-after")
        #expect(!Enumerator.entryChanged(current: current, next: next),
                "directory etag-only change must not produce a phantom diff.updated")
    }

    /// Defensive: directories always report contentLength 0, but if the value
    /// somehow drifts the comparison must still be suppressed for directories.
    @Test func entryChangedDirectoryContentLengthOnlyChangeReturnsFalse() {
        let current = makeRecord(isDir: true, contentLength: 0)
        let next = makeRecord(isDir: true, contentLength: 4096)
        #expect(!Enumerator.entryChanged(current: current, next: next),
                "directory contentLength-only change must not produce a phantom diff.updated")
    }

    /// Guard against over-broad regression: a file whose etag changes must still
    /// be detected as changed.
    @Test func entryChangedFileEtagChangeReturnsTrue() {
        let current = makeRecord(isDir: false, etag: "etag-v1")
        let next = makeRecord(isDir: false, etag: "etag-v2")
        #expect(Enumerator.entryChanged(current: current, next: next),
                "file etag change must still trigger an update")
    }

    /// Regression anchor for #361: a directory whose only change is lastModifiedNs
    /// must not trigger a diff (the original phantom-delta guard).
    @Test func entryChangedDirectoryLastModifiedOnlyChangeReturnsFalse() {
        let current = makeRecord(isDir: true, lastModifiedNs: 1_000_000)
        let next = makeRecord(isDir: true, lastModifiedNs: 2_000_000)
        #expect(!Enumerator.entryChanged(current: current, next: next),
                "directory lastModifiedNs-only change must not produce a phantom diff.updated")
    }

    /// Directories are never HEAD/GET'd so their createdNs is always zero from
    /// the list response; the one-way backfill trigger must be suppressed for
    /// directories to close the latent phantom-delta vector.
    @Test func entryChangedDirectoryCreatedNsZeroToNonZeroReturnsFalse() {
        var current = makeRecord(isDir: true)
        var next = makeRecord(isDir: true)
        current.createdNs = 0
        next.createdNs = 1_715_526_400_000_000_000
        #expect(!Enumerator.entryChanged(current: current, next: next),
                "directory createdNs backfill trigger must not fire — directories never receive a real creation time")
    }

    /// Sanity: the file createdNs backfill trigger must still fire for files.
    @Test func entryChangedFileCreatedNsZeroToNonZeroReturnsTrue() {
        var current = makeRecord(isDir: false)
        var next = makeRecord(isDir: false)
        current.createdNs = 0
        next.createdNs = 1_715_526_400_000_000_000
        #expect(Enumerator.entryChanged(current: current, next: next),
                "file createdNs backfill trigger must still fire")
    }
}
