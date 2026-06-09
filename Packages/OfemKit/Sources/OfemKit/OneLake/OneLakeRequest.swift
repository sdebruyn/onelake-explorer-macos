import Foundation

// MARK: - URL builders

/// Builds a DFS path URL for an item-relative path.
///
/// Format: `/<workspaceGUID>/<itemGUID>[/<relPath…>][?<query>]`
///
/// Each path segment is individually percent-encoded so reserved characters
/// (spaces, `#`, `?`, `%`, `+`, …) in legitimate OneLake names are preserved
/// as literal bytes.
func oneLakePathURL(
    base: URL,
    workspaceGUID: String,
    itemGUID: String,
    relPath: String,
    query: [URLQueryItem]? = nil
) -> URL {
    var components = URLComponents(url: base, resolvingAgainstBaseURL: false)!

    // Build percent-encoded path segments.
    var segments = [workspaceGUID.percentEncodedPathSegment, itemGUID.percentEncodedPathSegment]
    let trimmed = relPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    if !trimmed.isEmpty {
        let parts = trimmed.components(separatedBy: "/")
        segments += parts.map { $0.percentEncodedPathSegment }
    }
    components.percentEncodedPath = "/" + segments.joined(separator: "/")

    if let q = query, !q.isEmpty {
        components.queryItems = q
    } else {
        components.queryItems = nil
    }

    return components.url!
}

/// Builds a DFS filesystem (workspace-level) URL for list operations.
///
/// Format: `/<workspaceGUID>?resource=filesystem&<query>`
func oneLakeListURL(
    base: URL,
    workspaceGUID: String,
    query: [URLQueryItem]
) -> URL {
    var components = URLComponents(url: base, resolvingAgainstBaseURL: false)!
    components.percentEncodedPath = "/" + workspaceGUID.percentEncodedPathSegment
    components.queryItems = query
    return components.url!
}

// MARK: - Common DFS header injection

/// Adds the OneLake-required `x-ms-version` header to a request.
func oneLakeVersionHeader() -> [String: String] {
    ["x-ms-version": "2021-08-06"]
}

// MARK: - String extension

private extension String {
    /// Percent-encodes a single path segment (all reserved chars except `/`
    /// are encoded, but `/` itself is excluded from the allowed set so it
    /// cannot appear inside a segment).
    var percentEncodedPathSegment: String {
        // `urlPathAllowed` includes '/', which we don't want inside a segment.
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove("/")
        return addingPercentEncoding(withAllowedCharacters: allowed) ?? self
    }
}
