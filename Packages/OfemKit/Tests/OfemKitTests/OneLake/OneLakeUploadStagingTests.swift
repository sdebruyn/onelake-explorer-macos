import Foundation
@testable import OfemKit
import Testing

// MARK: - OneLakeUploadStagingTests

/// Verifies the temp-path-then-rename upload commit (finding F11).
///
/// The DFS create step is a full overwrite of whatever currently lives at a
/// path; flush is a separate, later request. Uploading straight to the live
/// destination therefore truncates it to 0 bytes the moment create succeeds —
/// if the process or connection dies before flush lands (and the retry
/// budget is exhausted), the previous content is gone for good. OneLakeClient
/// instead stages create+append+flush at a temp sibling path within the same
/// item and only exposes the destination path via a same-item rename once
/// the upload has fully landed, so an interrupted upload leaves the original
/// destination untouched.
@Suite("OneLakeClient — upload staging (F11)")
struct OneLakeUploadStagingTests {
    private static let wsGUID = "ws-guid-staging"
    private static let itemGUID = "item-guid-staging"
    private static let baseURL = URL(string: "https://onelake.dfs.fabric.microsoft.com")!
    private static let destPath = "Files/report.csv"

    // MARK: - Helpers

    /// Builds a client backed by a mock session that serves `stubs` in order,
    /// and returns the queue ID used to inspect recorded requests afterward.
    private func makeClient(stubs: [MockURLProtocol.StubResponse]) async -> (OneLakeClient, String) {
        let queueID = UUID().uuidString
        MockURLProtocol.registerQueue(id: queueID, stubs: stubs)
        let session = makeMockSession(queueID: queueID)
        let pool = SessionPool(tokenProvider: NoopTokenProvider())
        await pool._setSessionForTesting(session, alias: "test", scope: .oneLake)
        return (OneLakeClient(sessionPool: pool, baseURL: Self.baseURL), queueID)
    }

    /// Writes `content` to a fresh temp file and returns its URL.
    private func makeSourceFile(_ content: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ofem-staging-test-\(UUID().uuidString).bin")
        try content.write(to: url)
        return url
    }

    /// Extracts the item-relative path (everything after `/<wsGUID>/<itemGUID>/`)
    /// from a recorded request URL, ignoring any query string. Fixture names
    /// below stay within ASCII path-safe characters, so the decoded
    /// `URLComponents.path` is a faithful stand-in for the raw item path.
    private func itemRelativePath(_ url: String) -> String? {
        guard let comps = URLComponents(string: url) else { return nil }
        let prefix = "/\(Self.wsGUID)/\(Self.itemGUID)/"
        guard comps.path.hasPrefix(prefix) else { return nil }
        return String(comps.path.dropFirst(prefix.count))
    }

    // MARK: - Success path

    @Test("write(sourceURL:): stages at a temp sibling, commits via a single rename, never touches the destination directly")
    func successStagesAndRenames() async throws {
        let content = Data("hello onelake".utf8)
        let sourceURL = try makeSourceFile(content)
        defer { try? FileManager.default.removeItem(at: sourceURL) }

        let (client, queueID) = await makeClient(stubs: [
            .init(status: 201), // create
            .init(status: 202), // append
            .init(status: 200), // flush
            .init(status: 201), // rename
        ])
        defer { MockURLProtocol.clearQueue(id: queueID) }

        try await client.write(
            alias: "test",
            workspaceGUID: Self.wsGUID,
            itemGUID: Self.itemGUID,
            path: Self.destPath,
            sourceURL: sourceURL,
            size: Int64(content.count)
        )

        let requests = MockURLProtocol.recordedRequests(id: queueID)
        #expect(requests.count == 4)

        // create/append/flush must all land on the exact same staging path.
        let stagingPaths = requests.dropLast().compactMap { itemRelativePath($0.url) }
        #expect(stagingPaths.count == 3)
        #expect(Set(stagingPaths).count == 1)
        let stagingPath = try #require(stagingPaths.first)
        #expect(stagingPath != Self.destPath)
        #expect(stagingPath.hasPrefix("Files/.ofem-upload-"))

        // Only the final request — the rename — may reference the destination.
        for req in requests.dropLast() {
            #expect(itemRelativePath(req.url) != Self.destPath)
        }
        let rename = requests[3]
        #expect(rename.method == "PUT")
        #expect(itemRelativePath(rename.url) == Self.destPath)
        #expect(rename.headers["x-ms-rename-source"] == "/\(Self.wsGUID)/\(Self.itemGUID)/\(stagingPath)")
    }

    // MARK: - Failure paths

    @Test("write(sourceURL:): a flush failure never renames, leaves the destination untouched, and best-effort deletes the staging file")
    func flushFailureCleansUpAndLeavesDestinationUntouched() async throws {
        let content = Data("hello onelake".utf8)
        let sourceURL = try makeSourceFile(content)
        defer { try? FileManager.default.removeItem(at: sourceURL) }

        let (client, queueID) = await makeClient(stubs: [
            .init(status: 201), // create
            .init(status: 202), // append
            .init(status: 500), // flush fails
            .init(status: 200), // best-effort cleanup delete
        ])
        defer { MockURLProtocol.clearQueue(id: queueID) }

        await #expect(throws: OneLakeError.self) {
            try await client.write(
                alias: "test",
                workspaceGUID: Self.wsGUID,
                itemGUID: Self.itemGUID,
                path: Self.destPath,
                sourceURL: sourceURL,
                size: Int64(content.count)
            )
        }

        let requests = MockURLProtocol.recordedRequests(id: queueID)
        #expect(requests.count == 4) // create, append, failed flush, cleanup delete

        // The destination path was never referenced — no rename happened.
        for req in requests {
            #expect(itemRelativePath(req.url) != Self.destPath)
        }

        let stagingPath = try #require(itemRelativePath(requests[0].url))
        let cleanup = requests[3]
        #expect(cleanup.method == "DELETE")
        #expect(itemRelativePath(cleanup.url) == stagingPath)
    }

    @Test("write(sourceURL:): a create failure still best-effort cleans up and propagates the original error")
    func createFailurePropagatesAndCleansUp() async throws {
        let content = Data("x".utf8)
        let sourceURL = try makeSourceFile(content)
        defer { try? FileManager.default.removeItem(at: sourceURL) }

        let (client, queueID) = await makeClient(stubs: [
            .init(status: 503), // create fails
            .init(status: 404), // cleanup delete of a staging path that was never created
        ])
        defer { MockURLProtocol.clearQueue(id: queueID) }

        await #expect(throws: OneLakeError.self) {
            try await client.write(
                alias: "test",
                workspaceGUID: Self.wsGUID,
                itemGUID: Self.itemGUID,
                path: Self.destPath,
                sourceURL: sourceURL,
                size: Int64(content.count)
            )
        }

        let requests = MockURLProtocol.recordedRequests(id: queueID)
        #expect(requests.count == 2) // failed create + best-effort cleanup delete
        #expect(requests[1].method == "DELETE")
        #expect(itemRelativePath(requests[0].url) == itemRelativePath(requests[1].url))
    }

    // MARK: - Data-based overload parity

    @Test("write(content:): also stages at a temp sibling and commits via rename")
    func dataOverloadStagesAndRenames() async throws {
        let content = Data("hello onelake".utf8)
        let (client, queueID) = await makeClient(stubs: [
            .init(status: 201), // create
            .init(status: 202), // append
            .init(status: 200), // flush
            .init(status: 201), // rename
        ])
        defer { MockURLProtocol.clearQueue(id: queueID) }

        try await client.write(
            alias: "test",
            workspaceGUID: Self.wsGUID,
            itemGUID: Self.itemGUID,
            path: Self.destPath,
            content: content,
            size: Int64(content.count)
        )

        let requests = MockURLProtocol.recordedRequests(id: queueID)
        #expect(requests.count == 4)
        let stagingPaths = requests.dropLast().compactMap { itemRelativePath($0.url) }
        #expect(Set(stagingPaths).count == 1)
        #expect(stagingPaths.first != Self.destPath)
        #expect(itemRelativePath(requests[3].url) == Self.destPath)
    }
}
