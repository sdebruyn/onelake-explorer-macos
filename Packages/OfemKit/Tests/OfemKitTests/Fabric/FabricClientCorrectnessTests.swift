import Foundation
@testable import OfemKit
import Testing

// MARK: - Helpers

private let fabricBaseURL = URL(string: "https://api.fabric.microsoft.com")!

private func makeClient() -> FabricClient {
    let pool = SessionPool(tokenProvider: NoopTokenProvider())
    return FabricClient(sessionPool: pool, baseURL: fabricBaseURL)
}

// MARK: - FabricErrorMappingTests

@Suite("FabricError — error mapping correctness")
struct FabricErrorMappingTests {
    @Test("apiError wrapping 403 sentinel is unwrapped to .forbidden")
    func apiErrorForbiddenUnwrapped() {
        let ae = APIError(statusCode: 403, status: "403 Forbidden", body: Data())
        let wrapped = HTTPClientError.apiError(ae)
        let mapped = FabricError.from(wrapped)
        if case FabricError.forbidden = mapped { /* pass */ } else {
            Issue.record("Expected .forbidden after apiError unwrap, got \(mapped)")
        }
    }

    @Test("apiError wrapping 404 sentinel is unwrapped to .notFound")
    func apiErrorNotFoundUnwrapped() {
        let ae = APIError(statusCode: 404, status: "404 Not Found", body: Data())
        let wrapped = HTTPClientError.apiError(ae)
        let mapped = FabricError.from(wrapped)
        if case FabricError.notFound = mapped { /* pass */ } else {
            Issue.record("Expected .notFound after apiError unwrap, got \(mapped)")
        }
    }

    @Test("apiError wrapping 500 sentinel is unwrapped to .serverError(500)")
    func apiError500Unwrapped() {
        let ae = APIError(statusCode: 500, status: "500 Internal Server Error", body: Data())
        let wrapped = HTTPClientError.apiError(ae)
        let mapped = FabricError.from(wrapped)
        if case FabricError.serverError(500) = mapped { /* pass */ } else {
            Issue.record("Expected .serverError(500) after apiError unwrap, got \(mapped)")
        }
    }

    @Test("bare CancellationError maps to .cancelled")
    func cancellationErrorMapped() {
        let mapped = FabricError.from(CancellationError())
        if case FabricError.cancelled = mapped { /* pass */ } else {
            Issue.record("Expected .cancelled from CancellationError, got \(mapped)")
        }
    }

    @Test("HTTPClientError.cancelled maps to .cancelled")
    func httpCancelledMapped() {
        let mapped = FabricError.from(HTTPClientError.cancelled)
        if case FabricError.cancelled = mapped { /* pass */ } else {
            Issue.record("Expected .cancelled from HTTPClientError.cancelled, got \(mapped)")
        }
    }

    @Test("retriesExhausted wrapping apiError(429) maps to .retriesExhausted")
    func retriesExhaustedWith429Unwrapped() {
        let ae = APIError(statusCode: 429, status: "429 Too Many Requests", body: Data())
        let lastErr = HTTPClientError.apiError(ae)
        let retriesErr = HTTPClientError.retriesExhausted(attempts: 3, last: lastErr)
        let mapped = FabricError.from(retriesErr)
        if case FabricError.retriesExhausted = mapped { /* pass */ } else {
            Issue.record("Expected .retriesExhausted from retriesExhausted, got \(mapped)")
        }
    }
}

// MARK: - FabricContinuationURISafetyTests

@Suite("FabricRequest — continuationUri safety")
struct FabricContinuationURISafetyTests {
    @Test("resolveContinuationURI rejects a URI with a different port")
    func rejectsDifferentPort() throws {
        let base = try #require(URL(string: "https://api.fabric.microsoft.com"))
        let uri = "https://api.fabric.microsoft.com:8080/v1/workspaces?ct=x"
        do {
            _ = try resolveContinuationURI(uri, base: base)
            Issue.record("Expected continuationURIHostMismatch for unexpected port")
        } catch FabricError.continuationURIHostMismatch {
            // expected
        }
    }

    @Test("resolveContinuationURI rejects a URI with embedded userinfo")
    func rejectsUserinfo() throws {
        let base = try #require(URL(string: "https://api.fabric.microsoft.com"))
        let uri = "https://user:pass@api.fabric.microsoft.com/v1/workspaces?ct=x"
        do {
            _ = try resolveContinuationURI(uri, base: base)
            Issue.record("Expected continuationURIHostMismatch for userinfo")
        } catch FabricError.continuationURIHostMismatch {
            // expected
        }
    }

    @Test("resolveContinuationURI accepts same-host same-port URI")
    func acceptsSameHostSamePort() throws {
        let base = try #require(URL(string: "https://api.fabric.microsoft.com"))
        let uri = "https://api.fabric.microsoft.com/v1/workspaces?ct=x"
        let resolved = try resolveContinuationURI(uri, base: base)
        #expect(resolved.absoluteString.hasPrefix("https://api.fabric.microsoft.com"))
    }

    @Test("resolveContinuationURI accepts relative URI")
    func acceptsRelativeURI() throws {
        let base = try #require(URL(string: "https://api.fabric.microsoft.com"))
        let uri = "/v1/workspaces?ct=x"
        let resolved = try resolveContinuationURI(uri, base: base)
        #expect(resolved.absoluteString.hasPrefix("https://api.fabric.microsoft.com"))
    }
}

// MARK: - FabricProtocolCompletenessTests

@Suite("FabricClientProtocol — listAllFolders in protocol")
struct FabricProtocolCompletenessTests {
    @Test("MockFabricClient conforms to updated protocol including listAllFolders")
    func mockConforms() async throws {
        let mock = MockFabricClient()
        mock.listFoldersResults = [.success([
            Folder(id: "f1", displayName: "Folder 1", workspaceID: "ws1"),
        ])]
        let folders = try await mock.listAllFolders(alias: "a", workspaceID: "ws1")
        #expect(folders.count == 1)
        #expect(folders[0].id == "f1")
    }
}
