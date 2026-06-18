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
// Additionally, ChangeWatcher runs a repeating loop that periodically signals
// the working set for every registered domain. The FPE's working-set
// enumerateChanges refreshes the workspace list from Fabric (throttled) and
// then reports the cache delta so newly created, removed, or renamed Fabric
// workspaces appear in Finder without user action.
//
// This class is @MainActor because NSFileProviderManager calls are documented
// as main-thread-only.

import FileProvider
import Foundation
import os.log

@MainActor
final class ChangeWatcher {
    static let shared = ChangeWatcher()

    private static let log = Logger(subsystem: ofemSubsystem, category: "change-watcher")

    /// How often the working set is signalled to refresh the workspace list.
    static let workingSetRefreshInterval: Duration = .seconds(90)

    /// Handle for the periodic working-set refresh loop. Stored so a second
    /// `start()` call can cancel the previous loop before launching a new one.
    private var workingSetRefreshTask: Task<Void, Never>?

    private init() {}

    // MARK: - Lifecycle

    /// Emit a one-shot full-resync signal to all registered domains so
    /// Finder re-enumerates after app launch, then start the periodic
    /// working-set refresh loop. Safe to call multiple times; each call
    /// cancels any previous loop and starts a fresh one.
    func start() {
        Task { [weak self] in
            // One-shot launch resync: signal the working set so the FPE
            // re-checks workspace changes that accumulated while the host
            // was stopped.
            await self?.signal(container: .workingSet)
        }
        Self.log.info("ChangeWatcher: one-shot launch resync triggered (FPE-owned change signaling)")

        startWorkingSetRefreshLoop()
    }

    // MARK: - Periodic working-set refresh

    /// Starts (or restarts) the repeating loop that signals the working set
    /// for every registered domain at `workingSetRefreshInterval` intervals.
    ///
    /// Cancels any previously running loop so calling `start()` twice does not
    /// stack two concurrent loops.
    private func startWorkingSetRefreshLoop() {
        workingSetRefreshTask?.cancel()
        workingSetRefreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.workingSetRefreshInterval)
                guard !Task.isCancelled else { break }
                // Each tick signals the working set for every registered domain.
                // The FPE's OfemWorkingSetEnumerator.enumerateChanges refreshes
                // the workspace list from Fabric (throttled to at most once per
                // OfemWorkingSetEnumerator.workspaceRefreshInterval) and then
                // reports the cache delta so Finder reflects added/removed/
                // renamed workspaces.
                await self?.signal(container: .workingSet)
            }
        }
        Self.log.info(
            "ChangeWatcher: periodic working-set refresh started (interval=\(Self.workingSetRefreshInterval, privacy: .public))"
        )
    }

    // MARK: - Signaling

    /// Signals `container` for every currently registered domain.
    private func signal(container: NSFileProviderItemIdentifier) async {
        let containerId = container.rawValue
        do {
            let domains = try await ofemGetAllDomains()
            for domain in domains {
                await signalContainer(domain: domain, containerId: containerId)
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

    private func signalContainer(domain: NSFileProviderDomain, containerId: String) async {
        let domainId = domain.identifier.rawValue
        let itemIdentifier = NSFileProviderItemIdentifier(rawValue: containerId)

        // Use the real domain object (not a re-fabricated one with an empty
        // displayName) so that NSFileProviderManager(for:) receives the
        // same domain that macOS registered.
        guard let manager = NSFileProviderManager(for: domain) else {
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
}
