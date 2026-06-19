import Foundation
import Testing
@testable import OfemKit

// MARK: - Test helpers

private let fabricBase = URL(string: "https://api.fabric.microsoft.com")!

/// Returns a client backed by a `SessionPool` with a noop token provider.
///
/// Tests that only exercise argument-validation or pure error-mapping code paths
/// do not require a live session — the pool is constructed but its lazily-created
/// sessions are never invoked.
private func makeClient() -> FabricClient {
    let pool = SessionPool(tokenProvider: NoopTokenProvider())
    return FabricClient(sessionPool: pool, baseURL: fabricBase)
}

// MARK: - FabricClientTests

@Suite("FabricClient")
struct FabricClientTests {
    // MARK: - Argument validation

    @Test("listItems: empty workspaceID throws missingArgument")
    func listItemsEmptyWorkspace() async throws {
        let client = makeClient()
        do {
            _ = try await client.listItems(alias: "a", workspaceID: "")
            Issue.record("expected throw")
        } catch FabricError.missingArgument {
            // expected
        }
    }

    @Test("listAllItems: empty workspaceID throws missingArgument")
    func listAllItemsEmptyWorkspace() async throws {
        let client = makeClient()
        do {
            _ = try await client.listAllItems(alias: "a", workspaceID: "")
            Issue.record("expected throw")
        } catch FabricError.missingArgument {
            // expected
        }
    }

    @Test("listFolders: empty workspaceID throws missingArgument")
    func listFoldersEmptyWorkspace() async throws {
        let client = makeClient()
        do {
            _ = try await client.listFolders(alias: "a", workspaceID: "")
            Issue.record("expected throw")
        } catch FabricError.missingArgument {
            // expected
        }
    }

    @Test("listAllFolders: empty workspace throws missingArgument")
    func listAllFoldersEmptyWorkspace() async throws {
        let client = makeClient()
        do {
            _ = try await client.listAllFolders(alias: "a", workspaceID: "")
            Issue.record("expected throw")
        } catch FabricError.missingArgument {
            // expected
        }
    }

    @Test("getItem: empty workspaceID throws missingArgument")
    func getItemEmptyWorkspace() async throws {
        let client = makeClient()
        do {
            _ = try await client.getItem(alias: "a", workspaceID: "", itemID: "it1")
            Issue.record("expected throw for empty workspaceID")
        } catch FabricError.missingArgument {
            // expected
        }
    }

    @Test("getItem: empty itemID throws missingArgument")
    func getItemEmptyItem() async throws {
        let client = makeClient()
        do {
            _ = try await client.getItem(alias: "a", workspaceID: "ws1", itemID: "")
            Issue.record("expected throw for empty itemID")
        } catch FabricError.missingArgument {
            // expected
        }
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

    @Test("FabricError.from maps CancellationError to FabricError.cancelled")
    func fabricErrorFromCancellationError() {
        let mapped = FabricError.from(CancellationError())
        if case .cancelled = mapped {
            // Correct.
        } else {
            Issue.record("Expected .cancelled from CancellationError, got \(mapped)")
        }
    }
}
