import Foundation
import Testing
@testable import OfemKit

// MARK: - Test helpers

private let wsGUID = "workspace-guid-test"
private let itemGUID = "item-guid-test"
private let baseURL = URL(string: "https://onelake.dfs.fabric.microsoft.com")!

// Reuse MockURLSession and MockTokenProvider from HTTPClientTests
// (they are in the same test target, so visible without re-declaration).

private func stub(status: Int, body: String = "", headers: [String: String] = [:]) -> MockURLSession.Stub {
    MockURLSession.Stub(
        data: body.data(using: .utf8)!,
        status: status,
        headers: headers,
        url: baseURL
    )
}

private func makeGate() -> HTTPGateRegistry {
    let reg = HTTPGateRegistry(defaults: HTTPGateDefaults(maxConcurrent: 8, tokensPerSecond: 100, burst: 100))
    Task { [reg] in
        await reg.register(host: "onelake.dfs.fabric.microsoft.com", maxConcurrent: 8, tokensPerSecond: 100, burst: 100)
    }
    return reg
}

private func makeClient(session: MockURLSession, maxAttempts: Int = 1) -> OneLakeClient {
    let http = HTTPClient(
        session: session,
        gateRegistry: makeGate(),
        retryPolicy: HTTPRetryPolicy(maxAttempts: maxAttempts, initialBackoff: .milliseconds(10), maxBackoff: .milliseconds(50))
    )
    return OneLakeClient(http: http, tokenProvider: MockTokenProvider(token: "test-tok"), baseURL: baseURL)
}

// MARK: - OneLakeClientTests

@Suite("OneLakeClient")
struct OneLakeClientTests {
    // MARK: - Argument validation

    @Test("listPath: empty workspaceGUID throws missingArgument")
    func listPathEmptyWorkspace() async throws {
        let session = MockURLSession(stubs: [])
        let client = makeClient(session: session)
        do {
            _ = try await client.listPath(alias: "a", workspaceGUID: "", itemGUID: itemGUID, directory: "", recursive: false)
            Issue.record("expected throw")
        } catch OneLakeError.missingArgument {
            // expected
        }
    }

    @Test("write: empty path throws missingArgument")
    func writeEmptyPath() async throws {
        let session = MockURLSession(stubs: [])
        let client = makeClient(session: session)
        do {
            try await client.write(alias: "a", workspaceGUID: wsGUID, itemGUID: itemGUID, path: "", content: Data(), size: 0)
            Issue.record("expected throw")
        } catch OneLakeError.missingArgument {
            // expected
        }
    }

    @Test("delete: empty path throws missingArgument")
    func deleteEmptyPath() async throws {
        let session = MockURLSession(stubs: [])
        let client = makeClient(session: session)
        do {
            try await client.delete(alias: "a", workspaceGUID: wsGUID, itemGUID: itemGUID, path: "")
            Issue.record("expected throw")
        } catch OneLakeError.missingArgument {
            // expected
        }
    }

    // MARK: - listPath

    @Test("listPath: decodes single entry from JSON response")
    func listPathDecodesEntry() async throws {
        let body = """
        {"paths":[{"name":"item-guid-test/Files/data.csv","isDirectory":"false","contentLength":"1024","etag":"W/\\"abc\\"","lastModified":"Mon, 01 Jan 2024 00:00:00 GMT"}]}
        """
        let session = MockURLSession(stubs: [
            stub(status: 200, body: body, headers: [:]),
        ])
        let client = makeClient(session: session)
        let result = try await client.listPath(alias: "a", workspaceGUID: wsGUID, itemGUID: itemGUID, directory: "Files", recursive: false)
        #expect(result.entries.count == 1)
        let entry = result.entries[0]
        // onelake-12: itemGUID prefix ("item-guid-test/") is stripped from the name.
        #expect(entry.name == "Files/data.csv")
        #expect(!entry.isDirectory)
        #expect(entry.contentLength == 1024)
    }

    @Test("listPath: follows pagination via x-ms-continuation header")
    func listPathFollowsPagination() async throws {
        let page1 = """
        {"paths":[{"name":"item-guid-test/Files/a.csv","isDirectory":"false","contentLength":"10"}]}
        """
        let page2 = """
        {"paths":[{"name":"item-guid-test/Files/b.csv","isDirectory":"false","contentLength":"20"}]}
        """
        let session = MockURLSession(stubs: [
            MockURLSession.Stub(data: page1.data(using: .utf8)!, status: 200, headers: ["x-ms-continuation": "tok2"], url: baseURL),
            MockURLSession.Stub(data: page2.data(using: .utf8)!, status: 200, headers: [:], url: baseURL),
        ])
        let client = makeClient(session: session)
        let result = try await client.listPath(alias: "a", workspaceGUID: wsGUID, itemGUID: itemGUID, directory: "", recursive: true)
        #expect(result.entries.count == 2)
        #expect(session.requests.count == 2)
    }

    @Test("listPath: empty paths array returns empty result")
    func listPathEmpty() async throws {
        let session = MockURLSession(stubs: [stub(status: 200, body: "{\"paths\":[]}")])
        let client = makeClient(session: session)
        let result = try await client.listPath(alias: "a", workspaceGUID: wsGUID, itemGUID: itemGUID, directory: "Files", recursive: false)
        #expect(result.entries.isEmpty)
    }

    @Test("listPath: 404 is mapped to OneLakeError.notFound")
    func listPath404() async throws {
        let session = MockURLSession(stubs: [stub(status: 404)])
        let client = makeClient(session: session)
        do {
            _ = try await client.listPath(alias: "a", workspaceGUID: wsGUID, itemGUID: itemGUID, directory: "", recursive: false)
            Issue.record("expected throw")
        } catch OneLakeError.notFound {
            // expected
        }
    }

    // MARK: - getProperties

    @Test("getProperties: reads headers from HEAD response")
    func getPropertiesReadsHeaders() async throws {
        let headers: [String: String] = [
            "Content-Length": "512",
            "ETag": "\"etag-abc\"",
            "x-ms-resource-type": "file",
        ]
        let session = MockURLSession(stubs: [
            MockURLSession.Stub(data: Data(), status: 200, headers: headers, url: baseURL),
        ])
        let client = makeClient(session: session)
        let props = try await client.getProperties(alias: "a", workspaceGUID: wsGUID, itemGUID: itemGUID, path: "Files/a.txt")
        #expect(props.contentLength == 512)
        #expect(props.eTag == "\"etag-abc\"")
        #expect(!props.isDirectory)
    }

    @Test("getProperties: x-ms-resource-type=directory marks isDirectory")
    func getPropertiesDirectory() async throws {
        let headers: [String: String] = [
            "x-ms-resource-type": "directory",
            "Content-Length": "0",
        ]
        let session = MockURLSession(stubs: [
            MockURLSession.Stub(data: Data(), status: 200, headers: headers, url: baseURL),
        ])
        let client = makeClient(session: session)
        let props = try await client.getProperties(alias: "a", workspaceGUID: wsGUID, itemGUID: itemGUID, path: "Files/subdir")
        #expect(props.isDirectory)
    }

    // MARK: - read

    @Test("read: sends Range header when range is specified")
    func readWithRange() async throws {
        let session = MockURLSession(stubs: [stub(status: 206, body: "chunk")])
        let client = makeClient(session: session)
        let (data, _) = try await client.read(alias: "a", workspaceGUID: wsGUID, itemGUID: itemGUID, path: "Files/a.txt", range: 0..<5)
        #expect(String(data: data, encoding: .utf8) == "chunk")
        let rangeHeader = session.requests.first?.value(forHTTPHeaderField: "Range")
        #expect(rangeHeader == "bytes=0-4")
    }

    @Test("read: sends If-Match header when etag is provided")
    func readWithIfMatch() async throws {
        let session = MockURLSession(stubs: [stub(status: 200, body: "body")])
        let client = makeClient(session: session)
        _ = try await client.read(alias: "a", workspaceGUID: wsGUID, itemGUID: itemGUID, path: "Files/a.txt", ifMatch: "\"etag-xyz\"")
        let ifMatchHeader = session.requests.first?.value(forHTTPHeaderField: "If-Match")
        #expect(ifMatchHeader == "\"etag-xyz\"")
    }

    @Test("read: 412 maps to OneLakeError.preconditionFailed")
    func readPreconditionFailed() async throws {
        let session = MockURLSession(stubs: [stub(status: 412)])
        let client = makeClient(session: session)
        do {
            _ = try await client.read(alias: "a", workspaceGUID: wsGUID, itemGUID: itemGUID, path: "Files/a.txt", ifMatch: "stale-etag")
            Issue.record("expected throw")
        } catch OneLakeError.preconditionFailed {
            // expected
        }
    }

    // MARK: - write

    @Test("write: sends 3 requests for a small file (create+append+flush)")
    func writeSmallFile() async throws {
        let content = Data("hello, world".utf8)
        let session = MockURLSession(stubs: [
            stub(status: 201), // create
            stub(status: 202), // append
            stub(status: 200), // flush
        ])
        let client = makeClient(session: session)
        try await client.write(
            alias: "a",
            workspaceGUID: wsGUID,
            itemGUID: itemGUID,
            path: "Files/new.txt",
            content: content,
            size: Int64(content.count)
        )
        #expect(session.requests.count == 3)
        // First request: PUT with resource=file
        #expect(session.requests[0].httpMethod == "PUT")
        // Second request: PATCH with action=append
        #expect(session.requests[1].httpMethod == "PATCH")
        #expect(session.requests[1].url?.query?.contains("action=append") == true)
        // Third request: PATCH with action=flush
        #expect(session.requests[2].httpMethod == "PATCH")
        #expect(session.requests[2].url?.query?.contains("action=flush") == true)
    }

    @Test("write: empty file sends create+flush only (no append)")
    func writeEmptyFile() async throws {
        let session = MockURLSession(stubs: [
            stub(status: 201), // create
            stub(status: 200), // flush
        ])
        let client = makeClient(session: session)
        try await client.write(
            alias: "a",
            workspaceGUID: wsGUID,
            itemGUID: itemGUID,
            path: "Files/empty.txt",
            content: Data(),
            size: 0
        )
        #expect(session.requests.count == 2)
    }

    // MARK: - createDirectory

    @Test("createDirectory: sends PUT with resource=directory")
    func createDirectoryPUT() async throws {
        let session = MockURLSession(stubs: [stub(status: 201)])
        let client = makeClient(session: session)
        try await client.createDirectory(alias: "a", workspaceGUID: wsGUID, itemGUID: itemGUID, path: "Files/NewFolder")
        #expect(session.requests.count == 1)
        #expect(session.requests[0].httpMethod == "PUT")
        #expect(session.requests[0].url?.query?.contains("resource=directory") == true)
    }

    // MARK: - delete

    @Test("delete: sends DELETE request")
    func deleteSendsDelete() async throws {
        let session = MockURLSession(stubs: [stub(status: 200)])
        let client = makeClient(session: session)
        try await client.delete(alias: "a", workspaceGUID: wsGUID, itemGUID: itemGUID, path: "Files/old.txt")
        #expect(session.requests[0].httpMethod == "DELETE")
    }

    @Test("delete: recursive=true adds recursive=true query param")
    func deleteRecursive() async throws {
        let session = MockURLSession(stubs: [stub(status: 200)])
        let client = makeClient(session: session)
        try await client.delete(alias: "a", workspaceGUID: wsGUID, itemGUID: itemGUID, path: "Files/dir", recursive: true)
        #expect(session.requests[0].url?.query?.contains("recursive=true") == true)
    }

    @Test("delete: 404 maps to OneLakeError.notFound")
    func delete404() async throws {
        let session = MockURLSession(stubs: [stub(status: 404)])
        let client = makeClient(session: session)
        do {
            try await client.delete(alias: "a", workspaceGUID: wsGUID, itemGUID: itemGUID, path: "Files/gone.txt")
            Issue.record("expected throw")
        } catch OneLakeError.notFound {
            // expected
        }
    }

    // MARK: - write (sourceURL overload)

    @Test("write(sourceURL:): throws shortRead when declared size exceeds actual file length")
    func writeSourceURLShortRead() async throws {
        // Write 1 KiB of deterministic data to a temp file, then declare a size
        // larger than the actual file — the FileHandle reaches EOF before the
        // declared size is satisfied, which must surface as OneLakeError.shortRead.
        let tmpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ofem-test-short-read-\(UUID().uuidString).bin")
        let fileBytes = Data(repeating: 0xAB, count: 1024)
        try fileBytes.write(to: tmpURL)
        defer { try? FileManager.default.removeItem(at: tmpURL) }

        let session = MockURLSession(stubs: [
            stub(status: 201), // create (PUT) — reached
            stub(status: 202), // append (PATCH) — defensive; not reached: the short
                               // read is detected on the first chunk before any append
        ])
        let client = makeClient(session: session)

        // Declare 4 KiB but only 1 KiB exists on disk.
        await #expect {
            try await client.write(
                alias: "a",
                workspaceGUID: wsGUID,
                itemGUID: itemGUID,
                path: "Files/short.bin",
                sourceURL: tmpURL,
                size: 4096
            )
        } throws: { error in
            if case OneLakeError.shortRead = error { return true }
            return false
        }
    }

    // MARK: - 409 Conflict mapping

    @Test("delete: 409 maps to OneLakeError.conflict")
    func delete409Conflict() async throws {
        // A non-empty directory deleted without recursive=true returns HTTP 409.
        // Verify the DFS error mapping surfaces this as OneLakeError.conflict.
        let session = MockURLSession(stubs: [stub(status: 409)])
        let client = makeClient(session: session)
        await #expect {
            try await client.delete(alias: "a", workspaceGUID: wsGUID, itemGUID: itemGUID, path: "Files/non-empty-dir")
        } throws: { error in
            if case OneLakeError.conflict = error { return true }
            return false
        }
    }

    // MARK: - x-ms-version header

    @Test("requests include x-ms-version: 2021-08-06")
    func versionHeader() async throws {
        let session = MockURLSession(stubs: [stub(status: 200, body: "{\"paths\":[]}")])
        let client = makeClient(session: session)
        _ = try await client.listPath(alias: "a", workspaceGUID: wsGUID, itemGUID: itemGUID, directory: "", recursive: false)
        let version = session.requests.first?.value(forHTTPHeaderField: "x-ms-version")
        #expect(version == "2021-08-06")
    }
}
