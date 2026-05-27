// FileProviderExtension.swift
// `NSFileProviderReplicatedExtension` subclass for OFEM.
//
// macOS instantiates one of these per registered domain (one domain
// per account-alias). Every protocol method dispatches into the Go
// core through `CoreBridge`, mapping bridge-level errors to typed
// `NSFileProviderError` values the framework retries / surfaces
// appropriately.
//
// Phase 1 is read-only: enumeration + fetch are wired up,
// create / modify / delete return `.featureUnsupported`. Those slots
// will light up when the upload path lands.

import FileProvider
import Foundation
import os.log

/// File Provider Extension entry point. Sandboxed; each registered
/// OneLake account-alias gets its own instance.
final class FileProviderExtension: NSObject, NSFileProviderReplicatedExtension {
    private static let log = Logger(
        subsystem: "dev.debruyn.ofem.fileprovider",
        category: "extension"
    )

    /// The domain this extension instance was created for. Used to
    /// derive the account-alias every bridge call must be scoped to.
    let domain: NSFileProviderDomain

    /// Cached alias so we don't re-strip the prefix on every call.
    private let alias: String

    /// Designated initializer the File Provider framework calls.
    required init(domain: NSFileProviderDomain) {
        self.domain = domain
        self.alias = OneLakeEnumerator.alias(from: domain)
        super.init()
        FileProviderExtension.log.info(
            "Initialised extension for domain \(domain.identifier.rawValue, privacy: .public) (alias=\(self.alias, privacy: .public))"
        )
        // Lazily boot the Go core. Idempotent — multiple extension
        // instances for different domains share one Go runtime in
        // this process.
        let ok = CoreBridge.shared.bootstrap()
        if !ok {
            FileProviderExtension.log.error(
                "CoreBridge.bootstrap() returned false for domain \(domain.identifier.rawValue, privacy: .public)"
            )
        }
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
        let progress = Progress(totalUnitCount: 1)
        let scope: EnumScope
        do {
            scope = try ItemIdentifierParser.parse(identifier)
        } catch let error as BridgeError {
            completionHandler(nil, error.nsFileProviderError)
            progress.completedUnitCount = 1
            return progress
        } catch {
            completionHandler(nil, error)
            progress.completedUnitCount = 1
            return progress
        }

        // Working set / trash containers have synthetic identities;
        // macOS sometimes asks for `item(for:)` on them. Returning
        // `.noSuchItem` is safe — the framework treats it as "the
        // container exists but has no entry of its own".
        switch scope {
        case .workingSet, .trashContainer:
            completionHandler(nil, NSFileProviderError(.noSuchItem))
            progress.completedUnitCount = 1
            return progress
        default:
            break
        }

        let bridgeId = ItemIdentifierParser.bridgeIdentifier(for: scope)
        let aliasCopy = self.alias
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let item = try CoreBridge.shared.item(alias: aliasCopy, identifier: bridgeId)
                completionHandler(OneLakeItem(from: item), nil)
            } catch let error as BridgeError {
                FileProviderExtension.log.error(
                    "item(for:) failed for \(aliasCopy, privacy: .public)/\(bridgeId, privacy: .public): \(String(describing: error), privacy: .public)"
                )
                completionHandler(nil, error.nsFileProviderError)
            } catch {
                FileProviderExtension.log.error(
                    "item(for:) failed for \(aliasCopy, privacy: .public)/\(bridgeId, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
                completionHandler(nil, error)
            }
            progress.completedUnitCount = 1
        }
        return progress
    }

    // MARK: - Content fetch

    func fetchContents(
        for itemIdentifier: NSFileProviderItemIdentifier,
        version _: NSFileProviderItemVersion?,
        request _: NSFileProviderRequest,
        completionHandler: @escaping (URL?, NSFileProviderItem?, Error?) -> Void
    ) -> Progress {
        let progress = Progress(totalUnitCount: 1)
        let scope: EnumScope
        do {
            scope = try ItemIdentifierParser.parse(itemIdentifier)
        } catch let error as BridgeError {
            completionHandler(nil, nil, error.nsFileProviderError)
            progress.completedUnitCount = 1
            return progress
        } catch {
            completionHandler(nil, nil, error)
            progress.completedUnitCount = 1
            return progress
        }

        // Fetching contents only makes sense for an item below the
        // root — never the root container, never the working set.
        switch scope {
        case .rootContainer, .workingSet, .trashContainer:
            completionHandler(nil, nil, NSFileProviderError(.noSuchItem))
            progress.completedUnitCount = 1
            return progress
        default:
            break
        }

        let bridgeId = ItemIdentifierParser.bridgeIdentifier(for: scope)
        let aliasCopy = self.alias
        // Ask macOS where to drop the file by allocating a temp file
        // under the per-extension scratch directory. The framework
        // then atomically moves it into its own replicated store
        // once we hand the URL back.
        let dest: URL
        do {
            let tmpDir = try FileManager.default.url(
                for: .itemReplacementDirectory,
                in: .userDomainMask,
                appropriateFor: FileManager.default.temporaryDirectory,
                create: true
            )
            dest = tmpDir.appendingPathComponent(UUID().uuidString)
        } catch {
            FileProviderExtension.log.error(
                "fetchContents: temp dir creation failed: \(error.localizedDescription, privacy: .public)"
            )
            completionHandler(nil, nil, error)
            progress.completedUnitCount = 1
            return progress
        }

        Task.detached {
            do {
                let item = try await CoreBridge.shared.fetchContents(
                    alias: aliasCopy,
                    identifier: bridgeId,
                    dest: dest
                )
                completionHandler(dest, OneLakeItem(from: item), nil)
            } catch let error as BridgeError {
                FileProviderExtension.log.error(
                    "fetchContents failed for \(aliasCopy, privacy: .public)/\(bridgeId, privacy: .public): \(String(describing: error), privacy: .public)"
                )
                completionHandler(nil, nil, error.nsFileProviderError)
            } catch {
                FileProviderExtension.log.error(
                    "fetchContents failed for \(aliasCopy, privacy: .public)/\(bridgeId, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
                completionHandler(nil, nil, error)
            }
            progress.completedUnitCount = 1
        }
        return progress
    }

    // MARK: - Mutations
    //
    // Phase 1 is read-only. Every mutation entry point returns the
    // Foundation `NSFeatureUnsupportedError`, the convention Apple's
    // own samples use for "not implemented yet" in a File Provider
    // (NSFileProviderError.Code intentionally has no
    // `featureUnsupported` case — see NSFileProviderError.h). The
    // framework treats this as non-retryable and surfaces a
    // user-visible error rather than looping. TODO(phase-2):
    // implement the upload, rename, reparent, and delete paths
    // when the sync engine ships.

    /// Foundation-domain "feature unsupported" error reused by every
    /// mutation stub below. Kept as a property so the call sites
    /// read top-to-bottom; building the `NSError` is otherwise
    /// boilerplate that drowns the intent.
    private var notImplementedError: NSError {
        NSError(domain: NSCocoaErrorDomain, code: NSFeatureUnsupportedError)
    }

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
        // TODO(phase-2): upload path
        FileProviderExtension.log.debug("createItem called — feature unsupported in Phase 1")
        completionHandler(nil, [], false, notImplementedError)
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
        // TODO(phase-2): upload + rename + reparent
        FileProviderExtension.log.debug(
            "modifyItem called for \(item.itemIdentifier.rawValue, privacy: .public) — feature unsupported"
        )
        completionHandler(nil, [], false, notImplementedError)
        return Progress(totalUnitCount: 1)
    }

    func deleteItem(
        identifier: NSFileProviderItemIdentifier,
        baseVersion _: NSFileProviderItemVersion,
        options _: NSFileProviderDeleteItemOptions = [],
        request _: NSFileProviderRequest,
        completionHandler: @escaping (Error?) -> Void
    ) -> Progress {
        // TODO(phase-2): delete + trash
        FileProviderExtension.log.debug(
            "deleteItem called for \(identifier.rawValue, privacy: .public) — feature unsupported"
        )
        completionHandler(notImplementedError)
        return Progress(totalUnitCount: 1)
    }

    // MARK: - Enumeration

    func enumerator(
        for containerItemIdentifier: NSFileProviderItemIdentifier,
        request _: NSFileProviderRequest
    ) throws -> NSFileProviderEnumerator {
        let scope = try ItemIdentifierParser.parse(containerItemIdentifier)
        if case .workingSet = scope {
            FileProviderExtension.log.debug(
                "enumerator(for: .workingSet) for \(self.alias, privacy: .public)"
            )
            return WorkingSetEnumerator(domain: domain)
        }
        FileProviderExtension.log.debug(
            "enumerator(for:) for \(containerItemIdentifier.rawValue, privacy: .public) (scope=\(String(describing: scope), privacy: .public))"
        )
        return OneLakeEnumerator(
            containerItemIdentifier: containerItemIdentifier,
            scope: scope,
            domain: domain
        )
    }
}
