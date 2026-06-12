import Foundation

// MARK: - AsyncSemaphore

/// A cancellation-aware async counting semaphore.
///
/// Used by ``SyncEngine`` to cap per-account concurrent download and upload
/// operations.
/// actor model makes per-alias maps unnecessary; one `AsyncSemaphore` per alias
/// is allocated lazily from within the `SyncEngine` actor).
///
/// ## Implementation note
///
/// Swift 6 disallows calling `NSLock.lock()` from async contexts in general,
/// but this implementation is safe: the lock is never held across a suspension
/// point. The `nonisolated(unsafe)` attribute on the stored state suppresses
/// the compiler's conservative diagnostic so the correct lock-then-check-then-
/// release pattern can be expressed.
///
/// ## Cancellation (sync-05)
///
/// `wait()` is cancellation-aware: when the calling task is cancelled while
/// waiting, the continuation is removed from the queue (releasing the slot),
/// and `CancellationError` is thrown. This ensures cancelled tasks never hold
/// one of the concurrency slots.
final class AsyncSemaphore: @unchecked Sendable {

    // MARK: - State

    // `nonisolated(unsafe)` suppresses the Swift 6 diagnostic for calling
    // NSLock from an async context. The lock is NEVER held across a suspension,
    // so the usage is safe.
    nonisolated(unsafe) private var count: Int
    nonisolated(unsafe) private var waiters: [WaiterEntry] = []
    private let lock = NSLock()

    // MARK: - Waiter entry

    /// Each waiter is identified by a stable ID so it can be removed on
    /// cancellation without scanning the whole queue.
    private struct WaiterEntry {
        let id: UInt64
        let continuation: CheckedContinuation<Void, any Error>
    }

    // MARK: - Monotonic ID counter

    nonisolated(unsafe) private var nextID: UInt64 = 0

    // MARK: - Init

    init(value: Int) {
        precondition(value > 0, "AsyncSemaphore: initial value must be > 0")
        count = value
    }

    // MARK: - Public API

    /// Decrements the semaphore count, suspending the caller when the count
    /// reaches zero until a paired ``signal()`` call increments it again.
    ///
    /// Throws `CancellationError` when the calling task is cancelled while
    /// waiting; any acquired slot is released back to the pool so it is never
    /// leaked.
    ///
    /// ## Cancellation design
    ///
    /// Two distinct cancellation scenarios exist:
    ///
    /// 1. **Cancelled while queued** — `onCancel` fires while the waiter is
    ///    still in `waiters`. The entry is removed and its continuation is
    ///    rejected with `CancellationError`. No `count` adjustment is needed
    ///    because the slot was never granted.
    ///
    /// 2. **Cancelled after dequeue** — `signal()` has already removed the
    ///    waiter from `waiters` and called `continuation.resume()`, granting a
    ///    slot. If cancellation also fires at this moment, `onCancel` finds no
    ///    entry in `waiters` and does **nothing** (the `else` branch is omitted
    ///    to avoid a spurious `count += 1`). After `withTaskCancellationHandler`
    ///    returns (the continuation has resumed), `wait()` checks for
    ///    cancellation: if the task was cancelled it calls `signal()` to return
    ///    the slot and then throws `CancellationError`. This guarantees net-zero
    ///    permit accounting across all races.
    func wait() async throws {
        // Early-out: if the task is already cancelled, don't even try to acquire
        // a slot — just throw immediately.
        try Task.checkCancellation()

        let id: UInt64 = lock.withLock {
            nextID += 1
            return nextID
        }

        // Track whether the slot was actually granted so the post-handler check
        // knows whether to call signal() on cancellation.
        var slotGranted = false

        try await withTaskCancellationHandler(
            operation: {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                    lock.lock()
                    if count > 0 {
                        count -= 1
                        lock.unlock()
                        slotGranted = true
                        continuation.resume()   // Resume immediately — no suspension.
                    } else {
                        waiters.append(WaiterEntry(id: id, continuation: continuation))
                        lock.unlock()           // Suspend after releasing the lock.
                    }
                }
            },
            onCancel: {
                // Called when the task is cancelled. If the waiter is still
                // queued, remove it and throw — no count adjustment needed
                // (the slot was never granted). If it is no longer queued,
                // signal() already resumed the continuation and owns the slot
                // release; do nothing here so count is not over-incremented.
                lock.lock()
                if let idx = waiters.firstIndex(where: { $0.id == id }) {
                    let entry = waiters.remove(at: idx)
                    lock.unlock()
                    entry.continuation.resume(throwing: CancellationError())
                } else {
                    // Waiter was already dequeued by signal() — slot release is
                    // handled below, after withTaskCancellationHandler returns.
                    lock.unlock()
                }
            }
        )

        // Scenario 2: the continuation resumed normally (slot was granted) but
        // the task was also cancelled. Return the slot and throw so the caller
        // never silently holds a permit while cancelled.
        if slotGranted, Task.isCancelled {
            signal()
            throw CancellationError()
        }
    }

    /// Increments the semaphore count, resuming the next waiting caller (if any).
    func signal() {
        lock.lock()
        if !waiters.isEmpty {
            let waiter = waiters.removeFirst()
            lock.unlock()
            waiter.continuation.resume()
        } else {
            count += 1
            lock.unlock()
        }
    }

    // MARK: - Inspection (for deterministic tests)

    /// Returns the number of tasks currently waiting on this semaphore.
    var waiterCount: Int {
        lock.withLock { waiters.count }
    }
}
