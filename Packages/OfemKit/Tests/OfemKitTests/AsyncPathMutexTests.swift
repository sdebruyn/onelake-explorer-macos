import Foundation
@testable import OfemKit
import Testing

// MARK: - OverlapTracker

/// Records concurrent entries into a critical section and the maximum
/// number observed at once. Used to prove ``AsyncPathMutex`` actually
/// serialises same-path callers rather than merely appearing to (F12).
private actor OverlapTracker {
    private var current = 0
    private(set) var maxConcurrent = 0
    private(set) var totalEntries = 0

    func enter() {
        current += 1
        totalEntries += 1
        maxConcurrent = max(maxConcurrent, current)
    }

    func exit() {
        current -= 1
    }
}

// MARK: - AsyncPathMutexTests

@Suite("AsyncPathMutex")
struct AsyncPathMutexTests {
    /// Every test uses a unique key so that concurrently-running tests
    /// (Swift Testing parallelises by default) never contend on the same
    /// entry in the process-wide `AsyncPathMutex.shared` registry.
    private func uniqueKey(_ label: String) -> String {
        "async-path-mutex-test-\(label)-\(UUID().uuidString)"
    }

    // MARK: - Core guarantee (F12)

    @Test("same-path critical sections never overlap, even under contention")
    func samePathCriticalSectionsNeverOverlap() async {
        let key = uniqueKey("no-overlap")
        let tracker = OverlapTracker()

        await withTaskGroup(of: Void.self) { group in
            for _ in 0 ..< 25 {
                group.addTask {
                    await AsyncPathMutex.shared.acquire(path: key)
                    await tracker.enter()
                    // A brief yield widens the window in which a broken
                    // (non-serialising) implementation would let a second
                    // caller's critical section overlap this one.
                    try? await Task.sleep(nanoseconds: 500_000)
                    await tracker.exit()
                    await AsyncPathMutex.shared.release(path: key)
                }
            }
        }

        let maxConcurrent = await tracker.maxConcurrent
        let total = await tracker.totalEntries
        #expect(maxConcurrent == 1, "critical sections for the same path must never overlap")
        #expect(total == 25, "every acquire must eventually be granted its turn")
    }

    // MARK: - No deadlock

    @Test("many concurrent turns for the same path all complete without deadlock")
    func manyConcurrentTurnsCompleteWithoutDeadlock() async {
        let key = uniqueKey("stress")
        let tracker = OverlapTracker()

        await withTaskGroup(of: Void.self) { group in
            for _ in 0 ..< 100 {
                group.addTask {
                    await AsyncPathMutex.shared.acquire(path: key)
                    await tracker.enter()
                    await tracker.exit()
                    await AsyncPathMutex.shared.release(path: key)
                }
            }
        }

        let total = await tracker.totalEntries
        #expect(total == 100, "all 100 turns must complete — a hang here means a lost/duplicated release")
    }

    @Test("sequential acquire then release then acquire again does not hang")
    func sequentialAcquireReleaseAcquire() async {
        let key = uniqueKey("sequential")
        await AsyncPathMutex.shared.acquire(path: key)
        await AsyncPathMutex.shared.release(path: key)
        // If release() failed to clear `held`, this second acquire would
        // hang forever waiting for a waiter that will never be queued.
        await AsyncPathMutex.shared.acquire(path: key)
        await AsyncPathMutex.shared.release(path: key)
    }

    // MARK: - Independence across keys

    @Test("different paths do not block each other")
    func differentPathsDoNotBlock() async {
        let keyA = uniqueKey("a")
        let keyB = uniqueKey("b")

        // Hold `keyA`'s turn without releasing it.
        await AsyncPathMutex.shared.acquire(path: keyA)

        // Acquiring/releasing an unrelated path must complete promptly —
        // if the implementation used a single global turn instead of a
        // per-path one, this would deadlock against the still-held `keyA`.
        await AsyncPathMutex.shared.acquire(path: keyB)
        await AsyncPathMutex.shared.release(path: keyB)

        await AsyncPathMutex.shared.release(path: keyA)
    }

    // MARK: - Edge cases

    @Test("release for a path with no outstanding acquire is a safe no-op")
    func releaseWithoutAcquireIsNoop() async {
        let key = uniqueKey("release-only")
        // Must not crash or corrupt state for a subsequent, legitimate use.
        await AsyncPathMutex.shared.release(path: key)

        await AsyncPathMutex.shared.acquire(path: key)
        await AsyncPathMutex.shared.release(path: key)
    }
}
