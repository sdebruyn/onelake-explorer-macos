import Foundation

// MARK: - PathEntry

/// One row of a DFS directory listing.
public struct PathEntry: Sendable, Equatable {
    /// Workspace-rooted name, e.g. `"<itemGUID>/Files/data.csv"`.
    public let name: String
    /// `true` when this entry is a directory.
    public let isDirectory: Bool
    /// File size in bytes; `0` for directories.
    public let contentLength: Int64
    /// ETag returned by the server; empty for directories.
    public let eTag: String
    /// Last-modified timestamp; `.distantPast` if the server did not return one.
    public let lastModified: Date

    public init(
        name: String,
        isDirectory: Bool,
        contentLength: Int64,
        eTag: String,
        lastModified: Date
    ) {
        self.name = name
        self.isDirectory = isDirectory
        self.contentLength = contentLength
        self.eTag = eTag
        self.lastModified = lastModified
    }
}

// MARK: - ListResult

/// Fully resolved directory listing (all pagination pages consumed).
public struct ListResult: Sendable {
    public let entries: [PathEntry]
    public init(entries: [PathEntry]) {
        self.entries = entries
    }
}

// MARK: - PathProperties

/// Metadata returned by a HEAD or GET on a single path.
public struct PathProperties: Sendable {
    public let isDirectory: Bool
    public let contentLength: Int64
    public let eTag: String
    public let lastModified: Date
    public let contentType: String

    public init(
        isDirectory: Bool,
        contentLength: Int64,
        eTag: String,
        lastModified: Date,
        contentType: String
    ) {
        self.isDirectory = isDirectory
        self.contentLength = contentLength
        self.eTag = eTag
        self.lastModified = lastModified
        self.contentType = contentType
    }
}

// MARK: - Wire-format types (private)

/// DFS list-response wire format — everything is a string.
struct RawPathEntry: Decodable {
    let name: String
    let isDirectory: String?
    let contentLength: String?
    let etag: String?
    let lastModified: String?
}

struct RawListBody: Decodable {
    let paths: [RawPathEntry]?
}

// MARK: - Conversion helpers

/// Converts a ``RawPathEntry`` (DFS string-typed) to a ``PathEntry``.
func convertRawEntry(_ raw: RawPathEntry) -> PathEntry {
    let isDir = raw.isDirectory == "true"
    let size = raw.contentLength.flatMap { Int64($0) } ?? 0
    let etag = raw.etag ?? ""
    let modified: Date
    if let s = raw.lastModified, let t = parseHTTPDate(s) {
        modified = t
    } else {
        modified = .distantPast
    }
    return PathEntry(name: raw.name, isDirectory: isDir, contentLength: size, eTag: etag, lastModified: modified)
}

/// Extracts ``PathProperties`` from the response headers of a HEAD or GET.
///
/// HTTP headers are case-insensitive (RFC 7230 §3.2). Foundation's
/// `HTTPURLResponse.allHeaderFields` preserves the original casing from the
/// wire, so we perform a case-insensitive lookup.
func propertiesFromHeaders(_ headers: [AnyHashable: Any]) -> PathProperties {
    // Build a normalised lookup dictionary (lowercase keys → value).
    var normalised: [String: String] = [:]
    for (k, v) in headers {
        if let key = k as? String, let val = v as? String {
            normalised[key.lowercased()] = val
        }
    }

    let isDir = normalised["x-ms-resource-type"] == "directory"
    let size = normalised["content-length"].flatMap { Int64($0) } ?? 0
    let etag = normalised["etag"] ?? ""
    let modified: Date
    if let s = normalised["last-modified"], let t = parseHTTPDate(s) {
        modified = t
    } else {
        modified = .distantPast
    }
    let contentType = normalised["content-type"] ?? ""
    return PathProperties(isDirectory: isDir, contentLength: size, eTag: etag, lastModified: modified, contentType: contentType)
}

/// Parses an HTTP-date string (RFC 1123, RFC 850, or asctime).
private func parseHTTPDate(_ s: String) -> Date? {
    for fmt in HTTPRetryDateFormatters.all {
        if let d = fmt.date(from: s) { return d }
    }
    return nil
}
