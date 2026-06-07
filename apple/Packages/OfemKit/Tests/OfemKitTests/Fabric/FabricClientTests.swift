import Foundation
import Testing
@testable import OfemKit

// MARK: - Test helpers

private let fabricBase = URL(string: "https://api.fabric.microsoft.com")!

private func stub(status: Int, body: String = "", headers: [String: String] = [:]) -> MockURLSession.Stub {
    MockURLSession.Stub(
        data: body.data(using: .utf8)!,
        status: status,
        headers: headers,
        url: fabricBase
    )
}

private func makeGate() -> HTTPGateRegistry {
    let reg = HTTPGateRegistry(defaults: HTTPGateDefaults(maxConcurrent: 8, tokensPerSecond: 100, burst: 100))
    Task { [reg] in
        await reg.register(host: "api.fabric.microsoft.com", maxConcurrent: 8, tokensPerSecond: 100, burst: 100)
    }
    return reg
}

private func makeClient(session: MockURLSession, maxAttempts: Int = 1) -> FabricClient {
    let http = HTTPClient(
        session: session,
        gateRegistry: makeGate(),
        retryPolicy: HTTPRetryPolicy(maxAttempts: maxAttempts, initialBackoff: .milliseconds(10), maxBackoff: .milliseconds(50))
    )
    return FabricClient(http: http, tokenProvider: MockTokenProvider(token: "fab-tok"), baseURL: fabricBase)
}

// MARK: - FabricClientTests

@Suite("FabricClient")
struct FabricClientTests {
    // MARK: - Argument validation

    @Test("listItems: empty workspaceID throws missingArgument")
    func listItemsEmptyWorkspace() async throws {
        let session = MockURLSession(stubs: [])
        let client = makeClient(session: session)
        do {
            _ = try await client.listItems(alias: "a", workspaceID: "")
            Issue.record("expected throw")
        } catch FabricError.missingArgument {
            // expected
        }
    }

    @Test("listAllItems: empty workspaceID throws missingArgument")
    func listAllItemsEmptyWorkspace() async throws {
        let session = MockURLSession(stubs: [])
        let client = makeClient(session: session)
        do {
            _ = try await client.listAllItems(alias: "a", workspaceID: "")
            Issue.record("expected throw")
        } catch FabricError.missingArgument {
            // expected
        }
    }

    @Test("listFolders: empty workspaceID throws missingArgument")
    func listFoldersEmptyWorkspace() async throws {
        let session = MockURLSession(stubs: [])
        let client = makeClient(session: session)
        do {
            _ = try await client.listFolders(alias: "a", workspaceID: "")
            Issue.record("expected throw")
        } catch FabricError.missingArgument {
            // expected
        }
    }

    @Test("getItem: empty workspaceID or itemID throws missingArgument")
    func getItemMissingArgs() async throws {
        let session = MockURLSession(stubs: [])
        let client = makeClient(session: session)
        do {
            _ = try await client.getItem(alias: "a", workspaceID: "", itemID: "it1")
            Issue.record("expected throw for empty workspaceID")
        } catch FabricError.missingArgument {
            // expected
        }
        do {
            _ = try await client.getItem(alias: "a", workspaceID: "ws1", itemID: "")
            Issue.record("expected throw for empty itemID")
        } catch FabricError.missingArgument {
            // expected
        }
    }

    // MARK: - listAllWorkspaces

    @Test("listAllWorkspaces: decodes workspaces from JSON response")
    func listAllWorkspacesHappyPath() async throws {
        let body = """
        {"value":[
          {"id":"ws1","displayName":"Alpha","type":"Workspace"},
          {"id":"ws2","displayName":"Beta","type":"Workspace","capacityId":"cap1"}
        ]}
        """
        let session = MockURLSession(stubs: [stub(status: 200, body: body)])
        let client = makeClient(session: session)
        let got = try await client.listAllWorkspaces(alias: "work")
        #expect(got.count == 2)
        #expect(got[0].id == "ws1")
        #expect(got[0].displayName == "Alpha")
        #expect(got[1].capacityID == "cap1")
    }

    @Test("listAllWorkspaces: optional fields default to empty strings")
    func listAllWorkspacesOptionalFields() async throws {
        let body = """
        {"value":[{"id":"ws1","displayName":"Min"}]}
        """
        let session = MockURLSession(stubs: [stub(status: 200, body: body)])
        let client = makeClient(session: session)
        let got = try await client.listAllWorkspaces(alias: "work")
        #expect(got.count == 1)
        #expect(got[0].type == "")
        #expect(got[0].description == "")
        #expect(got[0].capacityID == "")
        #expect(got[0].domainID == "")
    }

    @Test("listAllWorkspaces: follows continuationToken pagination")
    func listAllWorkspacesPagination() async throws {
        let page1 = """
        {"value":[{"id":"ws1","displayName":"Alpha"}],"continuationToken":"tok-p2"}
        """
        let page2 = """
        {"value":[{"id":"ws2","displayName":"Beta"}]}
        """
        let session = MockURLSession(stubs: [
            stub(status: 200, body: page1),
            stub(status: 200, body: page2),
        ])
        let client = makeClient(session: session)
        let got = try await client.listAllWorkspaces(alias: "work")
        #expect(got.count == 2)
        #expect(got[0].id == "ws1")
        #expect(got[1].id == "ws2")
        #expect(session.requests.count == 2)
        // Second request must include the continuation token in query
        let q2 = session.requests[1].url?.query
        #expect(q2?.contains("continuationToken=tok-p2") == true)
    }

    @Test("listAllWorkspaces: follows continuationUri pagination")
    func listAllWorkspacesContinuationURI() async throws {
        let page1 = """
        {"value":[{"id":"ws1","displayName":"Alpha"}],"continuationUri":"https://api.fabric.microsoft.com/v1/workspaces?cursor=abc"}
        """
        let page2 = """
        {"value":[{"id":"ws2","displayName":"Beta"}]}
        """
        let session = MockURLSession(stubs: [
            stub(status: 200, body: page1),
            stub(status: 200, body: page2),
        ])
        let client = makeClient(session: session)
        let got = try await client.listAllWorkspaces(alias: "work")
        #expect(got.count == 2)
        #expect(session.requests.count == 2)
        // Second request must use the full continuation URI path
        let url2 = session.requests[1].url
        #expect(url2?.query?.contains("cursor=abc") == true)
    }

    @Test("listAllWorkspaces: looping continuationToken throws loopingPagination")
    func listAllWorkspacesLoopingToken() async throws {
        let body = """
        {"value":[{"id":"ws1","displayName":"Alpha"}],"continuationToken":"STUCK"}
        """
        // Return STUCK token repeatedly; client should bail after second page.
        let session = MockURLSession(stubs: [
            stub(status: 200, body: body),
            stub(status: 200, body: body),
        ])
        let client = makeClient(session: session)
        do {
            _ = try await client.listAllWorkspaces(alias: "work")
            Issue.record("expected throw")
        } catch FabricError.loopingPagination {
            // expected
        }
    }

    @Test("listAllWorkspaces: cross-host continuationUri throws continuationURIHostMismatch")
    func listAllWorkspacesCrossHostURI() async throws {
        let body = """
        {"value":[{"id":"ws1","displayName":"Alpha"}],"continuationUri":"https://evil.example.com/v1/workspaces?cursor=x"}
        """
        let session = MockURLSession(stubs: [stub(status: 200, body: body)])
        let client = makeClient(session: session)
        do {
            _ = try await client.listAllWorkspaces(alias: "work")
            Issue.record("expected throw")
        } catch FabricError.continuationURIHostMismatch {
            // expected
        }
    }

    // MARK: - listWorkspaces (single page)

    @Test("listWorkspaces: returns page with items and continuation token")
    func listWorkspacesSinglePage() async throws {
        let body = """
        {"value":[{"id":"ws1","displayName":"Alpha"}],"continuationToken":"next-tok"}
        """
        let session = MockURLSession(stubs: [stub(status: 200, body: body)])
        let client = makeClient(session: session)
        let page = try await client.listWorkspaces(alias: "work")
        #expect(page.items.count == 1)
        #expect(page.items[0].id == "ws1")
        #expect(page.continuationToken == "next-tok")
    }

    @Test("listWorkspaces: returns nil continuationToken on last page")
    func listWorkspacesLastPage() async throws {
        let body = """
        {"value":[{"id":"ws1","displayName":"Alpha"}]}
        """
        let session = MockURLSession(stubs: [stub(status: 200, body: body)])
        let client = makeClient(session: session)
        let page = try await client.listWorkspaces(alias: "work")
        #expect(page.continuationToken == nil)
    }

    @Test("listWorkspaces: passes continuation token in query")
    func listWorkspacesPassesToken() async throws {
        let body = """
        {"value":[]}
        """
        let session = MockURLSession(stubs: [stub(status: 200, body: body)])
        let client = makeClient(session: session)
        _ = try await client.listWorkspaces(alias: "work", continuation: "my-token")
        let q = session.requests.first?.url?.query
        #expect(q?.contains("continuationToken=my-token") == true)
    }

    // MARK: - listAllItems

    @Test("listAllItems: decodes items with all fields")
    func listAllItemsHappyPath() async throws {
        let body = """
        {"value":[
          {"id":"it1","displayName":"MyLakehouse","type":"Lakehouse","workspaceId":"ws1"},
          {"id":"it2","displayName":"NB","type":"Notebook","workspaceId":"ws1","folderId":"f1","description":"a notebook"}
        ]}
        """
        let session = MockURLSession(stubs: [stub(status: 200, body: body)])
        let client = makeClient(session: session)
        let got = try await client.listAllItems(alias: "a", workspaceID: "ws1")
        #expect(got.count == 2)
        #expect(got[0].type == "Lakehouse")
        #expect(got[1].parentFolderID == "f1")
        #expect(got[1].description == "a notebook")
    }

    @Test("listAllItems: URL includes workspaceID in path")
    func listAllItemsURLPath() async throws {
        let body = """
        {"value":[]}
        """
        let session = MockURLSession(stubs: [stub(status: 200, body: body)])
        let client = makeClient(session: session)
        _ = try await client.listAllItems(alias: "a", workspaceID: "ws-abc")
        let path = session.requests.first?.url?.path
        #expect(path?.contains("ws-abc") == true)
        #expect(path?.contains("items") == true)
    }

    // MARK: - listAllFolders

    @Test("listAllFolders: decodes folders with optional parentFolderId")
    func listAllFoldersHappyPath() async throws {
        let body = """
        {"value":[
          {"id":"f1","displayName":"Folder A","workspaceId":"ws1"},
          {"id":"f2","displayName":"Sub","workspaceId":"ws1","parentFolderId":"f1"}
        ]}
        """
        let session = MockURLSession(stubs: [stub(status: 200, body: body)])
        let client = makeClient(session: session)
        let got = try await client.listAllFolders(alias: "a", workspaceID: "ws1")
        #expect(got.count == 2)
        #expect(got[0].parentFolderID == "")
        #expect(got[1].parentFolderID == "f1")
    }

    // MARK: - getItem

    @Test("getItem: decodes a single item")
    func getItemHappyPath() async throws {
        let body = """
        {"id":"it1","displayName":"MyLakehouse","type":"Lakehouse","workspaceId":"ws1","description":"demo"}
        """
        let session = MockURLSession(stubs: [stub(status: 200, body: body)])
        let client = makeClient(session: session)
        let item = try await client.getItem(alias: "a", workspaceID: "ws1", itemID: "it1")
        #expect(item.id == "it1")
        #expect(item.description == "demo")
    }

    @Test("getItem: URL includes workspaceID and itemID in path")
    func getItemURLPath() async throws {
        let body = """
        {"id":"it1","displayName":"X","workspaceId":"ws1"}
        """
        let session = MockURLSession(stubs: [stub(status: 200, body: body)])
        let client = makeClient(session: session)
        _ = try await client.getItem(alias: "a", workspaceID: "ws-xyz", itemID: "it-abc")
        let path = session.requests.first?.url?.path
        #expect(path?.contains("ws-xyz") == true)
        #expect(path?.contains("it-abc") == true)
    }

    // MARK: - Authorization header

    @Test("requests carry Bearer token for fabric scope")
    func requestsCarryBearerToken() async throws {
        let body = """
        {"value":[]}
        """
        let session = MockURLSession(stubs: [stub(status: 200, body: body)])
        let client = makeClient(session: session)
        _ = try await client.listAllWorkspaces(alias: "work")
        let auth = session.requests.first?.value(forHTTPHeaderField: "Authorization")
        #expect(auth == "Bearer fab-tok")
    }

    @Test("requests carry Accept: application/json header")
    func requestsCarryAcceptHeader() async throws {
        let body = """
        {"value":[]}
        """
        let session = MockURLSession(stubs: [stub(status: 200, body: body)])
        let client = makeClient(session: session)
        _ = try await client.listAllWorkspaces(alias: "work")
        let accept = session.requests.first?.value(forHTTPHeaderField: "Accept")
        #expect(accept == "application/json")
    }

    // MARK: - Error mapping

    @Test("401 is mapped to FabricError.unauthorized")
    func unauthorized() async throws {
        let session = MockURLSession(stubs: [stub(status: 401)])
        let client = makeClient(session: session)
        do {
            _ = try await client.listAllWorkspaces(alias: "work")
            Issue.record("expected throw")
        } catch FabricError.unauthorized {
            // expected
        }
    }

    @Test("403 is mapped to FabricError.forbidden")
    func forbidden() async throws {
        let session = MockURLSession(stubs: [stub(status: 403)])
        let client = makeClient(session: session)
        do {
            _ = try await client.listAllWorkspaces(alias: "work")
            Issue.record("expected throw")
        } catch FabricError.forbidden {
            // expected
        }
    }

    @Test("404 on getItem is mapped to FabricError.notFound")
    func getItemNotFound() async throws {
        let session = MockURLSession(stubs: [stub(status: 404)])
        let client = makeClient(session: session)
        do {
            _ = try await client.getItem(alias: "a", workspaceID: "ws1", itemID: "missing")
            Issue.record("expected throw")
        } catch FabricError.notFound {
            // expected
        }
    }

    @Test("429 exhausted retries is mapped to FabricError.rateLimited or retriesExhausted")
    func throttledExhausted() async throws {
        let session = MockURLSession(stubs: [
            stub(status: 429, headers: ["Retry-After": "0"]),
            stub(status: 429, headers: ["Retry-After": "0"]),
            stub(status: 429, headers: ["Retry-After": "0"]),
        ])
        let client = makeClient(session: session, maxAttempts: 3)
        do {
            _ = try await client.listAllWorkspaces(alias: "work")
            Issue.record("expected throw")
        } catch FabricError.retriesExhausted {
            // expected — HTTPClient exhausts retries, then FabricError.from maps it
        } catch FabricError.rateLimited {
            // also acceptable
        }
    }

    @Test("429 with single retry succeeds")
    func throttledRetrySucceeds() async throws {
        let body = """
        {"value":[{"id":"ws1","displayName":"Alpha"}]}
        """
        let session = MockURLSession(stubs: [
            stub(status: 429, headers: ["Retry-After": "0"]),
            stub(status: 200, body: body),
        ])
        let client = makeClient(session: session, maxAttempts: 3)
        let got = try await client.listAllWorkspaces(alias: "work")
        #expect(got.count == 1)
        #expect(session.requests.count == 2)
    }

    @Test("500 is mapped to FabricError.serverError")
    func serverError500() async throws {
        let session = MockURLSession(stubs: [stub(status: 500)])
        let client = makeClient(session: session, maxAttempts: 1)
        do {
            _ = try await client.listAllWorkspaces(alias: "work")
            Issue.record("expected throw")
        } catch FabricError.serverError(let code) {
            #expect(code == 500)
        } catch FabricError.retriesExhausted {
            // also acceptable when maxAttempts > 1
        }
    }

    @Test("invalid JSON body throws FabricError.decodeFailed")
    func decodeFailed() async throws {
        let session = MockURLSession(stubs: [stub(status: 200, body: "not-json")])
        let client = makeClient(session: session)
        do {
            _ = try await client.listAllWorkspaces(alias: "work")
            Issue.record("expected throw")
        } catch FabricError.decodeFailed {
            // expected
        }
    }
}
