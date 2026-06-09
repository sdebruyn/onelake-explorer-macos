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
            contentVersion: fallbackVersion(seed: alias, size: 0, mtime: nil),
            metadataVersion: fallbackVersion(seed: alias, size: 0, mtime: nil),
            capabilities: [.read, .enumerate]
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
            contentVersion: fallbackVersion(seed: workspace.id, size: 0, mtime: nil),
            metadataVersion: fallbackVersion(seed: workspace.displayName, size: 0, mtime: nil),
            capabilities: [.read, .enumerate]
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
            contentVersion: fallbackVersion(seed: fabricItem.id, size: 0, mtime: nil),
            metadataVersion: fallbackVersion(seed: fabricItem.displayName, size: 0, mtime: nil),
            capabilities: [.read, .enumerate]
        )
    }

    // MARK: From MetadataRecord

    /// Builds a `DomainItem` from a ``MetadataRecord`` (cache row).
    public static func from(record: MetadataRecord) throws -> DomainItem {
        guard !record.workspaceID.isEmpty, !record.itemID.isEmpty else {
            throw FPError.invalidRecord("workspaceID or itemID is empty")
        }

        let identifier: ItemIdentifier
        let parentIdentifier: ItemIdentifier

        if record.path.isEmpty {
            identifier = .item(workspaceID: record.workspaceID, itemID: record.itemID)
            parentIdentifier = .workspace(workspaceID: record.workspaceID)
        } else {
            identifier = .path(workspaceID: record.workspaceID, itemID: record.itemID, path: record.path)
            parentIdentifier = buildParentIdentifier(
                workspaceID: record.workspaceID,
                itemID: record.itemID,
                path: record.path
            )
        }

        // MIME type: prefer the cached value; fall back to UTType inference.
        var mimeType = record.contentType
        if mimeType.isEmpty && !record.isDir {
            let ext = (record.path as NSString).pathExtension
            if !ext.isEmpty, let utType = UTType(filenameExtension: ext) {
                mimeType = utType.preferredMIMEType ?? ""
            }
        }

        let caps: Set<DomainItem.Capability> = record.isDir
            ? [.read, .write, .delete, .enumerate, .addSubitems]
            : [.read, .write, .delete]

        return DomainItem(
            identifier: identifier,
            parentIdentifier: parentIdentifier,
            filename: record.name,
            isDirectory: record.isDir,
            size: record.contentLength,
            contentType: mimeType,
            modificationDate: record.lastModified,
            contentVersion: contentVersionFor(record: record),
            metadataVersion: metadataVersionFor(record: record),
            capabilities: caps
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
            contentVersion: fallbackVersion(seed: name, size: 0, mtime: nil),
            metadataVersion: fallbackVersion(seed: name, size: 0, mtime: nil),
            capabilities: [.read, .enumerate]
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
        let caps: Set<DomainItem.Capability> = isDirectory
            ? [.read, .write, .delete, .enumerate, .addSubitems]
            : [.read, .write, .delete]

        return DomainItem(
            identifier: identifier,
            parentIdentifier: parentIdentifier,
            filename: name,
            isDirectory: isDirectory,
            contentVersion: fallbackVersion(seed: name, size: 0, mtime: nil),
            metadataVersion: fallbackVersion(seed: name, size: 0, mtime: nil),
            capabilities: caps
        )
    }
}

// MARK: - Version helpers

/// Computes the content version token.
///
/// When an etag is present it is base64-encoded directly; otherwise the token
/// is computed from `(path, contentLength, lastModified)` via FNV-1a-64.
func contentVersionFor(record: MetadataRecord) -> Data {
    if !record.etag.isEmpty {
        return Data(record.etag.utf8).base64EncodedData()
    }
    return fallbackVersion(
        seed: record.path,
        size: record.contentLength,
        mtime: record.lastModified
    )
}

/// Computes the metadata version token from name + etag + size + mtime via
/// FNV-1a-64.
func metadataVersionFor(record: MetadataRecord) -> Data {
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
func fallbackVersion(seed: String, size: Int64, mtime: Date?) -> Data {
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

private func rfc3339(_ date: Date) -> String {
    let fmt = ISO8601DateFormatter()
    fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return fmt.string(from: date)
}

// MARK: - Parent identifier helper

/// Reconstructs the parent ``ItemIdentifier`` for a record with a non-empty
/// path.
private func buildParentIdentifier(workspaceID: String, itemID: String, path: String) -> ItemIdentifier {
    if let slashIdx = path.lastIndex(of: "/") {
        let parentPath = String(path[path.startIndex..<slashIdx])
        return .path(workspaceID: workspaceID, itemID: itemID, path: parentPath)
    }
    return .item(workspaceID: workspaceID, itemID: itemID)
}

// MARK: - FNV-1a 64-bit hasher

/// Minimal FNV-1a 64-bit hasher used for version tokens.
///
/// Matches the `hash/fnv` Go package's `fnv.New64a()` byte-level behaviour.
private struct FNV64a {
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

// MARK: - UInt64 → big-endian bytes helper

private extension UInt64 {
    var bytes: [UInt8] {
        withUnsafeBytes(of: self.bigEndian, Array.init)
    }
}
