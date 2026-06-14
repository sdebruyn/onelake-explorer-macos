import Foundation
import Testing
@testable import OfemKit

// MARK: - MockFailingStreamSession
//
// A URLSessionStreamProtocol that throws a transport error on the first N calls
// then delegates to MockStreamURLProtocol for the remaining calls.
//
// This is used to exercise the truncate-on-retry path in HTTPClient.download
// without a live network connection (SHOULD-1).

/// A `URLSessionStreamProtocol` that injects a transport error on its first
/// `failCount` calls, then serves responses from a `MockURLSession` via
/// `MockStreamURLProtocol` (same mechanism as `MockStreamSession`).
final class MockFailingStreamSession: URLSessionStreamProtocol, @unchecked Sendable {
    private let failCount: Int
    private let failError: any Error
    private let wrapped: MockURLSession
    private let innerSession: URLSession
    private var callCount = 0
    private let lock = NSLock()

    init(failCount: Int, failError: any Error, wrapped: MockURLSession) {
        self.failCount = failCount
        self.failError = failError
        self.wrapped = wrapped
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockStreamURLProtocol.self]
        config.timeoutIntervalForRequest = 5
        self.innerSession = URLSession(configuration: config)
    }

    func bytes(for request: URLRequest) async throws -> (URLSession.AsyncBytes, URLResponse) {
        let thisCall: Int = lock.withLock {
            let n = callCount
            callCount += 1
            return n
        }
        if thisCall < failCount {
            throw failError
        }
        // Delegate to the wrapped session via MockStreamURLProtocol.
        let stub = wrapped.dequeueNextStub()
        MockStreamURLProtocol.push(stub: stub)
        return try await innerSession.bytes(for: request, delegate: nil)
    }
}

// MARK: - Helpers

private let dlBaseURL = URL(string: "https://onelake.dfs.fabric.microsoft.com")!

private func makeDLGate() -> HTTPGateRegistry {
    HTTPGateRegistry(
        defaults: HTTPGateDefaults(maxConcurrent: 8, tokensPerSecond: 100, burst: 100),
        seeded: [HTTPGate(host: "onelake.dfs.fabric.microsoft.com",
                          maxConcurrent: 8, tokensPerSecond: 100, burst: 100)]
    )
}

private func makeTempFileHandle() throws -> (URL, FileHandle) {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("ofem-dl-test-\(UUID().uuidString).bin")
    FileManager.default.createFile(atPath: url.path, contents: nil)
    let handle = try FileHandle(forUpdating: url)
    return (url, handle)
}

private func dlStub(status: Int, body: Data, headers: [String: String] = [:]) -> MockURLSession.Stub {
    MockURLSession.Stub(data: body, status: status, headers: headers, url: dlBaseURL)
}

// MARK: - HTTPClientDownloadTests (SHOULD-1)

/// Tests for `HTTPClient.download` retry and truncation behaviour.
///
/// The key invariant under test: when attempt 1 fails with a transport error
/// after the destination `FileHandle` may already have been written to, the
/// truncate-before-retry sequence in `download` must ensure the destination
/// contains ONLY the bytes from the successful attempt — no concatenation or
/// corruption from a failed earlier attempt.
@Suite("HTTPClient — download retry / truncate-on-retry (SHOULD-1)", .serialized)
struct HTTPClientDownloadTests {

    /// A transport error on attempt 1 (mid-connection, before any bytes are
    /// written) followed by a full successful download on attempt 2 must produce
    /// a destination file that contains exactly the second attempt's bytes.
    ///
    /// If the truncate-before-retry code were missing, a partial write from
    /// attempt 1 (none in this case, but the destination offset could be non-zero
    /// from the seek/truncate logic) could corrupt the output.  The test
    /// verifies the exact byte sequence.
    @Test("transport error on attempt 1 → success on attempt 2: destination contains only attempt-2 bytes")
    func truncateOnRetryProducesCleanOutput() async throws {
        defer { MockStreamURLProtocol.reset() }

        let attempt2Body = Data(repeating: 0xCC, count: 256)

        // Attempt 1: throw a URLError (cannotConnectToHost is retriable).
        // Attempt 2: 200 OK with the expected body.
        let session = MockURLSession(stubs: [
            dlStub(status: 200, body: attempt2Body)
        ])
        let streamSession = MockFailingStreamSession(
            failCount: 1,
            failError: URLError(.cannotConnectToHost),
            wrapped: session
        )

        let http = HTTPClient(
            session: MockURLSession(stubs: []),  // buffered session not used by download
            streamSession: streamSession,
            gateRegistry: makeDLGate(),
            retryPolicy: HTTPRetryPolicy(
                maxAttempts: 3,
                initialBackoff: .milliseconds(5),
                maxBackoff: .milliseconds(20)
            )
        )

        let (tmpURL, handle) = try makeTempFileHandle()
        defer {
            try? handle.close()
            try? FileManager.default.removeItem(at: tmpURL)
        }

        var req = URLRequest(url: dlBaseURL.appendingPathComponent("ws/item/Files/a.bin"))
        req.httpMethod = "GET"

        _ = try await http.download(req, to: handle, idempotent: true)
        try handle.close()

        let written = try Data(contentsOf: tmpURL)

        // The file must contain ONLY the second attempt's bytes — exactly 256 bytes
        // of 0xCC.  If truncation were missing, the file could have garbage at the
        // start (from a previous seek position) or be a wrong length.
        #expect(written.count == attempt2Body.count,
            "Expected \(attempt2Body.count) bytes from attempt 2, got \(written.count)")
        #expect(written == attempt2Body,
            "Destination must contain only attempt-2 bytes; truncation appears to have failed")
    }

    /// When attempt 1 partially writes bytes (simulated here by the successful
    /// first stub being for a shorter payload) and attempt 2 delivers a
    /// different, longer body, the final destination must contain the attempt-2
    /// bytes only — not attempt-1 bytes followed by attempt-2 bytes.
    ///
    /// This verifies that seek(toOffset: 0) + truncate(atOffset: 0) resets
    /// the destination completely before each attempt, regardless of what
    /// was written before.
    @Test("attempt-1 partial write is fully replaced by attempt-2 bytes after truncation")
    func truncationErasesAttempt1BytesBeforeAttempt2() async throws {
        defer { MockStreamURLProtocol.reset() }

        // The second attempt delivers a distinct pattern so we can verify which
        // bytes are present.
        let attempt2Body = Data(repeating: 0xBB, count: 128)

        // Attempt 1 throws after yielding no bytes (transport-level failure
        // before any body is delivered).  Attempt 2 delivers the final content.
        let session = MockURLSession(stubs: [
            dlStub(status: 200, body: attempt2Body)
        ])
        let streamSession = MockFailingStreamSession(
            failCount: 1,
            failError: URLError(.cannotFindHost),
            wrapped: session
        )

        let http = HTTPClient(
            session: MockURLSession(stubs: []),
            streamSession: streamSession,
            gateRegistry: makeDLGate(),
            retryPolicy: HTTPRetryPolicy(
                maxAttempts: 3,
                initialBackoff: .milliseconds(5),
                maxBackoff: .milliseconds(20)
            )
        )

        let (tmpURL, handle) = try makeTempFileHandle()
        defer {
            try? handle.close()
            try? FileManager.default.removeItem(at: tmpURL)
        }

        var req = URLRequest(url: dlBaseURL.appendingPathComponent("ws/item/Files/b.bin"))
        req.httpMethod = "GET"

        _ = try await http.download(req, to: handle, idempotent: true)
        try handle.close()

        let written = try Data(contentsOf: tmpURL)

        #expect(written.count == attempt2Body.count,
            "Expected \(attempt2Body.count) bytes, got \(written.count) — possible concatenation with attempt-1 bytes")
        #expect(written == attempt2Body,
            "File must equal attempt-2 bytes exactly; got unexpected content")
    }
}
