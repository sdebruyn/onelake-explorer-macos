import Foundation

// MARK: - Fabric base URL

/// Default Fabric REST API endpoint.
///
/// Mirrors `internal/fabric/client.go` — `defaultBaseURL`.
@usableFromInline
let fabricDefaultBaseURL = URL(string: "https://api.fabric.microsoft.com")!

// MARK: - URL builders

/// Builds a URL for a Fabric REST collection endpoint.
///
/// The path is appended to `base` directly; query items are added when
/// `continuationToken` is non-nil (replays the original path with the token
/// appended as a query parameter).
///
/// Mirrors `internal/fabric/client.go` — URL construction inside
/// `listAllPages`.
///
/// - Parameters:
///   - base: The Fabric REST base URL (e.g. `https://api.fabric.microsoft.com`).
///   - path: Absolute path such as `"/v1/workspaces"`.
///   - continuationToken: When non-nil, added as `?continuationToken=<value>`.
/// - Returns: A fully formed URL.
func fabricListURL(base: URL, path: String, continuationToken: String? = nil) -> URL {
    var components = URLComponents(url: base, resolvingAgainstBaseURL: false)!
    components.path = path
    if let tok = continuationToken, !tok.isEmpty {
        components.queryItems = [URLQueryItem(name: "continuationToken", value: tok)]
    } else {
        components.queryItems = nil
    }
    return components.url!
}

/// Builds a URL for a Fabric REST item endpoint (single resource).
///
/// Mirrors `internal/fabric/client.go` — path construction for `GetItem`.
///
/// - Parameters:
///   - base: The Fabric REST base URL.
///   - path: Absolute path such as `"/v1/workspaces/ws1/items/it1"`.
/// - Returns: A fully formed URL.
func fabricItemURL(base: URL, path: String) -> URL {
    var components = URLComponents(url: base, resolvingAgainstBaseURL: false)!
    components.path = path
    components.queryItems = nil
    return components.url!
}

// MARK: - continuationUri resolver

/// Resolves a Fabric `continuationUri` (an absolute URL) into a URL that can
/// be used directly as the next page request.
///
/// The URI must either be relative (path-only) or have the same host as `base`.
/// Pointing to a different host is rejected to prevent open-redirect attacks.
///
/// Mirrors `internal/fabric/client.go` — `relativeToBase`.
///
/// - Parameters:
///   - raw: The raw `continuationUri` string from the API response.
///   - base: The configured Fabric base URL.
/// - Returns: A URL suitable for the next page request.
/// - Throws: ``FabricError/continuationURIHostMismatch(_:)`` when `raw` points
///   to a different host.
func resolveContinuationURI(_ raw: String, base: URL) throws -> URL {
    guard let parsed = URL(string: raw) else {
        throw FabricError.httpError(URLError(.badURL, userInfo: [NSURLErrorFailingURLStringErrorKey: raw]))
    }

    // If the URI has a host, verify it matches the base host.
    if let uriHost = parsed.host, !uriHost.isEmpty {
        let baseHost = base.host ?? ""
        if uriHost.lowercased() != baseHost.lowercased() {
            throw FabricError.continuationURIHostMismatch(
                "continuationUri host \"\(uriHost)\" does not match base \"\(baseHost)\""
            )
        }
    }

    return parsed
}

// MARK: - Common Fabric request builder

/// Builds a base `URLRequest` for a Fabric REST call.
///
/// Sets `Accept: application/json` on every request.
/// The `Authorization` header is injected later by ``HTTPClient`` when
/// a `TokenProvider` is supplied.
///
/// - Parameters:
///   - method: HTTP method (e.g. `"GET"`).
///   - url: Fully formed request URL.
/// - Returns: A `URLRequest` ready for ``HTTPClient/execute(_:tokenProvider:alias:scope:idempotent:)``.
func fabricRequest(method: String, url: URL) -> URLRequest {
    var req = URLRequest(url: url)
    req.httpMethod = method
    req.setValue("application/json", forHTTPHeaderField: "Accept")
    return req
}
