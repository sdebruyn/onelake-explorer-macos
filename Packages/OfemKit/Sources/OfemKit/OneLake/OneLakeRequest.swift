import Foundation

// MARK: - Constants

/// The ADLS Gen2 DFS API version used by all OneLake requests.
///
/// Single source of truth — referenced by ``OneLakeClient/doRequest`` when
/// injecting the `x-ms-version` header.  The dead `oneLakeVersionHeader()`
/// helper (net-17) has been removed; the constant lives here.
let oneLakeDFSAPIVersion = "2021-08-06"

// MARK: - URL builder errors

/// Thrown when URL construction fails (onelake-03: replaces force-unwraps).
enum OneLakeURLError: Error {
    /// The base URL is malformed or cannot be composed with the given segments.
    case invalidURL(String)
}

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
///
/// - Throws: ``OneLakeURLError/invalidURL(_:)`` when the composed URL is nil
///   (onelake-03: no more force-unwraps in URL construction).
func oneLakePathURL(
    base: URL,
    workspaceGUID: String,
    itemGUID: String,
    relPath: String,
    query: [URLQueryItem]? = nil
) throws -> URL {
    guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
        throw OneLakeURLError.invalidURL("Cannot decompose base URL: \(base.absoluteString)")
    }

    // Build percent-encoded path segments.
    var segments = [workspaceGUID.percentEncodedPathSegment, itemGUID.percentEncodedPathSegment]
    let trimmed = relPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    if !trimmed.isEmpty {
        let parts = trimmed.components(separatedBy: "/")
        segments += parts.map(\.percentEncodedPathSegment)
    }
    components.percentEncodedPath = "/" + segments.joined(separator: "/")

    if let q = query, !q.isEmpty {
        // net-05: URLComponents.queryItems does not percent-encode '+'.
        // Use percentEncodedQueryItems with an allowed set that excludes '+'.
        components.percentEncodedQueryItems = q.map { percentEncodedQueryItem($0) }
    } else {
        components.queryItems = nil
    }

    guard let url = components.url else {
        throw OneLakeURLError.invalidURL("Cannot form URL from components for path: \(relPath)")
    }
    return url
}

/// Builds a DFS filesystem (workspace-level) URL for list operations.
///
/// Format: `/<workspaceGUID>?resource=filesystem&<query>`
///
/// Query values are percent-encoded via ``percentEncodedQueryItem(_:)``
/// to handle `+` in continuation tokens (net-05).
///
/// - Throws: ``OneLakeURLError/invalidURL(_:)`` when the composed URL is nil
///   (onelake-03: no more force-unwraps in URL construction).
func oneLakeListURL(
    base: URL,
    workspaceGUID: String,
    query: [URLQueryItem]
) throws -> URL {
    guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
        throw OneLakeURLError.invalidURL("Cannot decompose base URL: \(base.absoluteString)")
    }
    components.percentEncodedPath = "/" + workspaceGUID.percentEncodedPathSegment
    components.percentEncodedQueryItems = query.map { percentEncodedQueryItem($0) }
    guard let url = components.url else {
        throw OneLakeURLError.invalidURL("Cannot form list URL for workspace: \(workspaceGUID)")
    }
    return url
}

// MARK: - Query-item percent-encoding

/// Returns a `URLQueryItem` whose value has `+` (and other RFC 3986
/// sub-delimiters not encoded by the standard `urlQueryAllowed` set) escaped
/// as `%2B`.
///
/// `URLComponents.queryItems` uses `urlQueryAllowed`, which includes `+`; Azure
/// interprets unencoded `+` in query strings as a space, corrupting base64-
/// flavoured continuation tokens (net-05).
///
/// Only the *value* has `=`, `&`, and `+` removed from the allowed set. The
/// *name* only has `+` and `&` removed so that `=` in a future parameter name
/// is not over-encoded to `%3D` (non-blocking #5).
func percentEncodedQueryItem(_ item: URLQueryItem) -> URLQueryItem {
    // Name: only encode `+` and `&` — `=` is safe in a parameter name.
    var nameAllowed = CharacterSet.urlQueryAllowed
    nameAllowed.remove(charactersIn: "+&")
    // Value: also encode `=` so it cannot be misread as a key=value separator.
    var valueAllowed = nameAllowed
    valueAllowed.remove(charactersIn: "=")
    let encodedName = item.name.addingPercentEncoding(withAllowedCharacters: nameAllowed) ?? item.name
    let encodedValue = item.value.map {
        $0.addingPercentEncoding(withAllowedCharacters: valueAllowed) ?? $0
    }
    return URLQueryItem(name: encodedName, value: encodedValue)
}

// NIT-1: `percentEncodedPathSegment` is defined once in StringExtensions.swift
// and shared across the Clients domain. No private copy needed here.
