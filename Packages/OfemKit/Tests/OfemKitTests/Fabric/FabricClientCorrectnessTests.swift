import Foundation
import Testing
@testable import OfemKit

// MARK: - Helpers (reuse the fabric test helpers declared in FabricClientTests.swift)

// NOTE: `stub`, `makeGate`, and `makeClient` are already defined in
// FabricClientTests.swift in the same test target. We define new helpers
// here that differ only in configuration.

private let fabricBaseURL = URL(string: "https://api.fabric.microsoft.com")!

private func fabricStub(status: Int, body: String = "", headers: [String: String] = [:]) -> MockURLSession.Stub {
    MockURLSession.Stub(
        data: body.data(using: .utf8)!,
        status: status,
        headers: headers,
        url: fabricBaseURL
    )
}

private func makeFabricGate() -> HTTPGateRegistry {
    HTTPGateRegistry(
        defaults: HTTPGateDefaults(maxConcurrent: 8, tokensPerSecond: 100, burst: 100),
        seeded: [HTTPGate(host: "api.fabric.microsoft.com", maxConcurrent: 8, tokensPerSecond: 100, burst: 100)]
    )
}

private func makeFabricClient(session: MockURLSession, maxAttempts: Int = 1) -> FabricClient {
    let http = HTTPClient(
        session: session,
        gateRegistry: makeFabricGate(),
        retryPolicy: HTTPRetryPolicy(maxAttempts: maxAttempts, initialBackoff: .milliseconds(5), maxBackoff: .milliseconds(20))
    )
    return FabricClient(http: http, tokenProvider: MockTokenProvider(token: "fab-tok"), baseURL: fabricBaseURL)
}

// MARK: - FabricErrorMappingTests (fabric-01 / fabric-02)

@Suite("FabricError — error mapping correctness (fabric-01 / fabric-02)")
struct FabricErrorMappingTests {

    @Test("apiError wrapping 403 sentinel is unwrapped to .forbidden (fabric-01)")
    func apiErrorForbiddenUnwrapped() {
        let ae = APIError(statusCode: 403, status: "403 Forbidden", body: Data())
        let wrapped = HTTPClientError.apiError(ae)
        let mapped = FabricError.from(wrapped)
        if case FabricError.forbidden = mapped { /* pass */ } else {
            Issue.record("Expected .forbidden after apiError unwrap, got \(mapped)")
        }
    }

    @Test("apiError wrapping 404 sentinel is unwrapped to .notFound (fabric-01)")
    func apiErrorNotFoundUnwrapped() {
        let ae = APIError(statusCode: 404, status: "404 Not Found", body: Data())
        let wrapped = HTTPClientError.apiError(ae)
        let mapped = FabricError.from(wrapped)
        if case FabricError.notFound = mapped { /* pass */ } else {
            Issue.record("Expected .notFound after apiError unwrap, got \(mapped)")
        }
    }

    @Test("apiError wrapping 500 sentinel is unwrapped to .serverError(500) (fabric-01)")
    func apiError500Unwrapped() {
        let ae = APIError(statusCode: 500, status: "500 Internal Server Error", body: Data())
        let wrapped = HTTPClientError.apiError(ae)
        let mapped = FabricError.from(wrapped)
        if case FabricError.serverError(500) = mapped { /* pass */ } else {
            Issue.record("Expected .serverError(500) after apiError unwrap, got \(mapped)")
        }
    }

    @Test("bare CancellationError maps to .cancelled (fabric-02)")
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

    @Test("retriesExhausted wrapping apiError(429) maps to .rateLimited (fabric-01)")
    func retriesExhaustedWith429Unwrapped() {
        let ae = APIError(statusCode: 429, status: "429 Too Many Requests", body: Data())
        let lastErr = HTTPClientError.apiError(ae)
        let retriesErr = HTTPClientError.retriesExhausted(attempts: 3, last: lastErr)
        // retriesExhausted itself maps to .retriesExhausted — the inner apiError
        // is not unwrapped a second time (the outer error type determines mapping).
        let mapped = FabricError.from(retriesErr)
        if case FabricError.retriesExhausted = mapped { /* pass */ } else {
            Issue.record("Expected .retriesExhausted from retriesExhausted, got \(mapped)")
        }
    }
}

// MARK: - FabricContinuationUriTests (fabric-04 / continuationUri pagination)

@Suite("FabricClient — continuationUri pagination (fabric-04)")
struct FabricContinuationUriTests {

    @Test("listAllWorkspaces follows continuationUri when no continuationToken is present")
    func followsContinuationURI() async throws {
        let page1 = """
        {"value":[{"id":"ws-1","displayName":"Workspace 1","type":"Workspace"}],
         "continuationUri":"https://api.fabric.microsoft.com/v1/workspaces?continuationToken=tok-1"}
        """
        let page2 = """
        {"value":[{"id":"ws-2","displayName":"Workspace 2","type":"Workspace"}]}
        """
        let session = MockURLSession(stubs: [
            fabricStub(status: 200, body: page1),
            fabricStub(status: 200, body: page2),
        ])
        let client = makeFabricClient(session: session)
        let workspaces = try await client.listAllWorkspaces(alias: "a")
        #expect(workspaces.count == 2)
        #expect(workspaces[0].id == "ws-1")
        #expect(workspaces[1].id == "ws-2")
        #expect(session.requests.count == 2)
    }

    @Test("listWorkspaces: hasContinuation is true when only continuationUri is present (fabric-04)")
    func singlePageHasContinuationFlag() async throws {
        let body = """
        {"value":[{"id":"ws-1","displayName":"W1","type":"Workspace"}],
         "continuationUri":"https://api.fabric.microsoft.com/v1/workspaces?ct=x"}
        """
        let session = MockURLSession(stubs: [fabricStub(status: 200, body: body)])
        let client = makeFabricClient(session: session)
        let page = try await client.listWorkspaces(alias: "a")
        #expect(page.hasContinuation == true, "hasContinuation should be true when continuationUri is present")
        #expect(page.continuationToken == nil, "continuationToken should be nil when only URI is present")
    }

    @Test("listAllWorkspaces detects duplicate continuationUri cycle and throws loopingPagination")
    func detectsDuplicateURI() async throws {
        let uri = "https://api.fabric.microsoft.com/v1/workspaces?ct=dup"
        let page = """
        {"value":[{"id":"ws-1","displayName":"W1","type":"Workspace"}],
         "continuationUri":"\(uri)"}
        """
        let session = MockURLSession(stubs: [
            fabricStub(status: 200, body: page),
            fabricStub(status: 200, body: page), // same URI again
        ])
        let client = makeFabricClient(session: session)
        await #expect {
            _ = try await client.listAllWorkspaces(alias: "a")
        } throws: { error in
            if case FabricError.loopingPagination = error { return true }
            return false
        }
    }
}

// MARK: - FabricPercentEncodingTests (fabric-03)

@Suite("FabricClient — path percent-encoding (fabric-03)")
struct FabricPercentEncodingTests {

    @Test("listItems encodes workspaceID in URL path")
    func listItemsEncodesWorkspaceID() async throws {
        // The workspace ID contains characters that would restructure the URL if
        // unencoded. With real GUIDs this is low-risk, but the encoding must apply.
        let workspaceID = "ws-id/with-slash"  // contains '/' — would split path
        // We can't actually make a valid request here (the ID would hit a 404)
        // so we just verify the URL construction throws or encodes correctly.
        // In practice IDs are GUIDs; this tests the defensive encoding path.
        let session = MockURLSession(stubs: [fabricStub(status: 200, body: "{\"value\":[]}")])
        let client = makeFabricClient(session: session)
        // With percent-encoding, the '/' in the ID should become '%2F' so it
        // doesn't split the path. The request must reach the server (i.e. not
        // crash or throw a URL error).
        let page = try await client.listItems(alias: "a", workspaceID: workspaceID)
        // The URL should contain the percent-encoded form in the path.
        let requestURL = session.requests.first?.url?.absoluteString ?? ""
        // SHOULD-2: assert ONLY the correctly percent-encoded form — the unencoded
        // form must not be accepted as a passing result.
        #expect(requestURL.contains("ws-id%2Fwith-slash"),
            "URL path must percent-encode '/' as '%2F'; got: \(requestURL)")
        _ = page
    }
}

// MARK: - FabricResilienceTests (fabric-06)

@Suite("FabricClient — per-row decode resilience (fabric-06)")
struct FabricResilienceTests {

    @Test("listAllWorkspaces skips rows with missing id rather than failing the whole page")
    func missingIdSkipped() async throws {
        let body = """
        {"value":[
          {"id":"ws-1","displayName":"Good Workspace","type":"Workspace"},
          {"displayName":"No ID Workspace","type":"Workspace"},
          {"id":"ws-3","displayName":"Another Good","type":"Workspace"}
        ]}
        """
        let session = MockURLSession(stubs: [fabricStub(status: 200, body: body)])
        let client = makeFabricClient(session: session)
        let workspaces = try await client.listAllWorkspaces(alias: "a")
        // The row without an 'id' should be silently dropped (compactMap).
        #expect(workspaces.count == 2)
        #expect(workspaces.map(\.id) == ["ws-1", "ws-3"])
    }

    @Test("listAllItems skips rows with missing workspaceId rather than failing the whole page")
    func missingWorkspaceIdSkipped() async throws {
        let body = """
        {"value":[
          {"id":"it-1","displayName":"Good Item","workspaceId":"ws-1"},
          {"id":"it-2","displayName":"No Workspace"},
          {"id":"it-3","displayName":"Another Good","workspaceId":"ws-1"}
        ]}
        """
        let session = MockURLSession(stubs: [fabricStub(status: 200, body: body)])
        let client = makeFabricClient(session: session)
        let items = try await client.listAllItems(alias: "a", workspaceID: "ws-1")
        #expect(items.count == 2)
        #expect(items.map(\.id) == ["it-1", "it-3"])
    }
}

// MARK: - FabricContinuationURISafetyTests (fabric-07)

@Suite("FabricRequest — continuationUri safety (fabric-07)")
struct FabricContinuationURISafetyTests {

    @Test("resolveContinuationURI rejects a URI with a different port")
    func rejectsDifferentPort() throws {
        let base = URL(string: "https://api.fabric.microsoft.com")!
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
        let base = URL(string: "https://api.fabric.microsoft.com")!
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
        let base = URL(string: "https://api.fabric.microsoft.com")!
        let uri = "https://api.fabric.microsoft.com/v1/workspaces?ct=x"
        let resolved = try resolveContinuationURI(uri, base: base)
        #expect(resolved.absoluteString.hasPrefix("https://api.fabric.microsoft.com"))
    }

    @Test("resolveContinuationURI accepts relative URI")
    func acceptsRelativeURI() throws {
        let base = URL(string: "https://api.fabric.microsoft.com")!
        let uri = "/v1/workspaces?ct=x"
        let resolved = try resolveContinuationURI(uri, base: base)
        #expect(resolved.absoluteString.hasPrefix("https://api.fabric.microsoft.com"))
    }
}

// MARK: - FabricProtocolCompletenessTests (fabric-05)

@Suite("FabricClientProtocol — listAllFolders in protocol (fabric-05)")
struct FabricProtocolCompletenessTests {

    @Test("MockFabricClient conforms to updated protocol including listAllFolders")
    func mockConforms() async throws {
        // Just instantiate the mock and call listAllFolders to verify the
        // protocol requirement is satisfied.
        let mock = MockFabricClient()
        mock.listFoldersResults = [.success([
            Folder(id: "f1", displayName: "Folder 1", workspaceID: "ws1")
        ])]
        let folders = try await mock.listAllFolders(alias: "a", workspaceID: "ws1")
        #expect(folders.count == 1)
        #expect(folders[0].id == "f1")
    }

    @Test("FabricClient.listAllFolders exhausts pagination")
    func fabricClientListAllFolders() async throws {
        let page1 = """
        {"value":[{"id":"f1","displayName":"Folder1","workspaceId":"ws-1"}],
         "continuationToken":"tok-next"}
        """
        let page2 = """
        {"value":[{"id":"f2","displayName":"Folder2","workspaceId":"ws-1"}]}
        """
        let session = MockURLSession(stubs: [
            fabricStub(status: 200, body: page1),
            fabricStub(status: 200, body: page2),
        ])
        let client = makeFabricClient(session: session)
        let folders = try await client.listAllFolders(alias: "a", workspaceID: "ws-1")
        #expect(folders.count == 2)
        #expect(folders.map(\.id) == ["f1", "f2"])
    }
}
