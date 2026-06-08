import Testing
import Foundation
@testable import OfemKit

// MARK: - Enumerator helper tests

/// Tests for the stateless ``Enumerator`` helper functions.
///
/// Mirrors `internal/sync/enumerate_test.go`.
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
}
