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
    public var total: Int {
        added + updated + removed
    }

    /// Creates a `Diff`.
    init(added: Int = 0, updated: Int = 0, removed: Int = 0) {
        self.added = added
        self.updated = updated
        self.removed = removed
    }
}

// MARK: - EnumerateResult

// periphery:ignore
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
    public static let itemID = "__items__"
}

// MARK: - Page size

// periphery:ignore
/// Maximum items returned per ``EnumerateResult`` page.
let enumeratePageSize = 1000

// MARK: - Enumerator

/// Stateless enumeration helpers used by ``SyncEngine``.
enum Enumerator {
    // MARK: - Paging

    // periphery:ignore
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

    // MARK: - Listing presence

    /// Returns `true` when this directory's children have been listed at least
    /// once (`childrenSyncedAtNs > 0`).
    ///
    /// Distinguishes a genuinely-empty-but-enumerated folder (serve the empty
    /// listing) from a cold cache that has never been listed (block on a refresh
    /// on first open). Presence — not freshness — gates whether the cache is served.
    static func childrenEnumerated(record: MetadataRecord) -> Bool {
        record.childrenSyncedAt != nil
    }

    // MARK: - Diff helpers

    /// Returns `true` when `next` differs from `current` on any field that
    /// affects the listing the FPE presents.
    ///
    /// `itemType` is included: it drives capability computation
    /// (`DomainItem.computeCapabilities`), so an item whose type changes is a
    /// real capability-only drift that must surface as a diff and be flushed
    /// to Finder via the next working-set poll.
    ///
    /// `lastModifiedNs` is intentionally skipped for directory entries.
    /// ADLS Gen2 advances a directory's `lastModified` timestamp whenever any
    /// descendant is written (e.g. a Delta table commit), so this field changes
    /// on every active-table poll even when the directory's own child listing is
    /// completely unchanged. Directories carry an empty etag and zero
    /// contentLength, making `lastModifiedNs` the only differing field in that
    /// scenario — comparing it would produce a phantom `diff.updated > 0` every
    /// cycle, causing the working-set to signal on every poll and pegging CPU.
    /// Real directory-content changes are detected via child add / tombstone
    /// reconciliation, not via the parent directory timestamp.
    static func entryChanged(current: MetadataRecord, next: MetadataRecord) -> Bool {
        current.isDir != next.isDir ||
            current.contentLength != next.contentLength ||
            current.etag != next.etag ||
            (!current.isDir && current.lastModifiedNs != next.lastModifiedNs) ||
            current.name != next.name ||
            current.parentPath != next.parentPath ||
            current.itemType != next.itemType
    }

    // MARK: - Path helpers

    // periphery:ignore
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
        return String(trimmed[trimmed.startIndex ..< idx])
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
