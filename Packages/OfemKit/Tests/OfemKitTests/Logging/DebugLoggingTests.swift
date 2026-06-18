import Foundation
import Testing
@testable import OfemKit

// MARK: - DebugLoggingTests
//
// Verifies that FabricClient and OneLakeClient emit the expected structured
// debug log lines (per-request, per-page, end-of-sequence) through OfemLogger.
//
// Strategy: wire a debug-level OfemLogger backed by a RotatingFileWriter that
// writes JSON lines to a temp directory.  After each scenario, read the log
// file and assert the expected keys and values appear in the captured lines.

// MARK: - Helpers

/// Creates a debug-level OfemLogger that writes JSON lines to `directory`.
private func makeCapturingLogger(directory: URL) -> OfemLogger {
    let writer = RotatingFileWriter(logDirectory: directory)
    let config = LogConfiguration(
        subsystem: "dev.debruyn.ofem.test",
        category: "test",
        level: .debug,
        fileWriter: writer
    )
    return OfemLogger(configuration: config)
}

/// Reads all JSON log lines from `directory/ofem.log` and returns them as
/// `[String: String]` dictionaries (best-effort; lines that fail to parse are
/// skipped; non-string values are converted via String(describing:)).
private func capturedLines(directory: URL) throws -> [[String: String]] {
    let logURL = directory.appendingPathComponent("ofem.log")
    guard FileManager.default.fileExists(atPath: logURL.path) else { return [] }
    let raw = try String(contentsOf: logURL, encoding: .utf8)
    return raw
        .split(separator: "\n", omittingEmptySubsequences: true)
        .compactMap { line -> [String: String]? in
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return nil }
            // Flatten every value to a String so assertions stay simple.
            return obj.mapValues { v -> String in
                if let s = v as? String { return s }
                return String(describing: v)
            }
        }
}

/// Creates a temporary directory, passes its URL to `body`, then removes the
/// directory when `body` returns.
private func withTempDir(_ body: (URL) async throws -> Void) async throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("ofem-log-test-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try await body(dir)
}

// MARK: - Fabric stubs

private let fabricBase = URL(string: "https://api.fabric.microsoft.com")!

private func fabricStub(status: Int = 200, body: String = "") -> MockURLSession.Stub {
    MockURLSession.Stub(
        data: body.data(using: .utf8)!,
        status: status,
        headers: [:],
        url: fabricBase
    )
}

private func makeFabricClient(session: MockURLSession, logger: OfemLogger) -> FabricClient {
    let http = HTTPClient(
        session: session,
        gateRegistry: makeGate(host: "api.fabric.microsoft.com"),
        retryPolicy: HTTPRetryPolicy(maxAttempts: 1, initialBackoff: .milliseconds(5), maxBackoff: .milliseconds(20))
    )
    return FabricClient(
        http: http,
        tokenProvider: MockTokenProvider(token: "test-tok"),
        baseURL: fabricBase,
        logger: logger
    )
}

// MARK: - OneLake stubs

private let oneLakeBase = URL(string: "https://onelake.dfs.fabric.microsoft.com")!

private func oneLakeStub(status: Int = 200, body: String = "", continuation: String? = nil) -> MockURLSession.Stub {
    var headers: [String: String] = [:]
    if let c = continuation { headers["x-ms-continuation"] = c }
    return MockURLSession.Stub(
        data: body.data(using: .utf8)!,
        status: status,
        headers: headers,
        url: oneLakeBase
    )
}

private func makeOneLakeClient(session: MockURLSession, logger: OfemLogger) -> OneLakeClient {
    let http = HTTPClient(
        session: session,
        gateRegistry: makeGate(host: "onelake.dfs.fabric.microsoft.com"),
        retryPolicy: HTTPRetryPolicy(maxAttempts: 1, initialBackoff: .milliseconds(5), maxBackoff: .milliseconds(20))
    )
    return OneLakeClient(
        http: http,
        tokenProvider: MockTokenProvider(token: "test-tok"),
        baseURL: oneLakeBase,
        logger: logger
    )
}

// MARK: - FabricClient debug logging

@Suite("FabricClient debug logging")
struct FabricClientDebugLoggingTests {

    @Test("single-page listAllWorkspaces emits request, page, and complete log lines")
    func singlePageWorkspacesEmitsExpectedLines() async throws {
        let body = """
        {"value":[{"id":"ws1","displayName":"WS1","type":"Workspace"}]}
        """
        try await withTempDir { dir in
            let logger = makeCapturingLogger(directory: dir)
            let session = MockURLSession(stubs: [fabricStub(body: body)])
            let client = makeFabricClient(session: session, logger: logger)

            let workspaces = try await client.listAllWorkspaces(alias: "test")
            #expect(workspaces.count == 1)

            let lines = try capturedLines(directory: dir)

            // There must be a "fabric request" line.
            let requestLines = lines.filter { $0["msg"] == "fabric request" }
            #expect(!requestLines.isEmpty, "expected at least one 'fabric request' log line")
            if let req = requestLines.first {
                #expect(req["method"] == "GET")
                // path contains '/' so Privacy.scrubLogValue redacts it — key
                // must be present but value is "redacted".
                #expect(req["path"] != nil)
            }

            // There must be a "fabric response" line with status code.
            let responseLines = lines.filter { $0["msg"] == "fabric response" }
            #expect(!responseLines.isEmpty, "expected at least one 'fabric response' log line")
            if let resp = responseLines.first {
                #expect(resp["status"] == "200")
            }

            // There must be a "fabric list page" line for the last (only) page.
            // Numeric and boolean-string values are in the safe charset and are
            // written verbatim by Privacy.scrubLogValue.
            let pageLines = lines.filter { $0["msg"] == "fabric list page" }
            #expect(!pageLines.isEmpty, "expected at least one 'fabric list page' log line")
            if let pg = pageLines.first {
                #expect(pg["page"] == "1")
                #expect(pg["hasContinuation"] == "false")
            }

            // There must be a "fabric list complete" line.
            let completeLines = lines.filter { $0["msg"] == "fabric list complete" }
            #expect(!completeLines.isEmpty, "expected a 'fabric list complete' log line")
            if let comp = completeLines.first {
                #expect(comp["totalPages"] == "1")
                #expect(comp["totalItems"] == "1")
            }
        }
    }

    @Test("two-page listAllWorkspaces emits per-page lines and complete with totals")
    func twoPageWorkspacesEmitsPageLines() async throws {
        let page1 = """
        {"value":[{"id":"ws1","displayName":"WS1","type":"Workspace"},{"id":"ws2","displayName":"WS2","type":"Workspace"}],"continuationToken":"tok1"}
        """
        let page2 = """
        {"value":[{"id":"ws3","displayName":"WS3","type":"Workspace"}]}
        """
        try await withTempDir { dir in
            let logger = makeCapturingLogger(directory: dir)
            let session = MockURLSession(stubs: [fabricStub(body: page1), fabricStub(body: page2)])
            let client = makeFabricClient(session: session, logger: logger)

            let workspaces = try await client.listAllWorkspaces(alias: "test")
            #expect(workspaces.count == 3)

            let lines = try capturedLines(directory: dir)

            // Two request / response pairs.
            let requestLines = lines.filter { $0["msg"] == "fabric request" }
            #expect(requestLines.count == 2, "expected 2 'fabric request' lines, got \(requestLines.count)")

            // Two page lines.
            let pageLines = lines.filter { $0["msg"] == "fabric list page" }
            #expect(pageLines.count == 2, "expected 2 'fabric list page' lines, got \(pageLines.count)")

            // Page 1 has hasContinuation=true.
            let page1Line = pageLines.first(where: { $0["page"] == "1" })
            #expect(page1Line?["hasContinuation"] == "true")
            #expect(page1Line?["itemsThisPage"] == "2")

            // Page 2 has hasContinuation=false.
            let page2Line = pageLines.first(where: { $0["page"] == "2" })
            #expect(page2Line?["hasContinuation"] == "false")
            #expect(page2Line?["itemsThisPage"] == "1")

            // Complete line with totals.
            let completeLines = lines.filter { $0["msg"] == "fabric list complete" }
            #expect(completeLines.count == 1)
            #expect(completeLines.first?["totalPages"] == "2")
            #expect(completeLines.first?["totalItems"] == "3")
        }
    }
}

// MARK: - OneLakeClient debug logging

@Suite("OneLakeClient debug logging")
struct OneLakeClientDebugLoggingTests {

    @Test("single-page listPath emits request, response, page, and complete log lines")
    func singlePageListPathEmitsExpectedLines() async throws {
        let body = """
        {"paths":[{"name":"item-guid-test/Files/a.txt","isDirectory":"false","contentLength":"10"}]}
        """
        try await withTempDir { dir in
            let logger = makeCapturingLogger(directory: dir)
            let session = MockURLSession(stubs: [oneLakeStub(body: body)])
            let client = makeOneLakeClient(session: session, logger: logger)

            let result = try await client.listPath(
                alias: "test",
                workspaceGUID: "ws-guid",
                itemGUID: "item-guid-test",
                directory: "Files",
                recursive: false
            )
            #expect(result.entries.count == 1)

            let lines = try capturedLines(directory: dir)

            // Request line.
            let requestLines = lines.filter { $0["msg"] == "onelake request" }
            #expect(!requestLines.isEmpty, "expected at least one 'onelake request' log line")
            if let req = requestLines.first {
                #expect(req["method"] == "GET")
                // path contains '/' so Privacy.scrubLogValue redacts it — key
                // must be present but value is "redacted".
                #expect(req["path"] != nil)
            }

            // Response line with status code.
            let responseLines = lines.filter { $0["msg"] == "onelake response" }
            #expect(!responseLines.isEmpty, "expected at least one 'onelake response' log line")
            if let resp = responseLines.first {
                #expect(resp["status"] == "200")
            }

            // Page line for the last (only) page.
            // Numeric and boolean-string values are in the safe charset and are
            // written verbatim by Privacy.scrubLogValue.
            let pageLines = lines.filter { $0["msg"] == "onelake list page" }
            #expect(!pageLines.isEmpty, "expected at least one 'onelake list page' log line")
            if let pg = pageLines.first {
                #expect(pg["page"] == "1")
                #expect(pg["hasContinuation"] == "false")
                #expect(pg["itemsThisPage"] == "1")
            }

            // Complete line.
            let completeLines = lines.filter { $0["msg"] == "onelake list complete" }
            #expect(!completeLines.isEmpty, "expected an 'onelake list complete' log line")
            if let comp = completeLines.first {
                #expect(comp["totalPages"] == "1")
                #expect(comp["totalItems"] == "1")
            }
        }
    }

    @Test("two-page listPath emits per-page lines and complete with totals")
    func twoPageListPathEmitsPageLines() async throws {
        let page1Body = """
        {"paths":[{"name":"item-guid/Files/a.txt","isDirectory":"false","contentLength":"10"},{"name":"item-guid/Files/b.txt","isDirectory":"false","contentLength":"20"}]}
        """
        let page2Body = """
        {"paths":[{"name":"item-guid/Files/c.txt","isDirectory":"false","contentLength":"30"}]}
        """
        try await withTempDir { dir in
            let logger = makeCapturingLogger(directory: dir)
            let session = MockURLSession(stubs: [
                oneLakeStub(body: page1Body, continuation: "cont-token-1"),
                oneLakeStub(body: page2Body),
            ])
            let client = makeOneLakeClient(session: session, logger: logger)

            let result = try await client.listPath(
                alias: "test",
                workspaceGUID: "ws-guid",
                itemGUID: "item-guid",
                directory: "Files",
                recursive: false
            )
            #expect(result.entries.count == 3)

            let lines = try capturedLines(directory: dir)

            // Two request / response pairs.
            let requestLines = lines.filter { $0["msg"] == "onelake request" }
            #expect(requestLines.count == 2, "expected 2 'onelake request' lines, got \(requestLines.count)")

            // Two page lines.
            let pageLines = lines.filter { $0["msg"] == "onelake list page" }
            #expect(pageLines.count == 2, "expected 2 'onelake list page' lines, got \(pageLines.count)")

            let page1Line = pageLines.first(where: { $0["page"] == "1" })
            #expect(page1Line?["hasContinuation"] == "true")
            #expect(page1Line?["itemsThisPage"] == "2")

            let page2Line = pageLines.first(where: { $0["page"] == "2" })
            #expect(page2Line?["hasContinuation"] == "false")
            #expect(page2Line?["itemsThisPage"] == "1")

            // Complete line.
            let completeLines = lines.filter { $0["msg"] == "onelake list complete" }
            #expect(completeLines.count == 1)
            #expect(completeLines.first?["totalPages"] == "2")
            #expect(completeLines.first?["totalItems"] == "3")
        }
    }
}
