import Foundation

// MARK: - Fabric base URL

/// Default Fabric REST API endpoint.
public let fabricDefaultBaseURL = URL(string: "https://api.fabric.microsoft.com")!

// MARK: - Fabric URL builder errors

/// Thrown when Fabric URL construction fails (onelake-03 pattern).
enum FabricURLError: Error {
    case invalidURL(String)
}

// MARK: - URL builders

/// Builds a URL for a Fabric REST collection endpoint.
///
/// The path is appended to `base` directly; the optional `continuationToken`
/// is percent-encoded via ``percentEncodedQueryItem(_:)`` so that `+` in the
/// token value is not silently decoded as a space by the server (net-05).
///
/// Path segments (workspace/item IDs) in `path` must already be
/// percent-encoded by the caller when necessary (fabric-03).
///
/// - Parameters:
/// - base: The Fabric REST base URL (e.g. `https://api.fabric.microsoft.com`).
/// - path: Absolute path such as `"/v1/workspaces"`.
/// - continuationToken: When non-nil, added as `?continuationToken=<value>`.
/// - Returns: A fully formed URL.
/// - Throws: ``FabricURLError/invalidURL(_:)`` when URL composition fails.
func fabricListURL(base: URL, path: String, continuationToken: String? = nil) throws -> URL {
    guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
        throw FabricURLError.invalidURL("Cannot decompose base URL: \(base.absoluteString)")
    }
    // fabric-03: use percentEncodedPath so callers that have already applied
    // percentEncodedPathSegment encoding are not double-encoded by URLComponents.
    components.percentEncodedPath = path
    if let tok = continuationToken, !tok.isEmpty {
        // net-05: percent-encode the token so '+' is not decoded as a space.
        let item = URLQueryItem(name: "continuationToken", value: tok)
        components.percentEncodedQueryItems = [percentEncodedQueryItem(item)]
    } else {
        components.queryItems = nil
    }
    guard let url = components.url else {
        throw FabricURLError.invalidURL("Cannot form list URL for path: \(path)")
    }
    return url
}

/// Builds a URL for a Fabric REST item endpoint (single resource).
///
/// - Parameters:
/// - base: The Fabric REST base URL.
/// - path: Absolute path such as `"/v1/workspaces/ws1/items/it1"`.
/// - Returns: A fully formed URL.
/// - Throws: ``FabricURLError/invalidURL(_:)`` when URL composition fails.
func fabricItemURL(base: URL, path: String) throws -> URL {
    guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
        throw FabricURLError.invalidURL("Cannot decompose base URL: \(base.absoluteString)")
    }
    components.percentEncodedPath = path
    components.queryItems = nil
    guard let url = components.url else {
        throw FabricURLError.invalidURL("Cannot form item URL for path: \(path)")
    }
    return url
}

// MARK: - continuationUri resolver

/// Resolves a Fabric `continuationUri` string into an absolute URL that can
/// be used directly as the next-page request.
///
/// Two forms are accepted:
/// - **Absolute** (has a host): the scheme must be `https` and the host must
///   match `base`. Same-host absolute URIs are returned as-is.
/// - **Relative** (no host, no scheme): resolved against `base` using
///   `URL(string:relativeTo:).absoluteURL` so the result is a fully formed
///   URL (net-06: previously relative URIs were returned scheme-/host-less,
///   causing ``HTTPClient`` to reject them with `.badURL`).
///
/// - Parameters:
/// - raw: The raw `continuationUri` string from the API response.
/// - base: The configured Fabric base URL.
/// - Returns: A URL suitable for the next page request.
/// - Throws: ``FabricError/continuationURIHostMismatch(_:)`` when `raw` points
///   to a different host or uses a non-HTTPS scheme.
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
        // Enforce HTTPS — a same-host but non-HTTPS URI would still redirect
        // traffic off the secure channel (e.g. http:// downgrade).
        let scheme = parsed.scheme?.lowercased() ?? ""
        if scheme != "https" {
            throw FabricError.continuationURIHostMismatch(
                "continuationUri scheme \"\(scheme)\" is not https"
            )
        }
        // fabric-07: pin the port — an unexpected port on the same host is not
        // the configured endpoint (e.g. port 8080 vs default 443).
        let uriPort = parsed.port
        let basePort = base.port
        if uriPort != basePort {
            throw FabricError.continuationURIHostMismatch(
                "continuationUri port \(uriPort.map(String.init) ?? "default") does not match base port \(basePort.map(String.init) ?? "default")"
            )
        }
        // fabric-07: reject userinfo (user:password@) — embedded credentials in
        // a continuation URI are a security hazard.
        if let components = URLComponents(url: parsed, resolvingAgainstBaseURL: false),
           let user = components.user, !user.isEmpty
        {
            throw FabricError.continuationURIHostMismatch(
                "continuationUri must not contain userinfo credentials"
            )
        }
        // Absolute URL with matching host — use as-is.
        return parsed
    } else {
        // Relative URI (no host).
        // If a scheme is present without a host, reject it
        // (covers file://, javascript:, etc.).
        if let scheme = parsed.scheme, !scheme.isEmpty {
            throw FabricError.continuationURIHostMismatch(
                "continuationUri has unexpected scheme \"\(scheme)\" without a host"
            )
        }
        // net-06: resolve the path-relative URI against base so the result
        // carries scheme + host and can be used directly by HTTPClient.
        guard let resolved = URL(string: raw, relativeTo: base)?.absoluteURL else {
            throw FabricError.httpError(URLError(.badURL, userInfo: [NSURLErrorFailingURLStringErrorKey: raw]))
        }
        return resolved
    }
}

// MARK: - Common Fabric request builder

/// Builds a base `URLRequest` for a Fabric REST call.
///
/// Sets `Accept: application/json` on every request.
/// The `Authorization` header is injected later by ``HTTPClient`` when
/// a `TokenProvider` is supplied.
///
/// - Parameters:
/// - method: HTTP method (e.g. `"GET"`).
/// - url: Fully formed request URL.
/// - Returns: A `URLRequest` ready for ``HTTPClient/execute(_:tokenProvider:alias:scope:idempotent:)``.
func fabricRequest(method: String, url: URL) -> URLRequest {
    var req = URLRequest(url: url)
    req.httpMethod = method
    req.setValue("application/json", forHTTPHeaderField: "Accept")
    return req
}
