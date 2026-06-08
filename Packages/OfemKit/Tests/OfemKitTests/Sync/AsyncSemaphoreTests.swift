import Testing
import Foundation
@testable import OfemKit

// MARK: - AsyncSemaphore tests

/// Tests for ``AsyncSemaphore`` — counting semaphore for concurrency caps.
struct AsyncSemaphoreTests {

    @Test func singleWaitSignal() async {
        let sem = AsyncSemaphore(value: 1)
        await sem.wait()
        sem.signal()
        // Should reach here without hanging.
    }

    @Test func capacityAllowsMultipleConcurrentWaiters() async {
        let sem = AsyncSemaphore(value: 3)
        await sem.wait()
        await sem.wait()
        await sem.wait()
        sem.signal()
        sem.signal()
        sem.signal()
    }

    @Test func signalReleasesBlockedWaiter() async throws {
        // Verify a second task that blocks on wait() is unblocked by signal().
        let sem = AsyncSemaphore(value: 1)
        await sem.wait()  // Consume the only slot.

        // Collector for the result — actor-isolated so no races.
        actor Flag {
            var released = false
            func set() { released = true }
        }
        let flag = Flag()

        let task = Task {
            await sem.wait()
            await flag.set()
        }
        // Give the task time to enter wait() and block.
        try await Task.sleep(for: .milliseconds(30))
        #expect(await !flag.released)

        sem.signal()          // Unblock the waiting task.
        await task.value
        #expect(await flag.released)
    }

    @Test func fairnessFirstInFirstOut() async throws {
        // Verify tasks that enter wait() in order are woken in the same order.
        let sem = AsyncSemaphore(value: 1)
        await sem.wait()  // Consume the only slot.

        actor Collector {
            var order: [Int] = []
            func append(_ i: Int) { order.append(i) }
        }
        let col = Collector()

        // Enqueue tasks with a small delay between each so we know the order.
        let task1 = Task { await sem.wait(); await col.append(1); sem.signal() }
        try await Task.sleep(for: .milliseconds(10))
        let task2 = Task { await sem.wait(); await col.append(2); sem.signal() }
        try await Task.sleep(for: .milliseconds(10))
        let task3 = Task { await sem.wait(); await col.append(3); sem.signal() }

        // Let all tasks enter wait().
        try await Task.sleep(for: .milliseconds(30))

        sem.signal()  // Release; tasks should wake in FIFO order.
        _ = await (task1.value, task2.value, task3.value)
        #expect(await col.order == [1, 2, 3])
    }
}
