// FPEHelpersTests.swift
// Tests for FPEHelpers: cacheKey construction and parentPath arithmetic.

@preconcurrency import FileProvider
import Foundation
import OfemKit
import XCTest

final class FPEHelpersTests: XCTestCase {

    // MARK: - cacheKey (components variant)

    func testCacheKeyRoundTrip() {
        let key = cacheKey(alias: "work", workspaceID: "ws1", itemID: "item1", path: "Files/data.csv")
        XCTAssertEqual(key.accountAlias, "work")
        XCTAssertEqual(key.workspaceID, "ws1")
        XCTAssertEqual(key.itemID, "item1")
        XCTAssertEqual(key.path, "Files/data.csv")
    }

    func testCacheKeyEmptyPathForItemRoot() {
        let key = cacheKey(alias: "work", workspaceID: "ws", itemID: "item", path: "")
        XCTAssertEqual(key.path, "")
    }

    // MARK: - cacheKey (identifier variant)

    func testCacheKeyFromItemIdentifier() throws {
        let id = ItemIdentifier.item(workspaceID: "ws", itemID: "item")
        let key = try cacheKey(alias: "work", identifier: id)
        XCTAssertEqual(key.path, "")
        XCTAssertEqual(key.workspaceID, "ws")
        XCTAssertEqual(key.itemID, "item")
    }

    func testCacheKeyFromPathIdentifier() throws {
        let id = ItemIdentifier.path(workspaceID: "ws", itemID: "item", path: "a/b/c")
        let key = try cacheKey(alias: "work", identifier: id)
        XCTAssertEqual(key.path, "a/b/c")
    }

    func testCacheKeyFromRootIdentifierThrows() {
        XCTAssertThrowsError(try cacheKey(alias: "work", identifier: .root))
    }

    func testCacheKeyFromWorkspaceIdentifierThrows() {
        XCTAssertThrowsError(try cacheKey(alias: "work", identifier: .workspace(workspaceID: "ws")))
    }

    // MARK: - parentPath

    func testParentPathDeepFile() {
        XCTAssertEqual(parentPath(of: "Files/raw/2024/sales.csv"), "Files/raw/2024")
    }

    func testParentPathTopLevelFile() {
        XCTAssertEqual(parentPath(of: "Files"), "")
    }

    func testParentPathEmpty() {
        XCTAssertEqual(parentPath(of: ""), "")
    }

    func testParentPathSingleSlash() {
        XCTAssertEqual(parentPath(of: "a/b"), "a")
    }

    func testParentPathMultipleSegments() {
        XCTAssertEqual(parentPath(of: "a/b/c/d"), "a/b/c")
    }

    // MARK: - signallableContainer (CacheKey -> ItemIdentifier inverse)

    /// A folder inside an item maps to `.path`, and the identifier string
    /// round-trips through the parser back to the same identifier.
    func testSignallableContainerPathRoundTrips() throws {
        let key = CacheKey(accountAlias: "work", workspaceID: "ws", itemID: "item", path: "Tables/sales")
        let id = try XCTUnwrap(signallableContainer(for: key))
        XCTAssertEqual(id, .path(workspaceID: "ws", itemID: "item", path: "Tables/sales"))
        // Round-trips through identifierString + parser.
        let parsed = try ItemIdentifierParser.parse(id.identifierString)
        XCTAssertEqual(parsed, id)
    }

    /// An item root (empty path) maps to `.item`, round-tripping through the parser.
    func testSignallableContainerItemRootRoundTrips() throws {
        let key = CacheKey(accountAlias: "work", workspaceID: "ws", itemID: "item", path: "")
        let id = try XCTUnwrap(signallableContainer(for: key))
        XCTAssertEqual(id, .item(workspaceID: "ws", itemID: "item"))
        let parsed = try ItemIdentifierParser.parse(id.identifierString)
        XCTAssertEqual(parsed, id)
    }

    /// A per-workspace item listing (itemID == VirtualIDs.itemID) maps to
    /// `.workspace`, round-tripping through the parser. This is the container the
    /// discovery reconcile signals to clear a now-filtered item from Finder.
    func testSignallableContainerWorkspaceListingMapsToWorkspace() throws {
        let key = CacheKey(accountAlias: "work", workspaceID: "ws", itemID: VirtualIDs.itemID, path: "")
        let id = try XCTUnwrap(signallableContainer(for: key))
        XCTAssertEqual(id, .workspace(workspaceID: "ws"))
        let parsed = try ItemIdentifierParser.parse(id.identifierString)
        XCTAssertEqual(parsed, id)
    }

    /// The top-level workspaces listing maps to the root container, which must
    /// NOT be signalled (root stays remount-driven). Returns nil.
    func testSignallableContainerRootListingReturnsNil() {
        let key = CacheKey(
            accountAlias: "work",
            workspaceID: VirtualIDs.workspaceID,
            itemID: VirtualIDs.workspaceID,
            path: ""
        )
        XCTAssertNil(signallableContainer(for: key))
    }

    // MARK: - makeContainerChangeHandler (map + dispatch to signal)

    /// A change for a `.path` container dispatches `signal` with the matching
    /// identifier.
    func testHandlerSignalsCorrectIdentifierForPath() async throws {
        let recorder = SignalRecorder()
        let handler = makeContainerChangeHandler { id in recorder.record(id) }

        handler(CacheKey(accountAlias: "a", workspaceID: "ws", itemID: "item", path: "Tables"),
                Diff(added: 1))

        let signalled = await recorder.nextIdentifier()
        XCTAssertEqual(signalled, NSFileProviderItemIdentifier("ws/item/Tables"))
        XCTAssertEqual(recorder.count, 1)
    }

    /// A change for a workspace listing dispatches `signal` for the `.workspace`
    /// container identifier.
    func testHandlerSignalsWorkspaceForDiscoveryReconcile() async throws {
        let recorder = SignalRecorder()
        let handler = makeContainerChangeHandler { id in recorder.record(id) }

        handler(CacheKey(accountAlias: "a", workspaceID: "ws", itemID: VirtualIDs.itemID, path: ""),
                Diff(removed: 1))

        let signalled = await recorder.nextIdentifier()
        XCTAssertEqual(signalled, NSFileProviderItemIdentifier("ws"))
        XCTAssertEqual(recorder.count, 1)
    }

    /// A change for the root workspaces listing is skipped — no signal.
    func testHandlerSkipsRootContainer() async throws {
        let recorder = SignalRecorder()
        let handler = makeContainerChangeHandler { id in recorder.record(id) }

        handler(CacheKey(accountAlias: "a", workspaceID: VirtualIDs.workspaceID,
                         itemID: VirtualIDs.workspaceID, path: ""),
                Diff(added: 1))

        // The root key maps to nil, so the handler returns before spawning a
        // Task. Give any (erroneous) dispatch a chance to run, then assert none.
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(recorder.count, 0)
    }
}

// MARK: - SignalRecorder

/// Thread-safe async spy for the `signal` sink passed to
/// `makeContainerChangeHandler`.
///
/// `makeContainerChangeHandler` dispatches `signal` on a detached `Task`, so a
/// test cannot read `identifiers` immediately. `nextIdentifier()` awaits the
/// next recorded signal deterministically via an `AsyncStream`.
private final class SignalRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _identifiers: [NSFileProviderItemIdentifier] = []
    private let stream = AsyncStream<NSFileProviderItemIdentifier>.makeStream()

    var identifiers: [NSFileProviderItemIdentifier] { lock.withLock { _identifiers } }
    var count: Int { lock.withLock { _identifiers.count } }

    func record(_ id: NSFileProviderItemIdentifier) {
        lock.withLock { _identifiers.append(id) }
        stream.continuation.yield(id)
    }

    /// Awaits the next recorded signal identifier.
    func nextIdentifier() async -> NSFileProviderItemIdentifier? {
        var iter = stream.stream.makeAsyncIterator()
        return await iter.next()
    }
}
