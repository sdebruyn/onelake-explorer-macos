import Foundation
import Testing
@testable import OfemKit

// MARK: - Helpers

private let streamBaseURL = URL(string: "https://onelake.dfs.fabric.microsoft.com")!
private let wsGUID = "ws-guid-stream"
private let itemGUID = "item-guid-stream"

/// Returns a client backed by a `SessionPool` with a noop token provider.
///
/// Tests that only exercise argument-validation paths do not need a live session.
private func makeClient() -> OneLakeClient {
    let pool = SessionPool(tokenProvider: NoopTokenProvider())
    return OneLakeClient(sessionPool: pool, baseURL: streamBaseURL)
}

// MARK: - OneLakeStreamingTests

@Suite("OneLakeClient — streaming read(destination:)")
struct OneLakeStreamingTests {

    @Test("read(destination:) with empty range returns empty PathProperties without network call")
    func emptyRangeDestinationNoNetwork() async throws {
        let client = makeClient()

        let (tmpURL, handle) = try makeTempFileHandle(prefix: "ofem-stream-test")
        defer {
            try? handle.close()
            try? FileManager.default.removeItem(at: tmpURL)
        }

        let props = try await client.read(
            alias: "a",
            workspaceGUID: wsGUID,
            itemGUID: itemGUID,
            path: "Files/a.txt",
            range: 0..<0,
            destination: handle
        )
        #expect(props.contentLength == 0)
    }

    @Test("read(data overload) with empty range returns empty Data without network call")
    func emptyRangeDataNoNetwork() async throws {
        let client = makeClient()
        let (data, props) = try await client.read(
            alias: "a",
            workspaceGUID: wsGUID,
            itemGUID: itemGUID,
            path: "Files/a.txt",
            range: 5..<5 // empty range
        )
        #expect(data.isEmpty)
        #expect(props.contentLength == 0)
    }
}

// MARK: - OneLakeStatusMappingTests

@Suite("OneLakeError — status coverage")
struct OneLakeStatusMappingTests {

    @Test("serverError(Int) is mapped from HTTPClientError.serverError")
    func serverErrorMapped() {
        let err = HTTPClientError.serverError(503)
        let mapped = OneLakeError.from(err)
        if case OneLakeError.serverError(503) = mapped { /* pass */ } else {
            Issue.record("Expected .serverError(503), got \(mapped)")
        }
    }

    @Test("gone is mapped from HTTPClientError.gone")
    func goneMapped() {
        let err = HTTPClientError.gone
        let mapped = OneLakeError.from(err)
        if case OneLakeError.gone = mapped { /* pass */ } else {
            Issue.record("Expected .gone, got \(mapped)")
        }
    }

    @Test("payloadTooLarge is mapped from HTTPClientError.payloadTooLarge")
    func payloadTooLargeMapped() {
        let err = HTTPClientError.payloadTooLarge
        let mapped = OneLakeError.from(err)
        if case OneLakeError.payloadTooLarge = mapped { /* pass */ } else {
            Issue.record("Expected .payloadTooLarge, got \(mapped)")
        }
    }

    @Test("rangeNotSatisfiable is mapped from HTTPClientError.rangeNotSatisfiable")
    func rangeNotSatisfiableMapped() {
        let err = HTTPClientError.rangeNotSatisfiable
        let mapped = OneLakeError.from(err)
        if case OneLakeError.rangeNotSatisfiable = mapped { /* pass */ } else {
            Issue.record("Expected .rangeNotSatisfiable, got \(mapped)")
        }
    }

    @Test("apiError wrapping serverError is unwrapped correctly")
    func apiErrorUnwrapped() {
        let ae = APIError(statusCode: 503, status: "503 Service Unavailable", body: Data())
        let wrapped = HTTPClientError.apiError(ae)
        let mapped = OneLakeError.from(wrapped)
        if case OneLakeError.serverError(503) = mapped { /* pass */ } else {
            Issue.record("Expected .serverError(503) after apiError unwrap, got \(mapped)")
        }
    }

    @Test("CancellationError maps to .cancelled")
    func cancellationMapped() {
        let mapped = OneLakeError.from(CancellationError())
        if case OneLakeError.cancelled = mapped { /* pass */ } else {
            Issue.record("Expected .cancelled from CancellationError, got \(mapped)")
        }
    }
}

// MARK: - OneLakeSizeValidationTests

@Suite("OneLakeClient — size vs content.count validation")
struct OneLakeSizeValidationTests {

    @Test("write: size != content.count throws missingArgument")
    func sizeMismatchThrows() async throws {
        let client = makeClient()
        let content = Data("hello".utf8) // 5 bytes
        await #expect {
            try await client.write(
                alias: "a",
                workspaceGUID: wsGUID,
                itemGUID: itemGUID,
                path: "Files/a.txt",
                content: content,
                size: 999 // wrong
            )
        } throws: { error in
            if case OneLakeError.missingArgument = error { return true }
            return false
        }
    }
}
