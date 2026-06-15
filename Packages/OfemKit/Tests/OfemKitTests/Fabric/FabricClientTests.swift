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

// tests-04 / tests-15: makeGate(host:) is shared in NetTestHelpers.swift.

private func makeClient(session: MockURLSession, maxAttempts: Int = 1) -> FabricClient {
    let http = HTTPClient(
        session: session,
        gateRegistry: makeGate(host: "api.fabric.microsoft.com"),
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

    @Test("listAllWorkspaces: looping continuationUri throws loopingPagination")
    func listAllWorkspacesLoopingURI() async throws {
        let body = """
        {"value":[{"id":"ws1","displayName":"Alpha"}],"continuationUri":"https://api.fabric.microsoft.com/v1/workspaces?cursor=STUCK"}
        """
        // Return the same URI twice — client should bail on second page.
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

    @Test("listWorkspaces: continuationUri-only response returns nil continuationToken")
    func listWorkspacesContinuationURIReturnsNilToken() async throws {
        // When the server returns only continuationUri (no continuationToken),
        // the single-page API cannot round-trip it as a query parameter —
        // it returns nil so callers know to use listAllWorkspaces instead.
        let body = """
        {"value":[{"id":"ws1","displayName":"Alpha"}],"continuationUri":"https://api.fabric.microsoft.com/v1/workspaces?cursor=abc"}
        """
        let session = MockURLSession(stubs: [stub(status: 200, body: body)])
        let client = makeClient(session: session)
        let page = try await client.listWorkspaces(alias: "work")
        #expect(page.items.count == 1)
        #expect(page.continuationToken == nil)
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

    // MARK: - Additional status→error mappings

    @Test("408 request timeout is retried and, on exhaustion, surfaces a network error")
    func requestTimeoutRetriesExhausted() async throws {
        // 408 is retriable; after all attempts it surfaces as retriesExhausted.
        let session = MockURLSession(stubs: [
            stub(status: 408),
            stub(status: 408),
        ])
        let client = makeClient(session: session, maxAttempts: 2)
        do {
            _ = try await client.listAllWorkspaces(alias: "work")
            Issue.record("expected throw")
        } catch FabricError.retriesExhausted {
            // expected
        } catch FabricError.serverError {
            // also acceptable for implementations that map 408 as a serverError
        }
    }

    @Test("503 server error is mapped to FabricError.serverError(503)")
    func serverError503() async throws {
        let session = MockURLSession(stubs: [stub(status: 503)])
        let client = makeClient(session: session, maxAttempts: 1)
        do {
            _ = try await client.listAllWorkspaces(alias: "work")
            Issue.record("expected throw")
        } catch FabricError.serverError(let code) {
            #expect(code == 503)
        } catch FabricError.retriesExhausted {
            // acceptable when the retry policy retries 503
        }
    }

    @Test("502 bad gateway surfaces as serverError or retriesExhausted")
    func serverError502() async throws {
        let session = MockURLSession(stubs: [stub(status: 502)])
        let client = makeClient(session: session, maxAttempts: 1)
        do {
            _ = try await client.listAllWorkspaces(alias: "work")
            Issue.record("expected throw")
        } catch FabricError.serverError(let code) {
            #expect(code == 502)
        } catch FabricError.retriesExhausted {
            // acceptable
        }
    }

    // MARK: - Empty value array

    @Test("listAllWorkspaces: empty value array returns empty list")
    func listAllWorkspacesEmptyPage() async throws {
        let body = """
        {"value":[]}
        """
        let session = MockURLSession(stubs: [stub(status: 200, body: body)])
        let client = makeClient(session: session)
        let got = try await client.listAllWorkspaces(alias: "work")
        #expect(got.isEmpty)
        #expect(session.requests.count == 1)
    }

    @Test("listAllItems: empty value array returns empty list")
    func listAllItemsEmptyPage() async throws {
        let body = """
        {"value":[]}
        """
        let session = MockURLSession(stubs: [stub(status: 200, body: body)])
        let client = makeClient(session: session)
        let got = try await client.listAllItems(alias: "a", workspaceID: "ws1")
        #expect(got.isEmpty)
    }

    @Test("listAllFolders: empty workspace throws missingArgument")
    func listAllFoldersEmptyWorkspace() async throws {
        let session = MockURLSession(stubs: [])
        let client = makeClient(session: session)
        do {
            _ = try await client.listAllFolders(alias: "a", workspaceID: "")
            Issue.record("expected throw")
        } catch FabricError.missingArgument {
            // expected
        }
    }

    @Test("listAllFolders: empty value array returns empty list")
    func listAllFoldersEmptyPage() async throws {
        let body = """
        {"value":[]}
        """
        let session = MockURLSession(stubs: [stub(status: 200, body: body)])
        let client = makeClient(session: session)
        let got = try await client.listAllFolders(alias: "a", workspaceID: "ws1")
        #expect(got.isEmpty)
    }

    // MARK: - Malformed / partial JSON payloads

    @Test("listAllWorkspaces: JSON object instead of array for value throws decodeFailed")
    func listAllWorkspacesValueNotArray() async throws {
        // The schema expects `value` to be an array, not a dict.
        let body = """
        {"value":{"id":"ws1"}}
        """
        let session = MockURLSession(stubs: [stub(status: 200, body: body)])
        let client = makeClient(session: session)
        do {
            _ = try await client.listAllWorkspaces(alias: "work")
            Issue.record("expected throw")
        } catch FabricError.decodeFailed {
            // expected
        }
    }

    @Test("listAllItems: row with missing workspaceId is silently skipped (fabric-06)")
    func listAllItemsMissingWorkspaceIdField() async throws {
        // fabric-06: WireItem.workspaceId is now optional. A row missing workspaceId
        // is silently dropped via compactMap rather than aborting the whole page.
        let body = """
        {"value":[{"id":"it1","displayName":"X"}]}
        """
        let session = MockURLSession(stubs: [stub(status: 200, body: body)])
        let client = makeClient(session: session)
        let items = try await client.listAllItems(alias: "a", workspaceID: "ws1")
        // The row is dropped (no workspaceId), so we get an empty result — no throw.
        #expect(items.isEmpty, "Expected empty list: row without workspaceId should be silently dropped (fabric-06)")
    }

    @Test("listAllWorkspaces: empty body throws decodeFailed")
    func listAllWorkspacesEmptyBody() async throws {
        let session = MockURLSession(stubs: [stub(status: 200, body: "")])
        let client = makeClient(session: session)
        do {
            _ = try await client.listAllWorkspaces(alias: "work")
            Issue.record("expected throw")
        } catch FabricError.decodeFailed {
            // expected
        }
    }

    @Test("getItem: empty body throws decodeFailed")
    func getItemEmptyBody() async throws {
        let session = MockURLSession(stubs: [stub(status: 200, body: "")])
        let client = makeClient(session: session)
        do {
            _ = try await client.getItem(alias: "a", workspaceID: "ws1", itemID: "it1")
            Issue.record("expected throw")
        } catch FabricError.decodeFailed {
            // expected
        }
    }

    // MARK: - Pagination: multi-page listAllItems

    @Test("listAllItems: follows continuationToken across two pages")
    func listAllItemsPagination() async throws {
        let page1 = """
        {"value":[{"id":"it1","displayName":"Lh1","type":"Lakehouse","workspaceId":"ws1"}],"continuationToken":"tok2"}
        """
        let page2 = """
        {"value":[{"id":"it2","displayName":"Lh2","type":"Lakehouse","workspaceId":"ws1"}]}
        """
        let session = MockURLSession(stubs: [
            stub(status: 200, body: page1),
            stub(status: 200, body: page2),
        ])
        let client = makeClient(session: session)
        let got = try await client.listAllItems(alias: "a", workspaceID: "ws1")
        #expect(got.count == 2)
        #expect(got[0].id == "it1")
        #expect(got[1].id == "it2")
        #expect(session.requests.count == 2)
        // Second request carries the token.
        let q2 = session.requests[1].url?.query
        #expect(q2?.contains("tok2") == true)
    }

    @Test("listAllItems: looping continuationToken throws loopingPagination")
    func listAllItemsLoopingToken() async throws {
        let body = """
        {"value":[{"id":"it1","displayName":"X","type":"Lakehouse","workspaceId":"ws1"}],"continuationToken":"LOOP"}
        """
        let session = MockURLSession(stubs: [
            stub(status: 200, body: body),
            stub(status: 200, body: body),
        ])
        let client = makeClient(session: session)
        do {
            _ = try await client.listAllItems(alias: "a", workspaceID: "ws1")
            Issue.record("expected throw")
        } catch FabricError.loopingPagination {
            // expected
        }
    }

    @Test("listAllFolders: follows continuationToken across two pages")
    func listAllFoldersPagination() async throws {
        let page1 = """
        {"value":[{"id":"f1","displayName":"Folder1","workspaceId":"ws1"}],"continuationToken":"ftok2"}
        """
        let page2 = """
        {"value":[{"id":"f2","displayName":"Folder2","workspaceId":"ws1"}]}
        """
        let session = MockURLSession(stubs: [
            stub(status: 200, body: page1),
            stub(status: 200, body: page2),
        ])
        let client = makeClient(session: session)
        let got = try await client.listAllFolders(alias: "a", workspaceID: "ws1")
        #expect(got.count == 2)
        #expect(got[0].id == "f1")
        #expect(got[1].id == "f2")
        #expect(session.requests.count == 2)
    }

    @Test("listAllFolders: follows continuationUri pagination")
    func listAllFoldersContinuationURI() async throws {
        let page1 = """
        {"value":[{"id":"f1","displayName":"F","workspaceId":"ws1"}],"continuationUri":"https://api.fabric.microsoft.com/v1/workspaces/ws1/folders?cursor=xyz"}
        """
        let page2 = """
        {"value":[{"id":"f2","displayName":"G","workspaceId":"ws1"}]}
        """
        let session = MockURLSession(stubs: [
            stub(status: 200, body: page1),
            stub(status: 200, body: page2),
        ])
        let client = makeClient(session: session)
        let got = try await client.listAllFolders(alias: "a", workspaceID: "ws1")
        #expect(got.count == 2)
        #expect(session.requests.count == 2)
        let url2 = session.requests[1].url
        #expect(url2?.query?.contains("cursor=xyz") == true)
    }

    // MARK: - listItems single-page

    @Test("listItems: returns page with items and continuation token")
    func listItemsSinglePage() async throws {
        let body = """
        {"value":[{"id":"it1","displayName":"Lh","type":"Lakehouse","workspaceId":"ws1"}],"continuationToken":"next-tok"}
        """
        let session = MockURLSession(stubs: [stub(status: 200, body: body)])
        let client = makeClient(session: session)
        let page = try await client.listItems(alias: "a", workspaceID: "ws1")
        #expect(page.items.count == 1)
        #expect(page.items[0].id == "it1")
        #expect(page.continuationToken == "next-tok")
    }

    @Test("listItems: returns nil continuationToken on last page")
    func listItemsLastPage() async throws {
        let body = """
        {"value":[{"id":"it1","displayName":"Lh","type":"Lakehouse","workspaceId":"ws1"}]}
        """
        let session = MockURLSession(stubs: [stub(status: 200, body: body)])
        let client = makeClient(session: session)
        let page = try await client.listItems(alias: "a", workspaceID: "ws1")
        #expect(page.continuationToken == nil)
    }

    @Test("listItems: continuationUri-only response returns nil continuationToken")
    func listItemsContinuationURIReturnsNilToken() async throws {
        let body = """
        {"value":[{"id":"it1","displayName":"X","type":"Lakehouse","workspaceId":"ws1"}],"continuationUri":"https://api.fabric.microsoft.com/v1/workspaces/ws1/items?cursor=abc"}
        """
        let session = MockURLSession(stubs: [stub(status: 200, body: body)])
        let client = makeClient(session: session)
        let page = try await client.listItems(alias: "a", workspaceID: "ws1", continuation: nil)
        #expect(page.items.count == 1)
        #expect(page.continuationToken == nil)
    }

    @Test("listItems: passes continuation token in query string")
    func listItemsPassesContinuationToken() async throws {
        let body = """
        {"value":[]}
        """
        let session = MockURLSession(stubs: [stub(status: 200, body: body)])
        let client = makeClient(session: session)
        _ = try await client.listItems(alias: "a", workspaceID: "ws1", continuation: "my-tok")
        let q = session.requests.first?.url?.query
        #expect(q?.contains("continuationToken=my-tok") == true)
    }

    // MARK: - listFolders single-page

    @Test("listFolders: returns page with items and continuation token")
    func listFoldersSinglePage() async throws {
        let body = """
        {"value":[{"id":"f1","displayName":"F","workspaceId":"ws1"}],"continuationToken":"fnext"}
        """
        let session = MockURLSession(stubs: [stub(status: 200, body: body)])
        let client = makeClient(session: session)
        let page = try await client.listFolders(alias: "a", workspaceID: "ws1")
        #expect(page.items.count == 1)
        #expect(page.items[0].id == "f1")
        #expect(page.continuationToken == "fnext")
    }

    @Test("listFolders: returns nil continuationToken on last page")
    func listFoldersLastPage() async throws {
        let body = """
        {"value":[{"id":"f1","displayName":"F","workspaceId":"ws1"}]}
        """
        let session = MockURLSession(stubs: [stub(status: 200, body: body)])
        let client = makeClient(session: session)
        let page = try await client.listFolders(alias: "a", workspaceID: "ws1")
        #expect(page.continuationToken == nil)
    }

    @Test("listFolders: passes continuation token in query string")
    func listFoldersPassesContinuationToken() async throws {
        let body = """
        {"value":[]}
        """
        let session = MockURLSession(stubs: [stub(status: 200, body: body)])
        let client = makeClient(session: session)
        _ = try await client.listFolders(alias: "a", workspaceID: "ws1", continuation: "folder-tok")
        let q = session.requests.first?.url?.query
        #expect(q?.contains("continuationToken=folder-tok") == true)
    }

    // MARK: - Relative continuationUri resolution (net-06)

    @Test("listAllWorkspaces: relative continuationUri is resolved against base and followed")
    func listAllWorkspacesRelativeContinuationURI() async throws {
        // A path-relative URI (no scheme, no host) should be resolved against base.
        let page1 = """
        {"value":[{"id":"ws1","displayName":"Alpha"}],"continuationUri":"/v1/workspaces?cursor=rel"}
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
        // The second request URL must carry the cursor query parameter.
        let url2 = session.requests[1].url
        #expect(url2?.host == "api.fabric.microsoft.com")
        #expect(url2?.query?.contains("cursor=rel") == true)
    }

    // MARK: - continuationToken percent-encoding (net-05)

    @Test("continuationToken with plus sign is percent-encoded in query (net-05)")
    func continuationTokenPlusEncodedInQuery() async throws {
        let body = """
        {"value":[]}
        """
        let session = MockURLSession(stubs: [stub(status: 200, body: body)])
        let client = makeClient(session: session)
        _ = try await client.listWorkspaces(alias: "work", continuation: "tok+with+plus")
        let rawQuery = try #require(session.requests.first?.url?.query)
        // The plus signs in the original token must be percent-encoded (%2B),
        // not left as literal +, so the server does not decode them as spaces.
        #expect(rawQuery.contains("%2B"))
        #expect(!rawQuery.contains("tok+with+plus"))
    }

    // MARK: - URL path construction

    @Test("listFolders: URL includes workspaceID and 'folders' segment in path")
    func listFoldersURLPath() async throws {
        let body = """
        {"value":[]}
        """
        let session = MockURLSession(stubs: [stub(status: 200, body: body)])
        let client = makeClient(session: session)
        _ = try await client.listFolders(alias: "a", workspaceID: "ws-folder-test")
        let path = session.requests.first?.url?.path
        #expect(path?.contains("ws-folder-test") == true)
        #expect(path?.contains("folders") == true)
    }

    // MARK: - FabricError.from mapping

    @Test("FabricError.from maps HTTPClientError.cancelled to FabricError.cancelled")
    func fabricErrorFromCancelled() {
        let mapped = FabricError.from(HTTPClientError.cancelled)
        if case .cancelled = mapped {
            // Correct.
        } else {
            Issue.record("Expected .cancelled, got \(mapped)")
        }
    }

    @Test("FabricError.from maps HTTPClientError.forbidden to FabricError.forbidden")
    func fabricErrorFromForbidden() {
        let mapped = FabricError.from(HTTPClientError.forbidden)
        if case .forbidden = mapped {
            // Correct.
        } else {
            Issue.record("Expected .forbidden, got \(mapped)")
        }
    }

    @Test("FabricError.from maps HTTPClientError.notFound to FabricError.notFound")
    func fabricErrorFromNotFound() {
        let mapped = FabricError.from(HTTPClientError.notFound)
        if case .notFound = mapped {
            // Correct.
        } else {
            Issue.record("Expected .notFound, got \(mapped)")
        }
    }

    @Test("FabricError.from maps HTTPClientError.retriesExhausted to FabricError.retriesExhausted")
    func fabricErrorFromRetriesExhausted() {
        let inner = HTTPClientError.throttled
        let mapped = FabricError.from(HTTPClientError.retriesExhausted(attempts: 3, last: inner))
        if case .retriesExhausted(let attempts) = mapped {
            #expect(attempts == 3)
        } else {
            Issue.record("Expected .retriesExhausted, got \(mapped)")
        }
    }

    @Test("FabricError.from maps unknown error to FabricError.httpError")
    func fabricErrorFromUnknown() {
        struct MyErr: Error {}
        let mapped = FabricError.from(MyErr())
        if case .httpError = mapped {
            // Correct.
        } else {
            Issue.record("Expected .httpError, got \(mapped)")
        }
    }
}
