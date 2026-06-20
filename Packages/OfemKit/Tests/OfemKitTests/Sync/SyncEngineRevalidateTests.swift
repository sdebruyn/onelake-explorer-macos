import Testing
import Foundation
@testable import OfemKit

// MARK: - SyncEngine stale-while-revalidate tests

/// Covers the stale-while-revalidate enumeration redesign: serve cache on
/// presence, revalidate in the background with debounce + coalescing, fire the
/// injected change handler on drift, and stay silent (cache intact, no failure
/// telemetry) on cancellation / offline.
@Suite("SyncEngine revalidate")
struct SyncEngineRevalidateTests {

    // MARK: - Constants

    private static let alias = "test"
    private static let wsID  = "ws-1"
    private static let itID  = "item-1"

    private static var folderKey: CacheKey {
        CacheKey(accountAlias: alias, workspaceID: wsID, itemID: itID, path: "")
    }

    // MARK: - Helpers

    /// Builds an engine wired to `onelake`, with an optional change handler and
    /// telemetry client. Returns the engine + its backing store (remove
    /// `store.root` in a `defer`).
    private func makeEngine(
        onelake: any OneLakeClientProtocol,
        telemetry: TelemetryClient? = nil,
        onContainerChanged: ContainerChangeHandler? = nil
    ) throws -> (SyncEngine, CacheStore) {
        let store = try makeTempStore()
        let scratchDir = store.root.appending(path: "scratch", directoryHint: .isDirectory)
        let engine = SyncEngine(
            cache: store,
            onelake: onelake,
            fabric: MockFabricClient(),
            telemetry: telemetry,
            scratchBase: scratchDir,
            onContainerChanged: onContainerChanged
        )
        return (engine, store)
    }

    /// Seeds the parent directory row + its children. `childrenAgeSeconds` sets
    /// how long ago the listing was reconciled (`childrenSyncedAtNs`); pass a
    /// value larger than the debounce window to make the row revalidate-eligible.
    private func seedFolder(
        in store: CacheStore,
        childNames: [String],
        childrenAgeSeconds: TimeInterval
    ) async throws {
        let syncedAt = Date().addingTimeInterval(-childrenAgeSeconds)
        let syncedNs = Int64(syncedAt.timeIntervalSince1970 * 1_000_000_000)
        let parent = MetadataRecord(
            accountAlias: Self.alias, workspaceID: Self.wsID, itemID: Self.itID,
            path: "", parentPath: "", name: "root", isDir: true,
            childrenSyncedAtNs: syncedNs
        )
        try await store.upsert(parent)
        for n in childNames {
            let child = MetadataRecord(
                accountAlias: Self.alias, workspaceID: Self.wsID, itemID: Self.itID,
                path: n, parentPath: "", name: n, isDir: false,
                etag: "seed-\(n)"
            )
            try await store.upsert(child)
        }
    }

    /// Seeds an arbitrary directory `key` + its children, `ageSeconds` ago.
    private func seedDir(
        in store: CacheStore,
        key: CacheKey,
        childNames: [String],
        ageSeconds: TimeInterval
    ) async throws {
        let syncedNs = Int64(Date().addingTimeInterval(-ageSeconds).timeIntervalSince1970 * 1_000_000_000)
        let parent = MetadataRecord(
            accountAlias: key.accountAlias, workspaceID: key.workspaceID, itemID: key.itemID,
            path: key.path, parentPath: Enumerator.parentPath(key.path),
            name: Enumerator.baseName(key.path), isDir: true, childrenSyncedAtNs: syncedNs
        )
        try await store.upsert(parent)
        for n in childNames {
            let childPath = key.path.isEmpty ? n : "\(key.path)/\(n)"
            let child = MetadataRecord(
                accountAlias: key.accountAlias, workspaceID: key.workspaceID, itemID: key.itemID,
                path: childPath, parentPath: key.path, name: n, isDir: false, etag: "seed-\(n)"
            )
            try await store.upsert(child)
        }
    }

    private func listing(_ names: [String]) -> ListResult {
        ListResult(entries: names.map { PathEntry.file(name: $0, eTag: "remote-\($0)") })
    }

    // MARK: - AC1: first open (empty cache) blocks then returns live entries

    @Test("First open on a cold cache blocks on refreshFolder and returns live entries")
    func testFirstOpenColdCacheBlocksAndReturnsLive() async throws {
        let ol = MockOneLakeClient()
        let (engine, store) = try makeEngine(onelake: ol)
        defer { try? FileManager.default.removeItem(at: store.root) }

        ol.listPathResults.append(.success(listing(["a.txt", "b.txt"])))

        let children = try await engine.enumerate(key: Self.folderKey)

        #expect(Set(children.map(\.name)) == ["a.txt", "b.txt"])
        // Exactly one blocking listPath; no background task was needed.
        #expect(ol.listPathCalls.count == 1)
        #expect(await engine.revalidationTask(for: Self.folderKey) == nil)
    }

    // MARK: - AC2: populated-but-stale cache → serve cache + one background refresh

    @Test("Open with populated stale cache returns cache and triggers one background refresh")
    func testStaleCacheServesImmediatelyAndRevalidatesOnce() async throws {
        let ol = BlockingListMockOneLakeClient()
        let (engine, store) = try makeEngine(onelake: ol)
        defer { try? FileManager.default.removeItem(at: store.root) }

        // Stale (60 s old) populated listing; remote is identical → no-op refresh.
        try await seedFolder(in: store, childNames: ["a.txt"], childrenAgeSeconds: 60)

        let children = try await engine.enumerate(key: Self.folderKey)
        // Served from cache immediately — the seed row, not a live fetch.
        #expect(children.map(\.name) == ["a.txt"])

        // Exactly one background revalidate was scheduled and is in flight.
        var iter = ol.listEntered.makeAsyncIterator()
        _ = await iter.next()
        let task = try #require(await engine.revalidationTask(for: Self.folderKey))

        ol.unblock(with: listing(["a.txt"]))  // remote identical → no-op diff
        _ = await task.value

        #expect(ol.listPathCallCount == 1)
        // Map is pruned after the task completes.
        #expect(await engine.revalidationTask(for: Self.folderKey) == nil)
    }

    @Test("Open with fresh cache (within debounce) serves cache and does NOT revalidate")
    func testFreshCacheWithinDebounceDoesNotRevalidate() async throws {
        let ol = MockOneLakeClient()
        let (engine, store) = try makeEngine(onelake: ol)
        defer { try? FileManager.default.removeItem(at: store.root) }

        // Reconciled 1 s ago — inside the 10 s debounce window.
        try await seedFolder(in: store, childNames: ["a.txt"], childrenAgeSeconds: 1)

        let children = try await engine.enumerate(key: Self.folderKey)
        #expect(children.map(\.name) == ["a.txt"])

        // No background revalidate scheduled, no DFS call.
        #expect(await engine.revalidationTask(for: Self.folderKey) == nil)
        #expect(ol.listPathCalls.isEmpty)
    }

    // MARK: - AC3: debounce / coalescing — N rapid opens → at most one listPath

    @Test("N rapid opens within the debounce window issue at most one listPath")
    func testRapidOpensCoalesceToOneListPath() async throws {
        let ol = BlockingListMockOneLakeClient()
        let (engine, store) = try makeEngine(onelake: ol)
        defer { try? FileManager.default.removeItem(at: store.root) }

        try await seedFolder(in: store, childNames: ["a.txt"], childrenAgeSeconds: 60)

        // First open schedules a revalidate whose listPath blocks. Wait until it
        // is suspended so the remaining opens observe the in-flight entry.
        _ = try await engine.enumerate(key: Self.folderKey)
        var iter = ol.listEntered.makeAsyncIterator()
        _ = await iter.next()
        let task = try #require(await engine.revalidationTask(for: Self.folderKey))

        // Four more opens while the first revalidate is still in flight: each
        // coalesces (in-flight entry) rather than spawning a second listPath.
        for _ in 0..<4 {
            _ = try await engine.enumerate(key: Self.folderKey)
        }

        ol.unblock(with: listing(["a.txt"]))
        _ = await task.value

        // Exactly one DFS listPath across all five opens.
        #expect(ol.listPathCallCount == 1)
    }

    @Test("A concurrent open joins the in-flight revalidation instead of spawning a second")
    func testConcurrentOpenJoinsInFlightRevalidation() async throws {
        let ol = BlockingListMockOneLakeClient()
        let (engine, store) = try makeEngine(onelake: ol)
        defer { try? FileManager.default.removeItem(at: store.root) }

        try await seedFolder(in: store, childNames: ["a.txt"], childrenAgeSeconds: 60)

        // First open: serves cache, schedules a revalidate whose listPath blocks.
        _ = try await engine.enumerate(key: Self.folderKey)

        // Wait until the background revalidate has entered listPath and suspended.
        var iter = ol.listEntered.makeAsyncIterator()
        _ = await iter.next()

        // The in-flight revalidation task exists while listPath is blocked.
        let inFlight = try #require(await engine.revalidationTask(for: Self.folderKey))

        // A concurrent open arriving now must NOT spawn a second listPath; it
        // serves the cache and skips (the in-flight entry already covers it).
        _ = try await engine.enumerate(key: Self.folderKey)
        // Still the same single in-flight task — no second one was spawned.
        #expect(await engine.revalidationTask(for: Self.folderKey) != nil)

        // Unblock the single listPath and join the captured handle so the
        // assertions run after the revalidate has finished and pruned its entry.
        ol.unblock(with: listing(["a.txt"]))
        _ = await inFlight.value

        // Exactly one DFS listPath was issued across both opens.
        #expect(ol.listPathCallCount == 1)
        #expect(await engine.revalidationTask(for: Self.folderKey) == nil)
    }

    // MARK: - AC4: change handler fires on drift, stays silent on no-op

    @Test("Change handler fires once with the container key when a revalidate finds a change")
    func testChangeHandlerFiresOnDrift() async throws {
        let recorder = ContainerChangeRecorder()
        let ol = BlockingListMockOneLakeClient()
        let (engine, store) = try makeEngine(onelake: ol, onContainerChanged: recorder.handler)
        defer { try? FileManager.default.removeItem(at: store.root) }

        // Cached has [a]; remote now has [a, b] → diff.added == 1.
        try await seedFolder(in: store, childNames: ["a.txt"], childrenAgeSeconds: 60)

        _ = try await engine.enumerate(key: Self.folderKey)
        var iter = ol.listEntered.makeAsyncIterator()
        _ = await iter.next()
        let task = try #require(await engine.revalidationTask(for: Self.folderKey))
        ol.unblock(with: listing(["a.txt", "b.txt"]))
        let diff = await task.value
        #expect(diff.total > 0)

        // The handler runs OFF the actor (detached); await it deterministically.
        let call = try #require(await recorder.nextCall())
        #expect(call.container == Self.folderKey)
        #expect(call.diff.total > 0)
        #expect(recorder.calls().count == 1)

        // The revalidate persisted the new child into the cache.
        let children = try await store.children(of: Self.folderKey)
        #expect(Set(children.map(\.name)) == ["a.txt", "b.txt"])
    }

    @Test("Change handler does NOT fire when the revalidate finds no change")
    func testChangeHandlerSilentOnNoChange() async throws {
        let recorder = ContainerChangeRecorder()
        let ol = BlockingListMockOneLakeClient()
        let (engine, store) = try makeEngine(onelake: ol, onContainerChanged: recorder.handler)
        defer { try? FileManager.default.removeItem(at: store.root) }

        // Cached child matches the remote entry on every diffed field (isDir,
        // contentLength, etag, lastModified, name, parentPath) → no diff.
        let syncedNs = Int64(Date().addingTimeInterval(-60).timeIntervalSince1970 * 1_000_000_000)
        let parent = MetadataRecord(
            accountAlias: Self.alias, workspaceID: Self.wsID, itemID: Self.itID,
            path: "", parentPath: "", name: "root", isDir: true, childrenSyncedAtNs: syncedNs
        )
        let child = MetadataRecord(
            accountAlias: Self.alias, workspaceID: Self.wsID, itemID: Self.itID,
            path: "a.txt", parentPath: "", name: "a.txt", isDir: false,
            contentLength: 100, etag: "same", lastModifiedNs: 0
        )
        try await store.upsert(parent)
        try await store.upsert(child)
        let identical = ListResult(entries: [
            PathEntry(name: "a.txt", isDirectory: false, contentLength: 100,
                      eTag: "same", lastModified: Date(timeIntervalSince1970: 0))
        ])

        _ = try await engine.enumerate(key: Self.folderKey)
        var iter = ol.listEntered.makeAsyncIterator()
        _ = await iter.next()
        let task = try #require(await engine.revalidationTask(for: Self.folderKey))
        ol.unblock(with: identical)
        let diff = await task.value

        // No diff → runRevalidate never spawns the notification task, so the
        // recorder staying empty is deterministic (not a timing artefact).
        #expect(diff.total == 0)
        #expect(recorder.calls().isEmpty)
    }

    // MARK: - AC5: shutdown while a revalidate is blocked at listPath — cache intact, no failure telemetry

    @Test("Shutdown while a revalidate is blocked at listPath leaves the cache intact and emits no failure telemetry")
    func testShutdownWhileBlockedAtListPathLeavesCacheIntact() async throws {
        let recorder = ContainerChangeRecorder()
        let sink = MemoryTelemetrySink()
        let telemetry = TelemetryClient(
            sink: sink, appVersion: "test", installID: "test",
            configuration: TelemetryConfiguration(maxBatchSize: 1000, flushInterval: .seconds(3600))
        )
        let ol = BlockingListMockOneLakeClient()
        let (engine, store) = try makeEngine(onelake: ol, telemetry: telemetry, onContainerChanged: recorder.handler)
        defer { try? FileManager.default.removeItem(at: store.root) }

        try await seedFolder(in: store, childNames: ["a.txt"], childrenAgeSeconds: 60)

        _ = try await engine.enumerate(key: Self.folderKey)

        // Wait until the revalidate has entered the (blocked) listPath.
        var iter = ol.listEntered.makeAsyncIterator()
        _ = await iter.next()

        // quiesceRevalidations() does NOT cancel — it drains, so it awaits the
        // still-blocked task. In production a stuck listPath is bounded by the
        // HTTP request timeout (it returns/throws); model that here by failing the
        // listPath offline once the drain is waiting. Run the drain concurrently
        // and release listPath so it can complete.
        async let drain: Void = engine.quiesceRevalidations()
        let offlineTransport = HTTPClientError.transport(URLError(.notConnectedToInternet))
        ol.fail(with: OneLakeError.httpError(offlineTransport))
        await drain

        // listPath threw before the reconcile, so the cache is untouched.
        let children = try await store.children(of: Self.folderKey)
        #expect(children.map(\.name) == ["a.txt"])

        // No change notification, and no failure telemetry from the revalidate.
        #expect(recorder.calls().isEmpty)
        await telemetry.flush()
        #expect(sink.drain().filter { $0.success == false }.isEmpty)

        // After shutdown a late enumerate must not re-spawn a revalidate.
        _ = try await engine.enumerate(key: Self.folderKey)
        #expect(await engine.revalidationTask(for: Self.folderKey) == nil)

        await telemetry.shutdown()  // cancel the flush timer; don't leak it
    }

    // MARK: - AC6: offline revalidate keeps cache rows; enumerate still serves cache

    @Test("Offline revalidate keeps cached rows and enumerate still returns the cached listing")
    func testOfflineRevalidateKeepsCacheRows() async throws {
        let recorder = ContainerChangeRecorder()
        let sink = MemoryTelemetrySink()
        let telemetry = TelemetryClient(
            sink: sink, appVersion: "test", installID: "test",
            configuration: TelemetryConfiguration(maxBatchSize: 1000, flushInterval: .seconds(3600))
        )
        let ol = BlockingListMockOneLakeClient()
        let (engine, store) = try makeEngine(onelake: ol, telemetry: telemetry, onContainerChanged: recorder.handler)
        defer { try? FileManager.default.removeItem(at: store.root) }

        try await seedFolder(in: store, childNames: ["a.txt", "b.txt"], childrenAgeSeconds: 60)

        let children = try await engine.enumerate(key: Self.folderKey)
        // Cache served immediately.
        #expect(Set(children.map(\.name)) == ["a.txt", "b.txt"])

        // Capture the in-flight revalidate, then fail its listPath offline (the
        // wrapped transport URLError shape SyncEngine sees in production).
        var iter = ol.listEntered.makeAsyncIterator()
        _ = await iter.next()
        let task = try #require(await engine.revalidationTask(for: Self.folderKey))
        let offlineTransport = HTTPClientError.transport(URLError(.notConnectedToInternet))
        ol.fail(with: OneLakeError.httpError(offlineTransport))
        _ = await task.value

        // No deletes/tombstones: both cached rows survive the offline refresh.
        let after = try await store.children(of: Self.folderKey)
        #expect(Set(after.map(\.name)) == ["a.txt", "b.txt"])

        // Engine flipped to offline (refreshFolder fed the tracker) but the
        // revalidate stayed silent: no change handler, no failure telemetry.
        #expect(await engine.currentlyOffline == true)
        #expect(recorder.calls().isEmpty)
        await telemetry.flush()
        #expect(sink.drain().filter { $0.success == false }.isEmpty)

        // A subsequent enumerate still serves the cache (debounce now suppresses
        // a second revalidate, but presence still wins).
        let again = try await engine.enumerate(key: Self.folderKey)
        #expect(Set(again.map(\.name)) == ["a.txt", "b.txt"])

        await telemetry.shutdown()  // cancel the flush timer; don't leak it
    }

    // MARK: - empty-but-enumerated folder is present (served), cold folder is not

    @Test("An empty but previously-enumerated folder serves the empty listing and revalidates")
    func testEmptyEnumeratedFolderServesEmptyAndRevalidates() async throws {
        let ol = BlockingListMockOneLakeClient()
        let (engine, store) = try makeEngine(onelake: ol)
        defer { try? FileManager.default.removeItem(at: store.root) }

        // Parent enumerated 60 s ago, but it has no children.
        let syncedNs = Int64(Date().addingTimeInterval(-60).timeIntervalSince1970 * 1_000_000_000)
        let parent = MetadataRecord(
            accountAlias: Self.alias, workspaceID: Self.wsID, itemID: Self.itID,
            path: "", parentPath: "", name: "root", isDir: true, childrenSyncedAtNs: syncedNs
        )
        try await store.upsert(parent)

        let children = try await engine.enumerate(key: Self.folderKey)
        // Served the (empty) cached listing immediately — NOT the live fetch.
        #expect(children.isEmpty)

        // A background revalidate WAS scheduled (the folder is present, just empty).
        var iter = ol.listEntered.makeAsyncIterator()
        _ = await iter.next()
        let task = try #require(await engine.revalidationTask(for: Self.folderKey))
        ol.unblock(with: listing(["new.txt"]))
        _ = await task.value

        #expect(ol.listPathCallCount == 1)
        let after = try await store.children(of: Self.folderKey)
        #expect(after.map(\.name) == ["new.txt"])
    }

    // MARK: - shutdown drains the reconcile (write completes, not aborted mid-flight)

    @Test("quiesceRevalidations drains an in-flight reconcile so its write completes before shutdown returns")
    func testShutdownDrainsInFlightReconcile() async throws {
        let ol = BlockingListMockOneLakeClient()
        let (engine, store) = try makeEngine(onelake: ol)
        defer { try? FileManager.default.removeItem(at: store.root) }

        try await seedFolder(in: store, childNames: ["a.txt"], childrenAgeSeconds: 60)

        _ = try await engine.enumerate(key: Self.folderKey)
        var iter = ol.listEntered.makeAsyncIterator()
        _ = await iter.next()

        // Let listPath SUCCEED with a changed listing so the destructive reconcile
        // (batchUpsert/batchDelete) runs. Then drain. quiesceRevalidations() does
        // NOT cancel, so the committed reconcile completes its write cleanly — it
        // must not be torn mid-flight (a cancel would make GRDB's write throw and
        // b.txt would never land).
        ol.unblock(with: listing(["a.txt", "b.txt"]))
        await engine.quiesceRevalidations()

        // The reconcile ran to completion (both children present), and the await
        // guarantees no write is still in flight past shutdown.
        let after = try await store.children(of: Self.folderKey)
        #expect(Set(after.map(\.name)) == ["a.txt", "b.txt"])

        // After shutdown, a late enumerate must not re-spawn a revalidate.
        _ = try await engine.enumerate(key: Self.folderKey)
        #expect(await engine.revalidationTask(for: Self.folderKey) == nil)
        #expect(ol.listPathCallCount == 1)  // no second DFS call post-shutdown
    }

    // MARK: - quiesceRevalidations drains all in-flight tasks and clears the map

    /// Verifies that ``quiesceRevalidations()`` awaits ALL in-flight revalidate
    /// tasks and that every entry is pruned from `inFlightRevalidations` by the
    /// time the drain returns, even when multiple revalidates are in flight
    /// simultaneously.
    ///
    /// This does not assert drain ordering (sequential vs concurrent); it asserts
    /// correctness of the drain: every started task runs to completion, the map
    /// is empty afterwards, and no revalidate is silently abandoned.
    @Test("quiesceRevalidations completes and prunes all in-flight entries")
    func testQuiesceRevalidationsDrainsAllInFlightEntries() async throws {
        let ol = BlockingListMockOneLakeClient()
        let (engine, store) = try makeEngine(onelake: ol)
        defer { try? FileManager.default.removeItem(at: store.root) }

        // Two distinct folders so each gets its own in-flight revalidate.
        let keyA = CacheKey(accountAlias: Self.alias, workspaceID: Self.wsID, itemID: Self.itID, path: "A")
        let keyB = CacheKey(accountAlias: Self.alias, workspaceID: Self.wsID, itemID: Self.itID, path: "B")
        try await seedDir(in: store, key: keyA, childNames: ["a.txt"], ageSeconds: 60)
        try await seedDir(in: store, key: keyB, childNames: ["b.txt"], ageSeconds: 60)

        var iter = ol.listEntered.makeAsyncIterator()

        // Start revalidate for A and wait until it is blocked inside listPath.
        _ = try await engine.enumerate(key: keyA)
        _ = await iter.next()

        // Start revalidate for B and wait until it too is blocked inside listPath.
        _ = try await engine.enumerate(key: keyB)
        _ = await iter.next()

        #expect(ol.listPathCallCount == 2)

        // Unblock both pending listPath calls, then drain. Both revalidates can
        // now run to completion; quiesceRevalidations must not return until all
        // in-flight tasks have finished and their entries are pruned.
        ol.unblock(with: listing(["A/a.txt"]))
        ol.unblock(with: listing(["B/b.txt"]))
        await engine.quiesceRevalidations()

        // Both revalidates ran to completion and their in-flight entries were pruned.
        #expect(await engine.revalidationTask(for: keyA) == nil)
        #expect(await engine.revalidationTask(for: keyB) == nil)
    }

    // MARK: - itemType-only drift surfaces as a change

    @Test("A revalidate whose only change is itemType reports a diff and fires the handler")
    func testItemTypeOnlyChangeFiresHandler() async throws {
        let recorder = ContainerChangeRecorder()
        let ol = BlockingListMockOneLakeClient()
        let (engine, store) = try makeEngine(onelake: ol, onContainerChanged: recorder.handler)
        defer { try? FileManager.default.removeItem(at: store.root) }

        // refreshFolder derives the child's itemType from the discovery row
        // (itemID = VirtualIDs.itemID, path = the item GUID), not the folder row.
        // Seed that discovery row with "Lakehouse" so the refresh stamps the child
        // with a type it did not have before.
        let syncedNs = Int64(Date().addingTimeInterval(-60).timeIntervalSince1970 * 1_000_000_000)
        let discovery = MetadataRecord(
            accountAlias: Self.alias, workspaceID: Self.wsID, itemID: VirtualIDs.itemID,
            path: Self.itID, parentPath: "", name: "MyLH", isDir: true, itemType: "Lakehouse"
        )
        let parent = MetadataRecord(
            accountAlias: Self.alias, workspaceID: Self.wsID, itemID: Self.itID,
            path: "", parentPath: "", name: "root", isDir: true,
            childrenSyncedAtNs: syncedNs
        )
        // Child predates listItems: empty itemType, but matches the remote on
        // every other diffed field.
        let child = MetadataRecord(
            accountAlias: Self.alias, workspaceID: Self.wsID, itemID: Self.itID,
            path: "a.txt", parentPath: "", name: "a.txt", isDir: false,
            contentLength: 100, etag: "same", lastModifiedNs: 0, itemType: ""
        )
        try await store.upsert(discovery)
        try await store.upsert(parent)
        try await store.upsert(child)
        // Remote entry identical on every field except the type the refresh
        // derives from the discovery row (Lakehouse).
        let sameButTyped = ListResult(entries: [
            PathEntry(name: "a.txt", isDirectory: false, contentLength: 100,
                      eTag: "same", lastModified: Date(timeIntervalSince1970: 0))
        ])

        _ = try await engine.enumerate(key: Self.folderKey)
        var iter = ol.listEntered.makeAsyncIterator()
        _ = await iter.next()
        let task = try #require(await engine.revalidationTask(for: Self.folderKey))
        ol.unblock(with: sameButTyped)
        let diff = await task.value

        // itemType "" -> "Lakehouse" is the only delta, but it must register.
        #expect(diff.total > 0)
        let call = try #require(await recorder.nextCall())
        #expect(call.container == Self.folderKey)

        // The child row now carries the resolved type.
        let rows = try await store.children(of: Self.folderKey)
        #expect(rows.first(where: { $0.name == "a.txt" })?.itemType == "Lakehouse")
    }

    // MARK: - cross-key isolation

    @Test("A revalidate on one key does not suppress or affect a revalidate on another key")
    func testCrossKeyIsolation() async throws {
        let ol = BlockingListMockOneLakeClient()
        let (engine, store) = try makeEngine(onelake: ol)
        defer { try? FileManager.default.removeItem(at: store.root) }

        // Two distinct folders (different paths under the same item).
        let keyA = CacheKey(accountAlias: Self.alias, workspaceID: Self.wsID, itemID: Self.itID, path: "A")
        let keyB = CacheKey(accountAlias: Self.alias, workspaceID: Self.wsID, itemID: Self.itID, path: "B")
        try await seedDir(in: store, key: keyA, childNames: ["a1.txt"], ageSeconds: 60)
        try await seedDir(in: store, key: keyB, childNames: ["b1.txt"], ageSeconds: 60)

        var iter = ol.listEntered.makeAsyncIterator()

        // Open A → schedules a revalidate for A (blocks in listPath).
        _ = try await engine.enumerate(key: keyA)
        _ = await iter.next()
        let taskA = try #require(await engine.revalidationTask(for: keyA))

        // Open B while A is in flight → B is a different key, so it spawns its own
        // revalidate (A's debounce/in-flight must NOT suppress B).
        _ = try await engine.enumerate(key: keyB)
        _ = await iter.next()
        let taskB = try #require(await engine.revalidationTask(for: keyB))

        // Resolve both independently. listPath returns item-relative paths, so a
        // child of folder "A" is "A/<name>" (refreshFolder filters to direct
        // children of the requested directory).
        ol.unblock(with: listing(["A/a1.txt", "A/a2.txt"]))  // first waiter is A
        _ = await taskA.value
        ol.unblock(with: listing(["B/b1.txt", "B/b2.txt"]))  // then B
        _ = await taskB.value

        #expect(ol.listPathCallCount == 2)
        let aKids = try await store.children(of: keyA)
        let bKids = try await store.children(of: keyB)
        #expect(Set(aKids.map(\.name)) == ["a1.txt", "a2.txt"])
        #expect(Set(bKids.map(\.name)) == ["b1.txt", "b2.txt"])
    }

    // MARK: - sequential post-completion suppression

    @Test("Re-opening within the debounce window after a completed revalidate does not re-spawn")
    func testPostCompletionDebounceSuppressesReopen() async throws {
        let ol = BlockingListMockOneLakeClient()
        let (engine, store) = try makeEngine(onelake: ol)
        defer { try? FileManager.default.removeItem(at: store.root) }

        try await seedFolder(in: store, childNames: ["a.txt"], childrenAgeSeconds: 60)

        // First open → revalidate runs to completion (writes childrenSyncedAt=now).
        _ = try await engine.enumerate(key: Self.folderKey)
        var iter = ol.listEntered.makeAsyncIterator()
        _ = await iter.next()
        let task = try #require(await engine.revalidationTask(for: Self.folderKey))
        ol.unblock(with: listing(["a.txt"]))
        _ = await task.value
        #expect(ol.listPathCallCount == 1)

        // Re-open immediately: the freshly-written childrenSyncedAt (now) is within
        // the debounce window, so isFresh suppresses a second revalidate — no new
        // in-flight task, no second listPath.
        _ = try await engine.enumerate(key: Self.folderKey)
        #expect(await engine.revalidationTask(for: Self.folderKey) == nil)
        #expect(ol.listPathCallCount == 1)
    }
}

// MARK: - BlockingListMockOneLakeClient

/// A `OneLakeClientProtocol` mock whose `listPath` blocks until `unblock(with:)`
/// (or `fail(with:)`) is called, so a test can hold a background revalidate
/// suspended inside the DFS call and assert in-flight coalescing / cancellation
/// deterministically.
///
/// Supports multiple concurrently-blocked `listPath` calls: pending
/// continuations form a FIFO queue, and `unblock`/`fail` resolve the oldest.
/// `listEntered` yields once per call as it suspends, so a test can sequence
/// blocked calls by awaiting the stream.
final class BlockingListMockOneLakeClient: OneLakeClientProtocol, @unchecked Sendable {

    private var pending: [CheckedContinuation<ListResult, any Error>] = []
    private let lock = NSLock()
    private var _listPathCallCount = 0

    private let listEnteredStream = AsyncStream<Void>.makeStream()
    var listEntered: AsyncStream<Void> { listEnteredStream.stream }

    var listPathCallCount: Int { lock.withLock { _listPathCallCount } }

    /// Resolves the oldest blocked `listPath` with `result`.
    func unblock(with result: ListResult) {
        let cont = lock.withLock { pending.isEmpty ? nil : pending.removeFirst() }
        cont?.resume(returning: result)
    }

    /// Resolves the oldest blocked `listPath` by throwing `error`.
    func fail(with error: any Error) {
        let cont = lock.withLock { pending.isEmpty ? nil : pending.removeFirst() }
        cont?.resume(throwing: error)
    }

    func listPath(
        alias: String, workspaceGUID: String, itemGUID: String,
        directory: String, recursive: Bool
    ) async throws -> ListResult {
        lock.withLock { _listPathCallCount += 1 }
        return try await withTaskCancellationHandler(
            operation: {
                try await withCheckedThrowingContinuation { cont in
                    lock.withLock { pending.append(cont) }
                    listEnteredStream.continuation.yield(())
                }
            },
            onCancel: {
                // On cancellation resolve the oldest pending with a
                // CancellationError so the blocked task can unwind.
                let cont = lock.withLock { pending.isEmpty ? nil : pending.removeFirst() }
                cont?.resume(throwing: CancellationError())
            }
        )
    }

    // Remaining protocol surface is unused by these tests.
    func getProperties(alias: String, workspaceGUID: String, itemGUID: String, path: String) async throws -> PathProperties { PathProperties.make() }
    func read(alias: String, workspaceGUID: String, itemGUID: String, path: String, range: Range<Int64>?, ifMatch: String) async throws -> (Data, PathProperties) { (Data(), PathProperties.make()) }
    func read(alias: String, workspaceGUID: String, itemGUID: String, path: String, range: Range<Int64>?, ifMatch: String, destination: FileHandle) async throws -> PathProperties { PathProperties.make() }
    func write(alias: String, workspaceGUID: String, itemGUID: String, path: String, content: Data, size: Int64) async throws {}
    func write(alias: String, workspaceGUID: String, itemGUID: String, path: String, sourceURL: URL, size: Int64) async throws {}
    func createDirectory(alias: String, workspaceGUID: String, itemGUID: String, path: String) async throws {}
    func delete(alias: String, workspaceGUID: String, itemGUID: String, path: String, recursive: Bool) async throws {}
}
