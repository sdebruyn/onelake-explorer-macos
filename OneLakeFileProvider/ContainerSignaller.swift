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
//   signalEnumeratorOnce delegates to withCallbackOnce, which:
//     • Uses ResumeOnceBox: an NSLock-backed class whose take() atomically claims
//       and clears the stored continuation, so ONLY the first of {completion,
//       cancellation} ever resumes it. This prevents the double-resume trap that
//       #323 hit by sharing one continuation without a guard.
//     • Wraps with withTaskCancellationHandler AND checks Task.isCancelled
//       immediately after storing the continuation, so pre-cancelled tasks
//       (where onCancel fires before the continuation is stored) are also
//       released rather than leaking.

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
/// `work` receives a `deliver` closure that it must call with `nil` for
/// success or an `Error` for failure.  `withCallbackOnce` guarantees that
/// the underlying `CheckedContinuation` is resumed exactly once regardless
/// of the interleaving of `deliver` and task cancellation:
///
/// - **Normal path**: `deliver(nil/error)` claims the continuation via
///   `box.take()` and resumes it. A subsequent `onCancel` call sees `nil`
///   and is a no-op.
/// - **In-flight cancellation**: `onCancel` fires while the continuation is
///   suspended, claims it via `box.take()`, and resumes with
///   `CancellationError`. A subsequent `deliver` call sees `nil` and is a
///   no-op.
/// - **Pre-cancelled task** (the task was already cancelled before entering
///   `withCallbackOnce`): `withTaskCancellationHandler` runs `onCancel`
///   synchronously BEFORE the operation body, so `box.take()` sees `nil`
///   and no-ops. The body then stores the continuation and calls `work`.
///   To cover this interleaving, the body immediately re-checks
///   `Task.isCancelled`; if set, it calls `box.take()` and resumes with
///   `CancellationError` itself — releasing the continuation before
///   `work`'s callback can ever fire.
///
/// This primitive is `internal` (not `private`) so unit tests can exercise
/// the guard logic directly without requiring a real `NSFileProviderManager`.
func withCallbackOnce(
    work: @Sendable @escaping (_ deliver: @escaping @Sendable (Error?) -> Void) -> Void
) async throws {
    let box = ResumeOnceBox()

    try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            box.store(cont)
            // Pre-cancelled-task path: onCancel ran before the continuation
            // was stored, so its box.take() returned nil and was a no-op.
            // Re-check here and self-cancel so the continuation is not left
            // hanging when work's callback never fires.
            if Task.isCancelled {
                box.take()?.resume(throwing: CancellationError())
                return
            }
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
