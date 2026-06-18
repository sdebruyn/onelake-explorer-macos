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
// the root container for every registered domain. This ensures the workspace
// list in Finder stays current: newly created or renamed Fabric workspaces
// appear without waiting for macOS's own infrequent re-enumeration schedule.
// The FPE responds to a root-container signal by expiring the sync anchor,
// which forces a fresh enumerateItems(.root) → listWorkspaces call.
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

    /// How often the root container is signalled to refresh the workspace list.
    static let rootRefreshInterval: Duration = .seconds(90)

    /// Handle for the periodic root-refresh loop. Stored so a second `start()`
    /// call can cancel the previous loop before launching a new one.
    private var rootRefreshTask: Task<Void, Never>?

    private init() {}

    // MARK: - Lifecycle

    /// Emit a one-shot full-resync signal to all registered domains so
    /// Finder re-enumerates after app launch, then start the periodic
    /// root-container refresh loop. Safe to call multiple times; each call
    /// cancels any previous loop and starts a fresh one.
    func start() {
        Task { [weak self] in
            // Signal the working set first (existing one-shot resync), then
            // immediately signal the root container so any workspaces created
            // or renamed while the host was stopped are visible without
            // waiting for the first periodic tick.
            await self?.signal(container: .workingSet)
            await self?.signal(container: .rootContainer)
        }
        Self.log.info("ChangeWatcher: one-shot launch resync triggered (FPE-owned change signaling)")

        startRootRefreshLoop()
    }

    // MARK: - Periodic root refresh

    /// Starts (or restarts) the repeating loop that signals the root container
    /// for every registered domain at `rootRefreshInterval` intervals.
    ///
    /// Cancels any previously running loop so calling `start()` twice does not
    /// stack two concurrent loops.
    private func startRootRefreshLoop() {
        rootRefreshTask?.cancel()
        rootRefreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.rootRefreshInterval)
                guard !Task.isCancelled else { break }
                // Each tick signals rootContainer for every registered domain,
                // causing the FPE to expire the sync anchor and call
                // listWorkspaces (one Fabric REST call per domain). At 1–3
                // accounts the cost is negligible; acceptable at current scale.
                await self?.signal(container: .rootContainer)
            }
        }
        Self.log.info(
            "ChangeWatcher: periodic root refresh started (interval=\(Self.rootRefreshInterval, privacy: .public))"
        )
    }

    // MARK: - Signaling

    /// Signals `container` for every currently registered domain.
    ///
    /// - Parameters:
    ///   - container: The container identifier to signal (e.g. `.workingSet`,
    ///     `.rootContainer`). Each container type uses its own log level:
    ///     `.rootContainer` logs at `.debug`/`.warning`; `.workingSet` at
    ///     `.info`/`.error`.
    private func signal(container: NSFileProviderItemIdentifier) async {
        let containerId = container.rawValue
        let isRoot = container == .rootContainer
        do {
            let domains = try await ofemGetAllDomains()
            for domain in domains {
                await signalContainer(domain: domain, containerId: containerId)
            }
            if isRoot {
                Self.log.debug(
                    "ChangeWatcher: root-container refresh signal sent to \(domains.count, privacy: .public) domain(s)"
                )
            } else {
                Self.log.info(
                    "ChangeWatcher: resync signal sent to \(domains.count, privacy: .public) domain(s)"
                )
            }
        } catch {
            if isRoot {
                Self.log.warning(
                    "ChangeWatcher: could not list domains for root refresh: \(error.localizedDescription, privacy: .public)"
                )
            } else {
                Self.log.error(
                    "ChangeWatcher: could not list domains for resync: \(error.localizedDescription, privacy: .public)"
                )
            }
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
