import Foundation
@testable import OfemKit
import Testing

// MARK: - SyncEngine Transfer Tests

extension SyncEngineTests {
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

    // MARK: - currentlyOffline property

    @Test("currentlyOffline returns false by default")
    func isOfflineDefaultFalse() async throws {
        let ol = MockOneLakeClient()
        let (engine, _) = try makeEngine(onelake: ol)
        #expect(await engine.currentlyOffline == false)
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
}
