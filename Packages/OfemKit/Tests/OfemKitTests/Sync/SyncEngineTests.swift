import Foundation
@testable import OfemKit
import Testing

// MARK: - SyncEngine Tests

/// Tests for ``SyncEngine`` covering all previously-unverified paths.
@Suite("SyncEngine")
struct SyncEngineTests {
    // MARK: - Helpers

    /// Defaults to `.zero` (always revalidate with a HEAD), not
    /// `SyncEngine.defaultBlobFreshnessTTL`. Most of this suite's `open()`
    /// tests seed the cache row moments before asserting on `getPropertiesCalls`
    /// — with the production default those rows would land inside the TTL
    /// window and the HEAD they assert on would never fire. The TTL-skip
    /// behaviour itself is covered by dedicated tests below that pass a
    /// non-zero `blobFreshnessTTL` explicitly.
    private func makeEngine(
        onelake: any OneLakeClientProtocol = MockOneLakeClient(),
        fabric: MockFabricClient = MockFabricClient(),
        store: CacheStore? = nil,
        blobFreshnessTTL: Duration = .zero
    ) throws -> (SyncEngine, CacheStore) {
        let s = try store ?? makeTempStore()
        // tests-07: nest the scratch dir under store.root so the single
        // `defer { try? FileManager.default.removeItem(at: store.root) }` at
        // each call site cleans both the cache and the partial-download scratch
        // directory — no orphaned temp dirs left in $TMPDIR.
        let scratchDir = s.root.appending(path: "scratch", directoryHint: .isDirectory)
        let engine = SyncEngine(
            cache: s,
            onelake: onelake,
            fabric: fabric,
            scratchBase: scratchDir,
            blobFreshnessTTL: blobFreshnessTTL
        )
        return (engine, s)
    }

    private static let alias = "test"
    private static let wsID = "ws-1"
    private static let itID = "item-1"
    private static let path = "Files/data.csv"

    private static var baseKey: CacheKey {
        CacheKey(accountAlias: alias, workspaceID: wsID, itemID: itID, path: path)
    }

    // NOTE: PartialManager.discard+reset (412 path) coverage has been moved to
    // Sync/PartialManagerTests.swift (tests-12: was misplaced in SyncEngine suite).

    // MARK: - First open: no cache → downloads and returns content

    // tests-08: renamed from "Cache write failure still returns downloaded bytes"
    // (mislabeled — this test never induces a cache failure; it only exercises the
    // happy-path download and verifies the returned file URL is readable).
    @Test("open() downloads and returns correct bytes on first open (no prior cache)")
    func firstOpenDownloadsAndReturnsContent() async throws {
        let ol = MockOneLakeClient()
        let fabric = MockFabricClient()

        // Use a real store to exercise the full blob-write path.
        let (engine, store) = try makeEngine(onelake: ol, fabric: fabric)
        defer { try? FileManager.default.removeItem(at: store.root) }

        let key = Self.baseKey
        let body = Data(repeating: 0x55, count: 50)
        let props = PathProperties.make(contentLength: 50, eTag: "v1")
        ol.readResults.append(.success((body, props)))

        // No cached blob → skip freshness check → download.
        let fileURL = try await engine.open(key: key)
        let data = try Data(contentsOf: fileURL)
        #expect(data.count == 50)
        #expect(data == body)
    }

    // MARK: - sync-06: concurrent opens coalesce

    @Test("Concurrent open() for the same key issues only one download")
    func concurrentOpensCoalesce() async throws {
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
        let (url1, url2) = try await (r1, r2)

        let d1 = try Data(contentsOf: url1)
        let d2 = try Data(contentsOf: url2)
        #expect(d1.count == 30)
        #expect(d2.count == 30)
        // Only one network read should have occurred.
        #expect(ol.readCalls.count == 1)
    }

    // MARK: - sync-19: cache hits don't consume download slots

    @Test("Cache hit does not acquire a download slot")
    func cacheHitSkipsSlotAcquisition() async throws {
        let ol = MockOneLakeClient()
        let fabric = MockFabricClient()

        // Max 1 download slot so a stuck slot would deadlock the second call.
        let store = try makeTempStore()
        // tests-07: nest scratch under store.root so one removeItem covers both.
        let scratchDir = store.root.appending(path: "scratch", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: store.root) }
        let engine = SyncEngine(
            cache: store,
            onelake: ol,
            fabric: fabric,
            maxConcurrentDownloads: 1,
            scratchBase: scratchDir,
            // Force the second open() below through the HEAD (isBlobFresh)
            // path this test asserts on, rather than the TTL fast path.
            blobFreshnessTTL: .zero
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
        let blobURL = try await engine.open(key: key)
        let data = try Data(contentsOf: blobURL)
        #expect(data.count == 10)
        // Only one network read total (the first open).
        #expect(ol.readCalls.count == 1)
    }

    // MARK: - sync-14: macOS metadata filtered at enumeration

    @Test("refreshFolder does not surface .DS_Store entries")
    func macOSMetadataFilteredInEnumeration() async throws {
        let ol = MockOneLakeClient()
        let fabric = MockFabricClient()
        let (engine, store) = try makeEngine(onelake: ol, fabric: fabric)
        defer { try? FileManager.default.removeItem(at: store.root) }

        let key = CacheKey(accountAlias: Self.alias, workspaceID: Self.wsID, itemID: Self.itID, path: "")
        let listing = ListResult(entries: [
            PathEntry(name: "real.csv", isDirectory: false, contentLength: 10, eTag: "e1", lastModified: Date(timeIntervalSince1970: 0)),
            PathEntry(name: ".DS_Store", isDirectory: false, contentLength: 4, eTag: "e2", lastModified: Date(timeIntervalSince1970: 0)),
            PathEntry(name: "._real.csv", isDirectory: false, contentLength: 4, eTag: "e3", lastModified: Date(timeIntervalSince1970: 0)),
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

    // MARK: - F11: OneLakeClient upload-staging files filtered at enumeration

    @Test("refreshFolder does not surface OneLakeClient upload-staging entries")
    func uploadStagingFilteredInEnumeration() async throws {
        // A staging file (finding F11) can be caught mid-flight by a
        // concurrent listing, or left behind entirely if the process is
        // killed between a successful flush and the terminal rename. Either
        // way it must never surface as an ordinary visible file — the same
        // guarantee refreshFolder already gives .DS_Store / ._* junk via
        // isMacOSMetadata.
        let ol = MockOneLakeClient()
        let fabric = MockFabricClient()
        let (engine, store) = try makeEngine(onelake: ol, fabric: fabric)
        defer { try? FileManager.default.removeItem(at: store.root) }

        let key = CacheKey(accountAlias: Self.alias, workspaceID: Self.wsID, itemID: Self.itID, path: "")
        let stagingName = "\(ofemUploadStagingPrefix)\(UUID().uuidString)-real.csv"
        let listing = ListResult(entries: [
            PathEntry(name: "real.csv", isDirectory: false, contentLength: 10, eTag: "e1", lastModified: Date(timeIntervalSince1970: 0)),
            PathEntry(name: stagingName, isDirectory: false, contentLength: 10, eTag: "e2", lastModified: Date(timeIntervalSince1970: 0)),
        ])
        ol.listPathResults.append(.success(listing))

        let diff = try await engine.refreshFolder(key: key)

        // Only real.csv should be added; the staging entry must be filtered.
        #expect(diff.added == 1)
        let children = try await store.children(of: key)
        let paths = children.map(\.name)
        #expect(paths.contains("real.csv"))
        #expect(!paths.contains(stagingName))
    }

    // MARK: - sync-22: enumerate throws wrongItemKind for files

    @Test("enumerate() throws wrongItemKind when key is a file")
    func enumerateThrowsWrongItemKind() async throws {
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
    func headPathMarksPaused() async throws {
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
        let apiErr = HTTPClientError.apiError(APIError(statusCode: 503, status: "503 Service Unavailable", body: try #require(apiBody.data(using: .utf8))))
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

    // NOTE: FPError.classify(.throttled) coverage has been moved to
    // FP/FPErrorClassifyTests.swift (tests-12: was misplaced in SyncEngine suite).

    // MARK: - T1: cancellation-poisoning (C1 livelock fix)

    @Test("Stale cancelled in-flight task does not livelock the key — a fresh open() succeeds")
    func cancelledInFlightTaskDoesNotLivelockKey() async throws {
        let ol = BlockingMockOneLakeClient()
        let (engine, store) = try makeEngine(onelake: ol)
        defer { try? FileManager.default.removeItem(at: store.root) }

        let key = Self.baseKey
        let freshBody = Data(repeating: 0xBB, count: 20)
        let freshProps = PathProperties.make(contentLength: 20, eTag: "v2")

        // Task A starts the download — the blocking mock suspends inside read().
        let taskA = Task<URL, any Error> { try await engine.open(key: key) }

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
        let taskB = Task<URL, any Error> { try await engine.open(key: key) }

        // Wait for B's read() to enter and unblock it.
        _ = await readEnteredIter.next()
        ol.unblock(data: freshBody, props: freshProps)

        let urlB = try await taskB.value
        let resultB = try Data(contentsOf: urlB)
        #expect(resultB.count == 20)
        #expect(resultB == freshBody)
    }

    // MARK: - T2: real sync-07 fallback (blob store failure returns in-memory bytes)

    // tests-08: this test uses chmod 0o555 to force a write failure. That is
    // root-fragile — processes running as root ignore POSIX directory permissions
    // and the write succeeds, so the fallback path is never exercised. A
    // protocol-level injectable cache would be more robust; tracked for the
    // future but left as-is because the test is still valid for non-root CI.
    @Test("Blob store failure still returns downloaded bytes (real fallback path)")
    func blobStoreFailureReturnsBytesFromMemory() async throws {
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

        // open() must still return a usable file URL even though storeBlobFromURL failed.
        let fileURL = try await engine.open(key: key)
        let data = try Data(contentsOf: fileURL)
        #expect(data.count == 40)
        #expect(data == body)
    }

    // MARK: - blocker-1 regression: failed download discards spill so next open re-downloads

    @Test("Non-412 download failure discards the spill so the next open re-downloads from scratch")
    func failedDownloadDiscardsSpill() async throws {
        let ol = MockOneLakeClient()
        let fabric = MockFabricClient()
        let (engine, store) = try makeEngine(onelake: ol, fabric: fabric)
        defer { try? FileManager.default.removeItem(at: store.root) }

        let key = Self.baseKey

        // First attempt: network error mid-download.
        // Wrap a transport error as OneLakeError.httpError (the form SyncEngine receives).
        let networkErr = URLError(.networkConnectionLost)
        ol.readResults.append(.failure(OneLakeError.httpError(networkErr)))

        do {
            _ = try await engine.open(key: key)
            Issue.record("Expected error to be thrown on first open")
        } catch {
            // Expected — download failed.
        }

        // Second attempt: succeeds. If the spill was NOT discarded the engine
        // would try to resume from a stale offset using a stale/missing etag, which
        // could corrupt the download or produce a confusing error. The fix ensures
        // discard() is called so the second open issues a fresh full download.
        let body = Data(repeating: 0xAB, count: 20)
        let props = PathProperties.make(contentLength: 20, eTag: "v1")
        ol.readResults.append(.success((body, props)))

        let url = try await engine.open(key: key)
        let data = try Data(contentsOf: url)
        #expect(data.count == 20)
        #expect(data == body)
        // Exactly one read call for each attempt (first fails, second succeeds).
        #expect(ol.readCalls.count == 2)
        // Second read must use range: nil (full download, not a resume).
        #expect(ol.readCalls[1].range == nil)
    }

    // NOTE: CacheStore.batchUpsert / batchDelete coverage has been moved to
    // Cache/CacheStoreTests.swift (tests-12: was misplaced in SyncEngine suite).

    // MARK: - Paused workspace guard: guardPaused throws before any network call

    @Test("open() throws workspacePaused immediately when workspace is paused in cache")
    func pausedWorkspaceGuardBlocksOpen() async throws {
        let ol = MockOneLakeClient()
        let (engine, store) = try makeEngine(onelake: ol)
        defer { try? FileManager.default.removeItem(at: store.root) }

        // Mark the workspace as paused in the cache.
        let status = WorkspaceStatusRecord(
            accountAlias: Self.alias,
            workspaceID: Self.wsID,
            state: .paused,
            reason: "capacity_paused",
            detectedAtNs: Int64(Date().timeIntervalSince1970 * 1_000_000_000)
        )
        try await store.setWorkspaceStatus(status)

        let key = Self.baseKey
        do {
            _ = try await engine.open(key: key)
            Issue.record("Expected workspacePaused to be thrown")
        } catch SyncError.workspacePaused {
            // Correct.
        }
        // No network call should have been made.
        #expect(ol.readCalls.isEmpty)
    }

    @Test("refreshFolder() throws workspacePaused immediately when workspace is paused")
    func pausedWorkspaceGuardBlocksRefreshFolder() async throws {
        let ol = MockOneLakeClient()
        let (engine, store) = try makeEngine(onelake: ol)
        defer { try? FileManager.default.removeItem(at: store.root) }

        let status = WorkspaceStatusRecord(
            accountAlias: Self.alias,
            workspaceID: Self.wsID,
            state: .paused,
            reason: "capacity_paused",
            detectedAtNs: Int64(Date().timeIntervalSince1970 * 1_000_000_000)
        )
        try await store.setWorkspaceStatus(status)

        let key = CacheKey(accountAlias: Self.alias, workspaceID: Self.wsID, itemID: Self.itID, path: "")
        do {
            _ = try await engine.refreshFolder(key: key)
            Issue.record("Expected workspacePaused to be thrown")
        } catch SyncError.workspacePaused {
            // Correct.
        }
        #expect(ol.listPathCalls.isEmpty)
    }

    @Test("put() throws workspacePaused immediately when workspace is paused")
    func pausedWorkspaceGuardBlocksPut() async throws {
        let ol = MockOneLakeClient()
        let (engine, store) = try makeEngine(onelake: ol)
        defer { try? FileManager.default.removeItem(at: store.root) }

        let status = WorkspaceStatusRecord(
            accountAlias: Self.alias,
            workspaceID: Self.wsID,
            state: .paused,
            reason: "capacity_paused",
            detectedAtNs: Int64(Date().timeIntervalSince1970 * 1_000_000_000)
        )
        try await store.setWorkspaceStatus(status)

        // Write a small temp file to use as source.
        let src = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".txt")
        try Data(repeating: 0xAB, count: 10).write(to: src)
        defer { try? FileManager.default.removeItem(at: src) }

        let key = Self.baseKey
        do {
            try await engine.put(key: key, sourceURL: src)
            Issue.record("Expected workspacePaused to be thrown")
        } catch SyncError.workspacePaused {
            // Correct.
        }
        #expect(ol.writeCalls.isEmpty)
    }

    @Test("delete() throws workspacePaused immediately when workspace is paused")
    func pausedWorkspaceGuardBlocksDelete() async throws {
        let ol = MockOneLakeClient()
        let (engine, store) = try makeEngine(onelake: ol)
        defer { try? FileManager.default.removeItem(at: store.root) }

        let status = WorkspaceStatusRecord(
            accountAlias: Self.alias,
            workspaceID: Self.wsID,
            state: .paused,
            reason: "capacity_paused",
            detectedAtNs: Int64(Date().timeIntervalSince1970 * 1_000_000_000)
        )
        try await store.setWorkspaceStatus(status)

        let key = Self.baseKey
        do {
            try await engine.delete(key: key)
            Issue.record("Expected workspacePaused to be thrown")
        } catch SyncError.workspacePaused {
            // Correct.
        }
        #expect(ol.deleteCalls.isEmpty)
    }

    @Test("mkdir() throws workspacePaused immediately when workspace is paused")
    func pausedWorkspaceGuardBlocksMkdir() async throws {
        let ol = MockOneLakeClient()
        let (engine, store) = try makeEngine(onelake: ol)
        defer { try? FileManager.default.removeItem(at: store.root) }

        let status = WorkspaceStatusRecord(
            accountAlias: Self.alias,
            workspaceID: Self.wsID,
            state: .paused,
            reason: "capacity_paused",
            detectedAtNs: Int64(Date().timeIntervalSince1970 * 1_000_000_000)
        )
        try await store.setWorkspaceStatus(status)

        let key = CacheKey(accountAlias: Self.alias, workspaceID: Self.wsID, itemID: Self.itID, path: "NewDir")
        do {
            try await engine.mkdir(key: key)
            Issue.record("Expected workspacePaused to be thrown")
        } catch SyncError.workspacePaused {
            // Correct.
        }
    }

    // MARK: - refreshFolder: paused-capacity error from listPath marks workspace paused

    @Test("refreshFolder() marks workspace paused when listPath returns a paused-capacity error")
    func refreshFolderMarksPausedOnCapacityError() async throws {
        let ol = MockOneLakeClient()
        let (engine, store) = try makeEngine(onelake: ol)
        defer { try? FileManager.default.removeItem(at: store.root) }

        let apiBody = #"{"errorCode":"CapacityPaused","message":"capacity is currently paused"}"#
        let apiErr = HTTPClientError.apiError(APIError(statusCode: 503, status: "503 Service Unavailable", body: try #require(apiBody.data(using: .utf8))))
        ol.listPathResults.append(.failure(OneLakeError.httpError(apiErr)))

        let key = CacheKey(accountAlias: Self.alias, workspaceID: Self.wsID, itemID: Self.itID, path: "")
        do {
            _ = try await engine.refreshFolder(key: key)
            Issue.record("Expected workspacePaused to be thrown")
        } catch SyncError.workspacePaused {
            // Correct.
        }

        let status = try? await store.workspaceStatus(accountAlias: Self.alias, workspaceID: Self.wsID)
        #expect(status?.state == .paused)
    }

    // MARK: - delete: error propagation and workspace-paused mapping

    @Test("delete() propagates network error when it is not a paused-capacity signal")
    func deletePropagatesNetworkError() async throws {
        let ol = MockOneLakeClient()
        let (engine, store) = try makeEngine(onelake: ol)
        defer { try? FileManager.default.removeItem(at: store.root) }

        let networkErr = URLError(.networkConnectionLost)
        ol.deleteResults.append(.failure(OneLakeError.httpError(networkErr)))

        let key = Self.baseKey
        // tests-11: assert the concrete error type — any throw is not enough.
        do {
            try await engine.delete(key: key)
            Issue.record("Expected OneLakeError.httpError to be rethrown")
        } catch let err as OneLakeError {
            if case .httpError = err {
                // Correct — network error propagated as-is.
            } else {
                Issue.record("Expected .httpError, got \(err)")
            }
        } catch {
            Issue.record("Expected OneLakeError, got \(type(of: error)): \(error)")
        }
    }

    @Test("delete() marks workspace paused and throws workspacePaused on capacity error")
    func deleteMarksPausedOnCapacityError() async throws {
        let ol = MockOneLakeClient()
        let (engine, store) = try makeEngine(onelake: ol)
        defer { try? FileManager.default.removeItem(at: store.root) }

        let apiBody = #"{"errorCode":"CapacityPaused","message":"paused"}"#
        let apiErr = HTTPClientError.apiError(APIError(statusCode: 503, status: "503", body: try #require(apiBody.data(using: .utf8))))
        ol.deleteResults.append(.failure(OneLakeError.httpError(apiErr)))

        let key = Self.baseKey
        do {
            try await engine.delete(key: key)
            Issue.record("Expected workspacePaused")
        } catch SyncError.workspacePaused {
            // Correct.
        }
        let status = try? await store.workspaceStatus(accountAlias: Self.alias, workspaceID: Self.wsID)
        #expect(status?.state == .paused)
    }

    // MARK: - F14: a replayed DELETE that 404s is treated as success

    @Test("delete() treats a notFound error as success (replayed DELETE already committed)")
    func deleteTreatsNotFoundAsSuccess() async throws {
        let ol = MockOneLakeClient()
        let (engine, store) = try makeEngine(onelake: ol)
        defer { try? FileManager.default.removeItem(at: store.root) }

        // Seed a cache row so we can assert it is cleared on the success path.
        let key = Self.baseKey
        try await store.upsert(MetadataRecord(
            accountAlias: Self.alias, workspaceID: Self.wsID, itemID: Self.itID,
            path: Self.path, parentPath: "Files", name: "data.csv", isDir: false
        ))

        // DELETE is retryable in SessionPool; if the delete already committed
        // server-side and the ack was lost, the replay 404s. The row is gone
        // either way, so this must not surface as delete_failed.
        ol.deleteResults.append(.failure(OneLakeError.notFound))

        try await engine.delete(key: key)

        let cached = try? await store.fetch(key: key)
        #expect(cached == nil)
    }

    // MARK: - macOS metadata: put and delete with .DS_Store / ._* paths

    @Test("put() silently ignores .DS_Store uploads (no network call)")
    func putIgnoresDSStore() async throws {
        let ol = MockOneLakeClient()
        let (engine, store) = try makeEngine(onelake: ol)
        defer { try? FileManager.default.removeItem(at: store.root) }

        let src = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".txt")
        try Data(repeating: 0xFF, count: 4).write(to: src)
        defer { try? FileManager.default.removeItem(at: src) }

        let key = CacheKey(accountAlias: Self.alias, workspaceID: Self.wsID, itemID: Self.itID, path: ".DS_Store")
        // Must not throw and must not call onelake.write.
        try await engine.put(key: key, sourceURL: src)
        #expect(ol.writeCalls.isEmpty)
    }

    @Test("put() silently ignores AppleDouble (._*) uploads")
    func putIgnoresAppleDouble() async throws {
        let ol = MockOneLakeClient()
        let (engine, store) = try makeEngine(onelake: ol)
        defer { try? FileManager.default.removeItem(at: store.root) }

        let src = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try Data(repeating: 0x01, count: 8).write(to: src)
        defer { try? FileManager.default.removeItem(at: src) }

        let key = CacheKey(accountAlias: Self.alias, workspaceID: Self.wsID, itemID: Self.itID, path: "._myfile.txt")
        try await engine.put(key: key, sourceURL: src)
        #expect(ol.writeCalls.isEmpty)
    }

    @Test("delete() on .DS_Store only deletes from cache, no remote call")
    func deleteDSStoreLocalOnly() async throws {
        let ol = MockOneLakeClient()
        let (engine, store) = try makeEngine(onelake: ol)
        defer { try? FileManager.default.removeItem(at: store.root) }

        // Seed the cache with a .DS_Store entry.
        let key = CacheKey(accountAlias: Self.alias, workspaceID: Self.wsID, itemID: Self.itID, path: ".DS_Store")
        let record = MetadataRecord(
            accountAlias: Self.alias,
            workspaceID: Self.wsID,
            itemID: Self.itID,
            path: ".DS_Store",
            parentPath: "",
            name: ".DS_Store",
            isDir: false
        )
        try await store.upsert(record)

        try await engine.delete(key: key)

        // No remote delete call.
        #expect(ol.deleteCalls.isEmpty)
        // Row removed from cache.
        let fetched = try? await store.fetch(key: key)
        #expect(fetched == nil)
    }

    // MARK: - mkdir: error propagation

    @Test("mkdir() propagates network error")
    func mkdirPropagatesNetworkError() async throws {
        let ol = MockOneLakeClient()
        let (engine, store) = try makeEngine(onelake: ol)
        defer { try? FileManager.default.removeItem(at: store.root) }

        let networkErr = URLError(.networkConnectionLost)
        ol.createDirectoryResults.append(.failure(OneLakeError.httpError(networkErr)))

        let key = CacheKey(accountAlias: Self.alias, workspaceID: Self.wsID, itemID: Self.itID, path: "NewDir")
        // tests-11: assert the concrete error type, not just that something threw.
        do {
            try await engine.mkdir(key: key)
            Issue.record("Expected OneLakeError.httpError to be rethrown")
        } catch let err as OneLakeError {
            if case .httpError = err {
                // Correct — network error propagated as-is.
            } else {
                Issue.record("Expected .httpError, got \(err)")
            }
        } catch {
            Issue.record("Expected OneLakeError, got \(type(of: error)): \(error)")
        }
    }

    @Test("mkdir() marks workspace paused and throws workspacePaused on capacity error")
    func mkdirMarksPausedOnCapacityError() async throws {
        let ol = MockOneLakeClient()
        let (engine, store) = try makeEngine(onelake: ol)
        defer { try? FileManager.default.removeItem(at: store.root) }

        let apiBody = #"{"errorCode":"CapacityPaused","message":"paused"}"#
        let apiErr = HTTPClientError.apiError(APIError(statusCode: 503, status: "503", body: try #require(apiBody.data(using: .utf8))))
        ol.createDirectoryResults.append(.failure(OneLakeError.httpError(apiErr)))

        let key = CacheKey(accountAlias: Self.alias, workspaceID: Self.wsID, itemID: Self.itID, path: "NewDir")
        do {
            try await engine.mkdir(key: key)
            Issue.record("Expected workspacePaused")
        } catch SyncError.workspacePaused {
            // Correct.
        }
        let status = try? await store.workspaceStatus(accountAlias: Self.alias, workspaceID: Self.wsID)
        #expect(status?.state == .paused)
    }

    @Test("mkdir() succeeds and upserts a directory row in the cache")
    func mkdirUpsertsCacheRow() async throws {
        let ol = MockOneLakeClient()
        let (engine, store) = try makeEngine(onelake: ol)
        defer { try? FileManager.default.removeItem(at: store.root) }

        ol.createDirectoryResults.append(.success(()))

        let key = CacheKey(accountAlias: Self.alias, workspaceID: Self.wsID, itemID: Self.itID, path: "NewDir")
        try await engine.mkdir(key: key)

        let row = try? await store.fetch(key: key)
        #expect(row != nil)
        #expect(row?.isDir == true)
        #expect(row?.name == "NewDir")
    }

    // MARK: - put: success path upserts cache and mirrors blob

    @Test("put() success upserts a file row in the cache with correct path")
    func putSuccessUpsertsCacheRow() async throws {
        let ol = MockOneLakeClient()
        let (engine, store) = try makeEngine(onelake: ol)
        defer { try? FileManager.default.removeItem(at: store.root) }

        let src = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".csv")
        let fileData = Data(repeating: 0xCC, count: 128)
        try fileData.write(to: src)
        defer { try? FileManager.default.removeItem(at: src) }

        ol.writeResults.append(.success(()))
        // Best-effort HEAD after write — engine uses try? so stub not needed;
        // but we add one so the etag is captured.
        let postWriteProps = PathProperties.make(contentLength: 128, eTag: "server-etag")
        ol.getPropertiesResults.append(.success(postWriteProps))

        let key = Self.baseKey
        try await engine.put(key: key, sourceURL: src)

        let row = try? await store.fetch(key: key)
        #expect(row != nil)
        #expect(row?.isDir == false)
        #expect(row?.etag == "server-etag")
        #expect(row?.contentLength == 128)
    }

    @Test("put() propagates write failure")
    func putPropagatesWriteError() async throws {
        let ol = MockOneLakeClient()
        let (engine, store) = try makeEngine(onelake: ol)
        defer { try? FileManager.default.removeItem(at: store.root) }

        let src = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".csv")
        try Data(repeating: 0x42, count: 10).write(to: src)
        defer { try? FileManager.default.removeItem(at: src) }

        let networkErr = URLError(.networkConnectionLost)
        ol.writeResults.append(.failure(OneLakeError.httpError(networkErr)))

        let key = Self.baseKey
        // tests-11: assert the concrete error type, not just that something threw.
        do {
            try await engine.put(key: key, sourceURL: src)
            Issue.record("Expected OneLakeError.httpError to be rethrown")
        } catch let err as OneLakeError {
            if case .httpError = err {
                // Correct — write error propagated as-is.
            } else {
                Issue.record("Expected .httpError, got \(err)")
            }
        } catch {
            Issue.record("Expected OneLakeError, got \(type(of: error)): \(error)")
        }
    }

    // MARK: - HEAD freshness: etag changed falls through to download

    @Test("open() re-downloads when HEAD returns a different etag")
    func headEtagChangedTriggersDownload() async throws {
        let ol = MockOneLakeClient()
        let (engine, store) = try makeEngine(onelake: ol)
        defer { try? FileManager.default.removeItem(at: store.root) }

        let key = Self.baseKey

        // First download: etag v1.
        let body1 = Data(repeating: 0x01, count: 30)
        let props1 = PathProperties.make(contentLength: 30, eTag: "v1")
        ol.readResults.append(.success((body1, props1)))
        _ = try await engine.open(key: key)

        // HEAD returns a new etag (v2) — the cached blob is now stale.
        let propsHead = PathProperties.make(contentLength: 50, eTag: "v2")
        ol.getPropertiesResults.append(.success(propsHead))

        // Second download: new body.
        let body2 = Data(repeating: 0x02, count: 50)
        let props2 = PathProperties.make(contentLength: 50, eTag: "v2")
        ol.readResults.append(.success((body2, props2)))

        let url2 = try await engine.open(key: key)
        let data2 = try Data(contentsOf: url2)
        #expect(data2.count == 50)
        #expect(data2 == body2)
        #expect(ol.readCalls.count == 2)
    }

    @Test("open() serves cache hit when HEAD etag matches cached etag")
    func headEtagMatchedServesCacheHit() async throws {
        let ol = MockOneLakeClient()
        let (engine, store) = try makeEngine(onelake: ol)
        defer { try? FileManager.default.removeItem(at: store.root) }

        let key = Self.baseKey
        let body = Data(repeating: 0x55, count: 20)
        let props = PathProperties.make(contentLength: 20, eTag: "same-etag")
        ol.readResults.append(.success((body, props)))
        _ = try await engine.open(key: key)

        // HEAD returns same etag — cache is fresh.
        ol.getPropertiesResults.append(.success(props))

        let url2 = try await engine.open(key: key)
        let data2 = try Data(contentsOf: url2)
        #expect(data2.count == 20)
        // No second network read — served from cache.
        #expect(ol.readCalls.count == 1)
        // tests-10: exactly one HEAD (getProperties) should have been issued for the
        // freshness check, not zero (which would mean cache was skipped).
        #expect(ol.getPropertiesCalls.count == 1, "expected exactly one HEAD for freshness check")
    }

    @Test("open() falls through to download when cached etag is empty")
    func headEmptyCachedEtagTriggersDownload() async throws {
        let ol = MockOneLakeClient()
        let (engine, store) = try makeEngine(onelake: ol)
        defer { try? FileManager.default.removeItem(at: store.root) }

        let key = Self.baseKey

        // Seed a cache row with a blob SHA but empty etag.
        var record = MetadataRecord(
            accountAlias: Self.alias,
            workspaceID: Self.wsID,
            itemID: Self.itID,
            path: Self.path,
            parentPath: "Files",
            name: "data.csv",
            isDir: false,
            contentLength: 10,
            etag: ""
        )
        record.blobSHA256 = "some-sha"
        try await store.upsert(record)

        // HEAD succeeds but cached etag is empty → isBlobFresh returns false.
        let headProps = PathProperties.make(contentLength: 10, eTag: "server-etag")
        ol.getPropertiesResults.append(.success(headProps))

        let body = Data(repeating: 0xAA, count: 10)
        let props = PathProperties.make(contentLength: 10, eTag: "server-etag")
        ol.readResults.append(.success((body, props)))

        let url = try await engine.open(key: key)
        let data = try Data(contentsOf: url)
        #expect(data.count == 10)
        #expect(ol.readCalls.count == 1)
    }

    // MARK: - TTL-gated freshness HEAD

    @Test("open() within blobFreshnessTTL skips the freshness HEAD entirely")
    func openWithinTTLSkipsHead() async throws {
        let ol = MockOneLakeClient()
        // Production-sized TTL so the second open below lands well inside it.
        let (engine, store) = try makeEngine(onelake: ol, blobFreshnessTTL: .seconds(60))
        defer { try? FileManager.default.removeItem(at: store.root) }

        let key = Self.baseKey
        let body = Data(repeating: 0x77, count: 12)
        let props = PathProperties.make(contentLength: 12, eTag: "v1")
        ol.readResults.append(.success((body, props)))

        // First open: downloads and stamps syncedAtNs to "now".
        _ = try await engine.open(key: key)
        #expect(ol.readCalls.count == 1)

        // Second open, immediately after: the row is well inside the 60 s
        // window, so open() must serve the cached blob without ever calling
        // getProperties.
        let url2 = try await engine.open(key: key)
        let data2 = try Data(contentsOf: url2)
        #expect(data2 == body)
        #expect(ol.getPropertiesCalls.count == 0, "expected no HEAD inside the freshness TTL")
        #expect(ol.readCalls.count == 1, "expected no re-download inside the freshness TTL")
    }

    @Test("open() past the TTL skips the HEAD when already known offline, serving the stale blob")
    func openPastTTLKnownOfflineSkipsHead() async throws {
        let ol = MockOneLakeClient()
        // TTL disabled so every open below reaches the offline/HEAD branch.
        let (engine, store) = try makeEngine(onelake: ol, blobFreshnessTTL: .zero)
        defer { try? FileManager.default.removeItem(at: store.root) }

        let key = Self.baseKey
        let body = Data(repeating: 0x88, count: 8)
        let props = PathProperties.make(contentLength: 8, eTag: "v1")
        ol.readResults.append(.success((body, props)))
        _ = try await engine.open(key: key)
        #expect(ol.readCalls.count == 1)

        // Revalidate fails with an offline-class transport error — marks the
        // engine's OfflineTracker offline and serves the stale blob via the
        // existing post-HEAD-failure fallback.
        let offlineTransport = HTTPClientError.transport(URLError(.notConnectedToInternet))
        ol.getPropertiesResults.append(.failure(OneLakeError.httpError(offlineTransport)))
        _ = try await engine.open(key: key)
        #expect(ol.getPropertiesCalls.count == 1)
        #expect(await engine.currentlyOffline == true)

        // Third open, still offline: must skip the HEAD entirely — issuing
        // one would just block on the network before falling back to the
        // same stale blob. No further stub is queued, so a HEAD attempt here
        // would surface as a second recorded call (and, pre-fix, as
        // MockError.stubsExhausted).
        let url3 = try await engine.open(key: key)
        let data3 = try Data(contentsOf: url3)
        #expect(data3 == body)
        #expect(ol.getPropertiesCalls.count == 1, "known-offline open() must not attempt another HEAD")
    }

    @Test("A row invalidated by refreshFolder forces a real download even within the freshness TTL")
    func refreshFolderInvalidationForcesDownloadWithinTTL() async throws {
        let ol = MockOneLakeClient()
        // Production-sized TTL: after refreshFolder re-stamps the row below,
        // syncedAtNs is "now" and well inside this window — the TTL fast path
        // must still be skipped because blobSHA256 was cleared.
        let (engine, store) = try makeEngine(onelake: ol, blobFreshnessTTL: .seconds(60))
        defer { try? FileManager.default.removeItem(at: store.root) }

        let dirKey = CacheKey(accountAlias: Self.alias, workspaceID: Self.wsID, itemID: Self.itID, path: "Files")
        let key = Self.baseKey // "Files/data.csv"

        // Seed a normal cached download at etag v1.
        let body1 = Data(repeating: 0x01, count: 10)
        let props1 = PathProperties.make(contentLength: 10, eTag: "v1")
        ol.readResults.append(.success((body1, props1)))
        _ = try await engine.open(key: key)

        // The background poll loop's refreshFolder observes a remote etag
        // change (v2). entryChanged detects the delta, so the upserted row
        // carries the new etag with blobSHA256 cleared (unlinked from the
        // stale v1 blob — "Carry blob linkage when etag still matches" does
        // not apply) and a freshly stamped syncedAtNs.
        let listing = ListResult(entries: [
            PathEntry.file(name: "Files/data.csv", size: 20, eTag: "v2", lastModified: Date(timeIntervalSince1970: 0)),
        ])
        ol.listPathResults.append(.success(listing))
        _ = try await engine.refreshFolder(key: dirKey)

        let row = try await store.fetch(key: key)
        #expect(row.etag == "v2")
        #expect(row.blobSHA256.isEmpty, "refreshFolder must clear the blob link on an etag change")

        // open() again, immediately — well inside the 60 s TTL window
        // syncedAtNs was just stamped with. Because blobSHA256 is empty, the
        // TTL fast path's `!c.blobSHA256.isEmpty` guard must keep this out of
        // the cache-hit branch entirely: the engine issues a real download
        // and serves the NEW bytes, not a stale HEAD-free cache hit.
        let body2 = Data(repeating: 0x02, count: 20)
        let props2 = PathProperties.make(contentLength: 20, eTag: "v2")
        ol.readResults.append(.success((body2, props2)))

        let url2 = try await engine.open(key: key)
        let data2 = try Data(contentsOf: url2)
        #expect(data2 == body2, "open() within the TTL must still serve the NEW bytes after invalidation")
        #expect(ol.readCalls.count == 2, "expected a real re-download, not a stale cache hit")
    }

    // MARK: - openReturningRecord

    @Test("openReturningRecord returns the record describing the served bytes, not a pre-download snapshot")
    func openReturningRecordReflectsServedBytes() async throws {
        let ol = MockOneLakeClient()
        // TTL disabled so the second call below always revalidates via HEAD
        // instead of trusting the (now stale) first-download row.
        let (engine, store) = try makeEngine(onelake: ol, blobFreshnessTTL: .zero)
        defer { try? FileManager.default.removeItem(at: store.root) }

        let key = Self.baseKey
        let body1 = Data(repeating: 0x01, count: 10)
        let props1 = PathProperties.make(contentLength: 10, eTag: "v1")
        ol.readResults.append(.success((body1, props1)))

        // First open (download): the returned record must reflect the bytes
        // just downloaded.
        let (url1, record1) = try await engine.openReturningRecord(key: key)
        #expect(record1.etag == "v1")
        #expect(!record1.blobSHA256.isEmpty)
        #expect(try Data(contentsOf: url1) == body1)

        // Remote changed: HEAD reports a new etag, triggering a re-download.
        ol.getPropertiesResults.append(.success(PathProperties.make(contentLength: 20, eTag: "v2")))
        let body2 = Data(repeating: 0x02, count: 20)
        ol.readResults.append(.success((body2, PathProperties.make(contentLength: 20, eTag: "v2"))))

        let (url2, record2) = try await engine.openReturningRecord(key: key)
        // The record must describe the NEW bytes — a stale pre-download
        // fetch would still report v1/10 here.
        #expect(record2.etag == "v2")
        #expect(record2.contentLength == 20)
        #expect(try Data(contentsOf: url2) == body2)
    }

    // MARK: - refreshFolder: item-relative PathEntry.name (issue-244 regression)

    /// Regression test for the double-stripping bug fixed in issue #244.
    ///
    /// After onelake-12 (commit 6d3c25f), `OneLakeClient.listPath` returns
    /// `PathEntry.name` values that are already item-relative — the `<itemGUID>/`
    /// prefix is stripped by `convertRawEntry` inside the client. Before the fix,
    /// `SyncEngine.refreshFolder` called `Enumerator.stripItemPrefix` on those
    /// already-stripped names, which returned `nil` for every entry (the itemGUID
    /// was not present as a prefix) and left `remoteChildren` empty — causing zero
    /// children to be reconciled into the cache.
    ///
    /// This test drives `refreshFolder` with a mock returning item-relative names
    /// (matching what the real client returns) and asserts all children are cached.
    @Test("refreshFolder() reconciles item-relative PathEntry.name values into the cache (issue-244)")
    func refreshFolderItemRelativeNames() async throws {
        let ol = MockOneLakeClient()
        let (engine, store) = try makeEngine(onelake: ol)
        defer { try? FileManager.default.removeItem(at: store.root) }

        // Directory at a nested path, as used by the integration tests.
        let dir = "Files/ofem-ci/test-run"
        let key = CacheKey(
            accountAlias: Self.alias,
            workspaceID: Self.wsID,
            itemID: Self.itID,
            path: dir
        )

        // Item-relative names — no "<itemGUID>/" prefix.  This matches what
        // OneLakeClient.listPath returns after onelake-12.
        ol.listPathResults.append(.success(ListResult(entries: [
            PathEntry(name: "\(dir)/alpha.bin", isDirectory: false, contentLength: 100, eTag: "e1", lastModified: .distantPast),
            PathEntry(name: "\(dir)/beta.bin", isDirectory: false, contentLength: 200, eTag: "e2", lastModified: .distantPast),
            PathEntry(name: "\(dir)/sub", isDirectory: true, contentLength: 0, eTag: "", lastModified: .distantPast),
        ])))

        let diff = try await engine.refreshFolder(key: key)

        // Before the fix, all three entries were dropped (remoteChildren empty)
        // because stripItemPrefix returned nil for every item-relative name.
        #expect(diff.added == 3, "refreshFolder must add all 3 remote entries")

        let kids = try await store.children(of: key)
        #expect(kids.count == 3, "cache must contain 3 children after refresh")

        let alpha = kids.first { $0.name == "alpha.bin" }
        #expect(alpha != nil, "alpha.bin must be cached")
        #expect(alpha?.isDir == false)
        #expect(alpha?.contentLength == 100)

        let sub = kids.first { $0.name == "sub" }
        #expect(sub != nil, "sub directory must be cached")
        #expect(sub?.isDir == true)
    }

    // MARK: - refreshFolder: empty remote listing removes all cached children

    @Test("refreshFolder() with empty remote listing deletes all cached children")
    func refreshFolderEmptyRemovesCachedChildren() async throws {
        let ol = MockOneLakeClient()
        let (engine, store) = try makeEngine(onelake: ol)
        defer { try? FileManager.default.removeItem(at: store.root) }

        let key = CacheKey(accountAlias: Self.alias, workspaceID: Self.wsID, itemID: Self.itID, path: "")

        // Seed two children in the cache.
        let parent = MetadataRecord(accountAlias: Self.alias, workspaceID: Self.wsID, itemID: Self.itID,
                                    path: "", parentPath: "", name: "root", isDir: true)
        let child1 = MetadataRecord(accountAlias: Self.alias, workspaceID: Self.wsID, itemID: Self.itID,
                                    path: "a.csv", parentPath: "", name: "a.csv", isDir: false)
        let child2 = MetadataRecord(accountAlias: Self.alias, workspaceID: Self.wsID, itemID: Self.itID,
                                    path: "b.csv", parentPath: "", name: "b.csv", isDir: false)
        try await store.upsert(parent)
        try await store.upsert(child1)
        try await store.upsert(child2)

        // Remote listing returns nothing.
        ol.listPathResults.append(.success(ListResult(entries: [])))

        let diff = try await engine.refreshFolder(key: key)
        #expect(diff.removed == 2)
        #expect(diff.added == 0)

        let children = try await store.children(of: key)
        #expect(children.isEmpty)
    }

    // MARK: - refreshFolder: remote item vanished (stale cached child removed)

    @Test("refreshFolder() removes a cached entry when its remote counterpart disappears")
    func refreshFolderRemovesVanishedRemoteItem() async throws {
        let ol = MockOneLakeClient()
        let (engine, store) = try makeEngine(onelake: ol)
        defer { try? FileManager.default.removeItem(at: store.root) }

        let key = CacheKey(accountAlias: Self.alias, workspaceID: Self.wsID, itemID: Self.itID, path: "")

        // Seed three children.
        let parent = MetadataRecord(accountAlias: Self.alias, workspaceID: Self.wsID, itemID: Self.itID,
                                    path: "", parentPath: "", name: "root", isDir: true)
        try await store.upsert(parent)
        for name in ["keep.csv", "gone.csv", "also-keep.csv"] {
            let r = MetadataRecord(accountAlias: Self.alias, workspaceID: Self.wsID, itemID: Self.itID,
                                   path: name, parentPath: "", name: name, isDir: false)
            try await store.upsert(r)
        }

        // Remote only returns keep.csv and also-keep.csv.
        let listing = ListResult(entries: [
            PathEntry(name: "keep.csv", isDirectory: false, contentLength: 10, eTag: "e1", lastModified: .distantPast),
            PathEntry(name: "also-keep.csv", isDirectory: false, contentLength: 10, eTag: "e2", lastModified: .distantPast),
        ])
        ol.listPathResults.append(.success(listing))

        let diff = try await engine.refreshFolder(key: key)
        #expect(diff.removed == 1)

        let remaining = try await store.children(of: key)
        let names = remaining.map(\.name)
        #expect(names.contains("keep.csv"))
        #expect(names.contains("also-keep.csv"))
        #expect(!names.contains("gone.csv"))
    }

    // MARK: - refreshFolder: delete-phase DB error rolls back atomically (#427)

    /// Issue #427 / review finding M2: refreshFolder's upsert and delete phases
    /// used to be separate transactions, and both swallowed DB errors (log-only).
    /// A delete-phase failure after the upserts had already committed left
    /// vanished rows in the cache with no tombstone while the sync anchor (the
    /// max synced_at_ns, already advanced by the committed upserts) moved past
    /// them regardless. This test installs a `BEFORE DELETE` trigger that fails
    /// exactly the deletion of one vanished child — a stand-in for a transient
    /// SQLITE_BUSY/SQLITE_FULL — and asserts the failure propagates AND the
    /// whole reconcile (including the co-occurring upsert of a brand-new child)
    /// rolled back, rather than leaving a partially-applied cache.
    @Test("refreshFolder() propagates a delete-phase DB error and rolls back the co-committed upserts")
    func refreshFolderDeletePhaseFailureRollsBackUpserts() async throws {
        let ol = MockOneLakeClient()
        let (engine, store) = try makeEngine(onelake: ol)
        defer { try? FileManager.default.removeItem(at: store.root) }

        let key = CacheKey(accountAlias: Self.alias, workspaceID: Self.wsID, itemID: Self.itID, path: "")

        // Seed a parent row plus two children.
        let parent = MetadataRecord(accountAlias: Self.alias, workspaceID: Self.wsID, itemID: Self.itID,
                                    path: "", parentPath: "", name: "root", isDir: true)
        try await store.upsert(parent)
        for name in ["keep.csv", "gone.csv"] {
            let r = MetadataRecord(accountAlias: Self.alias, workspaceID: Self.wsID, itemID: Self.itID,
                                   path: name, parentPath: "", name: name, isDir: false)
            try await store.upsert(r)
        }

        // A trigger that fails ONLY the "gone.csv" delete, so it fires deep
        // inside the delete phase — after the upsert phase (below) has already
        // run its INSERT/UPDATE statements in the SAME transaction.
        try await store.dbPool.write { db in
            try db.execute(sql: """
            CREATE TEMP TRIGGER fail_gone_delete BEFORE DELETE ON path_metadata
            WHEN OLD.path = 'gone.csv'
            BEGIN SELECT RAISE(ABORT, 'issue-427 simulated delete-phase failure'); END;
            """)
        }

        // Remote listing: keep.csv survives, gone.csv vanished, new.csv is a
        // brand-new child — so this pass has both an upsert and a delete.
        let listing = ListResult(entries: [
            PathEntry(name: "keep.csv", isDirectory: false, contentLength: 10, eTag: "e1", lastModified: .distantPast),
            PathEntry(name: "new.csv", isDirectory: false, contentLength: 20, eTag: "e2", lastModified: .distantPast),
        ])
        ol.listPathResults.append(.success(listing))

        await #expect(throws: (any Error).self) {
            try await engine.refreshFolder(key: key)
        }

        // The delete-phase failure must roll back the WHOLE reconcile
        // transaction, not just the failing delete: new.csv must not have been
        // committed, and gone.csv must still be present and un-tombstoned — no
        // partial state where upserts landed but the vanished row silently
        // dropped out of the incremental delta.
        let children = try await store.children(of: key)
        let names = Set(children.map(\.name))
        #expect(names == ["keep.csv", "gone.csv"])
    }

    // MARK: - refreshFolder: etag carry-over when unchanged

    @Test("refreshFolder() carries blob linkage when remote etag is unchanged")
    func refreshFolderCarriesBlobLinkageOnUnchangedEtag() async throws {
        let ol = MockOneLakeClient()
        let (engine, store) = try makeEngine(onelake: ol)
        defer { try? FileManager.default.removeItem(at: store.root) }

        let key = CacheKey(accountAlias: Self.alias, workspaceID: Self.wsID, itemID: Self.itID, path: "")

        // Seed a parent and one child with a known etag + blobSHA256.
        let parent = MetadataRecord(accountAlias: Self.alias, workspaceID: Self.wsID, itemID: Self.itID,
                                    path: "", parentPath: "", name: "root", isDir: true)
        var child = MetadataRecord(accountAlias: Self.alias, workspaceID: Self.wsID, itemID: Self.itID,
                                   path: "data.csv", parentPath: "", name: "data.csv", isDir: false,
                                   contentLength: 50, etag: "stable-etag")
        child.blobSHA256 = "sha-abc"
        try await store.upsert(parent)
        try await store.upsert(child)

        // Remote returns same etag → blob linkage should be preserved.
        let listing = ListResult(entries: [
            PathEntry(name: "data.csv", isDirectory: false, contentLength: 50, eTag: "stable-etag", lastModified: .distantPast),
        ])
        ol.listPathResults.append(.success(listing))

        _ = try await engine.refreshFolder(key: key)

        let updated = try? await store.fetch(key: CacheKey(
            accountAlias: Self.alias, workspaceID: Self.wsID, itemID: Self.itID, path: "data.csv"
        ))
        #expect(updated?.blobSHA256 == "sha-abc")
    }

    @Test("refreshFolder() clears blob linkage when remote etag changes")
    func refreshFolderClearsBlobLinkageOnEtagChange() async throws {
        let ol = MockOneLakeClient()
        let (engine, store) = try makeEngine(onelake: ol)
        defer { try? FileManager.default.removeItem(at: store.root) }

        let key = CacheKey(accountAlias: Self.alias, workspaceID: Self.wsID, itemID: Self.itID, path: "")

        let parent = MetadataRecord(accountAlias: Self.alias, workspaceID: Self.wsID, itemID: Self.itID,
                                    path: "", parentPath: "", name: "root", isDir: true)
        var child = MetadataRecord(accountAlias: Self.alias, workspaceID: Self.wsID, itemID: Self.itID,
                                   path: "data.csv", parentPath: "", name: "data.csv", isDir: false,
                                   contentLength: 50, etag: "old-etag")
        child.blobSHA256 = "sha-old"
        try await store.upsert(parent)
        try await store.upsert(child)

        // Remote returns a new etag.
        let listing = ListResult(entries: [
            PathEntry(name: "data.csv", isDirectory: false, contentLength: 60, eTag: "new-etag", lastModified: Date()),
        ])
        ol.listPathResults.append(.success(listing))

        _ = try await engine.refreshFolder(key: key)

        let updated = try? await store.fetch(key: CacheKey(
            accountAlias: Self.alias, workspaceID: Self.wsID, itemID: Self.itID, path: "data.csv"
        ))
        // tests-18: assert the exact canonical cleared representation ("") rather than
        // a disjunction — MetadataRecord.blobSHA256 defaults to "" when blob linkage
        // is not carried (etag changed path in SyncEngine.refreshFolder).
        #expect(updated?.blobSHA256 == "", "blobSHA256 must be cleared (empty string) when etag changes")
        #expect(updated?.etag == "new-etag")
    }

    // MARK: - listWorkspaces: Fabric error rethrown when not capacity-paused

    @Test("listWorkspaces() rethrows non-paused Fabric errors")
    func listWorkspacesRethrowsNonPausedError() async throws {
        let ol = MockOneLakeClient()
        let fabric = MockFabricClient()
        let (engine, store) = try makeEngine(onelake: ol, fabric: fabric)
        defer { try? FileManager.default.removeItem(at: store.root) }

        fabric.listWorkspacesResults.append(.failure(MockError.intentional("network down")))

        // tests-11: assert the concrete error type (MockError.intentional), not just that
        // something threw. A wrong error type (e.g. mis-mapped SyncError) would still pass
        // the old `threw == true` check.
        do {
            _ = try await engine.listWorkspaces(alias: Self.alias)
            Issue.record("Expected MockError.intentional to be rethrown")
        } catch MockError.intentional {
            // Correct — non-paused error propagated as-is.
        } catch {
            Issue.record("Expected MockError.intentional, got \(type(of: error)): \(error)")
        }
    }

    @Test("listWorkspaces() marks paused and throws workspacePaused on capacity error")
    func listWorkspacesMarksPausedOnCapacityError() async throws {
        let ol = MockOneLakeClient()
        let fabric = MockFabricClient()
        let (engine, store) = try makeEngine(onelake: ol, fabric: fabric)
        defer { try? FileManager.default.removeItem(at: store.root) }

        let apiBody = #"{"errorCode":"CapacityPaused","message":"capacity is paused"}"#
        let apiErr = HTTPClientError.apiError(APIError(statusCode: 503, status: "503", body: try #require(apiBody.data(using: .utf8))))
        fabric.listWorkspacesResults.append(.failure(FabricError.httpError(apiErr)))

        do {
            _ = try await engine.listWorkspaces(alias: Self.alias)
            Issue.record("Expected workspacePaused")
        } catch SyncError.workspacePaused {
            // Correct.
        }

        let status = try? await store.workspaceStatus(accountAlias: Self.alias, workspaceID: VirtualIDs.workspaceID)
        #expect(status?.state == .paused)
    }

    @Test("listWorkspaces() returns workspaces and stamps cache rows on success")
    func listWorkspacesSuccessStampsCache() async throws {
        let ol = MockOneLakeClient()
        let fabric = MockFabricClient()
        let (engine, store) = try makeEngine(onelake: ol, fabric: fabric)
        defer { try? FileManager.default.removeItem(at: store.root) }

        let workspaces = [
            Workspace(id: "ws-a", displayName: "Alpha", type: "Workspace"),
            Workspace(id: "ws-b", displayName: "Beta", type: "Workspace"),
        ]
        fabric.listWorkspacesResults.append(.success(workspaces))

        let got = try await engine.listWorkspaces(alias: Self.alias)
        #expect(got.count == 2)
        #expect(got[0].id == "ws-a")

        // Cache should have rows for each workspace.
        let parentKey = CacheKey(
            accountAlias: Self.alias,
            workspaceID: VirtualIDs.workspaceID,
            itemID: VirtualIDs.workspaceID,
            path: ""
        )
        let children = try await store.children(of: parentKey)
        let paths = children.map(\.path)
        #expect(paths.contains("ws-a"))
        #expect(paths.contains("ws-b"))
    }

    // MARK: - listItems: Fabric error handling

    @Test("listItems() rethrows non-paused Fabric errors")
    func listItemsRethrowsNonPausedError() async throws {
        let ol = MockOneLakeClient()
        let fabric = MockFabricClient()
        let (engine, store) = try makeEngine(onelake: ol, fabric: fabric)
        defer { try? FileManager.default.removeItem(at: store.root) }

        fabric.listItemsResults.append(.failure(MockError.intentional("timeout")))

        // tests-11: assert the concrete error type, not just that something threw.
        do {
            _ = try await engine.listItems(alias: Self.alias, workspaceID: Self.wsID)
            Issue.record("Expected MockError.intentional to be rethrown")
        } catch MockError.intentional {
            // Correct — non-paused error propagated as-is.
        } catch {
            Issue.record("Expected MockError.intentional, got \(type(of: error)): \(error)")
        }
    }

    @Test("listItems() returns only storage-backed items and stamps their cache rows")
    func listItemsSuccessStampsCache() async throws {
        let ol = MockOneLakeClient()
        let fabric = MockFabricClient()
        let (engine, store) = try makeEngine(onelake: ol, fabric: fabric)
        defer { try? FileManager.default.removeItem(at: store.root) }

        // Fabric returns a Lakehouse and a Notebook; only the Lakehouse is storage-backed.
        let items = [
            Item(id: "it-1", displayName: "Lakehouse 1", type: "Lakehouse", workspaceID: Self.wsID),
            Item(id: "it-2", displayName: "Notebook 1", type: "Notebook", workspaceID: Self.wsID),
        ]
        fabric.listItemsResults.append(.success(items))

        let got = try await engine.listItems(alias: Self.alias, workspaceID: Self.wsID)
        // Notebook is a non-storage item and must be filtered out.
        #expect(got.count == 1)
        #expect(got[0].id == "it-1")

        let parentKey = CacheKey(
            accountAlias: Self.alias,
            workspaceID: Self.wsID,
            itemID: VirtualIDs.itemID,
            path: ""
        )
        let children = try await store.children(of: parentKey)
        let paths = children.map(\.path)
        #expect(paths.contains("it-1"))
        // Non-storage item must not appear in the cache either.
        #expect(!paths.contains("it-2"))
    }

    // MARK: - issue-296: non-storage item types filtered from workspace listing

    /// Regression test for issue #296.
    ///
    /// A Fabric Lakehouse auto-creates a SQLEndpoint and sometimes a default
    /// SemanticModel with the same `displayName`. Without filtering, both the
    /// Lakehouse and its SQLEndpoint appear as browsable folders in Finder, and
    /// macOS de-duplicates the display name by appending " 2".
    ///
    /// `listItems` must return only the four allowlisted item types
    /// (Lakehouse, Warehouse, MirroredDatabase, SQLDatabase) and exclude
    /// everything else (SQLEndpoint, SemanticModel, Notebook, Report, …).
    @Test("listItems() filters non-allowlisted item types, eliminating ' 2' duplicate entries (issue-296)")
    func listItemsFiltersNonStorageTypes() async throws {
        let ol = MockOneLakeClient()
        let fabric = MockFabricClient()
        let (engine, store) = try makeEngine(onelake: ol, fabric: fabric)
        defer { try? FileManager.default.removeItem(at: store.root) }

        // Simulate a real workspace: a Lakehouse whose auto-created SQLEndpoint
        // and default SemanticModel share the same displayName, plus a Warehouse,
        // a SQLDatabase, and a Notebook.
        let fabricItems = [
            Item(id: "lh-1", displayName: "Sales", type: "Lakehouse", workspaceID: Self.wsID),
            Item(id: "sql-1", displayName: "Sales", type: "SQLEndpoint", workspaceID: Self.wsID),
            Item(id: "sm-1", displayName: "Sales", type: "SemanticModel", workspaceID: Self.wsID),
            Item(id: "wh-1", displayName: "DW", type: "Warehouse", workspaceID: Self.wsID),
            Item(id: "sdb-1", displayName: "Mirror", type: "SQLDatabase", workspaceID: Self.wsID),
            Item(id: "nb-1", displayName: "EDA", type: "Notebook", workspaceID: Self.wsID),
        ]
        fabric.listItemsResults.append(.success(fabricItems))

        let got = try await engine.listItems(alias: Self.alias, workspaceID: Self.wsID)

        // Only the three storage-backed items must come back.
        #expect(got.count == 3)
        let ids = got.map(\.id)
        #expect(ids.contains("lh-1"), "Lakehouse must be returned")
        #expect(ids.contains("wh-1"), "Warehouse must be returned")
        #expect(ids.contains("sdb-1"), "SQLDatabase must be returned")
        #expect(!ids.contains("sql-1"), "SQLEndpoint must be filtered out")
        #expect(!ids.contains("sm-1"), "SemanticModel must be filtered out")
        #expect(!ids.contains("nb-1"), "Notebook must be filtered out")

        // Non-storage items must not appear in the discovery cache either.
        let parentKey = CacheKey(
            accountAlias: Self.alias,
            workspaceID: Self.wsID,
            itemID: VirtualIDs.itemID,
            path: ""
        )
        let cachedPaths = try await store.children(of: parentKey).map(\.path)
        #expect(cachedPaths.contains("lh-1"))
        #expect(cachedPaths.contains("wh-1"))
        #expect(cachedPaths.contains("sdb-1"))
        #expect(!cachedPaths.contains("sql-1"))
        #expect(!cachedPaths.contains("sm-1"))
        #expect(!cachedPaths.contains("nb-1"))
    }

    @Test("listItems() hides unknown item types (allowlist policy: hide by default)")
    func listItemsHidesUnknownTypes() async throws {
        let ol = MockOneLakeClient()
        let fabric = MockFabricClient()
        let (engine, store) = try makeEngine(onelake: ol, fabric: fabric)
        defer { try? FileManager.default.removeItem(at: store.root) }

        let fabricItems = [
            Item(id: "k-1", displayName: "Known", type: "Lakehouse", workspaceID: Self.wsID),
            Item(id: "u-1", displayName: "Unknown", type: "FutureItemType", workspaceID: Self.wsID),
            Item(id: "e-1", displayName: "Empty", type: "", workspaceID: Self.wsID),
        ]
        fabric.listItemsResults.append(.success(fabricItems))

        let got = try await engine.listItems(alias: Self.alias, workspaceID: Self.wsID)

        // Only the Lakehouse is in the allowlist; FutureItemType and empty type
        // are hidden by the strict allowlist policy.
        #expect(got.count == 1)
        let ids = got.map(\.id)
        #expect(ids.contains("k-1"))
        #expect(!ids.contains("u-1"), "unknown type must be hidden by allowlist")
        #expect(!ids.contains("e-1"), "empty type must be hidden by allowlist")
    }

    @Test("Item.hasOneLakeStorage reflects strict allowlist: true only for Lakehouse/Warehouse/MirroredDatabase/SQLDatabase")
    func itemHasOneLakeStorageAllowlistContents() {
        func item(type: String) -> Item {
            Item(id: "x", displayName: "x", type: type, workspaceID: "w")
        }
        // The four allowed types must be visible.
        #expect(item(type: "Lakehouse").hasOneLakeStorage)
        #expect(item(type: "Warehouse").hasOneLakeStorage)
        #expect(item(type: "MirroredDatabase").hasOneLakeStorage)
        #expect(item(type: "SQLDatabase").hasOneLakeStorage)
        // Types that have OneLake storage but are not yet supported are hidden.
        #expect(!item(type: "KQLDatabase").hasOneLakeStorage)
        #expect(!item(type: "Eventhouse").hasOneLakeStorage)
        #expect(!item(type: "MirroredWarehouse").hasOneLakeStorage)
        // Non-storage types must also be hidden.
        #expect(!item(type: "SQLEndpoint").hasOneLakeStorage)
        #expect(!item(type: "SemanticModel").hasOneLakeStorage)
        #expect(!item(type: "Notebook").hasOneLakeStorage)
        #expect(!item(type: "Report").hasOneLakeStorage)
        #expect(!item(type: "Dashboard").hasOneLakeStorage)
        #expect(!item(type: "DataPipeline").hasOneLakeStorage)
        // Unknown / future types are hidden by default.
        #expect(!item(type: "FutureItemType").hasOneLakeStorage)
        #expect(!item(type: "").hasOneLakeStorage)
    }

    @Test("Item.hasOneLakeStorage is case-insensitive for the four allowed types")
    func itemHasOneLakeStorageCaseInsensitive() {
        func item(type: String) -> Item {
            Item(id: "x", displayName: "x", type: type, workspaceID: "w")
        }
        // All-lower
        #expect(item(type: "lakehouse").hasOneLakeStorage)
        #expect(item(type: "warehouse").hasOneLakeStorage)
        #expect(item(type: "mirroreddatabase").hasOneLakeStorage)
        #expect(item(type: "sqldatabase").hasOneLakeStorage)
        // All-upper
        #expect(item(type: "LAKEHOUSE").hasOneLakeStorage)
        #expect(item(type: "WAREHOUSE").hasOneLakeStorage)
        #expect(item(type: "MIRROREDDATABASE").hasOneLakeStorage)
        #expect(item(type: "SQLDATABASE").hasOneLakeStorage)
        // Mixed case
        #expect(item(type: "LakeHouse").hasOneLakeStorage)
        #expect(item(type: "WareHouse").hasOneLakeStorage)
        #expect(item(type: "MirroredDatabase").hasOneLakeStorage)
        #expect(item(type: "SqlDatabase").hasOneLakeStorage)
        // Case-insensitive match must not accidentally allow other types.
        #expect(!item(type: "KQLDATABASE").hasOneLakeStorage)
        #expect(!item(type: "notebook").hasOneLakeStorage)
    }

    @Test("listItems() evicts previously-cached rows that are now excluded by the allowlist via expireDiscoveryRows")
    func listItemsEvictsPrecachedNonStorageRow() async throws {
        let ol = MockOneLakeClient()
        let fabric = MockFabricClient()
        let (engine, store) = try makeEngine(onelake: ol, fabric: fabric)
        defer { try? FileManager.default.removeItem(at: store.root) }

        // Simulate rows written by a pre-allowlist build: a SQLEndpoint (never had
        // storage) and a KQLDatabase (has storage but is not in the allowlist)
        // cached under the workspace items parent. expireDiscoveryRows must evict both
        // because neither "sql-stale" nor "kql-stale" is in the `seen` set built from
        // the four allowed item types (Lakehouse, Warehouse, MirroredDatabase, SQLDatabase).
        let sqlRow = MetadataRecord(
            accountAlias: Self.alias,
            workspaceID: Self.wsID,
            itemID: VirtualIDs.itemID,
            path: "sql-stale",
            parentPath: "",
            name: "Sales",
            isDir: true,
            lastAccessedNs: 0,
            syncedAtNs: 0
        )
        let kqlRow = MetadataRecord(
            accountAlias: Self.alias,
            workspaceID: Self.wsID,
            itemID: VirtualIDs.itemID,
            path: "kql-stale",
            parentPath: "",
            name: "Events",
            isDir: true,
            lastAccessedNs: 0,
            syncedAtNs: 0
        )
        try await store.upsert(sqlRow)
        try await store.upsert(kqlRow)

        // Fabric returns both excluded items and one allowed Lakehouse.
        fabric.listItemsResults.append(.success([
            Item(id: "sql-stale", displayName: "Sales", type: "SQLEndpoint", workspaceID: Self.wsID),
            Item(id: "kql-stale", displayName: "Events", type: "KQLDatabase", workspaceID: Self.wsID),
            Item(id: "lh-1", displayName: "Sales", type: "Lakehouse", workspaceID: Self.wsID),
        ]))
        _ = try await engine.listItems(alias: Self.alias, workspaceID: Self.wsID)

        let parentKey = CacheKey(
            accountAlias: Self.alias,
            workspaceID: Self.wsID,
            itemID: VirtualIDs.itemID,
            path: ""
        )
        let paths = try await store.children(of: parentKey).map(\.path)
        #expect(!paths.contains("sql-stale"), "expireDiscoveryRows must evict pre-cached SQLEndpoint rows")
        #expect(!paths.contains("kql-stale"), "expireDiscoveryRows must evict pre-cached KQLDatabase rows")
        #expect(paths.contains("lh-1"), "Lakehouse must remain in cache")
    }

    // MARK: - listItems: evicts stale discovery rows

    @Test("listItems() evicts a stale discovery row that was filtered out by the allowlist")
    func listItemsEvictsFilteredDiscoveryRow() async throws {
        let ol = MockOneLakeClient()
        let fabric = MockFabricClient()
        let (engine, store) = try makeEngine(onelake: ol, fabric: fabric)
        defer { try? FileManager.default.removeItem(at: store.root) }

        // A pre-cached SQLEndpoint that will be filtered out by the allowlist —
        // the now-filtered row that leaves a `<name> 2` duplicate in Finder.
        let staleRow = MetadataRecord(
            accountAlias: Self.alias, workspaceID: Self.wsID, itemID: VirtualIDs.itemID,
            path: "sql-stale", parentPath: "", name: "Sales", isDir: true
        )
        try await store.upsert(staleRow)

        // Fabric returns only an allowed Lakehouse; the SQLEndpoint is gone.
        fabric.listItemsResults.append(.success([
            Item(id: "lh-1", displayName: "Sales", type: "Lakehouse", workspaceID: Self.wsID),
        ]))
        _ = try await engine.listItems(alias: Self.alias, workspaceID: Self.wsID)

        // The stale row is hard-deleted (not resurrected).
        let parentKey = CacheKey(
            accountAlias: Self.alias, workspaceID: Self.wsID, itemID: VirtualIDs.itemID, path: ""
        )
        let paths = try await store.children(of: parentKey).map(\.path)
        #expect(!paths.contains("sql-stale"))
        #expect(paths.contains("lh-1"))
    }

    @Test("listItems() does not evict rows when all remote items are present in cache")
    func listItemsNoEvictionWhenNothingRemoved() async throws {
        let ol = MockOneLakeClient()
        let fabric = MockFabricClient()
        let (engine, store) = try makeEngine(onelake: ol, fabric: fabric)
        defer { try? FileManager.default.removeItem(at: store.root) }

        // Empty cache, single allowed item → nothing to expire.
        fabric.listItemsResults.append(.success([
            Item(id: "lh-1", displayName: "Sales", type: "Lakehouse", workspaceID: Self.wsID),
        ]))
        _ = try await engine.listItems(alias: Self.alias, workspaceID: Self.wsID)

        let parentKey = CacheKey(
            accountAlias: Self.alias, workspaceID: Self.wsID, itemID: VirtualIDs.itemID, path: ""
        )
        let paths = try await store.children(of: parentKey).map(\.path)
        #expect(paths.contains("lh-1"))
    }

    // MARK: - enumerate: stale cache triggers refresh

    @Test("enumerate() issues a remote refresh when the cached listing is stale")
    func enumerateStaleRefreshesFromRemote() async throws {
        let ol = MockOneLakeClient()
        let fabric = MockFabricClient()
        // Use a very short TTL (1 s) so the cached row is fresh, then check
        // that an empty cache routes through refreshFolder.
        let (engine, store) = try makeEngine(onelake: ol, fabric: fabric)
        defer { try? FileManager.default.removeItem(at: store.root) }

        let key = CacheKey(accountAlias: Self.alias, workspaceID: Self.wsID, itemID: Self.itID, path: "")

        // No parent row in cache → enumerate must call refreshFolder.
        let listing = ListResult(entries: [
            PathEntry(name: "hello.txt", isDirectory: false, contentLength: 5, eTag: "e1", lastModified: .distantPast),
        ])
        ol.listPathResults.append(.success(listing))

        let children = try await engine.enumerate(key: key)
        #expect(children.count == 1)
        #expect(children[0].name == "hello.txt")
        #expect(ol.listPathCalls.count == 1)
    }

    @Test("enumerate() serves from cache when listing is fresh")
    func enumerateServesFromFreshCache() async throws {
        let ol = MockOneLakeClient()
        let (engine, store) = try makeEngine(onelake: ol)
        defer { try? FileManager.default.removeItem(at: store.root) }

        let key = CacheKey(accountAlias: Self.alias, workspaceID: Self.wsID, itemID: Self.itID, path: "")
        let nowNs = Int64(Date().timeIntervalSince1970 * 1_000_000_000)

        // Insert a fresh parent row (childrenSyncedAtNs = now).
        let parent = MetadataRecord(
            accountAlias: Self.alias, workspaceID: Self.wsID, itemID: Self.itID,
            path: "", parentPath: "", name: "root", isDir: true,
            childrenSyncedAtNs: nowNs
        )
        let child = MetadataRecord(
            accountAlias: Self.alias, workspaceID: Self.wsID, itemID: Self.itID,
            path: "cached.csv", parentPath: "", name: "cached.csv", isDir: false
        )
        try await store.upsert(parent)
        try await store.upsert(child)

        let children = try await engine.enumerate(key: key)
        #expect(children.count == 1)
        #expect(children[0].name == "cached.csv")
        // No remote call.
        #expect(ol.listPathCalls.isEmpty)
    }

    // MARK: - currentlyOffline property

    @Test("currentlyOffline returns false by default")
    func isOfflineDefaultFalse() async throws {
        let ol = MockOneLakeClient()
        let (engine, _) = try makeEngine(onelake: ol)
        #expect(await engine.currentlyOffline == false)
    }

    // MARK: - delete: uses recursive=true for directories

    @Test("delete() passes recursive=true when the cache row is a directory")
    func deleteDirectoryUsesRecursiveTrue() async throws {
        let ol = MockOneLakeClient()
        let (engine, store) = try makeEngine(onelake: ol)
        defer { try? FileManager.default.removeItem(at: store.root) }

        // Seed a directory row.
        let key = CacheKey(accountAlias: Self.alias, workspaceID: Self.wsID, itemID: Self.itID, path: "MyDir")
        let record = MetadataRecord(
            accountAlias: Self.alias, workspaceID: Self.wsID, itemID: Self.itID,
            path: "MyDir", parentPath: "", name: "MyDir", isDir: true
        )
        try await store.upsert(record)

        ol.deleteResults.append(.success(()))
        try await engine.delete(key: key)

        #expect(ol.deleteCalls.count == 1)
        #expect(ol.deleteCalls[0].recursive == true)
    }

    @Test("delete() passes recursive=false when the cache row is a file")
    func deleteFileUsesRecursiveFalse() async throws {
        let ol = MockOneLakeClient()
        let (engine, store) = try makeEngine(onelake: ol)
        defer { try? FileManager.default.removeItem(at: store.root) }

        // Seed a file row.
        let key = Self.baseKey
        let record = MetadataRecord(
            accountAlias: Self.alias, workspaceID: Self.wsID, itemID: Self.itID,
            path: Self.path, parentPath: "Files", name: "data.csv", isDir: false
        )
        try await store.upsert(record)

        ol.deleteResults.append(.success(()))
        try await engine.delete(key: key)

        #expect(ol.deleteCalls.count == 1)
        #expect(ol.deleteCalls[0].recursive == false)
    }

    // MARK: - fix/offline-shortcircuit: open() offline fallback + isOffline via refreshFolder

    /// When the freshness HEAD fails with the realistic wrapped offline shape that
    /// the short-circuit path produces:
    ///   OneLakeError.httpError(HTTPClientError.transport(URLError(.notConnectedToInternet)))
    /// the engine must serve the stale cached blob and NOT touch the network again.
    @Test("open() serves stale cached blob when freshness HEAD fails with wrapped offline error")
    func openServesStaleBlob_whenHeadFailsOffline() async throws {
        let ol = MockOneLakeClient()
        let (engine, store) = try makeEngine(onelake: ol)
        defer { try? FileManager.default.removeItem(at: store.root) }

        let key = Self.baseKey

        // First open: prime the blob cache with a successful download.
        let body = Data(repeating: 0xDE, count: 40)
        let props = PathProperties.make(contentLength: 40, eTag: "v1")
        ol.readResults.append(.success((body, props)))
        _ = try await engine.open(key: key)
        #expect(ol.readCalls.count == 1)

        // Second open: HEAD fails with the exact wrapped shape the short-circuit
        // path produces — NOT a bare OneLakeError.httpError(URLError(...)), but
        // OneLakeError.httpError(HTTPClientError.transport(URLError(...))).
        let offlineTransport = HTTPClientError.transport(URLError(.notConnectedToInternet))
        let wrappedOffline = OneLakeError.httpError(offlineTransport)
        ol.getPropertiesResults.append(.failure(wrappedOffline))

        let blobURL = try await engine.open(key: key)
        let data = try Data(contentsOf: blobURL)
        #expect(data.count == 40)
        #expect(data == body)
        // No second network read — blob was served from the offline fallback path.
        #expect(ol.readCalls.count == 1)
    }

    /// After a `refreshFolder` failure with the wrapped offline shape, `currentlyOffline`
    /// must flip to true because `offlineTracker.observe(_:)` was fed the error.
    @Test("currentlyOffline becomes true after refreshFolder fails with wrapped offline error via listPath")
    func isOffline_trueAfterRefreshFolderFailsOffline() async throws {
        let ol = MockOneLakeClient()
        let (engine, store) = try makeEngine(onelake: ol)
        defer { try? FileManager.default.removeItem(at: store.root) }

        // Guard: starts online.
        #expect(await engine.currentlyOffline == false)

        // Inject the realistic offline error that SyncEngine sees from OneLakeClient
        // after the short-circuit path: transport-wrapped, then OneLake-wrapped.
        let offlineTransport = HTTPClientError.transport(URLError(.notConnectedToInternet))
        let wrappedOffline = OneLakeError.httpError(offlineTransport)
        ol.listPathResults.append(.failure(wrappedOffline))

        let key = CacheKey(accountAlias: Self.alias, workspaceID: Self.wsID, itemID: Self.itID, path: "")
        do {
            _ = try await engine.refreshFolder(key: key)
            Issue.record("Expected refreshFolder to throw")
        } catch {
            // The error is not a workspacePaused (503) so it should propagate as-is.
            if case SyncError.workspacePaused = error {
                Issue.record("Should not remap offline transport error to workspacePaused")
            }
        }

        // OfflineTracker must now be in the offline state.
        #expect(await engine.currentlyOffline == true)
    }

    @Test("delete() uses recursive=true when no cache row exists (unknown type)")
    func deleteUnknownTypeUsesRecursiveTrue() async throws {
        let ol = MockOneLakeClient()
        let (engine, store) = try makeEngine(onelake: ol)
        defer { try? FileManager.default.removeItem(at: store.root) }

        // No cache row for this key.
        ol.deleteResults.append(.success(()))
        let key = Self.baseKey
        try await engine.delete(key: key)

        #expect(ol.deleteCalls.count == 1)
        #expect(ol.deleteCalls[0].recursive == true)
    }

    // MARK: - listItems: item_type persisted from Item.type

    @Test("listItems() persists item_type from Item.type onto cache rows")
    func listItemsPersistsItemType() async throws {
        let ol = MockOneLakeClient()
        let fabric = MockFabricClient()
        let (engine, store) = try makeEngine(onelake: ol, fabric: fabric)
        defer { try? FileManager.default.removeItem(at: store.root) }

        let fabricItems = [
            Item(id: "lh-1", displayName: "Sales LH", type: "Lakehouse", workspaceID: Self.wsID),
            Item(id: "wh-1", displayName: "DW", type: "Warehouse", workspaceID: Self.wsID),
            Item(id: "sdb-1", displayName: "Mirror", type: "SQLDatabase", workspaceID: Self.wsID),
            Item(id: "mdb-1", displayName: "Replicated", type: "MirroredDatabase", workspaceID: Self.wsID),
        ]
        fabric.listItemsResults.append(.success(fabricItems))
        _ = try await engine.listItems(alias: Self.alias, workspaceID: Self.wsID)

        // Each item row is stored under (alias, wsID, VirtualIDs.itemID, path: itemID).
        let itemRowKey = { (path: String) in
            CacheKey(accountAlias: Self.alias, workspaceID: Self.wsID, itemID: VirtualIDs.itemID, path: path)
        }
        let lhRow = try await store.fetch(key: itemRowKey("lh-1"))
        let whRow = try await store.fetch(key: itemRowKey("wh-1"))
        let sdbRow = try await store.fetch(key: itemRowKey("sdb-1"))
        let mdbRow = try await store.fetch(key: itemRowKey("mdb-1"))

        #expect(lhRow.itemType == "Lakehouse", "Lakehouse item_type must be persisted")
        #expect(whRow.itemType == "Warehouse", "Warehouse item_type must be persisted")
        #expect(sdbRow.itemType == "SQLDatabase", "SQLDatabase item_type must be persisted")
        #expect(mdbRow.itemType == "MirroredDatabase", "MirroredDatabase item_type must be persisted")
    }

    // MARK: - refreshFolder: item_type propagated to child rows

    @Test("refreshFolder() stamps item_type from discovery row onto child path rows")
    func refreshFolderStampsItemType() async throws {
        let ol = MockOneLakeClient()
        let fabric = MockFabricClient()
        let (engine, store) = try makeEngine(onelake: ol, fabric: fabric)
        defer { try? FileManager.default.removeItem(at: store.root) }

        // Write the discovery row that listItems would produce (Lakehouse).
        let discoveryRow = MetadataRecord(
            accountAlias: Self.alias, workspaceID: Self.wsID,
            itemID: VirtualIDs.itemID, path: Self.itID,
            parentPath: "", name: "Sales LH", isDir: true,
            itemType: "Lakehouse"
        )
        try await store.upsert(discoveryRow)

        // Stub listPath to return one file under Files/.
        ol.listPathResults.append(.success(ListResult(entries: [
            PathEntry.file(name: "Files/data.csv"),
        ])))

        let key = CacheKey(accountAlias: Self.alias, workspaceID: Self.wsID, itemID: Self.itID, path: "Files")
        _ = try await engine.refreshFolder(key: key)

        let childKey = CacheKey(accountAlias: Self.alias, workspaceID: Self.wsID, itemID: Self.itID, path: "Files/data.csv")
        let childRow = try await store.fetch(key: childKey)
        #expect(childRow.itemType == "Lakehouse", "child rows must carry the Lakehouse item_type from the discovery row")
    }

    @Test("refreshFolder() before listItems: child rows get empty item_type and are read-only")
    func refreshFolderBeforeListItemsYieldsReadOnlyRows() async throws {
        let ol = MockOneLakeClient()
        let fabric = MockFabricClient()
        let (engine, store) = try makeEngine(onelake: ol, fabric: fabric)
        defer { try? FileManager.default.removeItem(at: store.root) }

        // No discovery row written — simulates refreshFolder racing ahead of listItems.
        ol.listPathResults.append(.success(ListResult(entries: [
            PathEntry.file(name: "Files/data.csv"),
        ])))

        let key = CacheKey(accountAlias: Self.alias, workspaceID: Self.wsID, itemID: Self.itID, path: "Files")
        _ = try await engine.refreshFolder(key: key)

        let childKey = CacheKey(accountAlias: Self.alias, workspaceID: Self.wsID, itemID: Self.itID, path: "Files/data.csv")
        let childRow = try await store.fetch(key: childKey)
        // item_type is "" — the row is read-only until the next listItems + refreshFolder cycle.
        #expect(childRow.itemType == "", "missing discovery row must produce empty item_type (transient read-only)")
    }

    // MARK: - put / mkdir: item_type propagated from parent cache row

    @Test("put() carries item_type from parent directory row into the upserted file row")
    func putCarriesItemTypeFromParent() async throws {
        let ol = MockOneLakeClient()
        let (engine, store) = try makeEngine(onelake: ol)
        defer { try? FileManager.default.removeItem(at: store.root) }

        // Pre-seed parent directory row with Lakehouse item_type.
        let parentRow = MetadataRecord(
            accountAlias: Self.alias, workspaceID: Self.wsID,
            itemID: Self.itID, path: "Files", parentPath: "",
            name: "Files", isDir: true, itemType: "Lakehouse"
        )
        try await store.upsert(parentRow)

        let src = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".csv")
        try Data(repeating: 0xAB, count: 64).write(to: src)
        defer { try? FileManager.default.removeItem(at: src) }

        ol.writeResults.append(.success(()))
        ol.getPropertiesResults.append(.success(PathProperties.make(contentLength: 64, eTag: "etag1")))

        let key = CacheKey(accountAlias: Self.alias, workspaceID: Self.wsID, itemID: Self.itID, path: "Files/data.csv")
        try await engine.put(key: key, sourceURL: src)

        let row = try await store.fetch(key: key)
        #expect(row.itemType == "Lakehouse", "put() must carry Lakehouse item_type so the file is immediately writable")
    }

    @Test("mkdir() carries item_type from parent directory row into the upserted directory row")
    func mkdirCarriesItemTypeFromParent() async throws {
        let ol = MockOneLakeClient()
        let (engine, store) = try makeEngine(onelake: ol)
        defer { try? FileManager.default.removeItem(at: store.root) }

        // Pre-seed parent directory row with Lakehouse item_type.
        let parentRow = MetadataRecord(
            accountAlias: Self.alias, workspaceID: Self.wsID,
            itemID: Self.itID, path: "Files", parentPath: "",
            name: "Files", isDir: true, itemType: "Lakehouse"
        )
        try await store.upsert(parentRow)

        ol.createDirectoryResults.append(.success(()))

        let key = CacheKey(accountAlias: Self.alias, workspaceID: Self.wsID, itemID: Self.itID, path: "Files/NewDir")
        try await engine.mkdir(key: key)

        let row = try await store.fetch(key: key)
        #expect(row.itemType == "Lakehouse", "mkdir() must carry Lakehouse item_type so the new directory is immediately writable")
    }

    // MARK: - refreshFolder: created_ns preservation (issue-370)

    /// `convertRawEntry` (the only production path into `refreshFolder`) never
    /// populates `PathEntry.creationDate` — the DFS list schema has no
    /// creationTime field. `refreshFolder` therefore always sees
    /// `entry.creationDate == nil`, and the expression
    ///     `dateToNs(entry.creationDate) ?? cur?.createdNs ?? 0`
    /// collapses to `cur?.createdNs ?? 0`.
    ///
    /// This test routes through `convertRawEntry` (matching production) and
    /// verifies that a previously-captured `createdNs` value is preserved
    /// across a sync poll — i.e. refreshFolder does not overwrite a good
    /// `createdNs` with 0 on a no-content-change re-poll.
    @Test("refreshFolder() preserves existing created_ns when DFS list has no creationDate (production path via convertRawEntry)")
    func refreshFolderPreservesCreatedNsViaConvertRawEntry() async throws {
        let ol = MockOneLakeClient()
        let (engine, store) = try makeEngine(onelake: ol)
        defer { try? FileManager.default.removeItem(at: store.root) }

        let knownUnixSeconds: TimeInterval = 1_715_526_400 // 2024-05-12T20:53:20Z
        let knownCreatedNs = dateToNs(Date(timeIntervalSince1970: knownUnixSeconds))

        let parentKey = CacheKey(accountAlias: Self.alias, workspaceID: Self.wsID, itemID: Self.itID, path: "Files")
        let childPath = "Files/data.csv"
        let parent = MetadataRecord(
            accountAlias: Self.alias, workspaceID: Self.wsID, itemID: Self.itID,
            path: "Files", parentPath: "", name: "Files", isDir: true
        )
        var child = MetadataRecord(
            accountAlias: Self.alias, workspaceID: Self.wsID, itemID: Self.itID,
            path: childPath, parentPath: "Files", name: "data.csv", isDir: false,
            contentLength: 42, etag: "v1"
        )
        // A previously-captured real creation time (e.g. from a prior HEAD/GET).
        child.createdNs = knownCreatedNs
        // The cached row must also carry the matching lastModifiedNs so that
        // entryChanged does not fire due to a 0-vs-real lastModifiedNs mismatch —
        // the test is about createdNs stability, not lastModified.
        child.lastModifiedNs = dateToNs(Date(timeIntervalSince1970: knownUnixSeconds))
        try await store.upsert(parent)
        try await store.upsert(child)

        // Wire-level JSON with no creationTime field — matches the DFS Path-List
        // schema exactly; convertRawEntry will produce creationDate: nil.
        // The etag value is kept free of extra quotes so it round-trips to "v1",
        // matching the value seeded into the cache above.
        let json = """
        {"paths":[{"name":"item-1/Files/data.csv","contentLength":"42","etag":"v1","lastModified":"Sun, 12 May 2024 15:06:40 GMT"}]}
        """
        let rawList = try JSONDecoder().decode(RawListBody.self, from: Data(json.utf8))
        let entries = (rawList.paths ?? []).map { convertRawEntry($0, itemGUID: Self.itID) }
        // Verify this is the real production path: creationDate must be nil.
        #expect(entries.first?.creationDate == nil, "convertRawEntry must never produce a creationDate from list JSON")

        ol.listPathResults.append(.success(ListResult(entries: entries)))

        // No content change (same etag, same lastModifiedNs), so refreshFolder
        // carries cur?.createdNs forward. entryChanged only fires for the
        // 0→non-zero backfill trigger; here current.createdNs is already non-zero
        // and next.createdNs == 0 (convertRawEntry returns creationDate: nil), so
        // the poll is stable (diff.updated == 0).
        let diff = try await engine.refreshFolder(key: parentKey)
        #expect(diff.updated == 0, "unchanged row must not produce a spurious update")

        let stored = try await store.fetch(key: CacheKey(
            accountAlias: Self.alias, workspaceID: Self.wsID, itemID: Self.itID, path: childPath
        ))
        #expect(stored.createdNs == knownCreatedNs,
                "refreshFolder must not overwrite a good createdNs when DFS list has no creationDate")
    }

    /// After the one-time backfill (via open/put HEAD), subsequent DFS-list polls
    /// must not produce spurious updated counts.
    ///
    /// Note: `convertRawEntry` always yields `creationDate: nil`; the backfill
    /// itself is done by `open()` / `put()` via the x-ms-creation-time HEAD header.
    @Test("refreshFolder() does not re-update a row whose created_ns is already set (stable after HEAD backfill)")
    func refreshFolderNoSpuriousUpdateAfterBackfill() async throws {
        let ol = MockOneLakeClient()
        let (engine, store) = try makeEngine(onelake: ol)
        defer { try? FileManager.default.removeItem(at: store.root) }

        let knownUnixSeconds: TimeInterval = 1_715_526_400
        let knownCreatedNs = dateToNs(Date(timeIntervalSince1970: knownUnixSeconds))

        let parentKey = CacheKey(accountAlias: Self.alias, workspaceID: Self.wsID, itemID: Self.itID, path: "Files")
        let childPath = "Files/data.csv"
        let parent = MetadataRecord(
            accountAlias: Self.alias, workspaceID: Self.wsID, itemID: Self.itID,
            path: "Files", parentPath: "", name: "Files", isDir: true
        )
        var child = MetadataRecord(
            accountAlias: Self.alias, workspaceID: Self.wsID, itemID: Self.itID,
            path: childPath, parentPath: "Files", name: "data.csv", isDir: false,
            contentLength: 42, etag: "v1"
        )
        child.createdNs = knownCreatedNs // already-backfilled via HEAD
        try await store.upsert(parent)
        try await store.upsert(child)

        // Production-path list entry (no creationDate from convertRawEntry).
        ol.listPathResults.append(.success(ListResult(entries: [
            PathEntry(name: childPath, isDirectory: false, contentLength: 42,
                      eTag: "v1", lastModified: .distantPast),
        ])))

        let diff = try await engine.refreshFolder(key: parentKey)

        #expect(diff.updated == 0, "no spurious update once created_ns is already set")
        #expect(diff.added == 0)
        #expect(diff.removed == 0)
    }

    // MARK: - put: created_ns preserved on HEAD failure (finding #1)

    /// When the post-upload HEAD fails, `put()` must not overwrite a
    /// previously-captured `createdNs` with 0. This mirrors the symmetric guard
    /// in `performDownload` (`cached?.createdNs ?? 0`).
    @Test("put() preserves existing createdNs when post-upload HEAD fails")
    func putPreservesCreatedNsOnHeadFailure() async throws {
        let ol = MockOneLakeClient()
        let (engine, store) = try makeEngine(onelake: ol)
        defer { try? FileManager.default.removeItem(at: store.root) }

        let knownUnixSeconds: TimeInterval = 1_715_526_400
        let knownCreatedNs = dateToNs(Date(timeIntervalSince1970: knownUnixSeconds))

        // Pre-seed cache row with a real creation time captured by a prior open().
        var existing = MetadataRecord(
            accountAlias: Self.alias, workspaceID: Self.wsID, itemID: Self.itID,
            path: Self.path, parentPath: "Files", name: "data.csv", isDir: false,
            contentLength: 10, etag: "old-etag"
        )
        existing.createdNs = knownCreatedNs
        try await store.upsert(existing)

        let src = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".csv")
        try Data(repeating: 0xAB, count: 10).write(to: src)
        defer { try? FileManager.default.removeItem(at: src) }

        ol.writeResults.append(.success(()))
        // HEAD fails — the row is written with createdNs carried forward from cache.
        ol.getPropertiesResults.append(.failure(URLError(.networkConnectionLost)))

        let key = Self.baseKey
        try await engine.put(key: key, sourceURL: src)

        let row = try await store.fetch(key: key)
        #expect(row.createdNs == knownCreatedNs,
                "put() must not overwrite a good createdNs with 0 when HEAD fails")
    }

    // MARK: - dateToNs: far-future date returns nil, not Optional(0) (finding #2)

    /// A far-future `x-ms-creation-time` (outside Int64 range) must not silently
    /// zero a good `createdNs`. `dateToNs` must return `nil` for overflow dates
    /// so `flatMap { dateToNs($0) } ?? cached?.createdNs ?? 0` falls through to
    /// the carried value rather than landing on `Optional(0)`.
    @Test("dateToNs returns nil for distantFuture, allowing cached createdNs fallback to apply")
    func dateToNsDistantFutureReturnsNilNotOptionalZero() async throws {
        let ol = MockOneLakeClient()
        let (engine, store) = try makeEngine(onelake: ol)
        defer { try? FileManager.default.removeItem(at: store.root) }

        let knownUnixSeconds: TimeInterval = 1_715_526_400
        let knownCreatedNs = dateToNs(Date(timeIntervalSince1970: knownUnixSeconds))

        // Pre-seed with a real creation time.
        var existing = MetadataRecord(
            accountAlias: Self.alias, workspaceID: Self.wsID, itemID: Self.itID,
            path: Self.path, parentPath: "Files", name: "data.csv", isDir: false,
            contentLength: 10, etag: "v1"
        )
        existing.createdNs = knownCreatedNs
        try await store.upsert(existing)

        let src = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".csv")
        try Data(repeating: 0xAB, count: 10).write(to: src)
        defer { try? FileManager.default.removeItem(at: src) }

        ol.writeResults.append(.success(()))
        // HEAD returns a far-future creation date that overflows Int64 nanoseconds.
        let farFutureProps = PathProperties(
            isDirectory: false, contentLength: 10, eTag: "v2",
            lastModified: Date(), contentType: "text/csv",
            creationDate: .distantFuture
        )
        ol.getPropertiesResults.append(.success(farFutureProps))

        let key = Self.baseKey
        try await engine.put(key: key, sourceURL: src)

        let row = try await store.fetch(key: key)
        #expect(row.createdNs == knownCreatedNs,
                "overflow creation date must not clobber a good cached createdNs")
    }

    // MARK: - dateToNs (private duplicate): exact Int64.max boundary no longer traps

    /// `Double(Int64.max)` rounds *up* to exactly `2^63`, one past the actual
    /// `Int64.max`. A remote `lastModified` whose nanosecond value lands on that
    /// rounded boundary must not trap `Int64(ns)` inside `SyncEngine`'s private
    /// `dateToNs` duplicate — it must clamp to the "unknown" sentinel (`0`),
    /// same as the canonical helper.
    @Test("refreshFolder() does not trap on a remote lastModified at the Int64.max rounding boundary")
    func refreshFolderBoundaryLastModifiedDoesNotTrap() async throws {
        let ol = MockOneLakeClient()
        let (engine, store) = try makeEngine(onelake: ol)
        defer { try? FileManager.default.removeItem(at: store.root) }

        let dir = "Files"
        let key = CacheKey(accountAlias: Self.alias, workspaceID: Self.wsID, itemID: Self.itID, path: dir)

        let boundaryDate = Date(timeIntervalSince1970: Double(Int64.max) / 1_000_000_000)
        ol.listPathResults.append(.success(ListResult(entries: [
            PathEntry(name: "\(dir)/boundary.bin", isDirectory: false, contentLength: 10, eTag: "e1", lastModified: boundaryDate),
        ])))

        // Must not trap — that's the whole point of the test.
        let diff = try await engine.refreshFolder(key: key)
        #expect(diff.added == 1)

        let kids = try await store.children(of: key)
        let row = kids.first { $0.name == "boundary.bin" }
        #expect(row != nil)
        #expect(row?.lastModifiedNs == 0, "out-of-range lastModified must clamp to 0, not trap")
    }

    // MARK: - C6: resume-download Int64 overflow no longer traps

    /// A resumed download combines a local resume offset (`plan.rangeStart`,
    /// read off the on-disk spill file) with the remote `Content-Length`
    /// header (`props.contentLength`) — both untrusted from the resume
    /// engine's point of view. A hostile/absurd `Content-Length` that would
    /// overflow `Int64` when added to the resume offset must surface as
    /// `SyncError.resumeOffsetOverflow` instead of trapping the process.
    @Test("open() resume with an absurd Content-Length surfaces a handled error instead of trapping")
    func resumeDownloadOverflowingContentLengthIsHandledNotTrapped() async throws {
        let ol = MockOneLakeClient()
        let (engine, store) = try makeEngine(onelake: ol)
        defer { try? FileManager.default.removeItem(at: store.root) }

        let key = Self.baseKey

        // Seed a cached row so PartialManager.rangeStart(for:cachedRecord:)
        // considers resuming (it requires cachedRecord.contentLength > 0).
        let existing = MetadataRecord(
            accountAlias: Self.alias, workspaceID: Self.wsID, itemID: Self.itID,
            path: Self.path, parentPath: "Files", name: "data.csv", isDir: false,
            contentLength: 1000, etag: "etag-v1"
        )
        try await store.upsert(existing)

        // Write a matching partial spill file + etag sidecar directly, using
        // the same scratch-dir layout SyncEngine computes internally
        // (scratchBase/<pid>), so PartialManager.rangeStart(for:) reports
        // hasPartial == true with a known rangeStart.
        let scratchDir = store.root.appending(path: "scratch", directoryHint: .isDirectory)
        let partialsDir = scratchDir.appendingPathComponent("\(ProcessInfo.processInfo.processIdentifier)")
        try FileManager.default.createDirectory(at: partialsDir, withIntermediateDirectories: true)
        let shadow = PartialManager(scratchDir: partialsDir)
        try Data(repeating: 0, count: 500).write(to: shadow.partialURL(for: key))
        try shadow.storeEtag("etag-v1", for: key)

        // Server reports a Content-Length so large that rangeStart (500) plus
        // it overflows Int64.
        let hugeProps = PathProperties(
            isDirectory: false, contentLength: Int64.max - 100, eTag: "etag-v1",
            lastModified: Date(), contentType: "text/csv"
        )
        ol.readResults.append(.success((Data(repeating: 0xAB, count: 1), hugeProps)))

        do {
            _ = try await engine.open(key: key)
            Issue.record("Expected SyncError.resumeOffsetOverflow to be thrown")
        } catch SyncError.resumeOffsetOverflow {
            // Correct — handled, no trap.
        }
    }

    /// A persistently-hostile `Content-Length` must not make `open()` loop
    /// forever: hitting `SyncError.resumeOffsetOverflow` has to discard the
    /// partial spill + etag sidecar so the NEXT attempt no longer has anything
    /// to resume from, and instead performs a full (non-`Range`) download
    /// (#413).
    @Test("open() discards the partial after a resume overflow so the retry self-heals into a full download")
    func resumeOverflowDiscardsPartialAndSelfHeals() async throws {
        let ol = MockOneLakeClient()
        let (engine, store) = try makeEngine(onelake: ol)
        defer { try? FileManager.default.removeItem(at: store.root) }

        let key = Self.baseKey

        let existing = MetadataRecord(
            accountAlias: Self.alias, workspaceID: Self.wsID, itemID: Self.itID,
            path: Self.path, parentPath: "Files", name: "data.csv", isDir: false,
            contentLength: 1000, etag: "etag-v1"
        )
        try await store.upsert(existing)

        // Same partial spill + etag sidecar setup as the overflow test above.
        let scratchDir = store.root.appending(path: "scratch", directoryHint: .isDirectory)
        let partialsDir = scratchDir.appendingPathComponent("\(ProcessInfo.processInfo.processIdentifier)")
        try FileManager.default.createDirectory(at: partialsDir, withIntermediateDirectories: true)
        let shadow = PartialManager(scratchDir: partialsDir)
        try Data(repeating: 0, count: 500).write(to: shadow.partialURL(for: key))
        try shadow.storeEtag("etag-v1", for: key)

        let hugeProps = PathProperties(
            isDirectory: false, contentLength: Int64.max - 100, eTag: "etag-v1",
            lastModified: Date(), contentType: "text/csv"
        )
        ol.readResults.append(.success((Data(repeating: 0xAB, count: 1), hugeProps)))

        do {
            _ = try await engine.open(key: key)
            Issue.record("Expected SyncError.resumeOffsetOverflow to be thrown")
        } catch SyncError.resumeOffsetOverflow {
            // Correct — handled, no trap.
        }

        // The overflowing attempt must have wiped the partial + sidecar; a
        // dangling pair here is exactly what re-triggers the same overflow.
        #expect(!FileManager.default.fileExists(atPath: shadow.partialURL(for: key).path))
        #expect(!FileManager.default.fileExists(atPath: shadow.etagURL(for: key).path))

        // Retry with a sane response. If the discard above didn't happen,
        // PartialManager.rangeStart(for:) would still see the 500-byte spill
        // and resume with the SAME huge Content-Length, overflowing again.
        let freshBody = Data("hello".utf8)
        let freshProps = PathProperties(
            isDirectory: false, contentLength: Int64(freshBody.count), eTag: "etag-v2",
            lastModified: Date(), contentType: "text/csv"
        )
        ol.readResults.append(.success((freshBody, freshProps)))

        let fileURL = try await engine.open(key: key)
        #expect(try Data(contentsOf: fileURL) == freshBody)

        let retryCall = try #require(ol.readCalls.last)
        #expect(retryCall.range == nil, "self-healed retry must be a full download, not a resume")
        #expect(retryCall.ifMatch.isEmpty, "self-healed retry must not pin to the stale etag")
    }

    // MARK: - C8: resumed download prefers the Content-Range total

    /// A resumed (206) download's `Content-Length` header reports only the
    /// size of the *returned range*, not the full file — `performDownload`
    /// derives the total by adding that (untrusted) value to the local
    /// resume offset (`plan.rangeStart`). `propertiesFromHeaders` also parses
    /// the `Content-Range: bytes <start>-<end>/<total>` header into
    /// `PathProperties.totalLength`, and `performDownload` must prefer that
    /// server-authoritative total when present — bypassing the addition (and
    /// its overflow guard) entirely (C8).
    ///
    /// Proven by pairing a correct `totalLength` (matching the real assembled
    /// file size) with a `contentLength` so large that the old rangeStart +
    /// Content-Length addition would have overflowed and thrown
    /// `SyncError.resumeOffsetOverflow` (same shape as the C6 tests above):
    /// with totalLength preferred, the addition is never attempted and the
    /// download succeeds.
    @Test("open() resume prefers Content-Range's totalLength over rangeStart + Content-Length (C8)")
    func resumeDownloadPrefersContentRangeTotalLength() async throws {
        let ol = MockOneLakeClient()
        let (engine, store) = try makeEngine(onelake: ol)
        defer { try? FileManager.default.removeItem(at: store.root) }

        let key = Self.baseKey

        let existing = MetadataRecord(
            accountAlias: Self.alias, workspaceID: Self.wsID, itemID: Self.itID,
            path: Self.path, parentPath: "Files", name: "data.csv", isDir: false,
            contentLength: 1000, etag: "etag-v1"
        )
        try await store.upsert(existing)

        // Same partial spill + etag sidecar setup as the C6 overflow tests:
        // a 500-byte spill file gives PartialManager.rangeStart(for:) a
        // hasPartial == true resume with rangeStart == 500.
        let scratchDir = store.root.appending(path: "scratch", directoryHint: .isDirectory)
        let partialsDir = scratchDir.appendingPathComponent("\(ProcessInfo.processInfo.processIdentifier)")
        try FileManager.default.createDirectory(at: partialsDir, withIntermediateDirectories: true)
        let shadow = PartialManager(scratchDir: partialsDir)
        try Data(repeating: 0, count: 500).write(to: shadow.partialURL(for: key))
        try shadow.storeEtag("etag-v1", for: key)

        // The remaining 5 bytes of the file. contentLength is deliberately a
        // hostile/wrong value (as if the server mis-reported Content-Length)
        // so the old rangeStart + contentLength compensation would overflow;
        // the authoritative totalLength (500 + 5 == 505, as Content-Range
        // would report) must be preferred instead.
        let tailBody = Data("hello".utf8)
        let props = PathProperties(
            isDirectory: false, contentLength: Int64.max - 100, eTag: "etag-v1",
            lastModified: Date(), contentType: "text/csv", totalLength: 505
        )
        ol.readResults.append(.success((tailBody, props)))

        let (fileURL, record) = try await engine.openReturningRecord(key: key)

        let assembled = try Data(contentsOf: fileURL)
        #expect(assembled.count == 505, "assembled spill file must be rangeStart (500) + the new bytes (5)")
        #expect(assembled.suffix(5) == tailBody)
        #expect(record.contentLength == 505,
                "row.contentLength must come from totalLength, not the overflowing rangeStart + Content-Length sum")
    }

    // MARK: - #461: resumed download progress accounts for plan.rangeStart

    /// A resumed download's `onProgress` callback must report an ABSOLUTE
    /// completed byte count — `plan.rangeStart` (the local resume offset)
    /// plus the bytes delivered by THIS network attempt — not bytes relative
    /// to this request alone, which would regress the FPE's progress bar
    /// back down on every resume instead of continuing from where the prior
    /// attempt left off (#461).
    @Test("open() with onProgress reports absolute completed bytes on a resumed download, floored at plan.rangeStart")
    func resumedDownloadProgressAccountsForRangeStart() async throws {
        let ol = MockOneLakeClient()
        let (engine, store) = try makeEngine(onelake: ol)
        defer { try? FileManager.default.removeItem(at: store.root) }

        let key = Self.baseKey

        let existing = MetadataRecord(
            accountAlias: Self.alias, workspaceID: Self.wsID, itemID: Self.itID,
            path: Self.path, parentPath: "Files", name: "data.csv", isDir: false,
            contentLength: 505, etag: "etag-v1"
        )
        try await store.upsert(existing)

        // Same partial spill + etag sidecar setup as the C6/C8 resume tests
        // above: a 500-byte spill file gives PartialManager.rangeStart(for:)
        // a hasPartial == true resume with rangeStart == 500.
        let scratchDir = store.root.appending(path: "scratch", directoryHint: .isDirectory)
        let partialsDir = scratchDir.appendingPathComponent("\(ProcessInfo.processInfo.processIdentifier)")
        try FileManager.default.createDirectory(at: partialsDir, withIntermediateDirectories: true)
        let shadow = PartialManager(scratchDir: partialsDir)
        try Data(repeating: 0, count: 500).write(to: shadow.partialURL(for: key))
        try shadow.storeEtag("etag-v1", for: key)

        // The remaining 5 bytes of the file. MockOneLakeClient.read(destination:)
        // reports progress relative to THESE 5 bytes only (a midpoint tick and
        // a final tick) — exactly like a real ranged GET's Content-Length only
        // covers the returned range, not the full file.
        let tailBody = Data("hello".utf8)
        let props = PathProperties(
            isDirectory: false, contentLength: 5, eTag: "etag-v1",
            lastModified: Date(), contentType: "text/csv", totalLength: 505
        )
        ol.readResults.append(.success((tailBody, props)))

        let recorder = ProgressTickRecorder()
        _ = try await engine.openReturningRecord(key: key) { completed, total in
            recorder.record(completed, total)
        }

        let ticks = recorder.ticks
        #expect(ticks.count == 2, "expected the mock's midpoint + final ticks, got \(ticks)")
        for tick in ticks {
            #expect(tick.completed >= 500,
                    "resumed download's completed bytes must be floored at rangeStart (500), got \(tick.completed)")
        }
        #expect(ticks.last?.completed == 505,
                "final tick must reach rangeStart (500) + this request's bytes (5)")
        // total is rangeStart (500) + THIS request's own live total (5, from
        // props.contentLength above) — 505 for both ticks here, not a
        // pre-download hint (#461 review round 2).
        #expect(ticks.allSatisfy { $0.total == 505 })
    }

    // MARK: - #461 review round 2: SyncEngine.absoluteDownloadProgress unit tests

    /// Deterministic, non-networked coverage of the pure wrapping function
    /// behind every `onProgress` tick — the CI-flaky Alamofire-integration
    /// path (`OneLakeStreamProgressTests` in `OneLakeStreamingTests.swift`)
    /// only smoke-tests that real chunked delivery reaches this function at
    /// all; the actual guarantees (absolute byte accounting, the
    /// completed-never-exceeds-total invariant, indeterminate handling, and
    /// overflow safety) are pinned here instead.
    @Suite("SyncEngine.absoluteDownloadProgress (#461)")
    struct AbsoluteDownloadProgressTests {
        @Test("a fresh (non-resumed) download passes completed/total through unchanged")
        func freshDownloadPassesThrough() {
            let result = SyncEngine.absoluteDownloadProgress(rangeStart: 0, completedInRequest: 40, totalInRequest: 100)
            #expect(result.completed == 40)
            #expect(result.total == 100)
        }

        @Test("a resumed download adds rangeStart to both completed and total")
        func resumedDownloadAddsRangeStart() {
            let result = SyncEngine.absoluteDownloadProgress(rangeStart: 500, completedInRequest: 2, totalInRequest: 5)
            #expect(result.completed == 502)
            #expect(result.total == 505)
        }

        @Test("completed never exceeds total, by construction, across a range of inputs")
        func completedNeverExceedsTotal() {
            let cases: [(rangeStart: Int64, completedInRequest: Int64, totalInRequest: Int64)] = [
                (0, 0, 0), (0, 100, 100), (500, 0, 505), (500, 505, 505), (1, 1, 1), (12345, 6789, 20000),
            ]
            for testCase in cases {
                let result = SyncEngine.absoluteDownloadProgress(
                    rangeStart: testCase.rangeStart,
                    completedInRequest: testCase.completedInRequest,
                    totalInRequest: testCase.totalInRequest
                )
                if result.total > 0 {
                    #expect(result.completed <= result.total, "completed must never exceed total: \(testCase) -> \(result)")
                }
            }
        }

        @Test("an unknown per-request total (<= 0) reports indeterminate (total == 0), not a fabricated number")
        func unknownTotalReportsIndeterminate() {
            let zero = SyncEngine.absoluteDownloadProgress(rangeStart: 500, completedInRequest: 10, totalInRequest: 0)
            #expect(zero.completed == 510)
            #expect(zero.total == 0)

            let negative = SyncEngine.absoluteDownloadProgress(rangeStart: 500, completedInRequest: 10, totalInRequest: -1)
            #expect(negative.completed == 510)
            #expect(negative.total == 0)
        }

        @Test("an overflowing completed addition degrades to indeterminate rather than trapping")
        func overflowingCompletedDegradesToIndeterminate() {
            let result = SyncEngine.absoluteDownloadProgress(
                rangeStart: Int64.max - 5, completedInRequest: 10, totalInRequest: 20
            )
            #expect(result.completed == 0)
            #expect(result.total == 0)
        }

        @Test("an overflowing total addition still reports completed but drops total to indeterminate")
        func overflowingTotalDropsToIndeterminateButKeepsCompleted() {
            let result = SyncEngine.absoluteDownloadProgress(
                rangeStart: Int64.max - 5, completedInRequest: 3, totalInRequest: 20
            )
            #expect(result.completed == Int64.max - 2)
            #expect(result.total == 0)
        }

        @Test("a 412-retry-as-full-restart re-wrap with rangeStart 0 matches a fresh download")
        func fullRestartRewrapMatchesFreshDownload() {
            // Mirrors performNetworkRead's 412 branch: the retry passes
            // rangeStart: 0 regardless of the original (now-stale) resume
            // offset, since that attempt is a brand-new unranged GET.
            let result = SyncEngine.absoluteDownloadProgress(rangeStart: 0, completedInRequest: 30, totalInRequest: 90)
            #expect(result.completed == 30)
            #expect(result.total == 90)
        }
    }
}
