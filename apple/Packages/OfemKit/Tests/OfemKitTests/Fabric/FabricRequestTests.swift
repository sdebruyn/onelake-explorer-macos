import Foundation
import Testing
@testable import OfemKit

// MARK: - FabricRequestTests

@Suite("Fabric URL builders")
struct FabricRequestTests {
    private let base = URL(string: "https://api.fabric.microsoft.com")!

    // MARK: - fabricListURL

    @Test("fabricListURL: produces correct path without token")
    func listURLNoToken() {
        let url = fabricListURL(base: base, path: "/v1/workspaces")
        #expect(url.scheme == "https")
        #expect(url.host == "api.fabric.microsoft.com")
        #expect(url.path == "/v1/workspaces")
        #expect(url.query == nil)
    }

    @Test("fabricListURL: appends continuationToken as query param")
    func listURLWithToken() {
        let url = fabricListURL(base: base, path: "/v1/workspaces", continuationToken: "tok-abc")
        #expect(url.query == "continuationToken=tok-abc")
    }

    @Test("fabricListURL: nil continuationToken produces no query string")
    func listURLNilToken() {
        let url = fabricListURL(base: base, path: "/v1/workspaces", continuationToken: nil)
        #expect(url.query == nil)
    }

    @Test("fabricListURL: empty continuationToken produces no query string")
    func listURLEmptyToken() {
        let url = fabricListURL(base: base, path: "/v1/workspaces", continuationToken: "")
        #expect(url.query == nil)
    }

    @Test("fabricListURL: items endpoint includes workspaceID in path")
    func listURLItemsPath() {
        let url = fabricListURL(base: base, path: "/v1/workspaces/ws-123/items")
        #expect(url.path == "/v1/workspaces/ws-123/items")
    }

    @Test("fabricListURL: folders endpoint includes workspaceID in path")
    func listURLFoldersPath() {
        let url = fabricListURL(base: base, path: "/v1/workspaces/ws-456/folders")
        #expect(url.path == "/v1/workspaces/ws-456/folders")
    }

    // MARK: - fabricItemURL

    @Test("fabricItemURL: produces correct path with no query")
    func itemURLNoQuery() {
        let url = fabricItemURL(base: base, path: "/v1/workspaces/ws1/items/it1")
        #expect(url.path == "/v1/workspaces/ws1/items/it1")
        #expect(url.query == nil)
    }

    // MARK: - resolveContinuationURI

    @Test("resolveContinuationURI: absolute URL on same host resolves correctly")
    func resolveSameHost() throws {
        let raw = "https://api.fabric.microsoft.com/v1/workspaces?cursor=abc"
        let resolved = try resolveContinuationURI(raw, base: base)
        #expect(resolved.path == "/v1/workspaces")
        #expect(resolved.query?.contains("cursor=abc") == true)
    }

    @Test("resolveContinuationURI: relative path resolves correctly")
    func resolveRelativePath() throws {
        let raw = "/v1/workspaces?cursor=abc"
        let resolved = try resolveContinuationURI(raw, base: base)
        #expect(resolved.query?.contains("cursor=abc") == true)
    }

    @Test("resolveContinuationURI: different host throws continuationURIHostMismatch")
    func resolveDifferentHost() throws {
        let raw = "https://evil.example.com/v1/workspaces?cursor=x"
        do {
            _ = try resolveContinuationURI(raw, base: base)
            Issue.record("expected throw")
        } catch FabricError.continuationURIHostMismatch {
            // expected
        }
    }

    @Test("resolveContinuationURI: case-insensitive host comparison")
    func resolveHostCaseInsensitive() throws {
        let raw = "HTTPS://API.FABRIC.MICROSOFT.COM/v1/workspaces?cursor=abc"
        // Should not throw — same host, different case.
        let resolved = try resolveContinuationURI(raw, base: base)
        #expect(resolved.query?.contains("cursor=abc") == true)
    }

    @Test("resolveContinuationURI: http:// on same host is rejected (scheme guard)")
    func resolveHttpSchemeRejected() throws {
        let raw = "http://api.fabric.microsoft.com/v1/workspaces?cursor=x"
        do {
            _ = try resolveContinuationURI(raw, base: base)
            Issue.record("expected throw for http:// scheme")
        } catch FabricError.continuationURIHostMismatch {
            // expected
        }
    }

    @Test("resolveContinuationURI: file:// URI is rejected (no host, scheme present)")
    func resolveFileSchemeRejected() throws {
        let raw = "file:///v1/workspaces"
        do {
            _ = try resolveContinuationURI(raw, base: base)
            Issue.record("expected throw for file:// scheme")
        } catch FabricError.continuationURIHostMismatch {
            // expected
        }
    }

    @Test("resolveContinuationURI: evil-fabric.com.attacker.com does not match base host")
    func resolveSubdomainSpoofRejected() throws {
        let raw = "https://api.fabric.microsoft.com.attacker.com/v1/workspaces"
        do {
            _ = try resolveContinuationURI(raw, base: base)
            Issue.record("expected throw for spoofed host")
        } catch FabricError.continuationURIHostMismatch {
            // expected
        }
    }

    // MARK: - fabricRequest

    @Test("fabricRequest: sets correct HTTP method")
    func requestMethod() {
        let url = fabricListURL(base: URL(string: "https://api.fabric.microsoft.com")!, path: "/v1/workspaces")
        let req = fabricRequest(method: "GET", url: url)
        #expect(req.httpMethod == "GET")
    }

    @Test("fabricRequest: sets Accept: application/json")
    func requestAcceptHeader() {
        let url = fabricListURL(base: URL(string: "https://api.fabric.microsoft.com")!, path: "/v1/workspaces")
        let req = fabricRequest(method: "GET", url: url)
        #expect(req.value(forHTTPHeaderField: "Accept") == "application/json")
    }

    @Test("fabricRequest: correct URL is set")
    func requestURL() {
        let url = fabricItemURL(base: URL(string: "https://api.fabric.microsoft.com")!, path: "/v1/workspaces/ws1/items/it1")
        let req = fabricRequest(method: "GET", url: url)
        #expect(req.url?.path == "/v1/workspaces/ws1/items/it1")
    }
}
