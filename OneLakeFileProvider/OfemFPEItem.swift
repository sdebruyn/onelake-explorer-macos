// OfemFPEItem.swift
// NSFileProviderItem backed by OfemKit's DomainItem.
//
// Single NSFileProviderItem implementation backed by OfemKit's DomainItem.

@preconcurrency import FileProvider
import Foundation
import OfemKit
import UniformTypeIdentifiers

/// `NSFileProviderItem` wrapping a `DomainItem` from the Swift engine.
///
/// `@unchecked Sendable`: an immutable value carrier. Every stored property is
/// a `let` assigned once in `init` and never mutated afterwards, so instances
/// are safe to share across concurrency domains (they are produced inside an
/// enumeration `Task` and handed to the FileProvider framework). NSObject +
/// the non-Sendable FileProvider value types (`NSFileProviderItemVersion`,
/// `NSFileProviderItemCapabilities`) block automatic Sendable synthesis, so
/// `@unchecked` is the correct, idiomatic choice here.
final class OfemFPEItem: NSObject, NSFileProviderItem, @unchecked Sendable {
    let itemIdentifier: NSFileProviderItemIdentifier
    let parentItemIdentifier: NSFileProviderItemIdentifier
    let filename: String
    let contentType: UTType
    let capabilities: NSFileProviderItemCapabilities
    let documentSize: NSNumber?
    let contentModificationDate: Date?
    let itemVersion: NSFileProviderItemVersion

    init(from domainItem: DomainItem) {
        itemIdentifier = NSFileProviderItemIdentifier(
            domainItem.identifier.identifierString
        )
        parentItemIdentifier = NSFileProviderItemIdentifier(
            domainItem.parentIdentifier.identifierString
        )
        filename = domainItem.filename

        // UTType resolution
        if domainItem.isDirectory {
            contentType = .folder
        } else if !domainItem.contentType.isEmpty,
                  let utt = UTType(mimeType: domainItem.contentType)
        {
            contentType = utt
        } else {
            let ext = (domainItem.filename as NSString).pathExtension
            if !ext.isEmpty, let utt = UTType(filenameExtension: ext) {
                contentType = utt
            } else {
                contentType = .data
            }
        }

        // Capability mapping
        var bitmask: NSFileProviderItemCapabilities = []
        for cap in domainItem.capabilities {
            switch cap {
            case .read: bitmask.insert(.allowsReading)
            case .write: bitmask.insert(.allowsWriting)
            case .delete: bitmask.insert(.allowsDeleting)
            case .enumerate: bitmask.insert(.allowsContentEnumerating)
            case .addSubitems: bitmask.insert(.allowsAddingSubItems)
            }
        }
        capabilities = bitmask.isEmpty ? [.allowsReading, .allowsContentEnumerating] : bitmask

        documentSize = domainItem.isDirectory ? nil : NSNumber(value: domainItem.size)
        contentModificationDate = domainItem.modificationDate

        itemVersion = NSFileProviderItemVersion(
            contentVersion: domainItem.contentVersion,
            metadataVersion: domainItem.metadataVersion
        )

        super.init()
    }
}
