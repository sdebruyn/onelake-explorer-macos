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
//
// Continuation hardening — resume-once guard:
//   Apple does not guarantee that NSFileProviderManager.signalEnumerator(for:completionHandler:)
//   always calls its completion handler (fileproviderd crash / domain teardown).
//   A plain withCheckedThrowingContinuation would leak the continuation forever.
//   signalEnumeratorOnce wraps the call with:
//     • A lock-guarded optional continuation (nonisolated(unsafe) var inside the
//       closure) that is nil'd before every resume, so ONLY the first caller
//       (completion handler OR onCancel) actually resumes it — the second path
//       is a no-op. This prevents the double-resume trap that a prior attempt
//       (#323) hit by sharing one continuation without a resume-once guard.
//     • withTaskCancellationHandler so a cancelled caller (e.g. engine shutdown)
//       is released immediately with CancellationError rather than hanging.

@preconcurrency import FileProvider
import Foundation
import os.log

// MARK: - ResumeOnceBox (resume-once guard)

/// A lock-guarded box that ensures a `CheckedContinuation` is resumed at most
/// once across concurrent callers.
///
/// Both the "work completed" path and the "task cancelled" path call `take()`.
/// `take()` atomically reads and clears the stored continuation, returning it
/// to the caller only when it has not yet been claimed — so exactly one of the
/// two paths ever calls `resume` on the continuation.
///
/// `@unchecked Sendable`: the class is safe to pass across isolation domains
/// because all access to `stored` is protected by `lock`.
final class ResumeOnceBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: CheckedContinuation<Void, Error>?

    /// Stores `cont`. Must be called exactly once before any call to `take()`.
    func store(_ cont: CheckedContinuation<Void, Error>) {
        lock.withLock { stored = cont }
    }

    /// Atomically claims the stored continuation.  Returns the continuation the
    /// first time it is called; returns `nil` on every subsequent call.
    func take() -> CheckedContinuation<Void, Error>? {
        lock.withLock { let c = stored; stored = nil; return c }
    }
}

// MARK: - withCallbackOnce (testable resume-once primitive)

/// Awaits a callback-style operation exactly once, with a resume-once guard
/// and task-cancellation support.
///
/// `work` receives a `deliver` closure that it must call exactly once with
/// `nil` for success or an `Error` for failure.  `withCallbackOnce` wraps the
/// call in `withTaskCancellationHandler` so a cancelled caller is released
/// immediately via `CancellationError` rather than hanging.
///
/// The resume-once guarantee is enforced by `ResumeOnceBox`: both the
/// `deliver` path and the `onCancel` path call `box.take()`, which
/// atomically claims the stored continuation only once.  The second path
/// always receives `nil` and is a no-op, preventing both leaks and the
/// double-resume trap.
///
/// This primitive is `internal` (not `private`) so unit tests can exercise the
/// guard logic directly without requiring a real `NSFileProviderManager`.
func withCallbackOnce(
    work: @Sendable @escaping (_ deliver: @escaping @Sendable (Error?) -> Void) -> Void
) async throws {
    let box = ResumeOnceBox()

    try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            box.store(cont)
            work { error in
                guard let c = box.take() else { return }
                if let error { c.resume(throwing: error) } else { c.resume() }
            }
        }
    } onCancel: {
        box.take()?.resume(throwing: CancellationError())
    }
}

// MARK: - signalEnumeratorOnce

/// Calls `manager.signalEnumerator(for:completionHandler:)` with the
/// resume-once guard provided by `withCallbackOnce`.
func signalEnumeratorOnce(
    manager: NSFileProviderManager,
    container: NSFileProviderItemIdentifier
) async throws {
    try await withCallbackOnce { deliver in
        manager.signalEnumerator(for: container) { error in deliver(error) }
    }
}

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
    func signal(container: NSFileProviderItemIdentifier) async {
        let domain = domainBox.value
        let domainId = domain.identifier.rawValue

        guard let manager = NSFileProviderManager(for: domain) else {
            Self.log.debug(
                "ContainerSignaller: no manager for domain \(domainId, privacy: .public); domain may have been removed"
            )
            return
        }

        do {
            try await signalEnumeratorOnce(manager: manager, container: container)
            Self.log.debug(
                "ContainerSignaller: signalled \(domainId, privacy: .public)/\(container.rawValue, privacy: .public)"
            )
        } catch {
            // Non-fatal: Finder's own periodic refresh will catch up.
            Self.log.warning(
                "ContainerSignaller: signalEnumerator failed for \(domainId, privacy: .public)/\(container.rawValue, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
        }
    }
}
