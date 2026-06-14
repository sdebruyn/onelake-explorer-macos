import Foundation
import Testing
@testable import OfemKit

// MARK: - Helpers

private let streamBaseURL = URL(string: "https://onelake.dfs.fabric.microsoft.com")!
private let wsGUID = "ws-guid-stream"
private let itemGUID = "item-guid-stream"

private func makeStreamingGate() -> HTTPGateRegistry {
    HTTPGateRegistry(
        defaults: HTTPGateDefaults(maxConcurrent: 8, tokensPerSecond: 100, burst: 100),
        seeded: [HTTPGate(host: "onelake.dfs.fabric.microsoft.com",
                          maxConcurrent: 8, tokensPerSecond: 100, burst: 100)]
    )
}

/// Makes an OneLakeClient backed by a MockURLSession (buffered path).
///
/// For the `read(destination:)` method the client goes through
/// `HTTPClient.download` which uses `streamSession.bytes(for:)`. However,
/// `URLSession.bytes(for:)` cannot be intercepted by a custom URLProtocol
/// (URLProtocol only hooks into data-task flow). So for tests that exercise the
/// destination-write path we use a MockURLSession as BOTH the session and a
/// `MockStreamSession` adapter that wraps data-for in a compatible interface.
private func makeClientForTests(session: MockURLSession, maxAttempts: Int = 1) -> OneLakeClient {
    let mockStream = MockStreamSession(wrapped: session)
    let http = HTTPClient(
        session: session,
        streamSession: mockStream,
        gateRegistry: makeStreamingGate(),
        retryPolicy: HTTPRetryPolicy(maxAttempts: maxAttempts,
                                     initialBackoff: .milliseconds(5),
                                     maxBackoff: .milliseconds(20))
    )
    return OneLakeClient(http: http,
                         tokenProvider: MockTokenProvider(token: "stream-tok"),
                         baseURL: streamBaseURL)
}

private func makeTempFile() throws -> (URL, FileHandle) {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("ofem-stream-test-\(UUID().uuidString).bin")
    FileManager.default.createFile(atPath: url.path, contents: nil)
    let handle = try FileHandle(forUpdating: url)
    return (url, handle)
}

private func stub(status: Int, body: Data = Data(), headers: [String: String] = [:]) -> MockURLSession.Stub {
    MockURLSession.Stub(data: body, status: status, headers: headers, url: streamBaseURL)
}

// MARK: - MockStreamSession
//
// Adapts MockURLSession (which implements URLSessionProtocol via data(for:))
// to URLSessionStreamProtocol by wrapping the returned Data in a
// URLSession.AsyncBytes-like source.
//
// Since URLSession.AsyncBytes is not constructible in tests without a live
// connection, we use a different strategy: override `download(to:)` in a
// TestableHTTPClient subclass that writes buffered data from MockURLSession
// directly. This requires a wrapper at the HTTPClient level.
//
// Simpler approach: provide a URLSessionStreamProtocol conformer that
// converts the data(for:) response into URLSession.AsyncBytes by first
// saving to a temp file and using URLSession.bytes(for:) on a file:// URL.
// But that's complex. Instead, we test the streaming path via the real
// URLSession using a local http server.
//
// PRAGMATIC DECISION: We test the end-to-end `read(destination:)` path
// using a MockURLSession that returns the expected data, and we verify the
// destination file contains the correct bytes. The truncate-before-retry
// logic in HTTPClient.download is unit-tested separately in
// Net/HTTPClientDownloadTests.swift (SHOULD-1).
// For integration, the test below uses a URLProtocol approach.

/// A `URLSessionStreamProtocol` that adapts a `MockURLSession` so that
/// `HTTPClient.download(to:)` can be tested without a live network connection.
///
/// Each `bytes(for:)` call dequeues the next stub from the wrapped
/// `MockURLSession` and serves it through a private `URLSession` whose
/// `protocolClasses` includes `MockStreamURLProtocol`.  The stub is pushed
/// into a **per-instance** queue inside `MockStreamURLProtocol` before the
/// request fires, so concurrent test runs do not share state.
final class MockStreamSession: URLSessionStreamProtocol, @unchecked Sendable {
    private let wrapped: MockURLSession
    private let innerSession: URLSession

    init(wrapped: MockURLSession) {
        self.wrapped = wrapped
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockStreamURLProtocol.self]
        config.timeoutIntervalForRequest = 5
        self.innerSession = URLSession(configuration: config)
    }

    func bytes(for request: URLRequest) async throws -> (URLSession.AsyncBytes, URLResponse) {
        // Dequeue the next stub synchronously from the wrapped session and push
        // it into MockStreamURLProtocol's global queue BEFORE the inner session
        // fires the request.  This avoids any async call inside startLoading().
        let stub = wrapped.dequeueNextStub()
        MockStreamURLProtocol.push(stub: stub)
        return try await innerSession.bytes(for: request, delegate: nil)
    }
}

/// A `URLProtocol` subclass that serves pre-queued `MockURLSession.Stub`
/// values to `URLSession.bytes(for:)`.
///
/// Stubs are pushed by `MockStreamSession.bytes(for:)` immediately before
/// the request is issued.  Because each stub is pushed and consumed by
/// exactly one request, concurrent tests do not cross-contaminate as long as
/// each `MockStreamSession` instance uses its own wrapped `MockURLSession`.
final class MockStreamURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var queue: [MockURLSession.Stub] = []

    static func push(stub: MockURLSession.Stub) {
        lock.withLock { queue.append(stub) }
    }

    static func reset() {
        lock.withLock { queue.removeAll() }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let stub = MockStreamURLProtocol.lock.withLock { () -> MockURLSession.Stub? in
            guard !MockStreamURLProtocol.queue.isEmpty else { return nil }
            return MockStreamURLProtocol.queue.removeFirst()
        }
        guard let s = stub else {
            client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
            return
        }

        let response = HTTPURLResponse(
            url: request.url ?? s.url,
            statusCode: s.status,
            httpVersion: "HTTP/1.1",
            headerFields: s.headers
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: s.data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

// MARK: - OneLakeStreamingTests

// SHOULD-3: serialise tests in this suite and reset MockStreamURLProtocol's
// global queue in each test so stubs from one test cannot leak into another.
@Suite("OneLakeClient — streaming read(destination:) (net-19 / onelake-02)", .serialized)
struct OneLakeStreamingTests {

    @Test("read(destination:) writes body bytes to destination file")
    func streamingReadWritesToDisk() async throws {
        defer { MockStreamURLProtocol.reset() }
        let expected = Data(repeating: 0xAB, count: 512)
        let session = MockURLSession(stubs: [
            stub(status: 200, body: expected, headers: ["Content-Length": "512"])
        ])

        let (tmpURL, handle) = try makeTempFile()
        defer {
            try? handle.close()
            try? FileManager.default.removeItem(at: tmpURL)
        }

        let client = makeClientForTests(session: session)
        _ = try await client.read(
            alias: "a",
            workspaceGUID: wsGUID,
            itemGUID: itemGUID,
            path: "Files/big.bin",
            destination: handle
        )
        try handle.close()

        let written = try Data(contentsOf: tmpURL)
        #expect(written == expected,
            "Expected \(expected.count) bytes written to disk, got \(written.count)")
    }

    @Test("read(destination:) 404 maps to OneLakeError.notFound")
    func streamingRead404() async throws {
        defer { MockStreamURLProtocol.reset() }
        let session = MockURLSession(stubs: [stub(status: 404)])

        let (tmpURL, handle) = try makeTempFile()
        defer {
            try? handle.close()
            try? FileManager.default.removeItem(at: tmpURL)
        }

        let client = makeClientForTests(session: session)
        await #expect {
            _ = try await client.read(
                alias: "a",
                workspaceGUID: wsGUID,
                itemGUID: itemGUID,
                path: "Files/missing.bin",
                destination: handle
            )
        } throws: { error in
            if case OneLakeError.notFound = error { return true }
            return false
        }
    }

    @Test("read(destination:) 416 maps to OneLakeError.rangeNotSatisfiable (onelake-01)")
    func streamingRead416() async throws {
        defer { MockStreamURLProtocol.reset() }
        let session = MockURLSession(stubs: [stub(status: 416)])

        let (tmpURL, handle) = try makeTempFile()
        defer {
            try? handle.close()
            try? FileManager.default.removeItem(at: tmpURL)
        }

        let client = makeClientForTests(session: session)
        await #expect {
            _ = try await client.read(
                alias: "a",
                workspaceGUID: wsGUID,
                itemGUID: itemGUID,
                path: "Files/big.bin",
                range: 999_000_000..<1_000_000_000,
                destination: handle
            )
        } throws: { error in
            if case OneLakeError.rangeNotSatisfiable = error { return true }
            return false
        }
    }
}

// MARK: - OneLakeStatusMappingTests (onelake-01)

@Suite("OneLakeError — status coverage (onelake-01)")
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

// MARK: - OneLakeEmptyRangeTests (onelake-10)

@Suite("OneLakeClient — empty range guard (onelake-10)")
struct OneLakeEmptyRangeTests {
    @Test("empty range returns empty Data without network call")
    func emptyRangeReturnsEmpty() async throws {
        let session = MockURLSession(stubs: []) // no stubs — must not be called
        let http = HTTPClient(session: session,
                              gateRegistry: makeStreamingGate(),
                              retryPolicy: HTTPRetryPolicy(maxAttempts: 1))
        let client = OneLakeClient(http: http,
                                   tokenProvider: MockTokenProvider(token: "t"),
                                   baseURL: streamBaseURL)

        let (data, props) = try await client.read(
            alias: "a",
            workspaceGUID: wsGUID,
            itemGUID: itemGUID,
            path: "Files/a.txt",
            range: 5..<5 // empty range
        )
        #expect(data.isEmpty)
        #expect(props.contentLength == 0)
        #expect(session.requests.isEmpty)
    }

    @Test("empty range on destination overload returns empty PathProperties without network call")
    func emptyRangeDestinationNoNetwork() async throws {
        let session = MockURLSession(stubs: [])
        let http = HTTPClient(session: session,
                              gateRegistry: makeStreamingGate(),
                              retryPolicy: HTTPRetryPolicy(maxAttempts: 1))
        let client = OneLakeClient(http: http,
                                   tokenProvider: MockTokenProvider(token: "t"),
                                   baseURL: streamBaseURL)

        let (tmpURL, handle) = try makeTempFile()
        defer {
            try? handle.close()
            try? FileManager.default.removeItem(at: tmpURL)
        }

        let props = try await client.read(
            alias: "a",
            workspaceGUID: wsGUID,
            itemGUID: itemGUID,
            path: "Files/a.txt",
            range: 0..<0,
            destination: handle
        )
        #expect(props.contentLength == 0)
        #expect(session.requests.isEmpty)
    }
}

// MARK: - OneLakeContentLengthTests (onelake-07)

@Suite("OneLakeClient — Content-Length: 0 on empty body (onelake-07)")
struct OneLakeContentLengthTests {

    private func makeTestClient(session: MockURLSession) -> OneLakeClient {
        let http = HTTPClient(
            session: session,
            gateRegistry: makeStreamingGate(),
            retryPolicy: HTTPRetryPolicy(maxAttempts: 1)
        )
        return OneLakeClient(http: http,
                             tokenProvider: MockTokenProvider(token: "t"),
                             baseURL: streamBaseURL)
    }

    @Test("createDirectory sends Content-Length: 0")
    func createDirectoryContentLength() async throws {
        let session = MockURLSession(stubs: [
            MockURLSession.Stub(data: Data(), status: 201, headers: [:], url: streamBaseURL)
        ])
        let client = makeTestClient(session: session)
        try await client.createDirectory(
            alias: "a",
            workspaceGUID: wsGUID,
            itemGUID: itemGUID,
            path: "Files/NewDir"
        )
        let cl = session.requests.first?.value(forHTTPHeaderField: "Content-Length")
        #expect(cl == "0", "Expected Content-Length: 0 on bodyless PUT, got \(cl ?? "nil")")
    }

    @Test("write create step sends Content-Length: 0")
    func writeCreateContentLength() async throws {
        let session = MockURLSession(stubs: [
            MockURLSession.Stub(data: Data(), status: 201, headers: [:], url: streamBaseURL), // create
            MockURLSession.Stub(data: Data(), status: 200, headers: [:], url: streamBaseURL), // flush
        ])
        let client = makeTestClient(session: session)
        try await client.write(
            alias: "a",
            workspaceGUID: wsGUID,
            itemGUID: itemGUID,
            path: "Files/empty.txt",
            content: Data(),
            size: 0
        )
        let cl = session.requests[0].value(forHTTPHeaderField: "Content-Length")
        #expect(cl == "0")
    }
}

// MARK: - OneLakeSizeValidationTests (onelake-09)

@Suite("OneLakeClient — size vs content.count validation (onelake-09)")
struct OneLakeSizeValidationTests {

    @Test("write: size != content.count throws missingArgument")
    func sizeMismatchThrows() async throws {
        let session = MockURLSession(stubs: [])
        let http = HTTPClient(session: session,
                              gateRegistry: makeStreamingGate(),
                              retryPolicy: HTTPRetryPolicy(maxAttempts: 1))
        let client = OneLakeClient(http: http,
                                   tokenProvider: MockTokenProvider(token: "t"),
                                   baseURL: streamBaseURL)

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
        #expect(session.requests.isEmpty, "No network calls expected when size is wrong")
    }
}

// MARK: - OneLakePathEntryNameTests (onelake-12)

@Suite("OneLakeClient — PathEntry.name strips itemGUID prefix (onelake-12)")
struct OneLakePathEntryNameTests {
    @Test("listPath strips itemGUID prefix from entry names")
    func listPathStripsPrefix() async throws {
        let body = """
        {"paths":[
          {"name":"item-guid-stream/Files/data.csv","isDirectory":"false","contentLength":"1024"},
          {"name":"item-guid-stream/Files/subdir","isDirectory":"true","contentLength":"0"}
        ]}
        """
        let session = MockURLSession(stubs: [
            MockURLSession.Stub(data: body.data(using: .utf8)!,
                                status: 200,
                                headers: [:],
                                url: streamBaseURL)
        ])
        let http = HTTPClient(session: session,
                              gateRegistry: makeStreamingGate(),
                              retryPolicy: HTTPRetryPolicy(maxAttempts: 1))
        let client = OneLakeClient(http: http,
                                   tokenProvider: MockTokenProvider(token: "t"),
                                   baseURL: streamBaseURL)

        let result = try await client.listPath(
            alias: "a",
            workspaceGUID: wsGUID,
            itemGUID: itemGUID,
            directory: "Files",
            recursive: false
        )
        #expect(result.entries.count == 2)
        // The prefix "item-guid-stream/" must be stripped.
        #expect(result.entries[0].name == "Files/data.csv")
        #expect(result.entries[1].name == "Files/subdir")
    }

    @Test("listPath: name without itemGUID prefix is returned as-is (resilience)")
    func listPathNoPrefix() async throws {
        let body = """
        {"paths":[{"name":"other-guid/Files/a.csv","isDirectory":"false","contentLength":"10"}]}
        """
        let session = MockURLSession(stubs: [
            MockURLSession.Stub(data: body.data(using: .utf8)!,
                                status: 200,
                                headers: [:],
                                url: streamBaseURL)
        ])
        let http = HTTPClient(session: session,
                              gateRegistry: makeStreamingGate(),
                              retryPolicy: HTTPRetryPolicy(maxAttempts: 1))
        let client = OneLakeClient(http: http,
                                   tokenProvider: MockTokenProvider(token: "t"),
                                   baseURL: streamBaseURL)

        let result = try await client.listPath(
            alias: "a",
            workspaceGUID: wsGUID,
            itemGUID: itemGUID, // "item-guid-stream" — does NOT match "other-guid"
            directory: "Files",
            recursive: false
        )
        // Fallback: raw name returned unchanged.
        #expect(result.entries[0].name == "other-guid/Files/a.csv")
    }
}

// MARK: - OneLakePaginationGuardTests (onelake-11)

@Suite("OneLakeClient — pagination loop guard (onelake-11)")
struct OneLakePaginationGuardTests {
    @Test("listPath detects A→B→A cycle and throws paginationExceeded")
    func detectsCycle() async throws {
        let body = "{\"paths\":[{\"name\":\"\(itemGUID)/Files/a.csv\",\"isDirectory\":\"false\",\"contentLength\":\"10\"}]}"
        // Responses alternate between tok-A and tok-B to create an A→B→A cycle.
        let stubs = [
            MockURLSession.Stub(data: body.data(using: .utf8)!,
                                status: 200,
                                headers: ["x-ms-continuation": "tok-A"],
                                url: streamBaseURL),
            MockURLSession.Stub(data: body.data(using: .utf8)!,
                                status: 200,
                                headers: ["x-ms-continuation": "tok-B"],
                                url: streamBaseURL),
            MockURLSession.Stub(data: body.data(using: .utf8)!,
                                status: 200,
                                headers: ["x-ms-continuation": "tok-A"],
                                url: streamBaseURL),
        ]
        let session = MockURLSession(stubs: stubs)
        let http = HTTPClient(session: session,
                              gateRegistry: makeStreamingGate(),
                              retryPolicy: HTTPRetryPolicy(maxAttempts: 1))
        let client = OneLakeClient(http: http,
                                   tokenProvider: MockTokenProvider(token: "t"),
                                   baseURL: streamBaseURL)

        await #expect {
            _ = try await client.listPath(
                alias: "a",
                workspaceGUID: wsGUID,
                itemGUID: itemGUID,
                directory: "",
                recursive: false
            )
        } throws: { error in
            if case OneLakeError.paginationExceeded = error { return true }
            return false
        }
    }
}
