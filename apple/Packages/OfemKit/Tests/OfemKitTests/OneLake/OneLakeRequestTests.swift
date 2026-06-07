import Foundation
import Testing
@testable import OfemKit

// MARK: - OneLakeRequestTests

@Suite("OneLake URL builders")
struct OneLakeRequestTests {
    private let base = URL(string: "https://onelake.dfs.fabric.microsoft.com")!
    private let ws = "ws-guid-1234"
    private let item = "item-guid-5678"

    // MARK: - oneLakePathURL

    @Test("path URL includes workspace and item GUIDs")
    func pathURLContainsGUIDs() {
        let url = oneLakePathURL(base: base, workspaceGUID: ws, itemGUID: item, relPath: "")
        let path = url.path
        #expect(path.contains(ws))
        #expect(path.contains(item))
    }

    @Test("path URL includes relative path segments")
    func pathURLIncludesRelPath() {
        let url = oneLakePathURL(base: base, workspaceGUID: ws, itemGUID: item, relPath: "Files/data.csv")
        #expect(url.path.hasSuffix("/Files/data.csv"))
    }

    @Test("path URL strips leading slashes from relPath")
    func pathURLStripsLeadingSlash() {
        let url1 = oneLakePathURL(base: base, workspaceGUID: ws, itemGUID: item, relPath: "/Files/a")
        let url2 = oneLakePathURL(base: base, workspaceGUID: ws, itemGUID: item, relPath: "Files/a")
        #expect(url1.path == url2.path)
    }

    @Test("path URL percent-encodes spaces in path segments")
    func pathURLEncodesSpaces() {
        let url = oneLakePathURL(base: base, workspaceGUID: ws, itemGUID: item, relPath: "Files/my file.csv")
        #expect(url.absoluteString.contains("my%20file.csv"))
    }

    @Test("path URL includes query items")
    func pathURLQueryItems() {
        let url = oneLakePathURL(
            base: base,
            workspaceGUID: ws,
            itemGUID: item,
            relPath: "Files/a.csv",
            query: [URLQueryItem(name: "resource", value: "file")]
        )
        #expect(url.query == "resource=file")
    }

    @Test("path URL with no query has no query string")
    func pathURLNoQuery() {
        let url = oneLakePathURL(base: base, workspaceGUID: ws, itemGUID: item, relPath: "Files/a")
        #expect(url.query == nil)
    }

    // MARK: - oneLakeListURL

    @Test("list URL uses workspace as filesystem root")
    func listURLRoot() {
        let url = oneLakeListURL(
            base: base,
            workspaceGUID: ws,
            query: [URLQueryItem(name: "resource", value: "filesystem")]
        )
        // Path should be just /ws-guid
        #expect(url.path == "/\(ws)")
        #expect(url.query?.contains("resource=filesystem") == true)
    }

    @Test("list URL includes continuation token")
    func listURLContinuation() {
        let url = oneLakeListURL(
            base: base,
            workspaceGUID: ws,
            query: [
                URLQueryItem(name: "resource", value: "filesystem"),
                URLQueryItem(name: "continuation", value: "token123"),
            ]
        )
        #expect(url.query?.contains("continuation=token123") == true)
    }

    // MARK: - Round-trip path encoding

    @Test("special characters in path are encoded and host is preserved")
    func specialCharactersEncoded() {
        let url = oneLakePathURL(
            base: base,
            workspaceGUID: ws,
            itemGUID: item,
            relPath: "Files/café & more.csv"
        )
        #expect(url.host == "onelake.dfs.fabric.microsoft.com")
        // Check the percent-encoded form, not the decoded `url.path`
        // (URL.path returns the decoded string on Apple platforms).
        let absoluteStr = url.absoluteString
        #expect(!absoluteStr.contains(" "))
    }
}
