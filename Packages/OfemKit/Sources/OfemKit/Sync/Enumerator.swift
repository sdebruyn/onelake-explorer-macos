import Foundation
import os.log

// MARK: - Diff

/// Summarises what ``SyncEngine/refreshFolder(key:)`` changed locally.
public struct Diff: Sendable {
    /// Number of new entries inserted into the cache.
    public var added: Int = 0
    /// Number of existing entries whose metadata changed.
    public var updated: Int = 0
    /// Number of cache entries deleted because they no longer exist remotely.
    public var removed: Int = 0
    /// `added + updated + removed`.
    public var total: Int { added + updated + removed }
}

// MARK: - EnumerateResult

/// The result of a paged enumeration.
public struct EnumerateResult: Sendable {
    /// The items on this page.
    public let items: [DomainItem]
    /// Opaque cursor token; `nil` when this is the last page.
    public let nextCursor: String?
}

// MARK: - VirtualIDs

/// Placeholder IDs used when caching the top-level workspace / item listings.
public enum VirtualIDs {
    public static let workspaceID = "__workspaces__"
    public static let itemID      = "__items__"
}

// MARK: - Page size

/// Maximum items returned per ``EnumerateResult`` page.
let enumeratePageSize = 1_000

// MARK: - Enumerator

/// Stateless enumeration helpers used by ``SyncEngine``.
enum Enumerator {

    private static let log = Logger(subsystem: "dev.debruyn.ofem", category: "Enumerator")

    // MARK: - Paging

    /// Slices `all` into one page starting at the offset encoded in `cursor`.
    static func page(items: [DomainItem], cursor: String?) throws -> EnumerateResult {
        let offset: Int
        if let c = cursor, !c.isEmpty {
            guard let data = Data(base64Encoded: c),
                  let str = String(data: data, encoding: .utf8),
                  let n = Int(str)
            else {
                throw FPError.invalidIdentifier("invalid cursor: \(cursor ?? "")")
            }
            offset = n
        } else {
            offset = 0
        }

        guard offset >= 0, offset <= items.count else {
            throw FPError.invalidIdentifier("cursor offset \(offset) out of range [0, \(items.count)]")
        }

        let slice = Array(items[offset...])
        if slice.count > enumeratePageSize {
            let nextOffset = offset + enumeratePageSize
            let nextCursor = Data("\(nextOffset)".utf8).base64EncodedString()
            return EnumerateResult(items: Array(slice.prefix(enumeratePageSize)), nextCursor: nextCursor)
        }
        return EnumerateResult(items: slice, nextCursor: nil)
    }

    // MARK: - Freshness

    /// Returns `true` when the parent's children were listed within `ttl`.
    ///
    /// - Parameters:
    ///   - record: The metadata record to check.
    ///   - ttl: The maximum age (in seconds) before a cached listing is considered stale.
    ///   - now: The current time. Defaults to `Date()` in production; pass an
    ///     explicit value in tests to exercise boundary behaviour deterministically.
    static func isFresh(record: MetadataRecord, ttl: TimeInterval, now: Date = Date()) -> Bool {
        guard let childrenSyncedAt = record.childrenSyncedAt else { return false }
        return now.timeIntervalSince(childrenSyncedAt) <= ttl
    }

    // MARK: - Diff helpers

    /// Returns `true` when `next` differs from `current` on any field the
    /// remote can change.
    static func entryChanged(current: MetadataRecord, next: MetadataRecord) -> Bool {
        current.isDir != next.isDir ||
        current.contentLength != next.contentLength ||
        current.etag != next.etag ||
        current.lastModifiedNs != next.lastModifiedNs ||
        current.name != next.name ||
        current.parentPath != next.parentPath
    }

    // MARK: - Path helpers

    /// Removes the leading `"<itemGUID>/"` prefix and trims trailing slashes.
    ///
    /// Returns `nil` when `name` does not belong to `itemGUID`.
    static func stripItemPrefix(name: String, itemGUID: String) -> String? {
        var n = name
        if n.hasPrefix("/") { n = String(n.dropFirst()) }
        if n == itemGUID || n == itemGUID + "/" { return "" }
        if n.hasPrefix(itemGUID + "/") {
            let rel = String(n.dropFirst(itemGUID.count + 1))
            return rel.hasSuffix("/") ? String(rel.dropLast()) : rel
        }
        return nil
    }

    /// Returns `true` when `child` is exactly one path segment deeper than
    /// `parent` (empty `parent` = item root).
    static func isDirectChild(parent: String, child: String) -> Bool {
        guard !child.isEmpty else { return false }
        if parent.isEmpty {
            return !child.contains("/")
        }
        guard child.hasPrefix(parent + "/") else { return false }
        let tail = String(child.dropFirst(parent.count + 1))
        return !tail.isEmpty && !tail.contains("/")
    }

    /// Returns the parent directory path of `p`, or `""` at the item root.
    static func parentPath(_ p: String) -> String {
        let trimmed = p.hasSuffix("/") ? String(p.dropLast()) : p
        guard let idx = trimmed.lastIndex(of: "/") else { return "" }
        return String(trimmed[trimmed.startIndex..<idx])
    }

    /// Returns the last path segment of `p`, or `""` for an empty path.
    static func baseName(_ p: String) -> String {
        guard !p.isEmpty else { return "" }
        if let idx = p.lastIndex(of: "/") {
            return String(p[p.index(after: idx)...])
        }
        return p
    }
}
