import Foundation

// MARK: - Constants

/// The ADLS Gen2 DFS API version used by all OneLake requests.
///
/// Single source of truth — referenced by ``OneLakeClient/doRequest`` when
/// injecting the `x-ms-version` header.  The dead `oneLakeVersionHeader()`
/// helper (net-17) has been removed; the constant lives here.
let oneLakeDFSAPIVersion = "2021-08-06"

// MARK: - URL builders

/// Builds a DFS path URL for an item-relative path.
///
/// Format: `/<workspaceGUID>/<itemGUID>[/<relPath…>][?<query>]`
///
/// Each path segment is individually percent-encoded so reserved characters
/// (spaces, `#`, `?`, `%`, `+`, …) in legitimate OneLake names are preserved
/// as literal bytes.
///
/// Query values go through ``percentEncodedQueryItem(_:)`` so that `+` (and
/// other RFC 3986 sub-delimiters) in continuation tokens and directory names
/// are properly escaped (net-05).
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
        // net-05: URLComponents.queryItems does not percent-encode '+'.
        // Use percentEncodedQueryItems with an allowed set that excludes '+'.
        components.percentEncodedQueryItems = q.map { percentEncodedQueryItem($0) }
    } else {
        components.queryItems = nil
    }

    return components.url!
}

/// Builds a DFS filesystem (workspace-level) URL for list operations.
///
/// Format: `/<workspaceGUID>?resource=filesystem&<query>`
///
/// Query values are percent-encoded via ``percentEncodedQueryItem(_:)``
/// to handle `+` in continuation tokens (net-05).
func oneLakeListURL(
    base: URL,
    workspaceGUID: String,
    query: [URLQueryItem]
) -> URL {
    var components = URLComponents(url: base, resolvingAgainstBaseURL: false)!
    components.percentEncodedPath = "/" + workspaceGUID.percentEncodedPathSegment
    components.percentEncodedQueryItems = query.map { percentEncodedQueryItem($0) }
    return components.url!
}

// MARK: - Query-item percent-encoding

/// Returns a `URLQueryItem` whose value has `+` (and other RFC 3986
/// sub-delimiters not encoded by the standard `urlQueryAllowed` set) escaped
/// as `%2B`.
///
/// `URLComponents.queryItems` uses `urlQueryAllowed`, which includes `+`; Azure
/// interprets unencoded `+` in query strings as a space, corrupting base64-
/// flavoured continuation tokens (net-05).
func percentEncodedQueryItem(_ item: URLQueryItem) -> URLQueryItem {
    var allowed = CharacterSet.urlQueryAllowed
    // Remove sub-delimiters that have special meaning in query strings.
    allowed.remove(charactersIn: "+&=")
    let encodedName  = item.name.addingPercentEncoding(withAllowedCharacters: allowed) ?? item.name
    let encodedValue = item.value.map {
        $0.addingPercentEncoding(withAllowedCharacters: allowed) ?? $0
    }
    return URLQueryItem(name: encodedName, value: encodedValue)
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
