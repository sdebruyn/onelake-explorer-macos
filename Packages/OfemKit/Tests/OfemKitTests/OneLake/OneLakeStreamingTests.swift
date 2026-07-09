import Foundation
@testable import OfemKit
import Testing

// MARK: - Helpers

private let streamBaseURL = URL(string: "https://onelake.dfs.fabric.microsoft.com")!
private let wsGUID = "ws-guid-stream"
private let itemGUID = "item-guid-stream"

/// Returns a client backed by a `SessionPool` with a noop token provider.
///
/// Tests that only exercise argument-validation paths do not need a live session.
private func makeClient() -> OneLakeClient {
    let pool = SessionPool(tokenProvider: NoopTokenProvider())
    return OneLakeClient(sessionPool: pool, baseURL: streamBaseURL)
}

// MARK: - OneLakeStreamingTests

@Suite("OneLakeClient — streaming read(destination:)")
struct OneLakeStreamingTests {
    @Test("read(destination:) with empty range returns empty PathProperties without network call")
    func emptyRangeDestinationNoNetwork() async throws {
        let client = makeClient()

        let (tmpURL, handle) = try makeTempFileHandle(prefix: "ofem-stream-test")
        defer {
            try? handle.close()
            try? FileManager.default.removeItem(at: tmpURL)
        }

        let props = try await client.read(
            alias: "a",
            workspaceGUID: wsGUID,
            itemGUID: itemGUID,
            path: "Files/a.txt",
            range: 0 ..< 0,
            destination: handle
        )
        #expect(props.contentLength == 0)
    }

    @Test("read(data overload) with empty range returns empty Data without network call")
    func emptyRangeDataNoNetwork() async throws {
        let client = makeClient()
        let (data, props) = try await client.read(
            alias: "a",
            workspaceGUID: wsGUID,
            itemGUID: itemGUID,
            path: "Files/a.txt",
            range: 5 ..< 5 // empty range
        )
        #expect(data.isEmpty)
        #expect(props.contentLength == 0)
    }
}

// MARK: - OneLakeStreamTempFileCleanupTests

/// M5 / #430: `doStreamRequest` downloads to a private temp file before
/// copying into the caller's destination handle (see the doc on
/// `OneLakeClient.read(destination:)`). The temp file used to leak on the
/// nil-response guard and outer-catch exit paths. These tests pin it removed
/// on every exit — a transport failure with no response, a validation
/// failure, and success — using an isolated `downloadTempDirectory` per test
/// so the assertion never races other suites that also scribble in the
/// shared system temp dir under parallel test execution.
@Suite("OneLakeClient — doStreamRequest temp-file cleanup (M5)")
struct OneLakeStreamTempFileCleanupTests {
    private static let wsGUID = "ws-guid-cleanup"
    private static let itemGUID = "item-guid-cleanup"

    /// Builds a client backed by a mock session plus an isolated, uniquely
    /// named staging directory so a leaked-file assertion never sees a file
    /// left behind by an unrelated, concurrently running test.
    private func makeClient(stubs: [MockURLProtocol.StubResponse]) async -> (OneLakeClient, String, URL) {
        let queueID = UUID().uuidString
        MockURLProtocol.registerQueue(id: queueID, stubs: stubs)
        let session = makeMockSession(queueID: queueID)
        let pool = SessionPool(tokenProvider: NoopTokenProvider())
        await pool._setSessionForTesting(session, alias: "test", scope: .oneLake)
        let stagingDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ofem-stream-cleanup-\(UUID().uuidString)", isDirectory: true)
        let client = OneLakeClient(
            sessionPool: pool,
            baseURL: streamBaseURL,
            downloadTempDirectory: stagingDir
        )
        return (client, queueID, stagingDir)
    }

    /// Files left behind in `directory`, or `[]` if it was never created —
    /// `doStreamRequest` only creates it lazily via
    /// `.createIntermediateDirectories` on first write.
    private func leakedFiles(in directory: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
    }

    @Test("a transport failure with no response never leaves a staged temp file behind")
    func nilResponseFailureLeavesNoTempFile() async throws {
        // Empty stub queue: MockURLProtocol fails the request before ever
        // calling didReceive(response:), so dl.response stays nil and
        // doStreamRequest's nil-response guard fires — the path that used to
        // leak the staged temp file (M5).
        let (client, queueID, stagingDir) = await makeClient(stubs: [])
        defer {
            MockURLProtocol.clearQueue(id: queueID)
            try? FileManager.default.removeItem(at: stagingDir)
        }

        let (destURL, handle) = try makeTempFileHandle(prefix: "ofem-stream-cleanup-dest")
        defer {
            try? handle.close()
            try? FileManager.default.removeItem(at: destURL)
        }

        await #expect(throws: OneLakeError.self) {
            try await client.read(
                alias: "test",
                workspaceGUID: Self.wsGUID,
                itemGUID: Self.itemGUID,
                path: "Files/a.txt",
                destination: handle
            )
        }

        #expect(leakedFiles(in: stagingDir).isEmpty)
    }

    @Test("a non-2xx response that fails validation never leaves a staged temp file behind")
    func validationFailureLeavesNoTempFile() async throws {
        // A real (short) response body is downloaded to the staging
        // directory before .validate() rejects the 500 status — this
        // exercises the doStreamRequest's `.failure(afError)` branch, the
        // other path that used to leak (M5).
        let (client, queueID, stagingDir) = await makeClient(stubs: [
            .init(status: 500, body: "boom"),
        ])
        defer {
            MockURLProtocol.clearQueue(id: queueID)
            try? FileManager.default.removeItem(at: stagingDir)
        }

        let (destURL, handle) = try makeTempFileHandle(prefix: "ofem-stream-cleanup-dest")
        defer {
            try? handle.close()
            try? FileManager.default.removeItem(at: destURL)
        }

        await #expect(throws: OneLakeError.self) {
            try await client.read(
                alias: "test",
                workspaceGUID: Self.wsGUID,
                itemGUID: Self.itemGUID,
                path: "Files/a.txt",
                destination: handle
            )
        }

        #expect(leakedFiles(in: stagingDir).isEmpty)
    }

    @Test("a successful download copies bytes into the destination and never leaves a staged temp file behind")
    func successLeavesNoTempFile() async throws {
        let payload = Data("hello onelake streaming".utf8)
        let (client, queueID, stagingDir) = await makeClient(stubs: [
            .init(status: 200, body: payload),
        ])
        defer {
            MockURLProtocol.clearQueue(id: queueID)
            try? FileManager.default.removeItem(at: stagingDir)
        }

        let (destURL, handle) = try makeTempFileHandle(prefix: "ofem-stream-cleanup-dest")
        defer { try? FileManager.default.removeItem(at: destURL) }

        _ = try await client.read(
            alias: "test",
            workspaceGUID: Self.wsGUID,
            itemGUID: Self.itemGUID,
            path: "Files/a.txt",
            destination: handle
        )

        #expect(leakedFiles(in: stagingDir).isEmpty)
        try handle.close()
        #expect(try Data(contentsOf: destURL) == payload)
    }
}

// MARK: - OneLakeStreamProgressTests (#461)

/// `doStreamRequest`'s `onProgress` callback, attached via Alamofire's
/// `DownloadRequest.downloadProgress`.
@Suite("OneLakeClient — doStreamRequest incremental download progress (#461)")
struct OneLakeStreamProgressTests {
    private static let wsGUID = "ws-guid-progress"
    private static let itemGUID = "item-guid-progress"

    /// Isolated staging directory + mock session, matching
    /// `OneLakeStreamTempFileCleanupTests.makeClient(stubs:)`.
    private func makeClient(stubs: [MockURLProtocol.StubResponse]) async -> (OneLakeClient, String, URL) {
        let queueID = UUID().uuidString
        MockURLProtocol.registerQueue(id: queueID, stubs: stubs)
        let session = makeMockSession(queueID: queueID)
        let pool = SessionPool(tokenProvider: NoopTokenProvider())
        await pool._setSessionForTesting(session, alias: "test", scope: .oneLake)
        let stagingDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ofem-stream-progress-\(UUID().uuidString)", isDirectory: true)
        let client = OneLakeClient(
            sessionPool: pool,
            baseURL: streamBaseURL,
            downloadTempDirectory: stagingDir
        )
        return (client, queueID, stagingDir)
    }

    /// #461 review round 1: an earlier version of this test asserted ≥2
    /// ticks for a 3-chunk body, but that failed deterministically on real
    /// CI — the URL Loading System can coalesce `bodyChunks` delivered
    /// back-to-back (even with `MockURLProtocol`'s inter-chunk delay, see
    /// `NetTestHelpers.startLoading()`) into a single `didWriteData` /
    /// `downloadProgress` tick for a small payload, which is outside this
    /// test's control. This is now a SMOKE test for the real Alamofire
    /// wiring end to end (≥1 tick, correct final byte count, and — as a
    /// bonus check only when more than one tick did land — monotonically
    /// increasing). The actual ≥2-ticks/monotonic guarantee and the
    /// completed-never-exceeds-total invariant are pinned deterministically
    /// by `SyncEngineTests`'s unit tests on `SyncEngine.absoluteDownloadProgress`,
    /// which don't depend on real chunked delivery.
    @Test("downloadProgress fires at least once for a multi-chunk body, reaching the full byte count")
    func multiChunkProgressFiresAtLeastOnce() async throws {
        let chunks = [
            Data(repeating: 0x41, count: 4096),
            Data(repeating: 0x42, count: 4096),
            Data(repeating: 0x43, count: 4096),
        ]
        let full = chunks.reduce(into: Data()) { $0.append($1) }
        let (client, queueID, stagingDir) = await makeClient(stubs: [
            .init(status: 200, body: full, bodyChunks: chunks),
        ])
        defer {
            MockURLProtocol.clearQueue(id: queueID)
            try? FileManager.default.removeItem(at: stagingDir)
        }

        let (destURL, handle) = try makeTempFileHandle(prefix: "ofem-stream-progress-dest")
        defer {
            try? handle.close()
            try? FileManager.default.removeItem(at: destURL)
        }

        let recorder = ProgressTickRecorder()
        _ = try await client.read(
            alias: "test",
            workspaceGUID: Self.wsGUID,
            itemGUID: Self.itemGUID,
            path: "Files/a.txt",
            destination: handle,
            onProgress: { completed, total in
                recorder.record(completed, total)
            }
        )

        // downloadProgress's closure is dispatched relative to the request's
        // own completion asynchronously — see the doc comment on
        // `HTTPRetryTests.declaredContentLengthOverCapIsPreflightRejected`
        // for the same caveat on the DataRequest side. Poll briefly for at
        // least one tick to land rather than asserting immediately after
        // the await.
        var ticks = recorder.ticks
        var iterations = 0
        while ticks.isEmpty, iterations < 200 {
            try? await Task.sleep(nanoseconds: 2_000_000)
            ticks = recorder.ticks
            iterations += 1
        }

        #expect(!ticks.isEmpty, "expected at least 1 progress tick for a 3-chunk body")
        if ticks.count > 1 {
            var previousCompleted: Int64 = -1
            for tick in ticks {
                #expect(tick.completed > previousCompleted, "completed bytes must strictly increase: \(ticks)")
                previousCompleted = tick.completed
            }
        }
        #expect(ticks.last?.completed == Int64(full.count))

        try handle.close()
        #expect(try Data(contentsOf: destURL) == full)
    }

    @Test("onProgress defaulting to nil registers no downloadProgress handler — existing callers are unchanged")
    func nilProgressIsUnobserved() async throws {
        let payload = Data("no progress observer attached".utf8)
        let (client, queueID, stagingDir) = await makeClient(stubs: [
            .init(status: 200, body: payload),
        ])
        defer {
            MockURLProtocol.clearQueue(id: queueID)
            try? FileManager.default.removeItem(at: stagingDir)
        }

        let (destURL, handle) = try makeTempFileHandle(prefix: "ofem-stream-progress-dest-nil")
        defer {
            try? handle.close()
            try? FileManager.default.removeItem(at: destURL)
        }

        // No onProgress argument at all — exercises the default-nil path.
        _ = try await client.read(
            alias: "test",
            workspaceGUID: Self.wsGUID,
            itemGUID: Self.itemGUID,
            path: "Files/a.txt",
            destination: handle
        )

        try handle.close()
        #expect(try Data(contentsOf: destURL) == payload)
    }
}

// MARK: - OneLakeStatusMappingTests

@Suite("OneLakeError — status coverage")
struct OneLakeStatusMappingTests {
    @Test("serverError(Int) is mapped from HTTPClientError.serverError")
    func serverErrorMapped() {
        let err = HTTPClientError.serverError(503)
        let mapped = OneLakeError.from(err)
        if case OneLakeError.serverError(503) = mapped { /* pass */ } else {
            Issue.record("Expected .serverError(503), got \(mapped)")
        }
    }

    @Test("gone is mapped from HTTPClientError.gone")
    func goneMapped() {
        let err = HTTPClientError.gone
        let mapped = OneLakeError.from(err)
        if case OneLakeError.gone = mapped { /* pass */ } else {
            Issue.record("Expected .gone, got \(mapped)")
        }
    }

    @Test("payloadTooLarge is mapped from HTTPClientError.payloadTooLarge")
    func payloadTooLargeMapped() {
        let err = HTTPClientError.payloadTooLarge
        let mapped = OneLakeError.from(err)
        if case OneLakeError.payloadTooLarge = mapped { /* pass */ } else {
            Issue.record("Expected .payloadTooLarge, got \(mapped)")
        }
    }

    @Test("rangeNotSatisfiable is mapped from HTTPClientError.rangeNotSatisfiable")
    func rangeNotSatisfiableMapped() {
        let err = HTTPClientError.rangeNotSatisfiable
        let mapped = OneLakeError.from(err)
        if case OneLakeError.rangeNotSatisfiable = mapped { /* pass */ } else {
            Issue.record("Expected .rangeNotSatisfiable, got \(mapped)")
        }
    }

    @Test("apiError wrapping serverError is unwrapped correctly")
    func apiErrorUnwrapped() {
        let ae = APIError(statusCode: 503, status: "503 Service Unavailable", body: Data())
        let wrapped = HTTPClientError.apiError(ae)
        let mapped = OneLakeError.from(wrapped)
        if case OneLakeError.serverError(503) = mapped { /* pass */ } else {
            Issue.record("Expected .serverError(503) after apiError unwrap, got \(mapped)")
        }
    }

    @Test("CancellationError maps to .cancelled")
    func cancellationMapped() {
        let mapped = OneLakeError.from(CancellationError())
        if case OneLakeError.cancelled = mapped { /* pass */ } else {
            Issue.record("Expected .cancelled from CancellationError, got \(mapped)")
        }
    }
}

// MARK: - OneLakeSizeValidationTests

@Suite("OneLakeClient — size vs content.count validation")
struct OneLakeSizeValidationTests {
    @Test("write: size != content.count throws missingArgument")
    func sizeMismatchThrows() async throws {
        let client = makeClient()
        let content = Data("hello".utf8) // 5 bytes
        await #expect {
            try await client.write(
                alias: "a",
                workspaceGUID: wsGUID,
                itemGUID: itemGUID,
                path: "Files/a.txt",
                content: content,
                size: 999 // wrong
            )
        } throws: { error in
            if case OneLakeError.missingArgument = error { return true }
            return false
        }
    }
}
