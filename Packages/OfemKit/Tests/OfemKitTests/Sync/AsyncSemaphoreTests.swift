import Testing
import Foundation
@testable import OfemKit

// MARK: - AsyncSemaphore tests

/// Tests for ``AsyncSemaphore`` — counting semaphore for concurrency caps.
///
/// All ordering tests use ``waiterCount`` to confirm a task has actually
/// suspended on the semaphore before the releasing signal is sent, replacing
/// the sleep-based approach that was inherently racy (tests-13).
struct AsyncSemaphoreTests {

    // MARK: - Basic acquire / release

    // tests-20: strengthened to assert that wait() actually decrements the
    // semaphore (so signal() is required to allow another wait()).
    @Test func singleWaitSignal() async throws {
        let sem = AsyncSemaphore(value: 1)
        try await sem.wait()
        // After consuming the only slot, a second wait() must block.
        // The waiterCount doesn't help here since the slot is consumed but not
        // in the waiter queue — assert that a Task attempting wait() would queue
        // as a waiter (i.e., the slot is truly consumed).
        let blocked = Task<Void, any Error> { try await sem.wait() }
        while sem.waiterCount < 1 { await Task.yield() }
        #expect(sem.waiterCount == 1, "slot must be consumed: second waiter blocks")
        sem.signal()                 // Release to unblock
        try await blocked.value      // Must complete now
        sem.signal()                 // Return to initial capacity
        #expect(sem.waiterCount == 0, "semaphore must be fully released")
    }

    @Test func capacityAllowsMultipleConcurrentWaiters() async throws {
        let sem = AsyncSemaphore(value: 3)
        try await sem.wait()
        try await sem.wait()
        try await sem.wait()
        // All 3 slots consumed; a fourth waiter must block.
        let blocked = Task<Void, any Error> { try await sem.wait() }
        while sem.waiterCount < 1 { await Task.yield() }
        #expect(sem.waiterCount == 1, "slot capacity respected: fourth waiter must queue")
        blocked.cancel()
        // Wait for the cancellation to drain the waiter.
        while sem.waiterCount > 0 { await Task.yield() }
        sem.signal()
        sem.signal()
        sem.signal()
        #expect(sem.waiterCount == 0)
    }

    // MARK: - Blocking and unblocking (deterministic via waiterCount)

    @Test func signalReleasesBlockedWaiter() async throws {
        let sem = AsyncSemaphore(value: 1)
        try await sem.wait()  // Consume the only slot.

        actor Flag {
            var released = false
            func set() { released = true }
        }
        let flag = Flag()

        let task = Task {
            try await sem.wait()
            await flag.set()
        }

        // Wait deterministically until the task has actually suspended on the
        // semaphore (waiterCount reaches 1) instead of relying on Task.sleep
        // ordering (tests-13).
        while sem.waiterCount < 1 { await Task.yield() }
        #expect(await !flag.released)

        sem.signal()          // Unblock the waiting task.
        try await task.value
        #expect(await flag.released)
    }

    @Test func fairnessFirstInFirstOut() async throws {
        let sem = AsyncSemaphore(value: 1)
        try await sem.wait()  // Consume the only slot.

        actor Collector {
            var order: [Int] = []
            func append(_ i: Int) { order.append(i) }
        }
        let col = Collector()

        // Enqueue tasks. Each waits until the previous one has actually enqueued
        // (waiterCount reaches expected depth) so the FIFO order is guaranteed
        // without relying on Task scheduler timing (tests-13).
        let task1 = Task { try await sem.wait(); await col.append(1); sem.signal() }
        while sem.waiterCount < 1 { await Task.yield() }

        let task2 = Task { try await sem.wait(); await col.append(2); sem.signal() }
        while sem.waiterCount < 2 { await Task.yield() }

        let task3 = Task { try await sem.wait(); await col.append(3); sem.signal() }
        while sem.waiterCount < 3 { await Task.yield() }

        sem.signal()  // Release; tasks should wake in FIFO order.
        _ = try await (task1.value, task2.value, task3.value)
        #expect(await col.order == [1, 2, 3])
    }

    // MARK: - Cancellation (sync-05)

    @Test func cancelledWaiterThrowsCancellationError() async throws {
        let sem = AsyncSemaphore(value: 1)
        try await sem.wait()  // Consume the only slot.

        let task = Task {
            try await sem.wait()
        }

        // Ensure the task has entered wait() before cancelling.
        while sem.waiterCount < 1 { await Task.yield() }

        task.cancel()

        do {
            try await task.value
            Issue.record("Expected CancellationError")
        } catch is CancellationError {
            // Correct.
        }

        // The cancelled waiter must have released its queue slot so the
        // semaphore can still be acquired by another caller.
        #expect(sem.waiterCount == 0)
        // Signal the original slot; count should go back to 1.
        sem.signal()
        // A fresh waiter should succeed immediately.
        try await sem.wait()
        sem.signal()
    }

    @Test func cancelledWaiterReleasesSlot() async throws {
        // Verify that after a cancellation the semaphore's total capacity is
        // not reduced (the cancelled task must not permanently hold a slot).
        let sem = AsyncSemaphore(value: 2)
        try await sem.wait()
        try await sem.wait()  // All slots consumed.

        let blocked1 = Task { try await sem.wait() }
        let blocked2 = Task { try await sem.wait() }
        while sem.waiterCount < 2 { await Task.yield() }

        blocked1.cancel()
        // Let the cancellation propagate.
        while sem.waiterCount > 1 { await Task.yield() }

        // Release one real slot — blocked2 should wake (not blocked1).
        sem.signal()
        try await blocked2.value
        sem.signal() // release the other slot
        // blocked1 should have thrown CancellationError.
        do {
            try await blocked1.value
            Issue.record("Expected CancellationError from blocked1")
        } catch is CancellationError {}
    }

    @Test func preCancelledTaskThrowsImmediately() async throws {
        let sem = AsyncSemaphore(value: 1)

        // A task that is cancelled before it calls wait() should get
        // CancellationError immediately via the early-out checkCancellation().
        let t = Task<Void, any Error> {
            // Yield briefly so the cancel() call below races in; use
            // checkCancellation after yield to reliably observe the cancel.
            await Task.yield()
            try Task.checkCancellation()
            try await sem.wait()
        }
        t.cancel()
        do {
            try await t.value
        } catch is CancellationError {
            // Correct — slot should not have been consumed.
        }
        // Semaphore capacity should be intact.
        try await sem.wait()
        sem.signal()
    }

    // MARK: - T3: net-zero permit accounting after signal/cancel race

    @Test("Cancelled waiter leaves semaphore at full capacity — a fresh wait() succeeds immediately")
    func cancelledWaiterNetZeroPermitAccounting() async throws {
        // capacity = 2, consume both slots so any additional waiter blocks.
        let sem = AsyncSemaphore(value: 2)
        try await sem.wait()
        try await sem.wait()

        // A third task must queue as a waiter.
        let blocked = Task<Void, any Error> { try await sem.wait() }
        while sem.waiterCount < 1 { await Task.yield() }

        // Cancel the blocked waiter.
        blocked.cancel()

        // Await cancellation propagation.
        do {
            try await blocked.value
            Issue.record("Expected CancellationError")
        } catch is CancellationError { /* expected */ }

        // Release both original slots.
        sem.signal()
        sem.signal()

        // Capacity is back to 2. A fresh waiter should succeed immediately
        // (no blocking, no deadlock) proving net-zero permit accounting.
        try await sem.wait()
        #expect(sem.waiterCount == 0)
        sem.signal()
        try await sem.wait()
        #expect(sem.waiterCount == 0)
        sem.signal()
    }
}
