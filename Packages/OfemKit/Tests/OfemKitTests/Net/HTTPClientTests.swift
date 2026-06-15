import Foundation
import Testing
@testable import OfemKit

// MARK: - MockURLSession

/// Synchronous mock session. Each call to `data(for:)` dequeues one
/// response stub from `stubs`. Throws if stubs are exhausted.
final class MockURLSession: URLSessionProtocol, @unchecked Sendable {
    struct Stub {
        let data: Data
        let status: Int
        let headers: [String: String]
        let url: URL
    }

    private var stubs: [Stub]
    private(set) var requests: [URLRequest] = []
    private let lock = NSLock()

    init(stubs: [Stub]) {
        self.stubs = stubs
    }

    /// Dequeues the next stub synchronously (without recording a request).
    /// Used by `MockStreamSession` to pre-populate `MockStreamURLProtocol`.
    func dequeueNextStub() -> Stub {
        lock.withLock {
            precondition(!stubs.isEmpty, "MockURLSession: stubs exhausted")
            return stubs.removeFirst()
        }
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        lock.withLock { requests.append(request) }
        let stub = lock.withLock { () -> Stub in
            precondition(!stubs.isEmpty, "MockURLSession: stubs exhausted")
            return stubs.removeFirst()
        }
        let allHeaders: [String: String] = stub.headers
        // HTTPURLResponse requires these.
        let response = HTTPURLResponse(
            url: stub.url,
            statusCode: stub.status,
            httpVersion: "HTTP/1.1",
            headerFields: allHeaders
        )!
        return (stub.data, response)
    }
}

// MARK: - MockTokenProvider

struct MockTokenProvider: TokenProvider {
    let token: String
    func token(alias: String, scope: TokenScope) async throws -> String { token }
}

// MARK: - Helpers

private let testURL = URL(string: "https://onelake.dfs.fabric.microsoft.com/ws/item/Files/a.txt")!

private func stub(status: Int, body: String = "", headers: [String: String] = [:]) -> MockURLSession.Stub {
    MockURLSession.Stub(
        data: body.data(using: .utf8)!,
        status: status,
        headers: headers,
        url: testURL
    )
}

private func makeGate() -> HTTPGateRegistry {
    // Delegates to the shared helper in NetTestHelpers.swift (tests-15).
    // Use the seeded initializer so the gate is registered before any
    // execute() call. Firing registration inside an unstructured Task{}
    // creates a race where execute() may run before the registration lands.
    makeGate(host: "onelake.dfs.fabric.microsoft.com")
}

// MARK: - HTTPClientTests

@Suite("HTTPClient")
struct HTTPClientTests {
    // MARK: - 2xx

    @Test("2xx returns data and response immediately")
    func success200() async throws {
        let session = MockURLSession(stubs: [stub(status: 200, body: "hello")])
        let client = HTTPClient(
            session: session,
            gateRegistry: makeGate(),
            retryPolicy: HTTPRetryPolicy(maxAttempts: 3)
        )
        var req = URLRequest(url: testURL)
        req.httpMethod = "GET"
        let (data, resp) = try await client.execute(req)
        #expect(String(data: data, encoding: .utf8) == "hello")
        #expect(resp.statusCode == 200)
        #expect(session.requests.count == 1)
    }

    // MARK: - Authorization header injection

    @Test("injects Bearer token when tokenProvider is supplied")
    func injectsBearerToken() async throws {
        let session = MockURLSession(stubs: [stub(status: 200)])
        let client = HTTPClient(
            session: session,
            gateRegistry: makeGate(),
            retryPolicy: HTTPRetryPolicy(maxAttempts: 1)
        )
        var req = URLRequest(url: testURL)
        req.httpMethod = "GET"
        let tp = MockTokenProvider(token: "test-token-123")
        _ = try await client.execute(req, tokenProvider: tp, alias: "work")
        let auth = session.requests.first?.value(forHTTPHeaderField: "Authorization")
        #expect(auth == "Bearer test-token-123")
    }

    // MARK: - 4xx terminal

    @Test("401 throws .unauthorized immediately without retry")
    func unauthorized() async throws {
        let session = MockURLSession(stubs: [stub(status: 401)])
        let client = HTTPClient(
            session: session,
            gateRegistry: makeGate(),
            retryPolicy: HTTPRetryPolicy(maxAttempts: 3)
        )
        var req = URLRequest(url: testURL)
        req.httpMethod = "GET"
        do {
            _ = try await client.execute(req)
            Issue.record("expected throw")
        } catch HTTPClientError.unauthorized {
            // expected
        }
        #expect(session.requests.count == 1)
    }

    @Test("404 throws .notFound immediately")
    func notFound() async throws {
        let session = MockURLSession(stubs: [stub(status: 404)])
        let client = HTTPClient(
            session: session,
            gateRegistry: makeGate(),
            retryPolicy: HTTPRetryPolicy(maxAttempts: 3)
        )
        var req = URLRequest(url: testURL)
        req.httpMethod = "GET"
        do {
            _ = try await client.execute(req)
            Issue.record("expected throw")
        } catch HTTPClientError.notFound {
            // expected
        }
        #expect(session.requests.count == 1)
    }

    // MARK: - 5xx retry

    @Test("500 is retried up to maxAttempts")
    func retries500() async throws {
        let stubs = [
            stub(status: 500),
            stub(status: 500),
            stub(status: 200, body: "ok"),
        ]
        let session = MockURLSession(stubs: stubs)
        let client = HTTPClient(
            session: session,
            gateRegistry: makeGate(),
            retryPolicy: HTTPRetryPolicy(maxAttempts: 3, initialBackoff: .milliseconds(10), maxBackoff: .milliseconds(50))
        )
        var req = URLRequest(url: testURL)
        req.httpMethod = "GET"
        let (data, _) = try await client.execute(req)
        #expect(String(data: data, encoding: .utf8) == "ok")
        #expect(session.requests.count == 3)
    }

    @Test("exhausted retries throw .retriesExhausted")
    func exhaustedRetries() async throws {
        let stubs = [stub(status: 503), stub(status: 503), stub(status: 503)]
        let session = MockURLSession(stubs: stubs)
        let client = HTTPClient(
            session: session,
            gateRegistry: makeGate(),
            retryPolicy: HTTPRetryPolicy(maxAttempts: 3, initialBackoff: .milliseconds(10), maxBackoff: .milliseconds(50))
        )
        var req = URLRequest(url: testURL)
        req.httpMethod = "GET"
        do {
            _ = try await client.execute(req)
            Issue.record("expected throw")
        } catch HTTPClientError.retriesExhausted(let attempts, _) {
            #expect(attempts == 3)
        }
        #expect(session.requests.count == 3)
    }

    // MARK: - 429 Retry-After honoured

    @Test("429 with Retry-After delta-seconds is honoured")
    func retryAfterHonoured() async throws {
        let stubs = [
            stub(status: 429, headers: ["Retry-After": "0"]),
            stub(status: 200, body: "ok"),
        ]
        let session = MockURLSession(stubs: stubs)
        let client = HTTPClient(
            session: session,
            gateRegistry: makeGate(),
            retryPolicy: HTTPRetryPolicy(maxAttempts: 3, initialBackoff: .milliseconds(10))
        )
        var req = URLRequest(url: testURL)
        req.httpMethod = "GET"
        let (data, _) = try await client.execute(req)
        #expect(String(data: data, encoding: .utf8) == "ok")
        #expect(session.requests.count == 2)
    }

    // MARK: - User-Agent header

    @Test("sets User-Agent header on every request")
    func userAgentHeader() async throws {
        let session = MockURLSession(stubs: [stub(status: 200)])
        let client = HTTPClient(
            session: session,
            gateRegistry: makeGate(),
            retryPolicy: HTTPRetryPolicy(maxAttempts: 1),
            userAgent: "TestAgent/9.9"
        )
        var req = URLRequest(url: testURL)
        req.httpMethod = "GET"
        _ = try await client.execute(req)
        let ua = session.requests.first?.value(forHTTPHeaderField: "User-Agent")
        #expect(ua == "TestAgent/9.9")
    }
}
