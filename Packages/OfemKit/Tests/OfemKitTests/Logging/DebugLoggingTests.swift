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
/// `[String: String]` dictionaries. Non-string values are converted via
/// `String(describing:)`. Throws `CaptureError.malformedJSON` when any line
/// is non-empty but fails JSON parsing, so a logger format regression surfaces
/// immediately rather than silently returning a partial result.
private func capturedLines(directory: URL) throws -> [[String: String]] {
    let logURL = directory.appendingPathComponent("ofem.log")
    guard FileManager.default.fileExists(atPath: logURL.path) else { return [] }
    let raw = try String(contentsOf: logURL, encoding: .utf8)
    var result: [[String: String]] = []
    for line in raw.split(separator: "\n", omittingEmptySubsequences: true) {
        let lineStr = String(line)
        guard let data = lineStr.data(using: .utf8) else {
            throw CaptureError.invalidUTF8(lineStr)
        }
        do {
            let parsed = try JSONSerialization.jsonObject(with: data)
            guard let obj = parsed as? [String: Any] else {
                throw CaptureError.malformedJSON(lineStr)
            }
            result.append(obj.mapValues { v -> String in
                if let s = v as? String { return s }
                return String(describing: v)
            })
        } catch let err as CaptureError {
            throw err
        } catch {
            throw CaptureError.malformedJSON(lineStr)
        }
    }
    return result
}

private enum CaptureError: Error, CustomStringConvertible {
    case invalidUTF8(String)
    case malformedJSON(String)

    var description: String {
        switch self {
        case .invalidUTF8(let line):
            return "capturedLines: line is not valid UTF-8: \(line)"
        case .malformedJSON(let line):
            return "capturedLines: line failed JSON parsing — logger format regression? Line: \(line)"
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

            // There must be a "fabric request" line with a static endpoint label
            // (passes the scrubber) instead of a raw URL path (which would be redacted).
            let requestLines = lines.filter { $0["msg"] == "fabric request" }
            #expect(!requestLines.isEmpty, "expected at least one 'fabric request' log line")
            if let req = requestLines.first {
                #expect(req["method"] == "GET")
                #expect(req["endpoint"] == "listWorkspaces")
            }

            // There must be a "fabric response" line with status code.
            let responseLines = lines.filter { $0["msg"] == "fabric response" }
            #expect(!responseLines.isEmpty, "expected at least one 'fabric response' log line")
            if let resp = responseLines.first {
                #expect(resp["endpoint"] == "listWorkspaces")
                #expect(resp["status"] == "200")
            }

            // There must be a "fabric list page" line for the last (only) page.
            // Numeric and boolean-string values are in the safe charset and are
            // written verbatim by Privacy.scrubLogValue.
            let pageLines = lines.filter { $0["msg"] == "fabric list page" }
            #expect(!pageLines.isEmpty, "expected at least one 'fabric list page' log line")
            if let pg = pageLines.first {
                #expect(pg["endpoint"] == "listWorkspaces")
                #expect(pg["page"] == "1")
                #expect(pg["hasContinuation"] == "false")
            }

            // There must be a "fabric list complete" line.
            let completeLines = lines.filter { $0["msg"] == "fabric list complete" }
            #expect(!completeLines.isEmpty, "expected a 'fabric list complete' log line")
            if let comp = completeLines.first {
                #expect(comp["endpoint"] == "listWorkspaces")
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

            // Request line — endpoint label and GUIDs survive the scrubber verbatim;
            // raw URL paths would be redacted (they contain '/').
            let requestLines = lines.filter { $0["msg"] == "onelake request" }
            #expect(!requestLines.isEmpty, "expected at least one 'onelake request' log line")
            if let req = requestLines.first {
                #expect(req["method"] == "GET")
                #expect(req["endpoint"] == "listPath")
                #expect(req["workspaceId"] == "ws-guid")
                #expect(req["itemId"] == "item-guid-test")
            }

            // Response line with status code.
            let responseLines = lines.filter { $0["msg"] == "onelake response" }
            #expect(!responseLines.isEmpty, "expected at least one 'onelake response' log line")
            if let resp = responseLines.first {
                #expect(resp["endpoint"] == "listPath")
                #expect(resp["workspaceId"] == "ws-guid")
                #expect(resp["itemId"] == "item-guid-test")
                #expect(resp["status"] == "200")
            }

            // Page line for the last (only) page.
            // Numeric and boolean-string values are in the safe charset and are
            // written verbatim by Privacy.scrubLogValue.
            let pageLines = lines.filter { $0["msg"] == "onelake list page" }
            #expect(!pageLines.isEmpty, "expected at least one 'onelake list page' log line")
            if let pg = pageLines.first {
                #expect(pg["endpoint"] == "listPath")
                #expect(pg["workspaceId"] == "ws-guid")
                #expect(pg["itemId"] == "item-guid-test")
                #expect(pg["page"] == "1")
                #expect(pg["hasContinuation"] == "false")
                #expect(pg["itemsThisPage"] == "1")
            }

            // Complete line.
            let completeLines = lines.filter { $0["msg"] == "onelake list complete" }
            #expect(!completeLines.isEmpty, "expected an 'onelake list complete' log line")
            if let comp = completeLines.first {
                #expect(comp["endpoint"] == "listPath")
                #expect(comp["workspaceId"] == "ws-guid")
                #expect(comp["itemId"] == "item-guid-test")
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

            // Two request / response pairs — each carries the GUID keys verbatim.
            let requestLines = lines.filter { $0["msg"] == "onelake request" }
            #expect(requestLines.count == 2, "expected 2 'onelake request' lines, got \(requestLines.count)")
            #expect(requestLines.allSatisfy { $0["endpoint"] == "listPath" })
            #expect(requestLines.allSatisfy { $0["workspaceId"] == "ws-guid" })
            #expect(requestLines.allSatisfy { $0["itemId"] == "item-guid" })

            // Two page lines.
            let pageLines = lines.filter { $0["msg"] == "onelake list page" }
            #expect(pageLines.count == 2, "expected 2 'onelake list page' lines, got \(pageLines.count)")

            let page1Line = pageLines.first(where: { $0["page"] == "1" })
            #expect(page1Line?["hasContinuation"] == "true")
            #expect(page1Line?["itemsThisPage"] == "2")
            #expect(page1Line?["workspaceId"] == "ws-guid")
            #expect(page1Line?["itemId"] == "item-guid")

            let page2Line = pageLines.first(where: { $0["page"] == "2" })
            #expect(page2Line?["hasContinuation"] == "false")
            #expect(page2Line?["itemsThisPage"] == "1")

            // Complete line — find it by msg and then assert each field value.
            let completeLines = lines.filter { $0["msg"] == "onelake list complete" }
            let completeLine = completeLines.first(where: { $0["totalPages"] != nil })
            #expect(completeLine != nil, "expected an 'onelake list complete' log line with totalPages")
            #expect(completeLine?["endpoint"] == "listPath")
            #expect(completeLine?["workspaceId"] == "ws-guid")
            #expect(completeLine?["itemId"] == "item-guid")
            #expect(completeLine?["totalPages"] == "2")
            #expect(completeLine?["totalItems"] == "3")
        }
    }
}
