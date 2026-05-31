// FileProviderExtension.swift
// `NSFileProviderReplicatedExtension` subclass for OFEM.
//
// macOS instantiates one of these per registered domain (one domain
// per account-alias). Every protocol method dispatches into the Go
// core through `CoreBridge`, mapping bridge-level errors to typed
// `NSFileProviderError` values the framework retries / surfaces
// appropriately.
//
// Enumeration, fetch, and the full write path (create / modify / delete)
// are wired up. Metadata-only modifications (rename, reparent, xattr)
// return NSError(domain: NSCocoaErrorDomain, code: NSFeatureUnsupportedError)
// — `NSFileProviderError.Code.featureUnsupported` is iOS-only, so we use
// Foundation's generic equivalent — and are not yet implemented.

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

    /// Directory for staging fetched file contents before handing the
    /// URL back to the system. We use the framework-managed per-domain
    /// temporary directory: files written here are imported and then
    /// reaped by the system, so the extension never deletes them itself
    /// (deleting races the system's asynchronous import and yields a
    /// POSIX ENOENT materialization failure).
    private func fetchScratchDirectory() throws -> URL {
        guard let manager = NSFileProviderManager(for: domain) else {
            throw NSError(domain: NSCocoaErrorDomain, code: NSFileNoSuchFileError)
        }
        return try manager.temporaryDirectoryURL()
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
        // Indeterminate progress: the work runs on a background queue and
        // NSProgress is not safe to mutate there while the framework reads
        // it, so we never touch completedUnitCount. Completion is signalled
        // by the completion handler, which is the framework's real done
        // signal. (Same pattern in every method below.)
        let progress = Progress(totalUnitCount: -1)
        let scope: EnumScope
        do {
            scope = try ItemIdentifierParser.parse(identifier)
        } catch let error as BridgeError {
            completionHandler(nil, error.nsFileProviderError)
            return progress
        } catch {
            completionHandler(nil, error)
            return progress
        }

        // Working set / trash containers have synthetic identities;
        // macOS sometimes asks for `item(for:)` on them. Returning
        // `.noSuchItem` is safe — the framework treats it as "the
        // container exists but has no entry of its own".
        switch scope {
        case .workingSet, .trashContainer:
            completionHandler(nil, NSFileProviderError(.noSuchItem))
            return progress
        default:
            break
        }

        let bridgeId = ItemIdentifierParser.bridgeIdentifier(for: scope)
        let aliasCopy = self.alias
        let task = Task {
            do {
                let item = try await CoreBridge.shared.item(alias: aliasCopy, identifier: bridgeId)
                completionHandler(OneLakeItem(from: item), nil)
            } catch is CancellationError {
                FileProviderExtension.log.debug(
                    "item(for:) cancelled for \(aliasCopy, privacy: .public)/\(bridgeId, privacy: .public)"
                )
                completionHandler(nil, NSFileProviderError(.cannotSynchronize))
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
        }
        progress.cancellationHandler = { task.cancel() }
        return progress
    }

    // MARK: - Content fetch

    func fetchContents(
        for itemIdentifier: NSFileProviderItemIdentifier,
        version _: NSFileProviderItemVersion?,
        request _: NSFileProviderRequest,
        completionHandler: @escaping (URL?, NSFileProviderItem?, Error?) -> Void
    ) -> Progress {
        let progress = Progress(totalUnitCount: -1)
        let scope: EnumScope
        do {
            scope = try ItemIdentifierParser.parse(itemIdentifier)
        } catch let error as BridgeError {
            completionHandler(nil, nil, error.nsFileProviderError)
            return progress
        } catch {
            completionHandler(nil, nil, error)
            return progress
        }

        // Fetching contents only makes sense for an item below the
        // root — never the root container, never the working set.
        switch scope {
        case .rootContainer, .workingSet, .trashContainer:
            completionHandler(nil, nil, NSFileProviderError(.noSuchItem))
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
            // The system takes ownership of the file we hand back: it
            // imports the bytes asynchronously AFTER the completion
            // handler returns. We must NOT delete the file (or its parent)
            // ourselves — doing so races the import and the system then
            // sees POSIX ENOENT and fails materialization. We therefore
            // write into the per-domain temporary directory the framework
            // manages and reaps for exactly this purpose.
            let tmpDir = try fetchScratchDirectory()
            dest = tmpDir.appendingPathComponent(UUID().uuidString)
        } catch {
            FileProviderExtension.log.error(
                "fetchContents: temp dir resolution failed: \(error.localizedDescription, privacy: .public)"
            )
            completionHandler(nil, nil, error)
            return progress
        }

        let task = Task {
            do {
                let item = try await CoreBridge.shared.fetchContents(
                    alias: aliasCopy,
                    identifier: bridgeId,
                    dest: dest
                )
                completionHandler(dest, OneLakeItem(from: item), nil)
            } catch is CancellationError {
                FileProviderExtension.log.debug(
                    "fetchContents cancelled for \(aliasCopy, privacy: .public)/\(bridgeId, privacy: .public)"
                )
                completionHandler(nil, nil, NSFileProviderError(.cannotSynchronize))
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
        }
        progress.cancellationHandler = { task.cancel() }
        return progress
    }

    // MARK: - Mutations

    func createItem(
        basedOn template: NSFileProviderItem,
        fields _: NSFileProviderItemFields,
        contents: URL?,
        options _: NSFileProviderCreateItemOptions = [],
        request _: NSFileProviderRequest,
        completionHandler: @escaping (
            NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?
        ) -> Void
    ) -> Progress {
        let progress = Progress(totalUnitCount: -1)
        let aliasCopy = self.alias

        let parentScope: EnumScope
        do {
            parentScope = try ItemIdentifierParser.parse(template.parentItemIdentifier)
        } catch let error as BridgeError {
            completionHandler(nil, [], false, error.nsFileProviderError)
            return progress
        } catch {
            completionHandler(nil, [], false, error)
            return progress
        }
        let parentBridgeId = ItemIdentifierParser.bridgeIdentifier(for: parentScope)
        let isDir = template.contentType == .folder
        let srcPath = contents?.path

        FileProviderExtension.log.debug(
            "createItem \(template.filename, privacy: .public) isDir=\(isDir, privacy: .public) parent=\(parentBridgeId, privacy: .public)"
        )

        let task = Task {
            do {
                let bridgeItem = try await CoreBridge.shared.createItem(
                    alias: aliasCopy,
                    parentIdentifier: parentBridgeId,
                    filename: template.filename,
                    isDir: isDir,
                    srcPath: srcPath
                )
                completionHandler(OneLakeItem(from: bridgeItem), [], false, nil)
            } catch is CancellationError {
                FileProviderExtension.log.debug(
                    "createItem cancelled for \(aliasCopy, privacy: .public)/\(parentBridgeId, privacy: .public)/\(template.filename, privacy: .public)"
                )
                completionHandler(nil, [], false, NSFileProviderError(.cannotSynchronize))
            } catch let error as BridgeError {
                FileProviderExtension.log.error(
                    "createItem failed for \(aliasCopy, privacy: .public)/\(parentBridgeId, privacy: .public)/\(template.filename, privacy: .public): \(String(describing: error), privacy: .public)"
                )
                completionHandler(nil, [], false, error.nsFileProviderError)
            } catch {
                FileProviderExtension.log.error(
                    "createItem failed: \(error.localizedDescription, privacy: .public)"
                )
                completionHandler(nil, [], false, error)
            }
        }
        progress.cancellationHandler = { task.cancel() }
        return progress
    }

    func modifyItem(
        _ item: NSFileProviderItem,
        baseVersion _: NSFileProviderItemVersion,
        changedFields: NSFileProviderItemFields,
        contents: URL?,
        options _: NSFileProviderModifyItemOptions = [],
        request _: NSFileProviderRequest,
        completionHandler: @escaping (
            NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?
        ) -> Void
    ) -> Progress {
        let progress = Progress(totalUnitCount: -1)

        // Content-bearing modifications only. Metadata-only changes (rename,
        // reparent, xattr) come back as NSFeatureUnsupportedError so macOS does
        // not retry them in a loop. NSFileProviderError has no featureUnsupported
        // case on macOS, so Foundation's generic equivalent is the conventional
        // fallback.
        guard changedFields.contains(.contents), let contentsURL = contents else {
            FileProviderExtension.log.debug(
                "modifyItem \(item.itemIdentifier.rawValue, privacy: .public) — metadata-only, not yet supported"
            )
            completionHandler(
                nil, [], false,
                NSError(domain: NSCocoaErrorDomain, code: NSFeatureUnsupportedError)
            )
            return progress
        }

        let aliasCopy = self.alias
        let scope: EnumScope
        do {
            scope = try ItemIdentifierParser.parse(item.itemIdentifier)
        } catch let error as BridgeError {
            completionHandler(nil, [], false, error.nsFileProviderError)
            return progress
        } catch {
            completionHandler(nil, [], false, error)
            return progress
        }
        let identifier = ItemIdentifierParser.bridgeIdentifier(for: scope)
        let srcPath = contentsURL.path

        FileProviderExtension.log.debug("modifyItem \(identifier, privacy: .public)")

        let task = Task {
            do {
                let bridgeItem = try await CoreBridge.shared.modifyItem(
                    alias: aliasCopy,
                    identifier: identifier,
                    srcPath: srcPath
                )
                completionHandler(OneLakeItem(from: bridgeItem), [], false, nil)
            } catch is CancellationError {
                FileProviderExtension.log.debug(
                    "modifyItem cancelled for \(aliasCopy, privacy: .public)/\(identifier, privacy: .public)"
                )
                completionHandler(nil, [], false, NSFileProviderError(.cannotSynchronize))
            } catch let error as BridgeError {
                FileProviderExtension.log.error(
                    "modifyItem failed for \(aliasCopy, privacy: .public)/\(identifier, privacy: .public): \(String(describing: error), privacy: .public)"
                )
                completionHandler(nil, [], false, error.nsFileProviderError)
            } catch {
                FileProviderExtension.log.error(
                    "modifyItem failed: \(error.localizedDescription, privacy: .public)"
                )
                completionHandler(nil, [], false, error)
            }
        }
        progress.cancellationHandler = { task.cancel() }
        return progress
    }

    func deleteItem(
        identifier: NSFileProviderItemIdentifier,
        baseVersion _: NSFileProviderItemVersion,
        options _: NSFileProviderDeleteItemOptions = [],
        request _: NSFileProviderRequest,
        completionHandler: @escaping (Error?) -> Void
    ) -> Progress {
        let progress = Progress(totalUnitCount: -1)
        let aliasCopy = self.alias
        let scope: EnumScope
        do {
            scope = try ItemIdentifierParser.parse(identifier)
        } catch let error as BridgeError {
            completionHandler(error.nsFileProviderError)
            return progress
        } catch {
            completionHandler(error)
            return progress
        }
        let rawId = ItemIdentifierParser.bridgeIdentifier(for: scope)

        FileProviderExtension.log.debug("deleteItem \(rawId, privacy: .public)")

        let task = Task {
            do {
                try await CoreBridge.shared.deleteItem(alias: aliasCopy, identifier: rawId)
                completionHandler(nil)
            } catch is CancellationError {
                FileProviderExtension.log.debug(
                    "deleteItem cancelled for \(aliasCopy, privacy: .public)/\(rawId, privacy: .public)"
                )
                completionHandler(NSFileProviderError(.cannotSynchronize))
            } catch let error as BridgeError {
                FileProviderExtension.log.error(
                    "deleteItem failed for \(aliasCopy, privacy: .public)/\(rawId, privacy: .public): \(String(describing: error), privacy: .public)"
                )
                completionHandler(error.nsFileProviderError)
            } catch {
                FileProviderExtension.log.error(
                    "deleteItem failed: \(error.localizedDescription, privacy: .public)"
                )
                completionHandler(error)
            }
        }
        progress.cancellationHandler = { task.cancel() }
        return progress
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
