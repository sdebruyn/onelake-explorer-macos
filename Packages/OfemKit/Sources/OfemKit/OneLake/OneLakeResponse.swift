import Foundation

// MARK: - PathEntry

/// One row of a DFS directory listing.
public struct PathEntry: Sendable, Equatable {
    /// Item-relative path, e.g. `"Files/data.csv"` (onelake-12: the raw
    /// wire value `"<itemGUID>/Files/data.csv"` has the `<itemGUID>/` prefix
    /// stripped by ``convertRawEntry(_:itemGUID:)``).
    public let name: String
    /// `true` when this entry is a directory.
    public let isDirectory: Bool
    /// File size in bytes; `0` for directories.
    public let contentLength: Int64
    /// ETag returned by the server; empty for directories.
    public let eTag: String
    /// Last-modified timestamp; `.distantPast` if the server did not return one.
    public let lastModified: Date
    /// Creation timestamp; `nil` if the server did not return one or the value
    /// was zero / unparseable.
    public let creationDate: Date?

    public init(
        name: String,
        isDirectory: Bool,
        contentLength: Int64,
        eTag: String,
        lastModified: Date,
        creationDate: Date? = nil
    ) {
        self.name = name
        self.isDirectory = isDirectory
        self.contentLength = contentLength
        self.eTag = eTag
        self.lastModified = lastModified
        self.creationDate = creationDate
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
    // periphery:ignore
    public let isDirectory: Bool
    public let contentLength: Int64
    public let eTag: String
    public let lastModified: Date
    public let contentType: String
    /// Creation timestamp from the `x-ms-creation-time` response header.
    /// `nil` when the header is absent or unparseable (service version < 2023-05-03,
    /// or a directory entry).
    public let creationDate: Date?
    /// The `total` component of a `Content-Range: bytes <start>-<end>/<total>`
    /// response header (RFC 7233 §4.2), present on a 206 Partial Content
    /// response to a ranged `read()`. `nil` on a full (200) response, or when
    /// the header is absent, unparseable, or reports the `*` (unknown)
    /// placeholder. Unlike ``contentLength`` — which on a 206 response is only
    /// the size of the returned range, not the full file — this is the
    /// server-authoritative total size (C8).
    public let totalLength: Int64?

    public init(
        isDirectory: Bool,
        contentLength: Int64,
        eTag: String,
        lastModified: Date,
        contentType: String,
        creationDate: Date? = nil,
        totalLength: Int64? = nil
    ) {
        self.isDirectory = isDirectory
        self.contentLength = contentLength
        self.eTag = eTag
        self.lastModified = lastModified
        self.contentType = contentType
        self.creationDate = creationDate
        self.totalLength = totalLength
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
///
/// The `itemGUID` parameter is used to strip the workspace-rooted prefix
/// (onelake-12: `"<itemGUID>/Files/data.csv"` → `"Files/data.csv"`).
func convertRawEntry(_ raw: RawPathEntry, itemGUID: String) -> PathEntry {
    let isDir = raw.isDirectory == "true"
    let size = raw.contentLength.flatMap { Int64($0) } ?? 0
    let etag = raw.etag ?? ""
    let modified: Date = if let s = raw.lastModified, let t = parseHTTPDate(s) {
        t
    } else {
        .distantPast
    }
    // onelake-12: strip the "<itemGUID>/" prefix that the DFS API prepends to
    // every name so consumers receive an item-relative path without needing to
    // know or re-strip the prefix themselves.
    let prefix = "\(itemGUID)/"
    let itemRelativeName: String = if raw.name.hasPrefix(prefix) {
        String(raw.name.dropFirst(prefix.count))
    } else {
        // Fallback: return the raw name unchanged (e.g. if the server changes
        // the format or itemGUID is not present as a leading segment).
        raw.name
    }
    // creationDate is not available in DFS list responses; it is captured
    // opportunistically via the x-ms-creation-time header on HEAD/GET.
    return PathEntry(name: itemRelativeName, isDirectory: isDir, contentLength: size, eTag: etag, lastModified: modified)
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

    // Build formatters once and reuse for both date fields to avoid allocating
    // 6 DateFormatter instances (3 per parseHTTPDate call) when both
    // last-modified and x-ms-creation-time are present (net-15).
    let fmts = makeHTTPDateFormatters()
    let modified: Date = if let s = normalised["last-modified"], let t = parseHTTPDate(s, formatters: fmts) {
        t
    } else {
        .distantPast
    }
    let contentType = normalised["content-type"] ?? ""
    // x-ms-creation-time is an RFC1123 HTTP-date returned by HEAD/GET since
    // service version 2023-05-03. Absent or unparseable → nil.
    let creationDate = normalised["x-ms-creation-time"].flatMap { parseHTTPDate($0, formatters: fmts) }
    let totalLength = totalLengthFromContentRange(normalised["content-range"])
    return PathProperties(
        isDirectory: isDir, contentLength: size, eTag: etag, lastModified: modified,
        contentType: contentType, creationDate: creationDate, totalLength: totalLength
    )
}

/// Parses the `total` component out of a `Content-Range: bytes <start>-<end>/<total>`
/// header value (C8). Returns `nil` when the header is absent, malformed, or
/// the total is the `*` (unknown) placeholder — the caller must then fall
/// back to another source for the full size.
private func totalLengthFromContentRange(_ headerValue: String?) -> Int64? {
    guard let value = headerValue, let slashIndex = value.lastIndex(of: "/") else { return nil }
    return Int64(value[value.index(after: slashIndex)...])
}

/// Parses an HTTP-date string (RFC 1123, RFC 850, or asctime).
///
/// Accepts an optional pre-built formatter list; when `nil` a fresh set is
/// created via `makeHTTPDateFormatters()` to avoid concurrent-access hazards
/// (net-15). Callers that parse multiple date fields in the same function
/// should pass a shared list built once to avoid redundant allocations.
private func parseHTTPDate(_ s: String, formatters: [DateFormatter]? = nil) -> Date? {
    for fmt in formatters ?? makeHTTPDateFormatters() {
        if let d = fmt.date(from: s) { return d }
    }
    return nil
}
