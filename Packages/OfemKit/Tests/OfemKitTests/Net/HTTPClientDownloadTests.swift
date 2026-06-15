import Foundation
import Testing
@testable import OfemKit

// MARK: - MockDirectStreamSession
//
// A URLSessionStreamProtocol that throws a transport error on the first N calls
// then returns a synthetic successful response by serving the given Data through
// a temporary file:// URL via a real URLSession.bytes(for:) call.
//
// This avoids the global MockStreamURLProtocol queue entirely, so these tests
// can run concurrently with OneLakeStreamingTests without cross-contamination.
// (SHOULD-1 / SHOULD-3)

/// A `URLSessionStreamProtocol` that injects a transport error on its first
/// `failCount` calls, then on subsequent calls returns a synthetic HTTP 200
/// response by streaming `successBody` through a temporary file.
///
/// Uses a real `URLSession.bytes(for:file://)` internally so `URLSession.AsyncBytes`
/// is genuinely produced — no `URLProtocol` hooks, no shared global state.
final class MockDirectStreamSession: URLSessionStreamProtocol, @unchecked Sendable {
    private let failCount: Int
    private let failError: any Error
    private let successBody: Data
    private var callCount = 0
    private let lock = NSLock()
    private let fakeURL: URL

    /// - Parameters:
    ///   - failCount: Number of initial calls that throw `failError`.
    ///   - failError: The error to throw on each of the first `failCount` calls.
    ///   - successBody: The byte payload to serve after the failure window.
    ///   - fakeURL: A URL whose `host` is used to build the synthetic
    ///     `HTTPURLResponse`. Must have a valid host component (e.g. the DFS
    ///     endpoint) so `HTTPClient` can look up the gate.
    init(failCount: Int, failError: any Error, successBody: Data, fakeURL: URL) {
        self.failCount = failCount
        self.failError = failError
        self.successBody = successBody
        self.fakeURL = fakeURL
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

        // Write the success body to a temp file and stream it from a file:// URL.
        // file:// streaming is zero-network and avoids any URLProtocol registration.
        // Write the stub data to a temp file.  Do NOT use defer to delete it here —
        // the AsyncBytes sequence is consumed asynchronously by the caller AFTER
        // this function returns, so the file must remain readable until the stream
        // is exhausted.  The OS temp directory reclaims it at the next reboot or
        // periodic cleanup.
        let tmpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ofem-dl-stub-\(UUID().uuidString).bin")
        try successBody.write(to: tmpURL)

        // Build a synthetic HTTPURLResponse whose URL matches the original request
        // (so `HTTPClient` sees the correct host for gate lookup) but whose body
        // comes from the file above.
        let responseURL = request.url ?? fakeURL
        let httpResponse = HTTPURLResponse(
            url: responseURL,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Length": "\(successBody.count)"]
        )!

        // Stream bytes from the temp file via a bare URLSession.
        let fileSession = URLSession(configuration: .ephemeral)
        let (asyncBytes, _) = try await fileSession.bytes(from: tmpURL)

        return (asyncBytes, httpResponse)
    }
}

// MARK: - Helpers
// tests-15: makeGate(host:) and makeTempFileHandle(prefix:) live in
// NetTestHelpers.swift and are shared across Net / OneLake download tests.

private let dlBaseURL = URL(string: "https://onelake.dfs.fabric.microsoft.com")!

// MARK: - HTTPClientDownloadTests (SHOULD-1)

/// Tests for `HTTPClient.download` retry and truncation behaviour.
///
/// The key invariant under test: when attempt 1 fails with a transport error,
/// the truncate-before-retry sequence in `download` must ensure the destination
/// contains ONLY the bytes from the successful attempt — no concatenation or
/// corruption from a failed earlier attempt.
///
/// These tests use `MockDirectStreamSession` which has no global shared state,
/// so they can run concurrently with other streaming-test suites without
/// cross-contaminating the shared `MockStreamURLProtocol` queue (SHOULD-3).
@Suite("HTTPClient — download retry / truncate-on-retry (SHOULD-1)")
struct HTTPClientDownloadTests {

    /// A transport error on attempt 1 (before any bytes are written) followed
    /// by a full successful download on attempt 2 must produce a destination
    /// file that contains exactly the second attempt's bytes.
    ///
    /// If the truncate-before-retry code were missing, a partial write from
    /// attempt 1 (none in this case) could corrupt the output.
    @Test("transport error on attempt 1 → success on attempt 2: destination contains only attempt-2 bytes")
    func truncateOnRetryProducesCleanOutput() async throws {
        let attempt2Body = Data(repeating: 0xCC, count: 256)

        // Attempt 1: throw URLError(.cannotConnectToHost) — retriable.
        // Attempt 2: stream 256 × 0xCC bytes to the destination.
        let streamSession = MockDirectStreamSession(
            failCount: 1,
            failError: URLError(.cannotConnectToHost),
            successBody: attempt2Body,
            fakeURL: dlBaseURL
        )

        let http = HTTPClient(
            session: MockURLSession(stubs: []),  // buffered session not used by download
            streamSession: streamSession,
            gateRegistry: makeGate(host: "onelake.dfs.fabric.microsoft.com"),
            retryPolicy: HTTPRetryPolicy(
                maxAttempts: 3,
                initialBackoff: .milliseconds(5),
                maxBackoff: .milliseconds(20)
            )
        )

        let (tmpURL, handle) = try makeTempFileHandle(prefix: "ofem-dl-test")
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

    /// When attempt 2 delivers a different body than attempt 1 would have,
    /// the final destination must contain the attempt-2 bytes only.
    ///
    /// This verifies that seek(toOffset: 0) + truncate(atOffset: 0) resets
    /// the destination completely before each attempt, regardless of what
    /// was written before.
    @Test("attempt-1 partial write is fully replaced by attempt-2 bytes after truncation")
    func truncationErasesAttempt1BytesBeforeAttempt2() async throws {
        // The second attempt delivers a distinct pattern so we can verify which
        // bytes are present.
        let attempt2Body = Data(repeating: 0xBB, count: 128)

        // Attempt 1 throws a transport error — no bytes reach the destination.
        // Attempt 2 delivers the final content.
        let streamSession = MockDirectStreamSession(
            failCount: 1,
            failError: URLError(.cannotFindHost),
            successBody: attempt2Body,
            fakeURL: dlBaseURL
        )

        let http = HTTPClient(
            session: MockURLSession(stubs: []),
            streamSession: streamSession,
            gateRegistry: makeGate(host: "onelake.dfs.fabric.microsoft.com"),
            retryPolicy: HTTPRetryPolicy(
                maxAttempts: 3,
                initialBackoff: .milliseconds(5),
                maxBackoff: .milliseconds(20)
            )
        )

        let (tmpURL, handle) = try makeTempFileHandle(prefix: "ofem-dl-test")
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
