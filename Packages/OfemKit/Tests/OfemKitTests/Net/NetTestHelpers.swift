import Alamofire
import Foundation
@testable import OfemKit

// MARK: - Shared helpers for HTTP / OneLake / Fabric test files

// MARK: - MockURLProtocol

/// A `URLProtocol` subclass that serves pre-registered stubs without a
/// live network connection.
///
/// Register stubs before creating the `Session`:
/// ```swift
/// MockURLProtocol.stubs = [
///     StubResponse(status: 200, body: jsonData, headers: [:]),
///     StubResponse(status: 404, body: Data(), headers: [:]),
/// ]
/// let session = makeMockSession()
/// ```
///
/// Stubs are consumed in FIFO order.  If the queue is empty, the request
/// fails with a `URLError(.resourceUnavailable)`.
///
/// Thread safety: `stubs` is guarded by `lock`; safe for concurrent use
/// within a single test (single-writer, multiple-reader via `lock`).
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

    private static let lock = NSLock()
    private static var _stubs: [StubResponse] = []

    /// The ordered queue of stub responses to serve.  Consumed in FIFO order.
    static var stubs: [StubResponse] {
        get { lock.withLock { _stubs } }
        set { lock.withLock { _stubs = newValue } }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let stub = Self.lock.withLock { () -> StubResponse? in
            Self._stubs.isEmpty ? nil : Self._stubs.removeFirst()
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
/// The returned session should be used as the `SessionPool` backing in tests
/// that need to control HTTP responses without a live network.
func makeMockSession(tokenProvider: any TokenProvider = NoopTokenProvider()) -> Session {
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
    return Session(configuration: config, interceptor: authInterceptor)
}

// MARK: - NoopTokenProvider

/// A `TokenProvider` stub that returns a fixed token without contacting MSAL.
struct NoopTokenProvider: TokenProvider, Sendable {
    let token: String

    init(token: String = "test-token") {
        self.token = token
    }

    func token(alias: String, scope: TokenScope) async throws -> String { token }
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
