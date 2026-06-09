import Testing
@testable import OfemKit

// MARK: - ItemIdentifierParser tests

/// Tests for ``ItemIdentifierParser`` — parsing opaque identifier strings that
/// the FPE stores / retrieves via `NSFileProviderItemIdentifier`.
struct ItemIdentifierParserTests {

    // MARK: - Root

    @Test func parsesRootContainer() throws {
        let id = try ItemIdentifierParser.parse(ItemIdentifier.rootContainerString)
        #expect(id == .root)
    }

    // MARK: - Valid paths

    @Test func parsesWorkspaceSegment() throws {
        let id = try ItemIdentifierParser.parse("/ws-abc")
        #expect(id == .workspace(workspaceID: "ws-abc"))
    }

    @Test func parsesItemSegment() throws {
        let id = try ItemIdentifierParser.parse("/ws-abc/item-xyz")
        #expect(id == .item(workspaceID: "ws-abc", itemID: "item-xyz"))
    }

    @Test func parsesPathSegmentSingleComponent() throws {
        let id = try ItemIdentifierParser.parse("/ws-abc/item-xyz/Files")
        #expect(id == .path(workspaceID: "ws-abc", itemID: "item-xyz", path: "Files"))
    }

    @Test func parsesPathSegmentMultiComponent() throws {
        let id = try ItemIdentifierParser.parse("/ws-abc/item-xyz/Files/a/b/c.txt")
        #expect(id == .path(workspaceID: "ws-abc", itemID: "item-xyz", path: "Files/a/b/c.txt"))
    }

    // MARK: - Invalid inputs

    @Test func rejectsEmptyString() {
        #expect(throws: (any Error).self) {
            try ItemIdentifierParser.parse("")
        }
    }

    @Test func rejectsMissingLeadingSlash() {
        #expect(throws: (any Error).self) {
            try ItemIdentifierParser.parse("ws-abc/item-xyz")
        }
    }

    @Test func rejectsTrailingSlash() {
        #expect(throws: (any Error).self) {
            try ItemIdentifierParser.parse("/ws-abc/")
        }
    }

    @Test func rejectsEmptyWorkspaceSegment() {
        #expect(throws: (any Error).self) {
            try ItemIdentifierParser.parse("//item-xyz")
        }
    }

    @Test func rejectsEmptyItemSegment() {
        #expect(throws: (any Error).self) {
            try ItemIdentifierParser.parse("/ws-abc//Files")
        }
    }
}
