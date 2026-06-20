import Foundation
@testable import OfemKit

// MARK: - ContainerChangeRecorder

/// Thread-safe collector for ``ContainerChangeHandler`` invocations, shared by
/// the `SyncEngine` test suites.
///
/// The engine invokes the handler from a detached task (OFF the actor), so a
/// test cannot assert on `calls()` immediately after joining the revalidate
/// task — the notification may not have run yet. `nextCall()` awaits the next
/// invocation deterministically.
///
/// Delivery is an actor-owned buffer + single waiter (not an `AsyncStream`):
/// `AsyncStream` allows only one iterator, and threading its non-`Sendable`
/// iterator through an actor trips Swift 6 sending checks. The buffer/waiter
/// queue here delivers each yielded call to exactly one `nextCall()` in FIFO
/// order, with no iterator to misuse. Callers invoke `nextCall()` serially
/// (one outstanding await at a time), which is all the suites require.
final class ContainerChangeRecorder: @unchecked Sendable {
    struct Call: Sendable { let container: CacheKey; let diff: Diff }

    /// Actor-owned delivery queue: buffers calls until a `nextCall()` consumes
    /// them, or parks a single waiter until the next call arrives.
    private actor Inbox {
        private var buffer: [Call] = []
        private var waiter: CheckedContinuation<Call?, Never>?

        func deliver(_ call: Call) {
            if let w = waiter {
                waiter = nil
                w.resume(returning: call)
            } else {
                buffer.append(call)
            }
        }

        func next() async -> Call? {
            if !buffer.isEmpty {
                return buffer.removeFirst()
            }
            return await withCheckedContinuation { cont in
                waiter = cont
            }
        }
    }

    private let lock = NSLock()
    private var _calls: [Call] = []
    private let inbox = Inbox()

    /// The change handler to inject into the engine. `@Sendable`: records the
    /// call under lock (for the synchronous `calls()` snapshot) and forwards it
    /// to the actor inbox for `nextCall()`.
    var handler: ContainerChangeHandler {
        { [self] container, diff in
            let call = Call(container: container, diff: diff)
            lock.withLock { _calls.append(call) }
            Task { await inbox.deliver(call) }
        }
    }

    /// Snapshot of invocations recorded so far.
    func calls() -> [Call] { lock.withLock { _calls } }

    /// Awaits and returns the next handler invocation (FIFO).
    func nextCall() async -> Call? {
        await inbox.next()
    }
}
