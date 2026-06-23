import Foundation
@testable import OfemKit
import Testing

// MARK: - Test helpers

private let wsGUID = "workspace-guid-test"
private let itemGUID = "item-guid-test"
private let baseURL = URL(string: "https://onelake.dfs.fabric.microsoft.com")!

/// Returns a client backed by a `SessionPool` with a noop token provider.
///
/// Tests that only exercise argument-validation code paths (i.e. the method
/// throws before any network call) do not require a live session — the pool
/// is constructed but its lazily-created sessions are never invoked.
private func makeClient() -> OneLakeClient {
    let pool = SessionPool(tokenProvider: NoopTokenProvider())
    return OneLakeClient(sessionPool: pool, baseURL: baseURL)
}

// MARK: - OneLakeClientTests

@Suite("OneLakeClient")
struct OneLakeClientTests {
    // MARK: - listPath argument validation

    @Test("listPath: empty workspaceGUID throws missingArgument")
    func listPathEmptyWorkspace() async throws {
        let client = makeClient()
        do {
            _ = try await client.listPath(alias: "a", workspaceGUID: "", itemGUID: itemGUID, directory: "", recursive: false)
            Issue.record("expected throw")
        } catch OneLakeError.missingArgument {
            // expected
        }
    }

    @Test("listPath: empty itemGUID throws missingArgument")
    func listPathEmptyItem() async throws {
        let client = makeClient()
        do {
            _ = try await client.listPath(alias: "a", workspaceGUID: wsGUID, itemGUID: "", directory: "", recursive: false)
            Issue.record("expected throw")
        } catch OneLakeError.missingArgument {
            // expected
        }
    }

    // MARK: - write argument validation

    @Test("write: empty workspaceGUID throws missingArgument")
    func writeEmptyWorkspace() async throws {
        let client = makeClient()
        do {
            try await client.write(alias: "a", workspaceGUID: "", itemGUID: itemGUID, path: "Files/a.txt", content: Data(), size: 0)
            Issue.record("expected throw")
        } catch OneLakeError.missingArgument {
            // expected
        }
    }

    @Test("write: empty path throws missingArgument")
    func writeEmptyPath() async throws {
        let client = makeClient()
        do {
            try await client.write(alias: "a", workspaceGUID: wsGUID, itemGUID: itemGUID, path: "", content: Data(), size: 0)
            Issue.record("expected throw")
        } catch OneLakeError.missingArgument {
            // expected
        }
    }

    @Test("write: size != content.count throws missingArgument")
    func writeSizeMismatch() async throws {
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

    // MARK: - delete argument validation

    @Test("delete: empty workspaceGUID throws missingArgument")
    func deleteEmptyWorkspace() async throws {
        let client = makeClient()
        do {
            try await client.delete(alias: "a", workspaceGUID: "", itemGUID: itemGUID, path: "Files/a.txt")
            Issue.record("expected throw")
        } catch OneLakeError.missingArgument {
            // expected
        }
    }

    @Test("delete: empty path throws missingArgument")
    func deleteEmptyPath() async throws {
        let client = makeClient()
        do {
            try await client.delete(alias: "a", workspaceGUID: wsGUID, itemGUID: itemGUID, path: "")
            Issue.record("expected throw")
        } catch OneLakeError.missingArgument {
            // expected
        }
    }

    // MARK: - createDirectory argument validation

    @Test("createDirectory: empty workspaceGUID throws missingArgument")
    func createDirectoryEmptyWorkspace() async throws {
        let client = makeClient()
        do {
            try await client.createDirectory(alias: "a", workspaceGUID: "", itemGUID: itemGUID, path: "Files/Dir")
            Issue.record("expected throw")
        } catch OneLakeError.missingArgument {
            // expected
        }
    }

    @Test("createDirectory: empty path throws missingArgument")
    func createDirectoryEmptyPath() async throws {
        let client = makeClient()
        do {
            try await client.createDirectory(alias: "a", workspaceGUID: wsGUID, itemGUID: itemGUID, path: "")
            Issue.record("expected throw")
        } catch OneLakeError.missingArgument {
            // expected
        }
    }

    // MARK: - getProperties argument validation

    @Test("getProperties: empty workspaceGUID throws missingArgument")
    func getPropertiesEmptyWorkspace() async throws {
        let client = makeClient()
        do {
            _ = try await client.getProperties(alias: "a", workspaceGUID: "", itemGUID: itemGUID, path: "Files/a.txt")
            Issue.record("expected throw")
        } catch OneLakeError.missingArgument {
            // expected
        }
    }

    // MARK: - rename argument validation

    @Test("rename: empty workspaceGUID throws missingArgument")
    func renameEmptyWorkspace() async throws {
        let client = makeClient()
        await #expect {
            try await client.rename(
                alias: "a", workspaceGUID: "", itemGUID: itemGUID,
                sourcePath: "Files/old", destinationPath: "Files/new"
            )
        } throws: { error in
            if case OneLakeError.missingArgument = error { return true }
            return false
        }
    }

    @Test("rename: empty sourcePath throws missingArgument")
    func renameEmptySource() async throws {
        let client = makeClient()
        await #expect {
            try await client.rename(
                alias: "a", workspaceGUID: wsGUID, itemGUID: itemGUID,
                sourcePath: "", destinationPath: "Files/new"
            )
        } throws: { error in
            if case OneLakeError.missingArgument = error { return true }
            return false
        }
    }

    @Test("rename: empty destinationPath throws missingArgument")
    func renameEmptyDestination() async throws {
        let client = makeClient()
        await #expect {
            try await client.rename(
                alias: "a", workspaceGUID: wsGUID, itemGUID: itemGUID,
                sourcePath: "Files/old", destinationPath: ""
            )
        } throws: { error in
            if case OneLakeError.missingArgument = error { return true }
            return false
        }
    }

    // MARK: - rename URL construction

    @Test("rename: destination URL and x-ms-rename-source header are correct")
    func renameURLAndHeader() throws {
        // Verify that the rename-source path shape matches the DFS filesystem
        // path used by the server: /<workspaceGUID>/<itemGUID>/<sourcePath>.
        //
        // This test drives the URL-construction logic in isolation by building
        // the same path the client would build and asserting its shape, without
        // issuing a real network request.
        let ws = "workspace-abc"
        let item = "item-xyz"
        let source = "Files/untitled folder"
        let base = try #require(URL(string: "https://onelake.dfs.fabric.microsoft.com"))

        // The rename-source header is derived from oneLakePathURL (the same
        // helper that builds the destination URL), so drive the test through it
        // directly and assert the hardcoded literal — re-deriving the encoding
        // inline here could not catch a real encoding regression in the helper.
        let renameSource = try oneLakePathURL(
            base: base,
            workspaceGUID: ws,
            itemGUID: item,
            relPath: source
        ).percentEncodedPath

        #expect(renameSource == "/workspace-abc/item-xyz/Files/untitled%20folder")

        // Verify destination URL shape.
        let destURL = try oneLakePathURL(
            base: base,
            workspaceGUID: ws,
            itemGUID: item,
            relPath: "Files/my folder"
        )
        #expect(destURL.path == "/workspace-abc/item-xyz/Files/my%20folder"
            || destURL.path == "/workspace-abc/item-xyz/Files/my folder")
        #expect(destURL.host == "onelake.dfs.fabric.microsoft.com")
    }
}
