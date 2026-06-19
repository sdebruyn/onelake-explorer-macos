// OfemFPEItem.swift
// NSFileProviderItem backed by OfemKit's DomainItem.
//
// Single NSFileProviderItem implementation backed by OfemKit's DomainItem.

@preconcurrency import FileProvider
import Foundation
import OfemKit
import UniformTypeIdentifiers

/// `NSFileProviderItem` wrapping a `DomainItem` from the Swift engine.
final class OfemFPEItem: NSObject, NSFileProviderItem {
    let itemIdentifier: NSFileProviderItemIdentifier
    let parentItemIdentifier: NSFileProviderItemIdentifier
    let filename: String
    let contentType: UTType
    let capabilities: NSFileProviderItemCapabilities
    let documentSize: NSNumber?
    let contentModificationDate: Date?
    let itemVersion: NSFileProviderItemVersion

    init(from domainItem: DomainItem) {
        self.itemIdentifier = NSFileProviderItemIdentifier(
            domainItem.identifier.identifierString
        )
        self.parentItemIdentifier = NSFileProviderItemIdentifier(
            domainItem.parentIdentifier.identifierString
        )
        self.filename = domainItem.filename

        // UTType resolution
        if domainItem.isDirectory {
            self.contentType = .folder
        } else if !domainItem.contentType.isEmpty,
                  let utt = UTType(mimeType: domainItem.contentType) {
            self.contentType = utt
        } else {
            let ext = (domainItem.filename as NSString).pathExtension
            if !ext.isEmpty, let utt = UTType(filenameExtension: ext) {
                self.contentType = utt
            } else {
                self.contentType = .data
            }
        }

        // Capability mapping
        var bitmask: NSFileProviderItemCapabilities = []
        for cap in domainItem.capabilities {
            switch cap {
            case .read:         bitmask.insert(.allowsReading)
            case .write:        bitmask.insert(.allowsWriting)
            case .delete:       bitmask.insert(.allowsDeleting)
            case .enumerate:    bitmask.insert(.allowsContentEnumerating)
            case .addSubitems:  bitmask.insert(.allowsAddingSubItems)
            }
        }
        self.capabilities = bitmask.isEmpty ? [.allowsReading, .allowsContentEnumerating] : bitmask

        self.documentSize = domainItem.isDirectory ? nil : NSNumber(value: domainItem.size)
        self.contentModificationDate = domainItem.modificationDate

        self.itemVersion = NSFileProviderItemVersion(
            contentVersion: domainItem.contentVersion,
            metadataVersion: domainItem.metadataVersion
        )

        super.init()
    }
}
