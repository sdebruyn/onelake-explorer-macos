// ChangeWatcher.swift
// Triggers Finder re-enumeration when OneLake content changes.
//
// The FPE owns the sync engine and calls NSFileProviderManager.signalEnumerator()
// directly from within the extension process whenever it detects changes.
//
// ChangeWatcher emits a single one-shot "full resync" signal at host-app launch
// so Finder re-enumerates all domains after the host starts (e.g. after a
// login-item boot), covering any changes that accumulated while the host was
// stopped.
//
// This class is @MainActor because NSFileProviderManager calls are documented
// as main-thread-only.

import FileProvider
import Foundation
import os.log

@MainActor
final class ChangeWatcher {
    static let shared = ChangeWatcher()

    private static let log = Logger(subsystem: "dev.debruyn.ofem", category: "change-watcher")

    private init() {}

    // MARK: - Lifecycle

    /// Emit a one-shot full-resync signal to all registered domains so
    /// Finder re-enumerates after app launch. Safe to call multiple times;
    /// each call triggers a new resync.
    func start() {
        Task { [weak self] in
            await self?.signalAllDomains()
        }
        Self.log.info("ChangeWatcher: one-shot launch resync triggered (FPE-owned change signaling)")
    }

    /// No-op in the FPE-only architecture. Kept for call-site compatibility.
    func stop() {
        Self.log.debug("ChangeWatcher: stop() called (no-op in FPE-only mode)")
    }

    // MARK: - Signaling

    private func signalAllDomains() async {
        do {
            let domains = try await allDomains()
            for domain in domains {
                await signalContainer(
                    domainId: domain.identifier.rawValue,
                    containerId: NSFileProviderItemIdentifier.workingSet.rawValue
                )
            }
            Self.log.info(
                "ChangeWatcher: resync signal sent to \(domains.count, privacy: .public) domain(s)"
            )
        } catch {
            Self.log.error(
                "ChangeWatcher: could not list domains for resync: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    private func signalContainer(domainId: String, containerId: String) async {
        let domainIdentifier = NSFileProviderDomainIdentifier(rawValue: domainId)
        let itemIdentifier = NSFileProviderItemIdentifier(rawValue: containerId)

        guard let manager = NSFileProviderManager(for: NSFileProviderDomain(
            identifier: domainIdentifier,
            displayName: ""
        )) else {
            Self.log.debug(
                "ChangeWatcher: no manager for domain \(domainId, privacy: .public); domain may not be registered yet"
            )
            return
        }

        do {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                manager.signalEnumerator(for: itemIdentifier) { error in
                    if let error = error {
                        cont.resume(throwing: error)
                    } else {
                        cont.resume()
                    }
                }
            }
            Self.log.debug(
                "ChangeWatcher: signalled \(domainId, privacy: .public)/\(containerId, privacy: .public)"
            )
        } catch {
            // Non-fatal: Finder's own periodic refresh will catch up.
            Self.log.warning(
                "ChangeWatcher: signalEnumerator failed for \(domainId, privacy: .public)/\(containerId, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    private func allDomains() async throws -> [NSFileProviderDomain] {
        try await withCheckedThrowingContinuation { continuation in
            NSFileProviderManager.getDomainsWithCompletionHandler { domains, error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: domains)
                }
            }
        }
    }
}
