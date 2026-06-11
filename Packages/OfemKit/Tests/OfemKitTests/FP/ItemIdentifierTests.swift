import Testing
@testable import OfemKit

// MARK: - ItemIdentifier tests

/// Tests for ``ItemIdentifier`` — round-trip through `identifierString` and
/// `parentIdentifier` derivation.
struct ItemIdentifierTests {

    // MARK: - Root

    @Test func rootHasKnownString() {
        let id = ItemIdentifier.root
        #expect(id.identifierString == ItemIdentifier.rootContainerString)
    }

    @Test func rootParentIsRoot() {
        #expect(ItemIdentifier.root.parentIdentifier == ItemIdentifier.root)
    }

    // MARK: - Workspace

    @Test func workspaceRoundTrip() throws {
        let id = ItemIdentifier.workspace(workspaceID: "ws-1")
        let reparsed = try ItemIdentifierParser.parse(id.identifierString)
        #expect(reparsed == id)
    }

    @Test func workspaceParentIsRoot() {
        let id = ItemIdentifier.workspace(workspaceID: "ws-1")
        #expect(id.parentIdentifier == ItemIdentifier.root)
    }

    // MARK: - Item (container)

    @Test func itemRoundTrip() throws {
        let id = ItemIdentifier.item(workspaceID: "ws-1", itemID: "item-2")
        let reparsed = try ItemIdentifierParser.parse(id.identifierString)
        #expect(reparsed == id)
    }

    @Test func itemParentIsWorkspace() {
        let id = ItemIdentifier.item(workspaceID: "ws-1", itemID: "item-2")
        #expect(id.parentIdentifier == ItemIdentifier.workspace(workspaceID: "ws-1"))
    }

    // MARK: - Path

    @Test func pathRoundTrip() throws {
        let id = ItemIdentifier.path(workspaceID: "ws-1", itemID: "item-2", path: "Files/report.csv")
        let reparsed = try ItemIdentifierParser.parse(id.identifierString)
        #expect(reparsed == id)
    }

    @Test func pathWithDeepNestedPath() throws {
        let id = ItemIdentifier.path(workspaceID: "ws-1", itemID: "item-2", path: "Files/a/b/c/d.txt")
        let reparsed = try ItemIdentifierParser.parse(id.identifierString)
        #expect(reparsed == id)
    }

    @Test func pathParentIsItem() {
        // A single-component path sits directly under the item.
        let id = ItemIdentifier.path(workspaceID: "ws-1", itemID: "item-2", path: "Files")
        #expect(id.parentIdentifier == ItemIdentifier.item(workspaceID: "ws-1", itemID: "item-2"))
    }

    @Test func pathWithSlashParentIsParentPath() {
        let id = ItemIdentifier.path(workspaceID: "ws-1", itemID: "item-2", path: "Files/a/b.txt")
        #expect(id.parentIdentifier == ItemIdentifier.path(workspaceID: "ws-1", itemID: "item-2", path: "Files/a"))
    }

    // MARK: - Equatable

    @Test func equatableDistinguishesKinds() {
        let ws = ItemIdentifier.workspace(workspaceID: "x")
        let item = ItemIdentifier.item(workspaceID: "x", itemID: "x")
        #expect(ws != item)
    }
}
