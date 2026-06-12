import Foundation
import Testing
@testable import OfemKit

// MARK: - MockThrowingURLSession

/// A ``URLSessionProtocol`` mock that can either return canned responses or
/// throw a transport error, used to test retry and cancellation paths.
///
/// ``MockURLSession`` (defined in HTTPClientTests.swift) only ever succeeds;
/// this companion can inject errors at configured positions.
final class MockThrowingURLSession: URLSessionProtocol, @unchecked Sendable {
    enum Outcome {
        case response(Data, Int, [String: String])
        case error(any Error)
    }

    private var outcomes: [Outcome]
    private(set) var requestCount: Int = 0
    private let lock = NSLock()

    init(outcomes: [Outcome]) {
        self.outcomes = outcomes
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let outcome: Outcome = lock.withLock {
            requestCount += 1
            precondition(!outcomes.isEmpty, "MockThrowingURLSession: outcomes exhausted")
            return outcomes.removeFirst()
        }
        switch outcome {
        case let .response(data, status, headers):
            let url = request.url ?? URL(string: "https://example.com")!
            let response = HTTPURLResponse(
                url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers
            )!
            return (data, response)
        case let .error(err):
            throw err
        }
    }
}

// MARK: - HTTPClient transport-error retry tests (net-16)

@Suite("HTTPClient — transport-error retry")
struct HTTPClientTransportRetryTests {

    private let testURL = URL(string: "https://onelake.dfs.fabric.microsoft.com/ws/item/file.txt")!

    private func makeGate() -> HTTPGateRegistry {
        let reg = HTTPGateRegistry(
            defaults: HTTPGateDefaults(maxConcurrent: 8, tokensPerSecond: 100, burst: 100)
        )
        Task { [reg] in
            await reg.register(
                host: "onelake.dfs.fabric.microsoft.com",
                maxConcurrent: 8, tokensPerSecond: 100, burst: 100
            )
        }
        return reg
    }

    private func makeClient(session: MockThrowingURLSession, maxAttempts: Int = 3) -> HTTPClient {
        HTTPClient(
            session: session,
            gateRegistry: makeGate(),
            retryPolicy: HTTPRetryPolicy(
                maxAttempts: maxAttempts,
                initialBackoff: .milliseconds(5),
                maxBackoff: .milliseconds(20)
            )
        )
    }

    @Test("cannotFindHost is retried as a transient error (net-16)")
    func cannotFindHostIsRetried() async throws {
        let session = MockThrowingURLSession(outcomes: [
            .error(URLError(.cannotFindHost)),
            .response(Data("ok".utf8), 200, [:]),
        ])
        let client = makeClient(session: session)
        var req = URLRequest(url: testURL)
        req.httpMethod = "GET"
        let (data, _) = try await client.execute(req, idempotent: true)
        #expect(String(data: data, encoding: .utf8) == "ok")
        #expect(session.requestCount == 2)
    }

    @Test("cannotConnectToHost is retried as a transient error (net-16)")
    func cannotConnectToHostIsRetried() async throws {
        let session = MockThrowingURLSession(outcomes: [
            .error(URLError(.cannotConnectToHost)),
            .response(Data("ok".utf8), 200, [:]),
        ])
        let client = makeClient(session: session)
        var req = URLRequest(url: testURL)
        req.httpMethod = "GET"
        let (data, _) = try await client.execute(req, idempotent: true)
        #expect(String(data: data, encoding: .utf8) == "ok")
        #expect(session.requestCount == 2)
    }

    @Test("transport errors exhaust retries and throw retriesExhausted")
    func transportErrorExhaustsRetries() async throws {
        let session = MockThrowingURLSession(outcomes: [
            .error(URLError(.cannotFindHost)),
            .error(URLError(.cannotFindHost)),
            .error(URLError(.cannotFindHost)),
        ])
        let client = makeClient(session: session, maxAttempts: 3)
        var req = URLRequest(url: testURL)
        req.httpMethod = "GET"
        do {
            _ = try await client.execute(req, idempotent: true)
            Issue.record("expected retriesExhausted to be thrown")
        } catch HTTPClientError.retriesExhausted(let attempts, _) {
            #expect(attempts == 3)
        }
    }

    @Test("tokenProvider with empty alias throws tokenAcquisitionFailed before any network call (net-14)")
    func tokenProviderWithEmptyAlias() async throws {
        let session = MockThrowingURLSession(outcomes: [])
        let client = makeClient(session: session, maxAttempts: 1)
        var req = URLRequest(url: testURL)
        req.httpMethod = "GET"
        do {
            _ = try await client.execute(req, tokenProvider: MockTokenProvider(token: "tok"), alias: "")
            Issue.record("expected tokenAcquisitionFailed to be thrown")
        } catch HTTPClientError.tokenAcquisitionFailed {
            // expected
        }
        #expect(session.requestCount == 0)
    }

    @Test("CancellationError during session.data is mapped to .cancelled (net-09)")
    func cancellationIsMapped() async throws {
        let session = MockThrowingURLSession(outcomes: [
            .error(CancellationError()),
        ])
        let client = makeClient(session: session, maxAttempts: 1)
        var req = URLRequest(url: testURL)
        req.httpMethod = "GET"
        do {
            _ = try await client.execute(req)
            Issue.record("expected .cancelled to be thrown")
        } catch HTTPClientError.cancelled {
            // expected
        }
    }
}

// MARK: - ParseRetryAfter additional date formats (net-07)

@Suite("parseRetryAfter — RFC 850 and asctime formats")
struct ParseRetryAfterAdditionalFormatsTests {

    private static let now = Date(timeIntervalSince1970: 1_700_000_000)

    @Test("parses RFC 850 date in the future")
    func rfc850DateInFuture() {
        let future = Date(timeIntervalSince1970: Self.now.timeIntervalSince1970 + 30)
        let str = HTTPRetryDateFormatters.rfc850.string(from: future)
        let result = parseRetryAfter(str, now: Self.now)
        guard let r = result else {
            Issue.record("parseRetryAfter returned nil for RFC 850 date '\(str)'")
            return
        }
        // Allow ±1 s rounding due to formatting truncation.
        let secs = r.components.seconds
        #expect(secs >= 29 && secs <= 31)
    }

    @Test("parses asctime date in the future")
    func asctimeDateInFuture() {
        let future = Date(timeIntervalSince1970: Self.now.timeIntervalSince1970 + 45)
        let str = HTTPRetryDateFormatters.asctime.string(from: future)
        let result = parseRetryAfter(str, now: Self.now)
        guard let r = result else {
            Issue.record("parseRetryAfter returned nil for asctime date '\(str)'")
            return
        }
        let secs = r.components.seconds
        #expect(secs >= 44 && secs <= 46)
    }

    @Test("RFC 850 date in the past returns nil")
    func rfc850DateInPast() {
        let past = Date(timeIntervalSince1970: Self.now.timeIntervalSince1970 - 60)
        let str = HTTPRetryDateFormatters.rfc850.string(from: past)
        #expect(parseRetryAfter(str, now: Self.now) == nil)
    }

    @Test("asctime date in the past returns nil")
    func asctimeDateInPast() {
        let past = Date(timeIntervalSince1970: Self.now.timeIntervalSince1970 - 60)
        let str = HTTPRetryDateFormatters.asctime.string(from: past)
        #expect(parseRetryAfter(str, now: Self.now) == nil)
    }
}

// MARK: - OneLakeError mapping tests (net-09)

@Suite("OneLakeError — error mapping")
struct OneLakeErrorMappingTests {

    @Test("HTTPClientError.cancelled maps to OneLakeError.cancelled")
    func cancelledMapping() {
        let err = OneLakeError.from(HTTPClientError.cancelled)
        if case .cancelled = err { /* expected */ } else {
            Issue.record("expected .cancelled, got \(err)")
        }
    }

    @Test("HTTPClientError.throttled maps to OneLakeError.rateLimited")
    func throttledMapping() {
        let err = OneLakeError.from(HTTPClientError.throttled)
        if case .rateLimited = err { /* expected */ } else {
            Issue.record("expected .rateLimited, got \(err)")
        }
    }

    @Test("CancellationError maps to OneLakeError.cancelled")
    func nativeCancellationMapping() {
        let err = OneLakeError.from(CancellationError())
        if case .cancelled = err { /* expected */ } else {
            Issue.record("expected .cancelled, got \(err)")
        }
    }

    @Test("apiError wrapping 429 sentinel unwraps to OneLakeError.rateLimited")
    func apiErrorWrappingThrottledSentinel() {
        let ae = APIError(statusCode: 429, status: "429 Too Many Requests", body: Data())
        let wrapped = HTTPClientError.apiError(ae)
        let err = OneLakeError.from(wrapped)
        if case .rateLimited = err { /* expected */ } else {
            Issue.record("expected .rateLimited after unwrapping apiError, got \(err)")
        }
    }
}

// MARK: - OneLakeClient streaming write test (net-10/arch-07)

@Suite("OneLakeClient — streaming write from file URL")
struct OneLakeClientStreamingWriteTests {

    private let dfsBaseURL = URL(string: "https://onelake.dfs.fabric.microsoft.com")!

    private func makeStub(status: Int) -> MockURLSession.Stub {
        MockURLSession.Stub(data: Data(), status: status, headers: [:], url: dfsBaseURL)
    }

    private func makeGate() -> HTTPGateRegistry {
        let reg = HTTPGateRegistry(
            defaults: HTTPGateDefaults(maxConcurrent: 8, tokensPerSecond: 100, burst: 100)
        )
        Task { [reg] in
            await reg.register(
                host: "onelake.dfs.fabric.microsoft.com",
                maxConcurrent: 8, tokensPerSecond: 100, burst: 100
            )
        }
        return reg
    }

    private func makeClient(session: MockURLSession) -> OneLakeClient {
        let http = HTTPClient(
            session: session,
            gateRegistry: makeGate(),
            retryPolicy: HTTPRetryPolicy(maxAttempts: 1)
        )
        return OneLakeClient(http: http, tokenProvider: MockTokenProvider(token: "tok"), baseURL: dfsBaseURL)
    }

    @Test("write(sourceURL:) sends create + append + flush for a small file (net-10/arch-07)")
    func writeFromURLSmallFile() async throws {
        let tmpDir = FileManager.default.temporaryDirectory
        let fileURL = tmpDir.appendingPathComponent(UUID().uuidString)
        let content = Data(repeating: 0xAB, count: 100)
        try content.write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        // PUT (create) + PATCH (append) + PATCH (flush) = 3 requests.
        let session = MockURLSession(stubs: [makeStub(status: 201), makeStub(status: 202), makeStub(status: 200)])
        let client = makeClient(session: session)
        try await client.write(
            alias: "a",
            workspaceGUID: "ws-guid",
            itemGUID: "item-guid",
            path: "Files/test.bin",
            sourceURL: fileURL,
            size: 100
        )
        #expect(session.requests.count == 3)
        #expect(session.requests[0].httpMethod == "PUT")
        #expect(session.requests[1].httpMethod == "PATCH")
        #expect(session.requests[2].httpMethod == "PATCH")
        #expect(session.requests[1].url?.query?.contains("action=append") == true)
        #expect(session.requests[2].url?.query?.contains("action=flush") == true)
    }

    @Test("write(sourceURL:) for zero-length file sends create + flush only (no append)")
    func writeFromURLZeroLengthFile() async throws {
        let tmpDir = FileManager.default.temporaryDirectory
        let fileURL = tmpDir.appendingPathComponent(UUID().uuidString)
        try Data().write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        // size=0: create + flush, no append.
        let session = MockURLSession(stubs: [makeStub(status: 201), makeStub(status: 200)])
        let client = makeClient(session: session)
        try await client.write(
            alias: "a",
            workspaceGUID: "ws-guid",
            itemGUID: "item-guid",
            path: "Files/empty.txt",
            sourceURL: fileURL,
            size: 0
        )
        #expect(session.requests.count == 2)
        #expect(session.requests[0].httpMethod == "PUT")
        #expect(session.requests[1].url?.query?.contains("action=flush") == true)
    }
}

// MARK: - OneLakeClient listPath pagination test (net-05)

@Suite("OneLakeClient — listPath percent-encoding in continuation token")
struct OneLakeClientListPathTests {

    private let dfsBaseURL = URL(string: "https://onelake.dfs.fabric.microsoft.com")!

    private func makeStub(status: Int, body: String, headers: [String: String] = [:]) -> MockURLSession.Stub {
        MockURLSession.Stub(data: body.data(using: .utf8)!, status: status, headers: headers, url: dfsBaseURL)
    }

    private func makeGate() -> HTTPGateRegistry {
        let reg = HTTPGateRegistry(
            defaults: HTTPGateDefaults(maxConcurrent: 8, tokensPerSecond: 100, burst: 100)
        )
        Task { [reg] in
            await reg.register(
                host: "onelake.dfs.fabric.microsoft.com",
                maxConcurrent: 8, tokensPerSecond: 100, burst: 100
            )
        }
        return reg
    }

    private func makeClient(session: MockURLSession) -> OneLakeClient {
        let http = HTTPClient(
            session: session,
            gateRegistry: makeGate(),
            retryPolicy: HTTPRetryPolicy(maxAttempts: 1)
        )
        return OneLakeClient(http: http, tokenProvider: MockTokenProvider(token: "tok"), baseURL: dfsBaseURL)
    }

    @Test("continuation token with '+' is percent-encoded as '%2B' in the follow-up request (net-05)")
    func plusInContinuationTokenIsEncoded() async throws {
        let page1 = """
        {"paths":[{"name":"item-guid/Files/a.csv","isDirectory":"false","contentLength":"10"}]}
        """
        let page2 = """
        {"paths":[{"name":"item-guid/Files/b.csv","isDirectory":"false","contentLength":"20"}]}
        """
        let session = MockURLSession(stubs: [
            makeStub(status: 200, body: page1, headers: ["x-ms-continuation": "ab+cd=="]),
            makeStub(status: 200, body: page2),
        ])
        let client = makeClient(session: session)
        let result = try await client.listPath(
            alias: "a", workspaceGUID: "ws-guid", itemGUID: "item-guid", directory: "", recursive: false
        )
        #expect(result.entries.count == 2)
        let secondURL = session.requests[1].url?.absoluteString ?? ""
        #expect(secondURL.contains("%2B"))
        #expect(!secondURL.contains("ab+cd"))
    }
}

// MARK: - FabricRequest helper unit tests (net-05, net-06)

@Suite("FabricRequest — URL helpers")
struct FabricRequestHelperTests {

    private let fabricBase = URL(string: "https://api.fabric.microsoft.com")!

    @Test("fabricListURL encodes '+' in continuationToken as '%2B' (net-05)")
    func plusInContinuationToken() {
        let url = fabricListURL(base: fabricBase, path: "/v1/workspaces", continuationToken: "ab+cd==")
        let urlStr = url.absoluteString
        #expect(urlStr.contains("%2B"))
        #expect(!urlStr.contains("ab+cd=="))
    }

    @Test("resolveContinuationURI resolves a path-relative URI against base (net-06)")
    func relativeContinuationURIResolved() throws {
        let resolved = try resolveContinuationURI("/v1/workspaces?cursor=abc", base: fabricBase)
        #expect(resolved.host == "api.fabric.microsoft.com")
        #expect(resolved.scheme == "https")
        #expect(resolved.query?.contains("cursor=abc") == true)
    }

    @Test("resolveContinuationURI with cross-host absolute URI throws (net-06)")
    func crossHostAbsoluteURIThrows() {
        do {
            _ = try resolveContinuationURI("https://evil.example.com/v1/workspaces", base: fabricBase)
            Issue.record("expected continuationURIHostMismatch")
        } catch FabricError.continuationURIHostMismatch {
            // expected
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }
}

// MARK: - FabricClient — relative continuationUri end-to-end (net-06, net-12)

@Suite("FabricClient — continuationUri pagination")
struct FabricClientContinuationURITests {

    private let fabricBase = URL(string: "https://api.fabric.microsoft.com")!

    private func makeStub(status: Int, body: String) -> MockURLSession.Stub {
        MockURLSession.Stub(data: body.data(using: .utf8)!, status: status, headers: [:], url: fabricBase)
    }

    private func makeGate() -> HTTPGateRegistry {
        let reg = HTTPGateRegistry(
            defaults: HTTPGateDefaults(maxConcurrent: 8, tokensPerSecond: 100, burst: 100)
        )
        Task { [reg] in
            await reg.register(
                host: "api.fabric.microsoft.com",
                maxConcurrent: 8, tokensPerSecond: 100, burst: 100
            )
        }
        return reg
    }

    private func makeClient(session: MockURLSession) -> FabricClient {
        let http = HTTPClient(
            session: session,
            gateRegistry: makeGate(),
            retryPolicy: HTTPRetryPolicy(maxAttempts: 1)
        )
        return FabricClient(http: http, tokenProvider: MockTokenProvider(token: "tok"), baseURL: fabricBase)
    }

    @Test("relative continuationUri is resolved and followed (net-06)")
    func relativeContinuationURI() async throws {
        let page1 = """
        {"value":[{"id":"ws-1","displayName":"WS1","type":"Workspace"}],\
        "continuationUri":"/v1/workspaces?cursor=abc123"}
        """
        let page2 = """
        {"value":[{"id":"ws-2","displayName":"WS2","type":"Workspace"}]}
        """
        let session = MockURLSession(stubs: [makeStub(status: 200, body: page1), makeStub(status: 200, body: page2)])
        let client = makeClient(session: session)
        let workspaces = try await client.listAllWorkspaces(alias: "work")
        #expect(workspaces.count == 2)
        #expect(session.requests.count == 2)
        // Relative URI was resolved — second request must have a host.
        #expect(session.requests[1].url?.host == "api.fabric.microsoft.com")
    }

    @Test("continuationUri-only response (no continuationToken) triggers a follow-up request (net-12)")
    func continuationURIOnlyResponse() async throws {
        let page1 = """
        {"value":[{"id":"ws-1","displayName":"WS1","type":"Workspace"}],\
        "continuationUri":"https://api.fabric.microsoft.com/v1/workspaces?cursor=next"}
        """
        let page2 = """
        {"value":[{"id":"ws-2","displayName":"WS2","type":"Workspace"}]}
        """
        let session = MockURLSession(stubs: [makeStub(status: 200, body: page1), makeStub(status: 200, body: page2)])
        let client = makeClient(session: session)
        let workspaces = try await client.listAllWorkspaces(alias: "work")
        #expect(workspaces.count == 2)
        #expect(session.requests.count == 2)
    }
}
