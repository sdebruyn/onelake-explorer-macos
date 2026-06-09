import Foundation

// MARK: - AsyncSemaphore

/// A simple async counting semaphore.
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
final class AsyncSemaphore: @unchecked Sendable {

    // MARK: - State

    // `nonisolated(unsafe)` suppresses the Swift 6 diagnostic for calling
    // NSLock from an async context. The lock is NEVER held across a suspension,
    // so the usage is safe.
    nonisolated(unsafe) private var count: Int
    nonisolated(unsafe) private var waiters: [CheckedContinuation<Void, Never>] = []
    private let lock = NSLock()

    // MARK: - Init

    init(value: Int) {
        precondition(value > 0, "AsyncSemaphore: initial value must be > 0")
        count = value
    }

    // MARK: - Public API

    /// Decrements the semaphore count, suspending the caller when the count
    /// reaches zero until a paired ``signal()`` call increments it again.
    func wait() async {
        // `withCheckedContinuation`'s closure runs synchronously before any
        // suspension, so the check-and-enqueue is atomic under the lock.
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if count > 0 {
                count -= 1
                lock.unlock()
                continuation.resume()   // Resume immediately — no suspension.
            } else {
                waiters.append(continuation)
                lock.unlock()           // Suspend after releasing the lock.
            }
        }
    }

    /// Increments the semaphore count, resuming the next waiting caller (if any).
    func signal() {
        lock.lock()
        if !waiters.isEmpty {
            let waiter = waiters.removeFirst()
            lock.unlock()
            waiter.resume()
        } else {
            count += 1
            lock.unlock()
        }
    }
}
