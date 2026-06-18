import Foundation
import CryptoKit
import UniformTypeIdentifiers

// MARK: - DomainItem

/// The File Provider domain model for a single entry returned by enumeration
/// or a metadata lookup.
///
/// The FPE turns each `DomainItem` into a concrete `NSFileProviderItem`; the
/// domain model itself carries no `FileProvider` framework dependency so it
/// can be built and tested without a full Xcode target.
///
/// ## Identifier hierarchy
///
/// ```
/// root (.rootContainer)
/// └── workspace "<wsID>"
/// └── item "<wsID>/<itemID>"
/// └── path "<wsID>/<itemID>/<path>"
/// ```
///
/// ## Capabilities
///
/// Capabilities are expressed as a `Set<Capability>` so the FPE can map them
/// directly to `NSFileProviderItemCapabilities` without string matching.
public struct DomainItem: Sendable, Equatable {

    // MARK: - Capability

    /// The set of operations the FPE may perform on an item.
    public enum Capability: String, Sendable, Hashable {
        case read
        case write
        case delete
        case enumerate
        case addSubitems = "add_subitems"
    }

    // MARK: - Capability presets (fp-05)

    /// Named capability-set constants so the policy lives in one place and
    /// cannot drift between factory helpers.
    internal enum CapabilitySet {
        /// Read-only containers (root, workspaces, Fabric items, stub dirs).
        static let readOnly: Set<Capability>         = [.read, .enumerate]
        /// Writable directories (DFS dirs in the cache, synthetic dirs).
        static let writableDirectory: Set<Capability> = [.read, .write, .delete, .enumerate, .addSubitems]
        /// Writable files (DFS files in the cache, synthetic files).
        static let writableFile: Set<Capability>      = [.read, .write, .delete]
    }

    // MARK: - Fields

    /// Structured identifier for this item.
    public let identifier: ItemIdentifier

    /// Structured identifier for the parent container.
    public let parentIdentifier: ItemIdentifier

    /// Display name shown in Finder (the last path segment, workspace name, etc.).
    public let filename: String

    /// `true` for directories and containers (workspaces, Fabric items).
    public let isDirectory: Bool

    /// Remote size in bytes. Zero for directories.
    public let size: Int64

    /// MIME type (e.g. `"text/csv"`). Empty when unknown.
    public let contentType: String

    /// Remote last-modification date. `nil` when unknown.
    public let modificationDate: Date?

    /// Opaque content version token (base64-encoded etag or FNV hash fallback).
    public let contentVersion: Data

    /// Opaque metadata version token.
    public let metadataVersion: Data

    /// The set of operations the caller may perform on this item.
    public let capabilities: Set<Capability>

    // MARK: - Init

    public init(
        identifier: ItemIdentifier,
        parentIdentifier: ItemIdentifier,
        filename: String,
        isDirectory: Bool,
        size: Int64 = 0,
        contentType: String = "",
        modificationDate: Date? = nil,
        contentVersion: Data,
        metadataVersion: Data,
        capabilities: Set<Capability>
    ) {
        self.identifier = identifier
        self.parentIdentifier = parentIdentifier
        self.filename = filename
        self.isDirectory = isDirectory
        self.size = size
        self.contentType = contentType
        self.modificationDate = modificationDate
        self.contentVersion = contentVersion
        self.metadataVersion = metadataVersion
        self.capabilities = capabilities
    }
}

// MARK: - DomainItem factory helpers

extension DomainItem {

    // MARK: Root

    /// Builds the root-container sentinel item for `alias`.
    public static func root(alias: String) -> DomainItem {
        DomainItem(
            identifier: .root,
            parentIdentifier: .root,
            filename: "OneLake \u{2014} \(alias)", // em-dash, like OneDrive
            isDirectory: true,
            contentVersion: ContentVersion.fallback(seed: alias, size: 0, mtime: nil),
            metadataVersion: ContentVersion.fallback(seed: alias, size: 0, mtime: nil),
            capabilities: CapabilitySet.readOnly
        )
    }

    // MARK: From Workspace

    /// Builds a `DomainItem` from a ``Workspace`` returned by the Fabric API.
    public static func from(workspace: Workspace) -> DomainItem {
        DomainItem(
            identifier: .workspace(workspaceID: workspace.id),
            parentIdentifier: .root,
            filename: workspace.displayName,
            isDirectory: true,
            contentVersion: ContentVersion.fallback(seed: workspace.id, size: 0, mtime: nil),
            metadataVersion: ContentVersion.fallback(seed: workspace.displayName, size: 0, mtime: nil),
            capabilities: CapabilitySet.readOnly
        )
    }

    // MARK: From Fabric Item

    /// Builds a `DomainItem` from a ``Item`` (Fabric item) returned by the Fabric API.
    public static func from(fabricItem: Item, workspaceID: String) -> DomainItem {
        DomainItem(
            identifier: .item(workspaceID: workspaceID, itemID: fabricItem.id),
            parentIdentifier: .workspace(workspaceID: workspaceID),
            filename: fabricItem.displayName,
            isDirectory: true,
            contentVersion: ContentVersion.fallback(seed: fabricItem.id, size: 0, mtime: nil),
            metadataVersion: ContentVersion.fallback(seed: fabricItem.displayName, size: 0, mtime: nil),
            capabilities: CapabilitySet.readOnly
        )
    }

    // MARK: From MetadataRecord

    /// Builds a `DomainItem` from a ``MetadataRecord`` (cache row).
    public static func from(record: MetadataRecord) throws -> DomainItem {
        guard !record.workspaceID.isEmpty, !record.itemID.isEmpty else {
            throw FPError.invalidRecord("workspaceID or itemID is empty")
        }

        // Sentinel rows written by SyncEngine.listWorkspaces use VirtualIDs.workspaceID
        // for both workspaceID and itemID. The generic .item / .path branch below would
        // embed the sentinel into the identifier, so handle them explicitly here.
        if record.workspaceID == VirtualIDs.workspaceID {
            if record.path.isEmpty {
                // The root-container sentinel row (path == ""). The root item itself is
                // never an *enumerated child* — it is the container, produced by
                // DomainItem.root(alias:) on demand. SyncEngine re-upserts this row with
                // a fresh syncedAtNs on every listWorkspaces, so it would otherwise land
                // in every delta batch and feed `.rootContainer` into didUpdate, which is
                // not a supported use of the change API. Throw so enumeration and delta
                // consumers (which already skip un-decodable rows) ignore it.
                throw FPError.invalidRecord("root-container sentinel row is not an enumerable item")
            }
            // Workspace sentinel row: path holds the workspace GUID. Delegate to
            // from(workspace:) so the identifier/parent/version shape can never drift
            // from the dedicated constructor. type is irrelevant to the produced item.
            return DomainItem.from(workspace: Workspace(id: record.path, displayName: record.name, type: ""))
        }

        // Construct the identifier first; derive the parent from it so the
        // path-splitting logic is owned in exactly one place: ItemIdentifier
        // (fp-03).
        let identifier: ItemIdentifier = record.path.isEmpty
            ? .item(workspaceID: record.workspaceID, itemID: record.itemID)
            : .path(workspaceID: record.workspaceID, itemID: record.itemID, path: record.path)

        let parentIdentifier = identifier.parentIdentifier

        // MIME type: prefer the cached value; fall back to UTType inference.
        // Use record.name (not record.path) as the source for extension lookup
        // so that the inferred type always matches the displayed filename (fp-06).
        var mimeType = record.contentType
        if mimeType.isEmpty && !record.isDir {
            let ext = (record.name as NSString).pathExtension
            if !ext.isEmpty, let utType = UTType(filenameExtension: ext) {
                mimeType = utType.preferredMIMEType ?? ""
            }
        }

        return DomainItem(
            identifier: identifier,
            parentIdentifier: parentIdentifier,
            filename: record.name,
            isDirectory: record.isDir,
            size: record.contentLength,
            contentType: mimeType,
            modificationDate: record.lastModified,
            contentVersion: ContentVersion.content(for: record),
            metadataVersion: ContentVersion.metadata(for: record),
            capabilities: record.isDir ? CapabilitySet.writableDirectory : CapabilitySet.writableFile
        )
    }

    // MARK: Stub directory

    /// Builds a placeholder directory item used before the first enumerate
    /// populates the cache.
    public static func stubDirectory(
        identifier: ItemIdentifier,
        parentIdentifier: ItemIdentifier,
        name: String
    ) -> DomainItem {
        DomainItem(
            identifier: identifier,
            parentIdentifier: parentIdentifier,
            filename: name,
            isDirectory: true,
            contentVersion: ContentVersion.fallback(seed: name, size: 0, mtime: nil),
            metadataVersion: ContentVersion.fallback(seed: name, size: 0, mtime: nil),
            capabilities: CapabilitySet.readOnly
        )
    }

    // MARK: Synthetic item

    /// Builds an item for a just-created path before its cache row exists.
    public static func synthetic(
        identifier: ItemIdentifier,
        parentIdentifier: ItemIdentifier,
        name: String,
        isDirectory: Bool
    ) -> DomainItem {
        DomainItem(
            identifier: identifier,
            parentIdentifier: parentIdentifier,
            filename: name,
            isDirectory: isDirectory,
            contentVersion: ContentVersion.fallback(seed: name, size: 0, mtime: nil),
            metadataVersion: ContentVersion.fallback(seed: name, size: 0, mtime: nil),
            capabilities: isDirectory ? CapabilitySet.writableDirectory : CapabilitySet.writableFile
        )
    }
}

// MARK: - Version helpers (fp-04)

/// Content-addressing helpers for File Provider change detection.
///
/// Gathered from file-level globals into a cohesive type so the concern is
/// clearly scoped, the module namespace is not polluted, and the FNV hasher
/// is accessible to tests via a single well-known path (fp-04, fp-09).
enum ContentVersion {

    // MARK: - Public API

    /// Computes the content version token for a cache record.
    ///
    /// When an etag is present it is base64-encoded directly; otherwise the
    /// token is derived from `(path, contentLength, lastModified)` via
    /// FNV-1a-64.
    static func content(for record: MetadataRecord) -> Data {
        if !record.etag.isEmpty {
            return Data(record.etag.utf8).base64EncodedData()
        }
        return fallback(seed: record.path, size: record.contentLength, mtime: record.lastModified)
    }

    /// Computes the metadata version token from name + etag + size + mtime
    /// via FNV-1a-64.
    static func metadata(for record: MetadataRecord) -> Data {
        var h = FNV64a()
        h.combine(record.name)
        h.combine("\0")
        h.combine(record.etag)
        h.combine("\0")
        h.combine(String(record.contentLength))
        h.combine("\0")
        if let mtime = record.lastModified {
            h.combine(rfc3339(mtime))
        }
        return Data(h.digest().bigEndian.bytes).base64EncodedData()
    }

    /// Computes an FNV-1a-64 fallback version token from `(seed, size, mtime)`.
    static func fallback(seed: String, size: Int64, mtime: Date?) -> Data {
        var h = FNV64a()
        h.combine(seed)
        h.combine("\0")
        h.combine(String(size))
        h.combine("\0")
        if let m = mtime {
            h.combine(rfc3339(m))
        }
        return Data(h.digest().bigEndian.bytes).base64EncodedData()
    }

    // MARK: - FNV-1a 64-bit hasher (fp-09: internal so tests can verify the digest)

    /// Minimal FNV-1a 64-bit hasher used for version tokens.
    ///
    /// Byte-level behaviour matches `fnv.New64a()` from the standard Go
    /// `hash/fnv` package.
    struct FNV64a {
        private static let offset: UInt64 = 14_695_981_039_346_656_037
        private static let prime:  UInt64 = 1_099_511_628_211

        private var value: UInt64 = FNV64a.offset

        mutating func combine(_ s: String) {
            for byte in s.utf8 {
                value ^= UInt64(byte)
                value &*= FNV64a.prime
            }
        }

        func digest() -> UInt64 { value }
    }

    // MARK: - Private utilities

    /// `ISO8601DateFormatter` is thread-safe; caching it as a `static let`
    /// avoids allocating one per call — enumerating a 1,000-item page
    /// previously allocated ~2,000 formatters (sync-20).
    // `ISO8601DateFormatter` is not `Sendable` but is safe to use from any
    // thread after construction — its `formatOptions` are set once and never
    // mutated.  `nonisolated(unsafe)` suppresses the Swift 6 diagnostic for
    // this read-only-global pattern (sync-20).
    nonisolated(unsafe) private static let formatter: ISO8601DateFormatter = {
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fmt
    }()

    private static func rfc3339(_ date: Date) -> String {
        formatter.string(from: date)
    }
}

/// Free-function alias of ``ContentVersion/fallback(seed:size:mtime:)``
/// retained for binary/source compatibility with existing callers (fp-04).
///
/// Tests in `DomainItemTests` already call this; keep it `internal` so
/// `@testable` imports can reach it without adding a new public symbol.
func fallbackVersion(seed: String, size: Int64, mtime: Date?) -> Data {
    ContentVersion.fallback(seed: seed, size: size, mtime: mtime)
}

// MARK: - UInt64 → big-endian bytes helper

extension UInt64 {
    var bytes: [UInt8] {
        withUnsafeBytes(of: self.bigEndian, Array.init)
    }
}
