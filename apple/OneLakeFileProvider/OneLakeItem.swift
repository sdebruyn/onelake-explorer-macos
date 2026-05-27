// OneLakeItem.swift
// Concrete `NSFileProviderItem` we hand to macOS for every file or
// folder the Go core enumerates. Decoupled from `BridgeItem` so the
// bridge layer stays pure-data and this layer can express
// File-Provider-specific concerns (UTType, capabilities, version
// fingerprint).

import FileProvider
import Foundation
import UniformTypeIdentifiers

/// Default capability set for items when the Go core returns no capability
/// list. Falls back to read + enumerate so Finder can at least browse.
private let defaultReadOnlyCapabilities: NSFileProviderItemCapabilities = [
    .allowsReading,
    .allowsContentEnumerating
]

/// Wraps a `BridgeItem` in the protocol the File Provider framework
/// consumes. Construction is cheap; we copy strings rather than hold
/// references so the enumerator can release the source array once
/// `didEnumerate` returns.
final class OneLakeItem: NSObject, NSFileProviderItem {
    let itemIdentifier: NSFileProviderItemIdentifier
    let parentItemIdentifier: NSFileProviderItemIdentifier
    let filename: String
    let contentType: UTType
    let capabilities: NSFileProviderItemCapabilities
    let documentSize: NSNumber?
    let contentModificationDate: Date?
    let itemVersion: NSFileProviderItemVersion

    init(from b: BridgeItem) {
        // Root-of-alias is conventionally signalled by an empty
        // identifier on the bridge; the framework expects the
        // well-known `.rootContainer` constant for that case.
        if b.identifier.isEmpty {
            self.itemIdentifier = .rootContainer
        } else {
            self.itemIdentifier = NSFileProviderItemIdentifier(b.identifier)
        }
        if let parent = b.parentIdentifier, !parent.isEmpty {
            self.parentItemIdentifier = NSFileProviderItemIdentifier(parent)
        } else {
            self.parentItemIdentifier = .rootContainer
        }
        self.filename = b.filename

        // Resolve UTType. Directories map to `.folder`; everything
        // else either uses the explicit MIME the Go core handed us
        // or falls back to a filename-extension lookup so Finder
        // and Quick Look pick sensible defaults.
        if b.isDir {
            self.contentType = .folder
        } else if let mime = b.contentType,
                  let utt = UTType(mimeType: mime) {
            self.contentType = utt
        } else {
            let ext = (b.filename as NSString).pathExtension
            if !ext.isEmpty, let utt = UTType(filenameExtension: ext) {
                self.contentType = utt
            } else {
                self.contentType = .data
            }
        }

        // Map the textual capability set from the bridge to the
        // framework's bitmask. The Go core controls what is allowed;
        // unknown tokens are silently skipped so a future capability
        // addition on the Go side never crashes older Swift code.
        if let caps = b.capabilities {
            var bitmask: NSFileProviderItemCapabilities = []
            for cap in caps {
                switch cap {
                case "read":
                    bitmask.insert(.allowsReading)
                case "enumerate":
                    bitmask.insert(.allowsContentEnumerating)
                case "write":
                    bitmask.insert(.allowsWriting)
                case "reparent":
                    bitmask.insert(.allowsReparenting)
                case "rename":
                    bitmask.insert(.allowsRenaming)
                case "trash":
                    bitmask.insert(.allowsTrashing)
                case "delete":
                    bitmask.insert(.allowsDeleting)
                // "add_subitems" is the canonical token emitted by the Go
                // core; "addChildren" is kept for back-compat in case any
                // cached bridge response uses the old spelling.
                case "add_subitems", "addChildren":
                    bitmask.insert(.allowsAddingSubItems)
                default:
                    continue
                }
            }
            self.capabilities = bitmask.isEmpty ? defaultReadOnlyCapabilities : bitmask
        } else {
            self.capabilities = defaultReadOnlyCapabilities
        }

        if let size = b.size, !b.isDir {
            self.documentSize = NSNumber(value: size)
        } else {
            self.documentSize = nil
        }
        self.contentModificationDate = b.modificationDate

        // The Go core hands us opaque base64 strings for both
        // version components; we treat them as opaque bytes and
        // pass straight through to the framework, which uses them
        // only for equality.
        let contentData = Data(base64Encoded: b.contentVersion) ?? Data(b.contentVersion.utf8)
        let metadataData = Data(base64Encoded: b.metadataVersion) ?? Data(b.metadataVersion.utf8)
        self.itemVersion = NSFileProviderItemVersion(
            contentVersion: contentData,
            metadataVersion: metadataData
        )

        super.init()
    }
}
