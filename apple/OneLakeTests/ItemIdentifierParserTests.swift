// ItemIdentifierParserTests.swift
// Smoke-level logic tests for the File Provider identifier grammar.
//
// This bundle compiles BridgeItemIdentifierParser.swift (the FPE target's
// legacy flat-format identifier parser) and apple/Shared directly (no
// host application), so it runs unsigned in CI with no signing identity.
// Its job is to catch Swift compile regressions and the most basic
// identifier-grammar mistakes on every PR.
//
// Note: OfemKit's ItemIdentifierParser (the / -prefixed new format) is
// covered by apple/Packages/OfemKit/Tests/OfemKitTests/FP/.

import FileProvider
import XCTest

final class ItemIdentifierParserTests: XCTestCase {
    /// Every scope the FPE can address must survive a
    /// bridgeIdentifier → parse round-trip unchanged.
    func testRoundTripAddressableScopes() throws {
        let scopes: [EnumScope] = [
            .rootContainer,
            .workspace(workspaceId: "ws-123"),
            .itemRoot(workspaceId: "ws-123", itemId: "item-456"),
            .itemPath(workspaceId: "ws-123", itemId: "item-456", path: "Files/sub/data.csv"),
        ]
        for scope in scopes {
            let id = BridgeItemIdentifierParser.bridgeIdentifier(for: scope)
            let parsed = try BridgeItemIdentifierParser.parse(NSFileProviderItemIdentifier(id))
            XCTAssertEqual(parsed, scope, "round-trip mismatch for \(scope)")
        }
    }

    /// A path inside an item keeps every slash past the second segment
    /// verbatim — only the workspace and item GUIDs are peeled off.
    func testPathPreservesInteriorSlashes() throws {
        let parsed = try BridgeItemIdentifierParser.parse(NSFileProviderItemIdentifier("ws/item/a/b/c.txt"))
        XCTAssertEqual(parsed, .itemPath(workspaceId: "ws", itemId: "item", path: "a/b/c.txt"))
    }

    /// The three well-known Apple constants and the empty string all map
    /// to typed scopes the enumerator can pattern-match on.
    func testWellKnownConstantsAndEmpty() throws {
        XCTAssertEqual(try BridgeItemIdentifierParser.parse(.rootContainer), .rootContainer)
        XCTAssertEqual(try BridgeItemIdentifierParser.parse(.workingSet), .workingSet)
        XCTAssertEqual(try BridgeItemIdentifierParser.parse(.trashContainer), .trashContainer)
        XCTAssertEqual(try BridgeItemIdentifierParser.parse(NSFileProviderItemIdentifier("")), .rootContainer)
    }

    /// A leading or interior empty GUID segment is malformed and must be
    /// rejected so callers can surface NSFileProviderError(.noSuchItem).
    func testRejectsEmptyGUIDSegments() {
        XCTAssertThrowsError(try BridgeItemIdentifierParser.parse(NSFileProviderItemIdentifier("/item")))
        XCTAssertThrowsError(try BridgeItemIdentifierParser.parse(NSFileProviderItemIdentifier("ws//item")))
    }

    /// A trailing slash on an identifier that only has two segments (ws/item/)
    /// must be treated as a malformed path (empty tail component) and rejected.
    func testRejectsTrailingSlashOnTwoSegmentIdentifier() {
        // "ws/item/" splits into ["ws", "item", ""] — the empty path segment
        // is invalid and must throw rather than silently produce
        // .itemPath(workspaceId:itemId:path:"").
        XCTAssertThrowsError(try BridgeItemIdentifierParser.parse(NSFileProviderItemIdentifier("ws/item/")))
    }

    /// Identifiers with more than three slash-delimited components keep all
    /// segments past the second as-is (the path can contain slashes) and the
    /// tail must never be empty.
    func testMoreThanThreeSegmentsWithNonEmptyTail() throws {
        // Four components: workspace / item / folder / file
        let parsed = try BridgeItemIdentifierParser.parse(
            NSFileProviderItemIdentifier("ws-a/item-b/folder/nested.parquet")
        )
        XCTAssertEqual(
            parsed,
            .itemPath(workspaceId: "ws-a", itemId: "item-b", path: "folder/nested.parquet")
        )
    }
}
