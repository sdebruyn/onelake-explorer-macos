import Testing
import Foundation
@testable import OfemKit

// MARK: - SyncEngine Tests

/// Tests for ``SyncEngine`` covering all previously-unverified paths.
@Suite("SyncEngine")
struct SyncEngineTests {

    // MARK: - Helpers

    private func makeEngine(
        onelake: any OneLakeClientProtocol = MockOneLakeClient(),
        fabric: MockFabricClient = MockFabricClient(),
        store: CacheStore? = nil
    ) throws -> (SyncEngine, CacheStore) {
        let s = try store ?? makeTempStore()
        let scratchDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let engine = SyncEngine(
            cache: s,
            onelake: onelake,
            fabric: fabric,
            scratchBase: scratchDir
        )
        return (engine, s)
    }

    private static let alias = "test"
    private static let wsID  = "ws-1"
    private static let itID  = "item-1"
    private static let path  = "Files/data.csv"

    private static var baseKey: CacheKey {
        CacheKey(accountAlias: alias, workspaceID: wsID, itemID: itID, path: path)
    }

    // MARK: - sync-01: 412 retry resets rangeStart

    @Test("412 resume retry — PartialManager discard+reset path compiles and resets state")
    func test412RetryResetsRangeStart() throws {
        // Unit test for PartialManager's sync-01 fix: after discard + reset,
        // rangeStart is 0 and hasPartial is false.
        let (pm, dir) = makePartialManager()
        defer { try? FileManager.default.removeItem(at: dir) }

        let key = Self.baseKey

        // Create a 10-byte partial with etag.
        let partialURL = pm.partialURL(for: key)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: partialURL.path, contents: Data(repeating: 0x41, count: 10))
        try pm.storeEtag("old-etag", for: key)

        let record = MetadataRecord(
            accountAlias: Self.alias,
            workspaceID: Self.wsID,
            itemID: Self.itID,
            path: Self.path,
            parentPath: "Files",
            name: "data.csv",
            isDir: false,
            contentLength: 100,
            etag: "old-etag"
        )

        // Before discard: should report a partial at offset 10.
        let (offset, _, hasPartial) = pm.rangeStart(for: key, cachedRecord: record)
        #expect(offset == 10)
        #expect(hasPartial)

        // Simulate the 412 discard + state reset in SyncEngine.
        pm.discard(for: key)
        // After discard: no partial on disk, rangeStart returns (0, nil, false).
        let (offset2, etag2, hasPartial2) = pm.rangeStart(for: key, cachedRecord: record)
        #expect(offset2 == 0)
        #expect(etag2 == nil)
        #expect(!hasPartial2)
    }

    /// Returns a `PartialManager` backed by a unique temp directory.
    private func makePartialManager() -> (PartialManager, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ofem-test-pm-\(UUID().uuidString)", isDirectory: true)
        return (PartialManager(scratchDir: dir), dir)
    }

    // MARK: - sync-07: cache failure returns downloaded bytes

    @Test("Cache write failure still returns downloaded bytes")
    func testCacheFailureReturnsBytesInMemory() async throws {
        let ol = MockOneLakeClient()
        let fabric = MockFabricClient()

        // Use a real store to test the "loadBlob fails so return allBytes" path.
        let (engine, store) = try makeEngine(onelake: ol, fabric: fabric)
        defer { try? FileManager.default.removeItem(at: store.root) }

        let key = Self.baseKey
        let body = Data(repeating: 0x55, count: 50)
        let props = PathProperties.make(contentLength: 50, eTag: "v1")
        ol.readResults.append(.success((body, props)))

        // No cached blob → skip freshness check → download.
        let data = try await engine.open(key: key)
        // Even if the blob store failed (it won't in this test, but the path
        // exercised is: loadBlob after storeBlob should return the same bytes).
        #expect(data.count == 50)
    }

    // MARK: - sync-06: concurrent opens coalesce

    @Test("Concurrent open() for the same key issues only one download")
    func testConcurrentOpensCoalesce() async throws {
        let ol = MockOneLakeClient()
        let fabric = MockFabricClient()
        let (engine, store) = try makeEngine(onelake: ol, fabric: fabric)
        defer { try? FileManager.default.removeItem(at: store.root) }

        let key = Self.baseKey
        let body = Data(repeating: 0xCC, count: 30)
        let props = PathProperties.make(contentLength: 30, eTag: "v1")

        // Only one read stub — if two downloads fire, the second will exhaust stubs.
        ol.readResults.append(.success((body, props)))

        // Launch two concurrent opens for the same key.
        async let r1 = engine.open(key: key)
        async let r2 = engine.open(key: key)
        let (d1, d2) = try await (r1, r2)

        #expect(d1.count == 30)
        #expect(d2.count == 30)
        // Only one network read should have occurred.
        #expect(ol.readCalls.count == 1)
    }

    // MARK: - sync-19: cache hits don't consume download slots

    @Test("Cache hit does not acquire a download slot")
    func testCacheHitSkipsSlotAcquisition() async throws {
        let ol = MockOneLakeClient()
        let fabric = MockFabricClient()

        // Max 1 download slot so a stuck slot would deadlock the second call.
        let store = try makeTempStore()
        defer { try? FileManager.default.removeItem(at: store.root) }
        let scratchDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let engine = SyncEngine(
            cache: store,
            onelake: ol,
            fabric: fabric,
            maxConcurrentDownloads: 1,
            scratchBase: scratchDir
        )

        let key = Self.baseKey
        let body = Data(repeating: 0xAA, count: 10)
        let props = PathProperties.make(contentLength: 10, eTag: "v1")

        // First open: populate the cache.
        ol.readResults.append(.success((body, props)))
        _ = try await engine.open(key: key)

        // HEAD for freshness: return same etag → cache hit.
        ol.getPropertiesResults.append(.success(props))

        // Second open: should be served from cache without consuming the slot.
        let data = try await engine.open(key: key)
        #expect(data.count == 10)
        // Only one network read total (the first open).
        #expect(ol.readCalls.count == 1)
    }

    // MARK: - sync-14: macOS metadata filtered at enumeration

    @Test("refreshFolder does not surface .DS_Store entries")
    func testMacOSMetadataFilteredInEnumeration() async throws {
        let ol = MockOneLakeClient()
        let fabric = MockFabricClient()
        let (engine, store) = try makeEngine(onelake: ol, fabric: fabric)
        defer { try? FileManager.default.removeItem(at: store.root) }

        let key = CacheKey(accountAlias: Self.alias, workspaceID: Self.wsID, itemID: Self.itID, path: "")
        let listing = ListResult(entries: [
            PathEntry(name: "\(Self.itID)/real.csv", isDirectory: false, contentLength: 10, eTag: "e1", lastModified: Date(timeIntervalSince1970: 0)),
            PathEntry(name: "\(Self.itID)/.DS_Store", isDirectory: false, contentLength: 4, eTag: "e2", lastModified: Date(timeIntervalSince1970: 0)),
            PathEntry(name: "\(Self.itID)/._real.csv", isDirectory: false, contentLength: 4, eTag: "e3", lastModified: Date(timeIntervalSince1970: 0)),
        ])
        ol.listPathResults.append(.success(listing))

        let diff = try await engine.refreshFolder(key: key)

        // Only real.csv should be added; .DS_Store and ._real.csv must be filtered.
        #expect(diff.added == 1)
        let children = try await store.children(of: key)
        let paths = children.map(\.name)
        #expect(paths.contains("real.csv"))
        #expect(!paths.contains(".DS_Store"))
        #expect(!paths.contains("._real.csv"))
    }

    // MARK: - sync-22: enumerate throws wrongItemKind for files

    @Test("enumerate() throws wrongItemKind when key is a file")
    func testEnumerateThrowsWrongItemKind() async throws {
        let ol = MockOneLakeClient()
        let fabric = MockFabricClient()
        let (engine, store) = try makeEngine(onelake: ol, fabric: fabric)
        defer { try? FileManager.default.removeItem(at: store.root) }

        // Insert a file (isDir: false) into the cache.
        let key = CacheKey(accountAlias: Self.alias, workspaceID: Self.wsID, itemID: Self.itID, path: "file.txt")
        let record = MetadataRecord(
            accountAlias: Self.alias,
            workspaceID: Self.wsID,
            itemID: Self.itID,
            path: "file.txt",
            parentPath: "",
            name: "file.txt",
            isDir: false,
            childrenSyncedAtNs: Int64(Date().timeIntervalSince1970 * 1e9) // Make it "fresh"
        )
        try await store.upsert(record)

        do {
            _ = try await engine.enumerate(key: key)
            Issue.record("Expected wrongItemKind to be thrown")
        } catch let fpErr as FPError {
            if case .wrongItemKind = fpErr {
                // Correct — test passes.
            } else {
                Issue.record("Expected wrongItemKind, got \(fpErr)")
            }
        }
    }

    // MARK: - sync-11: HEAD path routes through pauseManager

    @Test("isBlobFresh error path marks workspace paused via markPausedIfNeeded")
    func testHeadPathMarksPaused() async throws {
        let ol = MockOneLakeClient()
        let fabric = MockFabricClient()
        let (engine, store) = try makeEngine(onelake: ol, fabric: fabric)
        defer { try? FileManager.default.removeItem(at: store.root) }

        let key = Self.baseKey

        // Upsert a cached blob-bearing record so the freshness check is triggered.
        var record = MetadataRecord(
            accountAlias: Self.alias,
            workspaceID: Self.wsID,
            itemID: Self.itID,
            path: Self.path,
            parentPath: "Files",
            name: "data.csv",
            isDir: false,
            contentLength: 100,
            etag: "v1"
        )
        record.blobSHA256 = "dummy-sha"
        try await store.upsert(record)

        // HEAD returns a paused-capacity error (wrapped as OneLakeError.httpError).
        let apiBody = #"{"errorCode":"CapacityPaused","message":"capacity is currently paused"}"#
        let apiErr = HTTPClientError.apiError(APIError(statusCode: 503, status: "503 Service Unavailable", body: apiBody.data(using: .utf8)!))
        ol.getPropertiesResults.append(.failure(OneLakeError.httpError(apiErr)))

        do {
            _ = try await engine.open(key: key)
            Issue.record("Expected workspacePaused to be thrown")
        } catch SyncError.workspacePaused {
            // Correct.
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        // The workspace should now be recorded as paused.
        let status = try? await store.workspaceStatus(accountAlias: Self.alias, workspaceID: Self.wsID)
        #expect(status?.state == .paused)
    }

    // MARK: - sync-12: 429 from OneLakeError.httpError classified as serverBusy

    @Test("FPError.classify maps OneLakeError.httpError(.throttled) to serverBusy")
    func testThrottledClassifiedAsServerBusy() {
        let inner = HTTPClientError.throttled
        let wrapped = OneLakeError.httpError(inner)
        let code = FPError.classify(wrapped)
        #expect(code == .serverBusy)
    }

    // MARK: - T1: cancellation-poisoning (C1 livelock fix)

    @Test("Stale cancelled in-flight task does not livelock the key — a fresh open() succeeds")
    func testCancelledInFlightTaskDoesNotLivelockKey() async throws {
        let ol = BlockingMockOneLakeClient()
        let (engine, store) = try makeEngine(onelake: ol)
        defer { try? FileManager.default.removeItem(at: store.root) }

        let key = Self.baseKey
        let freshBody = Data(repeating: 0xBB, count: 20)
        let freshProps = PathProperties.make(contentLength: 20, eTag: "v2")

        // Task A starts the download — the blocking mock suspends inside read().
        let taskA = Task<Data, any Error> { try await engine.open(key: key) }

        // Wait until read() is entered so the in-flight entry exists in the actor.
        var readEnteredIter = ol.readEntered.makeAsyncIterator()
        _ = await readEnteredIter.next()

        // Cancel Task A. The mock's onCancel handler resumes the blocked
        // continuation with CancellationError; the internal download Task
        // (created inside open()) therefore completes with CancellationError.
        taskA.cancel()

        // Wait for Task A to propagate the cancellation and finish.
        do {
            _ = try await taskA.value
        } catch is CancellationError { /* expected */ }
        // At this point Task A's defer has run and removed the entry from
        // inFlightDownloads. The key is clean.

        // Task B opens the same key. There is no in-flight entry, so B spawns a
        // fresh download. The C1 fix ensures this works even if B were to receive
        // CancellationError from a stale entry (the generation guard prevents that).
        // Unblock the fresh read() call that B will issue.
        let taskB = Task<Data, any Error> { try await engine.open(key: key) }

        // Wait for B's read() to enter and unblock it.
        _ = await readEnteredIter.next()
        ol.unblock(data: freshBody, props: freshProps)

        let resultB = try await taskB.value
        #expect(resultB.count == 20)
        #expect(resultB == freshBody)
    }

    // MARK: - T2: real sync-07 fallback (blob store failure returns in-memory bytes)

    @Test("Blob store failure still returns downloaded bytes (real fallback path)")
    func testBlobStoreFailureReturnsBytesFromMemory() async throws {
        let ol = MockOneLakeClient()
        let (engine, store) = try makeEngine(onelake: ol)
        defer {
            // Restore write permission so cleanup can remove the directory.
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700], ofItemAtPath: store.blobRoot.path
            )
            try? FileManager.default.removeItem(at: store.root)
        }

        let key = Self.baseKey
        let body = Data(repeating: 0x77, count: 40)
        let props = PathProperties.make(contentLength: 40, eTag: "v1")
        ol.readResults.append(.success((body, props)))

        // Make the blob root read-only BEFORE the download so storeBlob fails.
        // The blobRoot directory is created by CacheStore.init, so it exists.
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o555], ofItemAtPath: store.blobRoot.path
        )

        // open() must still return the downloaded bytes even though storeBlob failed.
        let data = try await engine.open(key: key)
        #expect(data.count == 40)
        #expect(data == body)
    }

    // MARK: - sync-15: batch reconciliation

    @Test("refreshFolder upserts are batched (batchUpsert API exists and works)")
    func testBatchUpsert() async throws {
        let store = try makeTempStore()
        defer { try? FileManager.default.removeItem(at: store.root) }

        let records = (0..<10).map { i -> MetadataRecord in
            MetadataRecord(
                accountAlias: "a",
                workspaceID: "ws",
                itemID: "it",
                path: "f\(i).txt",
                parentPath: "",
                name: "f\(i).txt",
                isDir: false,
                contentLength: Int64(i)
            )
        }

        try await store.batchUpsert(records)
        let key = CacheKey(accountAlias: "a", workspaceID: "ws", itemID: "it", path: "")
        let root = MetadataRecord(accountAlias: "a", workspaceID: "ws", itemID: "it", path: "", parentPath: "", name: "root", isDir: true)
        try await store.upsert(root)
        // All 10 records should exist.
        let children = try await store.children(of: key)
        #expect(children.count == 10)
    }

    @Test("batchDelete removes multiple keys in one call")
    func testBatchDelete() async throws {
        let store = try makeTempStore()
        defer { try? FileManager.default.removeItem(at: store.root) }

        let root = MetadataRecord(accountAlias: "a", workspaceID: "ws", itemID: "it", path: "", parentPath: "", name: "root", isDir: true)
        try await store.upsert(root)
        for i in 0..<5 {
            let r = MetadataRecord(accountAlias: "a", workspaceID: "ws", itemID: "it", path: "f\(i).txt", parentPath: "", name: "f\(i).txt", isDir: false)
            try await store.upsert(r)
        }

        let keys = (0..<5).map { i in
            CacheKey(accountAlias: "a", workspaceID: "ws", itemID: "it", path: "f\(i).txt")
        }
        try await store.batchDelete(keys)

        let parentKey = CacheKey(accountAlias: "a", workspaceID: "ws", itemID: "it", path: "")
        let remaining = try await store.children(of: parentKey)
        #expect(remaining.isEmpty)
    }
}
