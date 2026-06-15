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
    //
    // Raw identifiers are slash-less: "ws", "ws/item", "ws/item/path...".

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

    @Test func rejectsTrailingSlash() {
        #expect(throws: (any Error).self) {
            try ItemIdentifierParser.parse("ws-abc/")
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

    // MARK: - fp-02: segment content validation (control chars, whitespace, backslash)

    @Test func rejectsNulByteInWorkspaceSegment() {
        // NUL byte inside a workspace GUID is a control character (U+0000).
        #expect(throws: (any Error).self) {
            try ItemIdentifierParser.parse("ws\0bad")
        }
    }

    @Test func rejectsNewlineInWorkspaceSegment() {
        // Newline (U+000A) is a control character.
        #expect(throws: (any Error).self) {
            try ItemIdentifierParser.parse("ws\ninjected")
        }
    }

    @Test func rejectsCrlfInItemSegment() {
        // CRLF inside an item ID would allow header injection when used in URLs.
        #expect(throws: (any Error).self) {
            try ItemIdentifierParser.parse("ws-abc/item\r\ninjected")
        }
    }

    @Test func rejectsBackslashInWorkspaceSegment() {
        // Backslash is a Windows path separator and is illegal inside any segment.
        #expect(throws: (any Error).self) {
            try ItemIdentifierParser.parse("ws\\backslash")
        }
    }

    @Test func rejectsBackslashInItemSegment() {
        #expect(throws: (any Error).self) {
            try ItemIdentifierParser.parse("ws-abc/item\\bad")
        }
    }

    @Test func rejectsBackslashInPathSegment() {
        #expect(throws: (any Error).self) {
            try ItemIdentifierParser.parse("ws-abc/item-xyz/Files\\bad.csv")
        }
    }

    @Test func rejectsLeadingWhitespaceInWorkspaceSegment() {
        // Leading space is canonically invalid — identifiers must not have whitespace.
        #expect(throws: (any Error).self) {
            try ItemIdentifierParser.parse(" ws-abc")
        }
    }

    @Test func rejectsTrailingWhitespaceInItemSegment() {
        #expect(throws: (any Error).self) {
            try ItemIdentifierParser.parse("ws-abc/item-xyz ")
        }
    }

    @Test func rejectsLeadingWhitespaceInPathComponent() {
        #expect(throws: (any Error).self) {
            try ItemIdentifierParser.parse("ws-abc/item-xyz/ Files/doc.txt")
        }
    }

    @Test func dotDotWithoutSlashIsAcceptedAsWorkspaceSegment() {
        // ".." does not contain a control character but the test verifies that
        // benign-looking traversal inputs that do not contain a slash are
        // currently accepted at the parser level (path safety is enforced by the
        // DFS client); this is a documentation test, not a rejection.
        // NOTE: ".." alone has no control chars/backslash/whitespace, so it is
        // NOT rejected by the content validator.  Callers must not trust that
        // segment content is semantically valid — only syntactically clean.
        let result = try? ItemIdentifierParser.parse("..")
        // Parser accepts it as a workspace segment (no control chars/whitespace).
        #expect(result == .workspace(workspaceID: ".."))
    }

    @Test func rejectsTabInPathSegment() {
        // Tab (U+0009) is ASCII whitespace and a control character.
        #expect(throws: (any Error).self) {
            try ItemIdentifierParser.parse("ws-abc/item-xyz/Files\t/doc.txt")
        }
    }

    @Test func rejectsDelCharInWorkspaceSegment() {
        // DEL (U+007F) is a control character.
        #expect(throws: (any Error).self) {
            try ItemIdentifierParser.parse("ws\u{7F}bad")
        }
    }

    @Test func acceptsGUIDFormattedSegments() throws {
        // Real workspace/item IDs are GUIDs — verify they still parse.
        let guid1 = "a1b2c3d4-e5f6-7890-abcd-ef1234567890"
        let guid2 = "b2c3d4e5-f6a7-8901-bcde-f12345678901"
        let id = try ItemIdentifierParser.parse("\(guid1)/\(guid2)/Files/report.csv")
        #expect(id == .path(workspaceID: guid1, itemID: guid2, path: "Files/report.csv"))
    }
}
