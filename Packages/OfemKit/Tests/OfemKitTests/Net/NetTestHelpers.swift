import Alamofire
import Foundation
@testable import OfemKit

// MARK: - Shared helpers for HTTP / OneLake / Fabric test files

// MARK: - MockURLProtocol

/// A `URLProtocol` subclass that serves pre-registered stubs without a
/// live network connection.
///
/// Each logical test session is assigned a unique queue ID.  Stubs are
/// registered per-queue so concurrent test suites do not consume each
/// other's stubs:
/// ```swift
/// let stubs = [StubResponse(status: 200, body: jsonData)]
/// let (session, queue) = makeMockSession(stubs: stubs)
/// // ... use session ...
/// MockURLProtocol.clearQueue(id: queue)
/// ```
///
/// Stubs are consumed in FIFO order.  If the queue is empty the request
/// fails with `URLError(.resourceUnavailable)`.
///
/// Thread safety: all queue access is serialised by `lock`.
final class MockURLProtocol: URLProtocol {
    /// A canned HTTP response stub.
    struct StubResponse {
        let status: Int
        let body: Data
        let headers: [String: String]

        init(status: Int, body: Data = Data(), headers: [String: String] = [:]) {
            self.status = status
            self.body = body
            self.headers = headers
        }

        init(status: Int, body: String, headers: [String: String] = [:]) {
            self.init(status: status, body: body.data(using: .utf8) ?? Data(), headers: headers)
        }
    }

    /// A request observed by a stub queue, recorded in arrival order.
    ///
    /// Lets tests assert on the exact sequence of calls a client made (e.g.
    /// that an upload created a staging path rather than the live
    /// destination) without teaching `StubResponse` anything about it.
    struct RecordedRequest {
        let method: String
        let url: String
        let headers: [String: String]
    }

    // MARK: - Per-queue registry

    private static let lock = NSLock()
    /// Header name used to route each request to its stub queue.
    static let queueIDHeader = "X-Mock-Queue-ID"
    // nonisolated(unsafe): serialised by `lock`.
    private nonisolated(unsafe) static var _queues: [String: [StubResponse]] = [:]
    // nonisolated(unsafe): serialised by `lock`.
    private nonisolated(unsafe) static var _recorded: [String: [RecordedRequest]] = [:]

    /// Registers a stub queue for the given identifier.
    static func registerQueue(id: String, stubs: [StubResponse]) {
        lock.withLock {
            _queues[id] = stubs
            _recorded[id] = []
        }
    }

    /// Removes a stub queue (call in `defer` to clean up after a test).
    static func clearQueue(id: String) {
        lock.withLock {
            _ = _queues.removeValue(forKey: id)
            _ = _recorded.removeValue(forKey: id)
        }
    }

    /// Returns every request this queue has received so far, in arrival order.
    static func recordedRequests(id: String) -> [RecordedRequest] {
        lock.withLock { _recorded[id] ?? [] }
    }

    /// Legacy global queue — used by tests that do not need per-session isolation.
    ///
    /// Prefer `registerQueue(id:stubs:)` + `makeMockSession(queueID:stubs:)` for
    /// new tests to avoid cross-suite interference.
    static var stubs: [StubResponse] {
        get { lock.withLock { _queues["global"] ?? [] } }
        set { lock.withLock { _queues["global"] = newValue } }
    }

    // MARK: - URLProtocol overrides

    override class func canInit(with _: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let queueID = request.value(forHTTPHeaderField: Self.queueIDHeader) ?? "global"
        let stub = Self.lock.withLock { () -> StubResponse? in
            let recorded = RecordedRequest(
                method: request.httpMethod ?? "GET",
                url: request.url?.absoluteString ?? "",
                headers: request.allHTTPHeaderFields ?? [:]
            )
            Self._recorded[queueID, default: []].append(recorded)
            guard var q = Self._queues[queueID], !q.isEmpty else { return nil }
            let first = q.removeFirst()
            Self._queues[queueID] = q
            return first
        }

        guard let stub else {
            client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
            return
        }

        let url = request.url ?? URL(string: "https://example.com")!
        let response = HTTPURLResponse(
            url: url,
            statusCode: stub.status,
            httpVersion: "HTTP/1.1",
            headerFields: stub.headers
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: stub.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

// MARK: - makeMockSession

/// Creates an Alamofire `Session` that routes all requests through
/// `MockURLProtocol`.
///
/// When `queueID` is supplied, the session injects an `X-Mock-Queue-ID`
/// header on every request so each session's stubs are isolated from those
/// of other concurrent sessions.  Callers must pair this with
/// `MockURLProtocol.registerQueue(id:stubs:)` before making requests and
/// `MockURLProtocol.clearQueue(id:)` when done.
///
/// When `queueID` is `nil`, the legacy global stub queue is used.
func makeMockSession(
    tokenProvider: any TokenProvider = NoopTokenProvider(),
    queueID: String? = nil
) -> Session {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [MockURLProtocol.self]
    config.urlCache = nil
    // Inject a no-op authenticator so the session does not attempt real
    // token acquisition from MSAL during tests.
    let credential = OfemCredential(accessToken: "test-token", expiresAt: .distantFuture)
    let authenticator = OfemAuthenticator(
        tokenProvider: tokenProvider,
        alias: "test",
        scope: .oneLake
    )
    let authInterceptor = AuthenticationInterceptor(
        authenticator: authenticator,
        credential: credential
    )

    if let queueID {
        // Adapter that stamps every outgoing request with the queue ID so
        // MockURLProtocol can route it to the correct stub queue.
        let adapter = QueueIDAdapter(queueID: queueID)
        let interceptor = Interceptor(adapters: [adapter], retriers: [], interceptors: [authInterceptor])
        return Session(configuration: config, interceptor: interceptor)
    } else {
        return Session(configuration: config, interceptor: authInterceptor)
    }
}

/// Request adapter that stamps the `X-Mock-Queue-ID` header on every request.
///
/// Internal (not `private`) so tests that need a custom `Interceptor` (e.g. to
/// exercise a specific `RequestRetrier` chain) can reuse it instead of
/// duplicating queue-routing logic.
struct QueueIDAdapter: RequestAdapter {
    let queueID: String
    func adapt(
        _ urlRequest: URLRequest,
        for _: Session,
        completion: @escaping (Result<URLRequest, any Error>) -> Void
    ) {
        var req = urlRequest
        req.setValue(queueID, forHTTPHeaderField: MockURLProtocol.queueIDHeader)
        completion(.success(req))
    }
}

// MARK: - NoopTokenProvider

/// A `TokenProvider` stub that returns a fixed token without contacting MSAL.
struct NoopTokenProvider: TokenProvider {
    let token: String

    init(token: String = "test-token") {
        self.token = token
    }

    func token(alias _: String, scope _: TokenScope) async throws -> String {
        token
    }
}

// MARK: - makeTempFileHandle

/// Creates a temporary file and opens it for reading and writing.
///
/// The caller is responsible for closing the handle and removing the file,
/// typically via `defer`:
/// ```swift
/// let (tmpURL, handle) = try makeTempFileHandle(prefix: "my-test")
/// defer {
///     try? handle.close()
///     try? FileManager.default.removeItem(at: tmpURL)
/// }
/// ```
func makeTempFileHandle(prefix: String = "ofem-test") throws -> (URL, FileHandle) {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("\(prefix)-\(UUID().uuidString).bin")
    FileManager.default.createFile(atPath: url.path, contents: nil)
    let handle = try FileHandle(forUpdating: url)
    return (url, handle)
}
