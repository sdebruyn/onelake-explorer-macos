import Foundation

// MARK: - AsyncSemaphore

/// A cancellation-aware async counting semaphore.
///
/// Used by ``SyncEngine`` to cap per-account concurrent download and upload
/// operations. One `AsyncSemaphore` per alias is allocated lazily from within
/// the `SyncEngine` actor.
///
/// ## Implementation note
///
/// Swift 6 disallows calling `NSLock.lock()` from async contexts in general,
/// but this implementation is safe: the lock is never held across a suspension
/// point. The `nonisolated(unsafe)` attribute on the stored state suppresses
/// the compiler's conservative diagnostic so the correct lock-then-check-then-
/// release pattern can be expressed.
///
/// ## Cancellation (sync-15 fix)
///
/// `wait()` is cancellation-aware. Three races are handled with net-zero
/// permit accounting in all cases:
///
/// 1. **Cancelled while queued** — `onCancel` fires while the waiter is still
///    in `waiters`. The entry is removed and its continuation is rejected with
///    `CancellationError`. No `count` adjustment is needed because the slot
///    was never granted.
///
/// 2. **Cancel races signal (the original bug)** — `signal()` dequeues the
///    waiter, sets `slotGranted = true` via the stored setter, then resumes
///    the continuation. The task is also cancelled; `onCancel` now finds no
///    entry in `waiters` and does nothing. After `withTaskCancellationHandler`
///    returns, `wait()` sees `slotGranted == true && Task.isCancelled`, calls
///    `signal()` to return the slot, and throws `CancellationError`. **Before
///    this fix** `slotGranted` was only set on the synchronous-grant path, so
///    the dequeued-but-cancelled waiter consumed a permit permanently.
///
/// 3. **Signal races cancel** — `onCancel` fires first, removes the waiter,
///    resumes its continuation with `CancellationError`, and does NOT touch
///    `count`. `signal()` then arrives, finds an empty queue, and increments
///    `count` normally — permit is conserved.
final class AsyncSemaphore: @unchecked Sendable {
    // MARK: - State

    // `nonisolated(unsafe)` suppresses the Swift 6 diagnostic for calling
    // NSLock from an async context. The lock is NEVER held across a suspension,
    // so the usage is safe.
    private nonisolated(unsafe) var count: Int
    private nonisolated(unsafe) var waiters: [WaiterEntry] = []
    private let lock = NSLock()

    // MARK: - Waiter entry

    /// Each waiter carries:
    /// - a stable `id` so it can be found during cancellation without a linear
    ///   scan over an unrelated field,
    /// - the `continuation` to resume,
    /// - a `grantSlot` closure that `signal()` calls **before** resuming the
    ///   continuation so `slotGranted` is visible to the post-handler check in
    ///   `wait()` regardless of task-scheduler interleaving (sync-15 fix).
    private struct WaiterEntry {
        let id: UInt64
        let continuation: CheckedContinuation<Void, any Error>
        let grantSlot: () -> Void
    }

    // MARK: - Monotonic ID counter

    private nonisolated(unsafe) var nextID: UInt64 = 0

    // MARK: - Init

    /// Creates an `AsyncSemaphore` with the given initial permit count.
    ///
    /// - Parameter value: Initial permit count. Must be `>= 0`. A value of `0`
    ///   is valid and produces a semaphore that blocks every caller until a
    ///   `signal()` is issued from outside the waiter (e.g. as a one-shot gate).
    init(value: Int) {
        precondition(value >= 0, "AsyncSemaphore: initial value must be >= 0")
        count = value
    }

    // MARK: - Public API

    /// Decrements the semaphore count, suspending the caller when the count
    /// reaches zero until a paired ``signal()`` call increments it again.
    ///
    /// Throws `CancellationError` when the calling task is cancelled while
    /// waiting; any acquired slot is released back to the pool so it is never
    /// leaked.
    func wait() async throws {
        // Early-out: if the task is already cancelled, don't even try to acquire
        // a slot — just throw immediately.
        try Task.checkCancellation()

        let id: UInt64 = lock.withLock {
            nextID += 1
            return nextID
        }

        // `slotGranted` tracks whether a slot was actually handed to this waiter,
        // in both the synchronous and asynchronous grant paths. The flag is set
        // inside the lock (synchronous) or via the `grantSlot` closure stored
        // on the `WaiterEntry` (asynchronous — called by `signal()` before it
        // resumes the continuation). The post-`withTaskCancellationHandler` check
        // uses it to decide whether to call `signal()` to return the slot.
        //
        // `nonisolated(unsafe)` is safe here because the flag is written at
        // most once (before the continuation resumes) and read after
        // `withTaskCancellationHandler` returns, forming a happens-before
        // relationship through the continuation handoff.
        nonisolated(unsafe) var slotGranted = false

        try await withTaskCancellationHandler(
            operation: {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                    lock.lock()
                    if count > 0 {
                        // Synchronous grant: slot is available right now.
                        count -= 1
                        slotGranted = true
                        lock.unlock()
                        continuation.resume() // Resume immediately — no suspension.
                    } else {
                        // Must queue — will be resumed by a future signal().
                        // Store a `grantSlot` closure so signal() can set
                        // slotGranted = true before resuming, ensuring the
                        // post-handler check sees the correct state (sync-15 fix).
                        waiters.append(WaiterEntry(
                            id: id,
                            continuation: continuation,
                            grantSlot: { slotGranted = true }
                        ))
                        lock.unlock() // Suspend after releasing the lock.
                    }
                }
            },
            onCancel: {
                // Called when the task is cancelled. If the waiter is still
                // queued, remove it and throw — no count adjustment needed
                // (the slot was never granted). If it is no longer queued,
                // signal() already set slotGranted=true and resumed the
                // continuation; the post-handler check below returns the slot.
                lock.lock()
                if let idx = waiters.firstIndex(where: { $0.id == id }) {
                    let entry = waiters.remove(at: idx)
                    lock.unlock()
                    entry.continuation.resume(throwing: CancellationError())
                } else {
                    // signal() already dequeued and resumed us — do nothing.
                    // slotGranted is true; the post-handler check will signal().
                    lock.unlock()
                }
            }
        )

        // Post-handler: if a slot was granted but the task was also cancelled,
        // return the slot and throw so the caller never silently holds a permit.
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
            // Set slotGranted=true BEFORE resuming so the post-handler check
            // in wait() sees it even if task cancellation fires immediately after
            // the continuation is resumed (sync-15 fix).
            waiter.grantSlot()
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
