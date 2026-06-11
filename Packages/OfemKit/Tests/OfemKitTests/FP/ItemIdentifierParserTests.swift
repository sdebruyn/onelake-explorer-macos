import Testing
@testable import OfemKit

// MARK: - ItemIdentifierParser tests

/// Tests for ``ItemIdentifierParser`` — parsing opaque identifier strings that
/// the FPE stores / retrieves via `NSFileProviderItemIdentifier`.
struct ItemIdentifierParserTests {

    // MARK: - Root

    @Test func parsesRootContainerSentinel() throws {
        let id = try ItemIdentifierParser.parse(ItemIdentifier.rootContainerString)
        #expect(id == .root)
    }

    @Test func parsesEmptyStringAsRoot() throws {
        // The bridge also maps "" → .root; OfemKit must match.
        let id = try ItemIdentifierParser.parse("")
        #expect(id == .root)
    }

    @Test func parsesTrashContainerSentinel() throws {
        let id = try ItemIdentifierParser.parse(ItemIdentifier.trashContainerString)
        #expect(id == .trash)
    }

    @Test func parsesWorkingSetSentinel() throws {
        let id = try ItemIdentifierParser.parse(ItemIdentifier.workingSetString)
        #expect(id == .workingSet)
    }

    // MARK: - Valid paths

    @Test func parsesWorkspaceSegment() throws {
        let id = try ItemIdentifierParser.parse("ws-abc")
        #expect(id == .workspace(workspaceID: "ws-abc"))
    }

    @Test func parsesItemSegment() throws {
        let id = try ItemIdentifierParser.parse("ws-abc/item-xyz")
        #expect(id == .item(workspaceID: "ws-abc", itemID: "item-xyz"))
    }

    @Test func parsesPathSegmentSingleComponent() throws {
        let id = try ItemIdentifierParser.parse("ws-abc/item-xyz/Files")
        #expect(id == .path(workspaceID: "ws-abc", itemID: "item-xyz", path: "Files"))
    }

    @Test func parsesPathSegmentMultiComponent() throws {
        let id = try ItemIdentifierParser.parse("ws-abc/item-xyz/Files/a/b/c.txt")
        #expect(id == .path(workspaceID: "ws-abc", itemID: "item-xyz", path: "Files/a/b/c.txt"))
    }

    // MARK: - sync-13: trailing slash normalisation

    /// "ws/item/" must parse identically to "ws/item" (not produce a
    /// .path with an empty tail that compares unequal to .item).
    @Test func trailingSlashOnItemNormalisesToItem() throws {
        let withSlash = try ItemIdentifierParser.parse("ws-abc/item-xyz/")
        let withoutSlash = try ItemIdentifierParser.parse("ws-abc/item-xyz")
        #expect(withSlash == withoutSlash)
        #expect(withSlash == .item(workspaceID: "ws-abc", itemID: "item-xyz"))
    }

    // MARK: - sync-13: double slash rejection in path tail

    /// "ws/item//file" — empty path segment after the item GUID — must
    /// be rejected so callers surface noSuchItem instead of emitting a
    /// malformed double-slash DFS URL.
    @Test func rejectsDoubleSlashInsidePathTail() {
        #expect(throws: (any Error).self) {
            try ItemIdentifierParser.parse("ws-abc/item-xyz//file.csv")
        }
    }

    /// An empty path segment anywhere in the tail must be rejected.
    @Test func rejectsEmptyPathSegment() {
        #expect(throws: (any Error).self) {
            try ItemIdentifierParser.parse("ws-abc/item-xyz/a//b.csv")
        }
    }

    // MARK: - Invalid inputs

    @Test func rejectsLeadingSlash() {
        #expect(throws: (any Error).self) {
            try ItemIdentifierParser.parse("/ws-abc")
        }
    }

    @Test func rejectsEmptyWorkspaceSegment() {
        #expect(throws: (any Error).self) {
            try ItemIdentifierParser.parse("/item-xyz")
        }
    }

    @Test func rejectsEmptyItemSegment() {
        #expect(throws: (any Error).self) {
            try ItemIdentifierParser.parse("ws-abc//Files")
        }
    }
}
