// ContainerSignaller.swift
// Signals a specific sub-container's enumerator via NSFileProviderManager.
//
// ContainerSignaller holds the NSFileProviderDomain for the FPE process and
// exposes a single async method that asks macOS to re-pull the enumerator for
// a given NSFileProviderItemIdentifier.  The call is non-fatal: failures are
// logged and swallowed so a signal failure never bubbles up to the caller.
//
// Actor isolation: ContainerSignaller has no actor isolation and makes no
// assumptions about which executor its methods run on.  Callers may call
// signal(container:) from any context.
//
// Sendable + @preconcurrency rationale:
//   NSFileProviderDomain and NSFileProviderManager are ObjC types that predate
//   Swift concurrency and carry no Sendable annotation.  ContainerSignaller wraps
//   the domain in an @unchecked Sendable box (DomainBox) because:
//   (a) the domain is effectively immutable after construction — nothing here
//       mutates it, and macOS owns its lifecycle,
//   (b) signalEnumerator(for:) is called via a checked continuation on whatever
//       executor the caller supplies; no internal state is mutated concurrently.
//   @preconcurrency import suppresses the strict-concurrency warnings that would
//   otherwise fire on NSFileProviderDomain/NSFileProviderManager references.
//   See also: ChangeWatcher.signalContainer (host-side equivalent, OneLake/ChangeWatcher.swift).

@preconcurrency import FileProvider
import Foundation
import os.log

// MARK: - ContainerSignaller

/// Signals a specific sub-container enumerator in a File Provider domain.
///
/// Use `signal(container:)` to ask macOS to call back into `enumerateChanges`
/// for the given item identifier.  Only sub-containers should be signalled;
/// `.rootContainer` is deliberately excluded (signalling it throws
/// `.syncAnchorExpired`, which triggers a full re-enumeration).
///
/// `ContainerSignaller` is `Sendable`: it holds the domain via an
/// `@unchecked Sendable` box, matching the established pattern used in
/// `OfemFPEEnumerator` for `NSFileProviderEnumerationObserver` and
/// `NSFileProviderChangeObserver`.
struct ContainerSignaller: Sendable {
    private static let log = Logger(
        subsystem: "dev.debruyn.ofem.fileprovider",
        category: "container-signaller"
    )

    // NSFileProviderDomain carries no Sendable annotation; box it so the
    // enclosing struct satisfies Swift 6 Sendable (see file-header rationale).
    private struct DomainBox: @unchecked Sendable {
        let value: NSFileProviderDomain
    }

    private let domainBox: DomainBox

    init(domain: NSFileProviderDomain) {
        self.domainBox = DomainBox(value: domain)
    }

    /// Signals the enumerator for `container` in the domain.
    ///
    /// Builds `NSFileProviderManager(for: domain)` on each call; the manager
    /// is not cached because the domain may be removed between calls.  If the
    /// manager cannot be created (domain removed/unregistered) the call is a
    /// no-op.  Any error from `signalEnumerator(for:)` is logged at `.warning`
    /// and swallowed — Finder's own periodic refresh will catch up.
    ///
    /// Task cancellation is handled via `withTaskCancellationHandler`: if the
    /// calling task is cancelled before the completion handler fires, the
    /// continuation is resumed immediately with `CancellationError` so the
    /// task does not suspend indefinitely.
    func signal(container: NSFileProviderItemIdentifier) async {
        let domain = domainBox.value
        let domainId = domain.identifier.rawValue

        guard let manager = NSFileProviderManager(for: domain) else {
            Self.log.debug(
                "ContainerSignaller: no manager for domain \(domainId, privacy: .public); domain may have been removed"
            )
            return
        }

        // Guard early so a pre-cancelled task returns immediately without
        // scheduling the signalEnumerator callback.
        guard !Task.isCancelled else { return }

        do {
            // nonisolated(unsafe): shared between the continuation body and the
            // onCancel handler.  withCheckedThrowingContinuation invokes its
            // body synchronously, so `cont` is always assigned before the task
            // can be cancelled from another thread.  The pre-cancellation guard
            // above handles the case where the task is already cancelled.
            // CheckedContinuation enforces the single-resume contract at runtime.
            nonisolated(unsafe) var cont: CheckedContinuation<Void, Error>? = nil
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                    cont = c
                    manager.signalEnumerator(for: container) { error in
                        if let error = error {
                            c.resume(throwing: error)
                        } else {
                            c.resume()
                        }
                    }
                }
            } onCancel: {
                cont?.resume(throwing: CancellationError())
            }
            Self.log.debug(
                "ContainerSignaller: signalled \(domainId, privacy: .public)/\(container.rawValue, privacy: .public)"
            )
        } catch is CancellationError {
            // Task was cancelled; nothing further to do.
        } catch {
            // Non-fatal: Finder's own periodic refresh will catch up.
            Self.log.warning(
                "ContainerSignaller: signalEnumerator failed for \(domainId, privacy: .public)/\(container.rawValue, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
        }
    }
}
