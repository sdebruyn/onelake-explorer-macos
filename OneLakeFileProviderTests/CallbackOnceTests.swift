// CallbackOnceTests.swift
// Tests for withCallbackOnce and ResumeOnceBox: the resume-once guard
// primitives used by signalEnumeratorOnce in ContainerSignaller.
//
// withCallbackOnce and ResumeOnceBox are in-module (OneLakeFileProvider sources
// are compiled directly into this test bundle), so no import is needed.
//
// Covered interleavings:
//   1. Normal success path — work closure runs, caller returns normally.
//   2. Normal failure path — work closure delivers an error, caller throws it.
//   3. Completion fires, then task cancelled — onCancel must be a silent no-op;
//      no double-resume; task succeeds.
//   4. Task cancelled while completion in-flight — concurrent race; no crash,
//      exactly one resume.
//   5. Task cancelled before completion fires — caller receives CancellationError;
//      a late deliver() call is a no-op (no crash, no second resume).
//   6. Pre-cancelled task — task already cancelled before entering
//      withCallbackOnce; caller must receive CancellationError even when the
//      callback never fires (covers the onCancel-fires-before-store gap).
//   7. Completion never fires — task cancellation releases the caller
//      (continuation does not leak).
//   8. Double deliver() — work calls deliver twice; second call is a no-op.

import XCTest

final class CallbackOnceTests: XCTestCase {

    // MARK: - ResumeOnceBox

    func testResumeOnceBox_takeReturnsNilWhenEmpty() {
        let box = ResumeOnceBox()
        XCTAssertNil(box.take(), "take() on an empty box must return nil")
    }

    // MARK: - 1. Normal success

    func testSuccessPath_resumesNormally() async throws {
        var workRan = false
        try await withCallbackOnce { deliver in
            workRan = true
            deliver(nil)
        }
        XCTAssertTrue(workRan, "work closure must have run")
    }

    // MARK: - 2. Normal failure

    func testFailurePath_throwsSuppliedError() async throws {
        struct Sentinel: Error {}
        var workRan = false
        do {
            try await withCallbackOnce { deliver in
                workRan = true
                deliver(Sentinel())
            }
            XCTFail("Expected withCallbackOnce to throw Sentinel")
        } catch is Sentinel {
            // Expected.
        }
        XCTAssertTrue(workRan, "work closure must have run before throwing")
    }

    // MARK: - 3. Completion fires first, then task cancelled

    /// Completion fires successfully; the subsequent cancel must observe an
    /// already-nil box and be a silent no-op. Without the guard, the second
    /// resume would crash with a CheckedContinuation trap.
    func testCompletionThenCancellation_taskSucceeds_noDoubleResume() async throws {
        let deliverBox = DeliverBox()

        let task = Task<Void, Error> {
            try await withCallbackOnce { deliver in
                deliverBox.store(deliver)
            }
        }

        await deliverBox.waitUntilStored()
        deliverBox.fire(error: nil)   // path 1: normal success
        task.cancel()                  // path 2: must be a no-op

        // task must complete successfully (not throw CancellationError)
        try await task.value
    }

    // MARK: - 4. Concurrent race: completion and cancellation simultaneously

    /// Fire completion and cancel concurrently (without sequencing). Exactly
    /// one of the two paths must claim the continuation; the other must be a
    /// no-op. No crash, no hang.
    func testConcurrentCompletionAndCancellation_noDoubleResume() async throws {
        let deliverBox = DeliverBox()
        let exited = ExitedFlag()
        nonisolated(unsafe) var threwCancellation = false
        nonisolated(unsafe) var succeeded = false

        let task = Task<Void, Error> {
            do {
                try await withCallbackOnce { deliver in
                    deliverBox.store(deliver)
                }
                await exited.set()
                succeeded = true
            } catch is CancellationError {
                await exited.set()
                threwCancellation = true
            }
        }

        await deliverBox.waitUntilStored()

        // Fire both paths without sequencing — let the scheduler decide.
        async let _ = Task { deliverBox.fire(error: nil) }.value
        task.cancel()

        await exited.waitUntilSet()

        // Exactly one of the two paths must have won.
        let exactly1 = (succeeded && !threwCancellation) || (!succeeded && threwCancellation)
        XCTAssertTrue(exactly1, "Exactly one of success/cancellation must win")
    }

    // MARK: - 5. Task cancelled before completion fires

    /// Cancel while work is in flight but deliver has not yet been called.
    /// Caller must receive CancellationError; the subsequent deliver() must
    /// be a no-op.
    func testCancellationBeforeCompletion_callerGetsCancellationError() async throws {
        let deliverBox = DeliverBox()
        let exited = ExitedFlag()
        nonisolated(unsafe) var gotCancellation = false

        let task = Task<Void, Error> {
            do {
                try await withCallbackOnce { deliver in
                    deliverBox.store(deliver)
                }
                XCTFail("Expected CancellationError, not normal return")
                await exited.set()
            } catch is CancellationError {
                gotCancellation = true
                await exited.set()
            }
        }

        await deliverBox.waitUntilStored()
        task.cancel()
        await exited.waitUntilSet()

        XCTAssertTrue(gotCancellation, "Caller must receive CancellationError")

        // Late deliver() — must be a silent no-op (no crash, no second resume).
        deliverBox.fire(error: nil)
        try? await Task.sleep(nanoseconds: 10_000_000)
    }

    // MARK: - 6. Pre-cancelled task

    /// The task is already cancelled BEFORE withCallbackOnce is entered.
    /// withTaskCancellationHandler fires onCancel synchronously before the
    /// body runs, so box.take() in onCancel sees nil (nothing stored yet).
    /// The body must detect Task.isCancelled and self-resume with
    /// CancellationError — even if work's callback never fires.
    func testPreCancelledTask_callerGetsCancellationError_evenWhenCallbackNeverFires() async throws {
        let expectation = XCTestExpectation(description: "pre-cancelled task exits")

        let task = Task<Void, Error> {
            // Cancel immediately before yielding to the executor.
            // Swift's cooperative executor will see the task as already
            // cancelled when withCallbackOnce runs.
            try await Task.sleep(nanoseconds: 0)  // yields so cancel is observable
        }
        task.cancel()
        // Drain any pending work so the task's cancellation is committed.
        await Task.yield()

        // Now create a fresh already-cancelled task that runs withCallbackOnce.
        let cancelledTask = Task<Void, Error> {
            do {
                try await withCallbackOnce { _ in
                    // Never call deliver — simulates a permanently missing callback.
                }
                XCTFail("Expected CancellationError from pre-cancelled task")
            } catch is CancellationError {
                expectation.fulfill()
            }
        }
        cancelledTask.cancel()

        await fulfillment(of: [expectation], timeout: 2)
    }

    // MARK: - 7. Completion never fires: task cancellation releases the caller

    func testNeverFires_taskCancellationReleasesCallerWithCancellationError() async {
        let expectation = XCTestExpectation(description: "withCallbackOnce exits")

        let task = Task {
            do {
                try await withCallbackOnce { _ in
                    // Deliberately never call deliver.
                }
            } catch is CancellationError {
                expectation.fulfill()
            } catch {
                XCTFail("Unexpected error: \(error)")
            }
        }

        try? await Task.sleep(nanoseconds: 5_000_000)
        task.cancel()

        await fulfillment(of: [expectation], timeout: 2)
    }

    // MARK: - 8. Double deliver(): second call is a no-op

    func testDoubleDeliver_secondCallIsNoOp() async throws {
        var resumeCount = 0
        // Use a sentinel to count resumes via a second channel — we cannot
        // observe the continuation directly, so we instead verify the caller
        // returns exactly once and the second deliver does not throw/crash.
        try await withCallbackOnce { deliver in
            deliver(nil)   // first deliver: resumes the continuation
            deliver(nil)   // second deliver: must be a silent no-op
            resumeCount += 1
        }
        XCTAssertEqual(resumeCount, 1, "work closure body must complete once")
    }
}

// MARK: - Test helpers

/// Thread-safe store for the deliver closure passed by withCallbackOnce.
/// Provides an async suspension point (`waitUntilStored`) so tests can wait
/// deterministically until withCallbackOnce has installed the continuation.
///
/// `fire()` captures and invokes deliver OUTSIDE the lock to avoid the
/// reentrancy deadlock that arises when `deliver` internally takes the same
/// `NSLock` (as `ResumeOnceBox` does).
private final class DeliverBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _deliver: ((Error?) -> Void)?
    private var _storedWaiter: CheckedContinuation<Void, Never>?

    func store(_ deliver: @escaping @Sendable (Error?) -> Void) {
        lock.withLock {
            _deliver = deliver
            _storedWaiter?.resume()
            _storedWaiter = nil
        }
    }

    func waitUntilStored() async {
        let already: Bool = lock.withLock { _deliver != nil }
        guard !already else { return }
        await withCheckedContinuation { cont in
            lock.withLock {
                if _deliver != nil {
                    cont.resume()
                } else {
                    _storedWaiter = cont
                }
            }
        }
    }

    /// Invokes deliver outside the lock to prevent reentrancy deadlocks.
    func fire(error: Error?) {
        let deliver: ((Error?) -> Void)? = lock.withLock { _deliver }
        deliver?(error)
    }
}

/// Actor-based flag used to await test-task completion across isolation domains.
private actor ExitedFlag {
    private var _isSet = false
    private var _waiter: CheckedContinuation<Void, Never>?

    func set() {
        _isSet = true
        _waiter?.resume()
        _waiter = nil
    }

    func waitUntilSet() async {
        if _isSet { return }
        await withCheckedContinuation { cont in _waiter = cont }
    }
}
