// FileProviderExtension.swift
// Skeleton NSFileProviderReplicatedExtension subclass for OFEM.
//
// This file is the entry point macOS instantiates whenever Finder
// needs metadata or contents for a registered OneLake domain. The
// real implementation will delegate every protocol method to the Go
// core library (`libofemcore.a`) over a cgo C-ABI bridge. The
// planned bridge surface is roughly:
//
//   ofem_enumerate(domain_id, container_id, page_cursor) -> page_json
//   ofem_fetch(domain_id, item_id, version, dest_path) -> item_json
//   ofem_create(domain_id, parent_id, item_json, src_path) -> item_json
//   ofem_modify(domain_id, item_id, fields_mask, src_path) -> item_json
//   ofem_delete(domain_id, item_id, version) -> void
//
// All of those calls block on the Go side and return JSON we decode
// back into `NSFileProviderItem` instances. None of that wiring
// exists yet — this PR only stands up the Swift target so xcodebuild
// has something to compile. See docs/file-provider.md for the
// architecture.
//
// TODO: bridge to libofemcore.

import FileProvider
import os.log

/// File Provider Extension stub. Each registered OneLake account is
/// represented by an `NSFileProviderDomain`, and macOS instantiates
/// one of these extensions per active domain.
final class FileProviderExtension: NSObject, NSFileProviderReplicatedExtension {
    private static let log = Logger(
        subsystem: "dev.debruyn.ofem.fileprovider",
        category: "extension"
    )

    /// The domain this extension instance was created for. macOS
    /// hands it to us through the designated initializer and we hold
    /// onto it so we can scope every Go-core call to one account.
    let domain: NSFileProviderDomain

    /// Designated initializer the File Provider framework calls.
    required init(domain: NSFileProviderDomain) {
        self.domain = domain
        super.init()
        FileProviderExtension.log.info(
            "Initialised extension for domain \(domain.identifier.rawValue, privacy: .public)"
        )
    }

    /// Called when macOS is done with this extension instance. The
    /// completion handler must be invoked exactly once.
    func invalidate() {
        FileProviderExtension.log.info(
            "Invalidating extension for domain \(self.domain.identifier.rawValue, privacy: .public)"
        )
    }

    // MARK: - Item metadata

    func item(
        for identifier: NSFileProviderItemIdentifier,
        request _: NSFileProviderRequest,
        completionHandler: @escaping (NSFileProviderItem?, Error?) -> Void
    ) -> Progress {
        // Phase 1 stub: report "no such item" for everything so the
        // domain registers cleanly without claiming files it cannot
        // serve.
        FileProviderExtension.log.debug(
            "item(for:) called for \(identifier.rawValue, privacy: .public) — returning noSuchItem"
        )
        completionHandler(nil, NSFileProviderError(.noSuchItem))
        return Progress(totalUnitCount: 1)
    }

    // MARK: - Content fetch

    func fetchContents(
        for itemIdentifier: NSFileProviderItemIdentifier,
        version _: NSFileProviderItemVersion?,
        request _: NSFileProviderRequest,
        completionHandler: @escaping (URL?, NSFileProviderItem?, Error?) -> Void
    ) -> Progress {
        FileProviderExtension.log.debug(
            "fetchContents called for \(itemIdentifier.rawValue, privacy: .public) — returning noSuchItem"
        )
        completionHandler(nil, nil, NSFileProviderError(.noSuchItem))
        return Progress(totalUnitCount: 1)
    }

    // MARK: - Mutations

    func createItem(
        basedOn _: NSFileProviderItem,
        fields _: NSFileProviderItemFields,
        contents _: URL?,
        options _: NSFileProviderCreateItemOptions = [],
        request _: NSFileProviderRequest,
        completionHandler: @escaping (
            NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?
        ) -> Void
    ) -> Progress {
        FileProviderExtension.log.debug("createItem called — not implemented in Phase 1 skeleton")
        completionHandler(nil, [], false, NSFileProviderError(.noSuchItem))
        return Progress(totalUnitCount: 1)
    }

    func modifyItem(
        _ item: NSFileProviderItem,
        baseVersion _: NSFileProviderItemVersion,
        changedFields _: NSFileProviderItemFields,
        contents _: URL?,
        options _: NSFileProviderModifyItemOptions = [],
        request _: NSFileProviderRequest,
        completionHandler: @escaping (
            NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?
        ) -> Void
    ) -> Progress {
        FileProviderExtension.log.debug(
            "modifyItem called for \(item.itemIdentifier.rawValue, privacy: .public) — not implemented"
        )
        completionHandler(nil, [], false, NSFileProviderError(.noSuchItem))
        return Progress(totalUnitCount: 1)
    }

    func deleteItem(
        identifier: NSFileProviderItemIdentifier,
        baseVersion _: NSFileProviderItemVersion,
        options _: NSFileProviderDeleteItemOptions = [],
        request _: NSFileProviderRequest,
        completionHandler: @escaping (Error?) -> Void
    ) -> Progress {
        FileProviderExtension.log.debug(
            "deleteItem called for \(identifier.rawValue, privacy: .public) — not implemented"
        )
        completionHandler(NSFileProviderError(.noSuchItem))
        return Progress(totalUnitCount: 1)
    }

    // MARK: - Enumeration

    func enumerator(
        for containerItemIdentifier: NSFileProviderItemIdentifier,
        request _: NSFileProviderRequest
    ) throws -> NSFileProviderEnumerator {
        FileProviderExtension.log.debug(
            "enumerator(for:) for \(containerItemIdentifier.rawValue, privacy: .public)"
        )
        return RootEnumerator(containerItemIdentifier: containerItemIdentifier)
    }
}
