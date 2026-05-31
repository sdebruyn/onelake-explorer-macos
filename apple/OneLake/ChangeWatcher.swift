// ChangeWatcher.swift
// Polls the daemon for OneLake changes and signals Finder to re-enumerate.
//
// Architecture decision:
//
//   The daemon detects changes via adaptive polling and stores them in an
//   in-memory Changefeed. The host app (this class) polls the daemon every
//   5 seconds via the sync.pollChanges JSON-RPC method over the daemon's
//   Unix-domain socket. When changes are reported, the host app calls
//   NSFileProviderManager.signalEnumerator(for:) for each affected
//   container so Finder re-enumerates and picks up new/modified/removed items.
//
// Trade-off:
//
//   Automatic Finder refresh requires the host app to be running. If the user
//   quits OneLake.app, Finder's File Provider Extension continues to work
//   (files can be opened, uploaded, downloaded) but it will not receive
//   proactive refresh signals. Finder performs its own periodic re-enumeration
//   as a fallback; the cadence is controlled by macOS and is typically slower
//   than our 5-second polling interval.
//
// This class is @MainActor because NSFileProviderManager calls are
// documented as main-thread-only.

import FileProvider
import Foundation
import os.log

@MainActor
final class ChangeWatcher {
    static let shared = ChangeWatcher()

    private static let log = Logger(subsystem: "dev.debruyn.ofem", category: "change-watcher")

    /// How often the watcher polls the daemon for new change events.
    private static let pollInterval: TimeInterval = 5

    private var task: Task<Void, Never>?
    private var anchor: Date?

    private init() {}

    // MARK: - Lifecycle

    /// Start the polling loop. Safe to call multiple times; a second call
    /// cancels the previous loop and starts a fresh one.
    func start() {
        task?.cancel()
        task = Task { [weak self] in
            await self?.runLoop()
        }
        Self.log.info("ChangeWatcher started (poll interval \(Self.pollInterval, privacy: .public)s)")
    }

    /// Stop the polling loop. Safe to call when already stopped.
    func stop() {
        task?.cancel()
        task = nil
        Self.log.info("ChangeWatcher stopped")
    }

    // MARK: - Polling loop

    private func runLoop() async {
        guard let socketPath = IPCClient.defaultSocketPath() else {
            Self.log.error("ChangeWatcher: cannot resolve daemon socket path")
            return
        }
        let client = IPCClient(socketPath: socketPath)
        var conn: IPCPersistentConnection?

        defer {
            if let c = conn { client.closePersistentConnection(c) }
        }

        while !Task.isCancelled {
            do {
                if conn == nil {
                    conn = try await client.openPersistentConnection()
                    // On reconnect, use nil anchor so the daemon sends all
                    // events it currently holds and we signal a full-resync
                    // to recover anything missed while disconnected.
                    anchor = nil
                    Self.log.debug("ChangeWatcher: connected to daemon")
                }

                let result = try await client.pollChanges(conn: conn!, since: anchor)
                anchor = result.anchor

                if result.fullResync {
                    Self.log.info("ChangeWatcher: full-resync requested by daemon")
                    await signalAllDomains()
                } else {
                    await signal(events: result.events)
                }
            } catch {
                Self.log.warning(
                    "ChangeWatcher: poll failed, will retry: \(error.localizedDescription, privacy: .public)"
                )
                // Reset connection so next iteration reconnects.
                if let c = conn {
                    client.closePersistentConnection(c)
                    conn = nil
                }
                // If the daemon reported FullResync in a response that we fail
                // to process (e.g. signalEnumerator threw), the flag is lost.
                // On reconnect we reset anchor to nil, which causes the daemon
                // to return all events it currently holds; if the feed itself was
                // truncated the daemon will set FullResync again. A persistent
                // pendingFullResync flag would be more robust but adds complexity
                // that is not yet warranted.
                anchor = nil
            }

            // Wait before next poll, but stop immediately on cancellation.
            try? await Task.sleep(nanoseconds: UInt64(Self.pollInterval * 1_000_000_000))
        }
    }

    // MARK: - Signaling

    private func signal(events: [(domainId: String, containerId: String)]) async {
        guard !events.isEmpty else { return }

        // Deduplicate: one signal per (domain, container) pair is enough.
        var seen = Set<String>()
        for ev in events {
            let key = "\(ev.domainId)||\(ev.containerId)"
            guard seen.insert(key).inserted else { continue }
            await signalContainer(domainId: ev.domainId, containerId: ev.containerId)
        }
    }

    private func signalAllDomains() async {
        do {
            let domains = try await allDomains()
            for domain in domains {
                await signalContainer(
                    domainId: domain.identifier.rawValue,
                    containerId: NSFileProviderItemIdentifier.workingSet.rawValue
                )
            }
        } catch {
            Self.log.error(
                "ChangeWatcher: could not list domains for full-resync: \(error.localizedDescription, privacy: .public)"
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
            // signalEnumerator errors are non-fatal; Finder's own periodic
            // refresh will catch up eventually.
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
