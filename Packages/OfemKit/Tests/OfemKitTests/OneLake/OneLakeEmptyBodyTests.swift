import Foundation
import Testing
@testable import OfemKit

// MARK: - OneLakeEmptyBodyTests

/// Regression tests for net-01: Alamofire's DataResponseSerializer must accept
/// empty 2xx response bodies.
///
/// Before the fix, ADLS Gen2 calls that return 200/201/202 with an empty body
/// (createDirectory PUT 201, delete DELETE 200) would fail with
/// AFError.responseSerializationFailed(reason: .inputDataNilOrZeroLength).
@Suite("OneLakeClient empty-body 2xx")
struct OneLakeEmptyBodyTests {

    private static let wsGUID = "workspace-guid-regression"
    private static let itemGUID = "item-guid-regression"
    private static let baseURL = URL(string: "https://onelake.dfs.fabric.microsoft.com")!

    // MARK: - Helpers

    /// Builds an OneLakeClient backed by a mock session that will serve the
    /// given stub responses.
    private func makeClient(stubs: [MockURLProtocol.StubResponse]) async -> OneLakeClient {
        let queueID = UUID().uuidString
        MockURLProtocol.registerQueue(id: queueID, stubs: stubs)
        let session = makeMockSession(queueID: queueID)
        let pool = SessionPool(tokenProvider: NoopTokenProvider())
        // Inject the mock session so no real network is attempted.
        await pool._setSessionForTesting(session, alias: "test", scope: .oneLake)
        return OneLakeClient(sessionPool: pool, baseURL: Self.baseURL)
    }

    // MARK: - createDirectory — 201 empty body

    @Test("createDirectory succeeds when server returns 201 with empty body")
    func createDirectoryEmpty201() async throws {
        // ADLS Gen2 returns HTTP 201 Created with no body on directory creation.
        let client = await makeClient(stubs: [
            MockURLProtocol.StubResponse(status: 201, body: Data()),
        ])
        // Must not throw — was failing with
        // AFError.responseSerializationFailed before the fix.
        try await client.createDirectory(
            alias: "test",
            workspaceGUID: Self.wsGUID,
            itemGUID: Self.itemGUID,
            path: "Files/RegressionDir"
        )
    }

    // MARK: - delete — 200 empty body

    @Test("delete succeeds when server returns 200 with empty body")
    func deleteEmpty200() async throws {
        // ADLS Gen2 returns HTTP 200 OK with no body on file/directory deletion.
        let client = await makeClient(stubs: [
            MockURLProtocol.StubResponse(status: 200, body: Data()),
        ])
        // Must not throw — was failing with
        // AFError.responseSerializationFailed before the fix.
        try await client.delete(
            alias: "test",
            workspaceGUID: Self.wsGUID,
            itemGUID: Self.itemGUID,
            path: "Files/RegressionFile.txt"
        )
    }

    // MARK: - delete — 202 empty body

    @Test("delete succeeds when server returns 202 with empty body")
    func deleteEmpty202() async throws {
        // ADLS Gen2 may return 202 Accepted on async deletes.
        let client = await makeClient(stubs: [
            MockURLProtocol.StubResponse(status: 202, body: Data()),
        ])
        try await client.delete(
            alias: "test",
            workspaceGUID: Self.wsGUID,
            itemGUID: Self.itemGUID,
            path: "Files/AsyncDir",
            recursive: true
        )
    }
}
