import Foundation
@testable import OfemKit
import Testing

// MARK: - SyncEngine item-listing refresh tests (F6/C16)

/// Tests for the materialized workspace-container refresh path: a workspace's
/// item listing is materialized under the ``VirtualIDs/itemID`` sentinel and
/// must be refreshed via the Fabric item listing
/// (``SyncEngine/refreshItemListing(alias:workspaceID:)``), never via
/// `refreshFolder` → `onelake.listPath(itemGUID: "__items__")`. Also covers the
/// per-workspace throttle and the in-flight coalesce.
@Suite("SyncEngine item-listing refresh")
struct SyncEngineItemListingRefreshTests {
    private static let alias = "acct"
    private static let ws = "ws-guid"

    /// The materialized workspace container key: item component is the sentinel.
    private static var itemsContainerKey: CacheKey {
        CacheKey(accountAlias: alias, workspaceID: ws, itemID: VirtualIDs.itemID, path: "")
    }

    // MARK: - Helpers

    /// A thread-safe, settable Unix-nanosecond clock (mirrors the one in
    /// SyncEngineRefreshMaterializedTests; test files cannot share a `private`
    /// nested type across files).
    private final class TestClock: @unchecked Sendable {
        private let lock = NSLock()
        private var _nowNs: Int64
        init(_ nowNs: Int64) {
            _nowNs = nowNs
        }

        var nowNs: Int64 {
            lock.withLock { _nowNs }
        }

        func advance(by ns: Int64) {
            lock.withLock { _nowNs += ns }
        }
    }

    private func makeEngine(
        fabric: any FabricClientProtocol,
        onelake: MockOneLakeClient = MockOneLakeClient(),
        clock: TestClock? = nil
    ) throws -> (SyncEngine, CacheStore) {
        let store = try makeTempStore()
        let scratchDir = store.root.appending(path: "scratch", directoryHint: .isDirectory)
        let provider: (@Sendable () -> Int64)? = if let clock {
            { clock.nowNs }
        } else {
            nil
        }
        let engine = SyncEngine(
            cache: store,
            onelake: onelake,
            fabric: fabric,
            scratchBase: scratchDir,
            nowNsProvider: provider
        )
        return (engine, store)
    }

    private static func lakehouse(_ id: String, name: String) -> Item {
        Item(id: id, displayName: name, type: "Lakehouse", workspaceID: ws)
    }

    // MARK: - Routing: sentinel container hits Fabric, never DFS

    @Test("refreshMaterializedContainer routes the __items__ sentinel to the Fabric listing, never listPath")
    func routesItemsSentinelToFabricNotDFS() async throws {
        let fabric = MockFabricClient()
        fabric.listItemsResults.append(.success([Self.lakehouse("item-a", name: "Lake A")]))
        let ol = MockOneLakeClient()
        let (engine, store) = try makeEngine(fabric: fabric, onelake: ol)
        defer { try? FileManager.default.removeItem(at: store.root) }

        let diff = try await engine.refreshMaterializedContainer(key: Self.itemsContainerKey)

        // Fabric was consulted; DFS listPath was NOT (it would 400 on "__items__").
        #expect(fabric.listAllItemsCallCount == 1)
        #expect(ol.listPathCalls.isEmpty)
        // First sight → the item is added.
        #expect(diff.added == 1)

        // The discovery row is now cached under the sentinel.
        let row = try await store.fetch(key: CacheKey(
            accountAlias: Self.alias, workspaceID: Self.ws,
            itemID: VirtualIDs.itemID, path: "item-a"
        ))
        #expect(row.name == "Lake A")
    }

    // MARK: - Vanished item → removed diff + .item tombstone

    @Test("A vanished item yields diff.removed == 1 and tombstones its .item identifier")
    func vanishedItemTombstonedWithItemIdentifier() async throws {
        let clock = TestClock(1_000_000_000_000)
        let fabric = MockFabricClient()
        // Poll 1: two items. Poll 2: only the first.
        fabric.listItemsResults.append(.success([
            Self.lakehouse("item-a", name: "Lake A"),
            Self.lakehouse("item-b", name: "Lake B"),
        ]))
        fabric.listItemsResults.append(.success([Self.lakehouse("item-a", name: "Lake A")]))
        let (engine, store) = try makeEngine(fabric: fabric, clock: clock)
        defer { try? FileManager.default.removeItem(at: store.root) }

        _ = try await engine.refreshItemListing(alias: Self.alias, workspaceID: Self.ws)
        let anchor = try await store.syncAnchorNs(accountAlias: Self.alias)

        // Advance past the throttle so poll 2 actually lists.
        clock.advance(by: 61 * 1_000_000_000)
        let diff = try await engine.refreshItemListing(alias: Self.alias, workspaceID: Self.ws)

        #expect(diff.removed == 1)
        // item-b's row is hard-deleted…
        let goneRow = try? await store.fetch(key: CacheKey(
            accountAlias: Self.alias, workspaceID: Self.ws,
            itemID: VirtualIDs.itemID, path: "item-b"
        ))
        #expect(goneRow == nil)
        // …and its removal surfaces as the ".item" identifier "ws/<guid>".
        let changes = try await store.itemsChangedAfter(accountAlias: Self.alias, ns: anchor)
        #expect(changes.deletedIdentifierStrings.contains("\(Self.ws)/item-b"))
        #expect(!changes.deletedIdentifierStrings.contains("\(Self.ws)/item-a"))
        // No sentinel ever leaks into a deletion identifier.
        #expect(!changes.deletedIdentifierStrings.contains { $0.contains(VirtualIDs.itemID) })
    }

    // MARK: - Throttle

    @Test("A second refresh within the throttle window issues no Fabric call")
    func throttleSkipsSecondListWithin60s() async throws {
        let clock = TestClock(1_000_000_000_000)
        let fabric = MockFabricClient()
        // Only ONE scripted result: the throttled second call must not consume it.
        fabric.listItemsResults.append(.success([Self.lakehouse("item-a", name: "Lake A")]))
        let (engine, store) = try makeEngine(fabric: fabric, clock: clock)
        defer { try? FileManager.default.removeItem(at: store.root) }

        _ = try await engine.refreshItemListing(alias: Self.alias, workspaceID: Self.ws)
        #expect(fabric.listAllItemsCallCount == 1)

        // +30 s: still inside the 60 s window → throttled, empty diff, no Fabric.
        clock.advance(by: 30 * 1_000_000_000)
        let diff = try await engine.refreshItemListing(alias: Self.alias, workspaceID: Self.ws)
        #expect(diff.total == 0)
        #expect(fabric.listAllItemsCallCount == 1)
    }

    @Test("A refresh past the throttle window issues a fresh Fabric call")
    func throttleAllowsListAfterInterval() async throws {
        let clock = TestClock(1_000_000_000_000)
        let fabric = MockFabricClient()
        fabric.listItemsResults.append(.success([Self.lakehouse("item-a", name: "Lake A")]))
        fabric.listItemsResults.append(.success([Self.lakehouse("item-a", name: "Lake A")]))
        let (engine, store) = try makeEngine(fabric: fabric, clock: clock)
        defer { try? FileManager.default.removeItem(at: store.root) }

        _ = try await engine.refreshItemListing(alias: Self.alias, workspaceID: Self.ws)
        #expect(fabric.listAllItemsCallCount == 1)

        // +61 s: past the window → lists again.
        clock.advance(by: 61 * 1_000_000_000)
        _ = try await engine.refreshItemListing(alias: Self.alias, workspaceID: Self.ws)
        #expect(fabric.listAllItemsCallCount == 2)
    }

    @Test("A throttled attempt does not stamp the clock (a Fabric error keeps the workspace due)")
    func throttleStampsOnlyOnSuccess() async throws {
        let clock = TestClock(1_000_000_000_000)
        let fabric = MockFabricClient()
        // Poll 1 fails; poll 2 (still nothing stamped) must be allowed to list.
        fabric.listItemsResults.append(.failure(MockError.intentional("boom")))
        fabric.listItemsResults.append(.success([Self.lakehouse("item-a", name: "Lake A")]))
        let (engine, store) = try makeEngine(fabric: fabric, clock: clock)
        defer { try? FileManager.default.removeItem(at: store.root) }

        await #expect(throws: (any Error).self) {
            _ = try await engine.refreshItemListing(alias: Self.alias, workspaceID: Self.ws)
        }
        #expect(fabric.listAllItemsCallCount == 1)

        // No clock advance: because the failed attempt did NOT stamp, the retry
        // is not throttled and lists immediately.
        let diff = try await engine.refreshItemListing(alias: Self.alias, workspaceID: Self.ws)
        #expect(fabric.listAllItemsCallCount == 2)
        #expect(diff.added == 1)
    }

    // MARK: - Fabric error rethrows before the destructive reconcile

    @Test("A Fabric error rethrows before the reconcile, leaving cached rows intact")
    func fabricErrorThrowsBeforeReconcile() async throws {
        let fabric = MockFabricClient()
        fabric.listItemsResults.append(.failure(MockError.intentional("offline")))
        let (engine, store) = try makeEngine(fabric: fabric)
        defer { try? FileManager.default.removeItem(at: store.root) }

        // Seed an existing discovery row that must survive the failed refresh.
        try await store.upsert(MetadataRecord(
            accountAlias: Self.alias, workspaceID: Self.ws, itemID: VirtualIDs.itemID,
            path: "item-a", parentPath: "", name: "Lake A", isDir: true, itemType: "Lakehouse"
        ))

        await #expect(throws: (any Error).self) {
            _ = try await engine.refreshItemListing(alias: Self.alias, workspaceID: Self.ws)
        }

        // The pre-existing row is untouched (no expiry ran).
        let row = try? await store.fetch(key: CacheKey(
            accountAlias: Self.alias, workspaceID: Self.ws,
            itemID: VirtualIDs.itemID, path: "item-a"
        ))
        #expect(row != nil)
    }

    // MARK: - In-flight coalesce

    @Test("Overlapping refreshes for the same workspace coalesce to a single Fabric call")
    func concurrentRefreshesCoalesce() async throws {
        let fabric = BlockingItemsFabricClient()
        let (engine, store) = try makeEngine(fabric: fabric)
        defer { try? FileManager.default.removeItem(at: store.root) }

        var iter = fabric.entered.makeAsyncIterator()

        // First refresh blocks inside listAllItems with the in-flight flag set.
        let first = Task {
            try await engine.refreshItemListing(alias: Self.alias, workspaceID: Self.ws)
        }
        _ = await iter.next() // first has entered listAllItems

        // Second refresh, while the first is in flight → coalesced empty diff,
        // and crucially NO second Fabric call.
        let second = try await engine.refreshItemListing(alias: Self.alias, workspaceID: Self.ws)
        #expect(second.total == 0)
        #expect(fabric.callCount == 1)

        // Unblock the first and let it finish.
        fabric.unblock(with: [Self.lakehouse("item-a", name: "Lake A")])
        _ = try await first.value
        #expect(fabric.callCount == 1)
    }
}

// MARK: - BlockingItemsFabricClient

/// A ``FabricClientProtocol`` mock whose `listAllItems` suspends until
/// `unblock(with:)` is called. Used to hold a `refreshItemListing` in flight so
/// a second overlapping call can be observed coalescing.
final class BlockingItemsFabricClient: FabricClientProtocol, @unchecked Sendable {
    private var pending: [CheckedContinuation<[Item], any Error>] = []
    private let lock = NSLock()
    private var _callCount = 0

    var callCount: Int {
        lock.withLock { _callCount }
    }

    private let enteredStream = AsyncStream<Void>.makeStream()
    var entered: AsyncStream<Void> {
        enteredStream.stream
    }

    func unblock(with items: [Item]) {
        let cont = lock.withLock { pending.isEmpty ? nil : pending.removeFirst() }
        cont?.resume(returning: items)
    }

    func listAllItems(alias _: String, workspaceID _: String) async throws -> [Item] {
        lock.withLock { _callCount += 1 }
        return try await withCheckedThrowingContinuation { cont in
            lock.withLock { pending.append(cont) }
            enteredStream.continuation.yield(())
        }
    }

    func listAllWorkspaces(alias _: String) async throws -> [Workspace] {
        []
    }

    func listAllFolders(alias _: String, workspaceID _: String) async throws -> [Folder] {
        []
    }
}
