// CallbackOnceTests.swift
// Tests for withCallbackOnce and ResumeOnceBox: the resume-once guard
// primitives used by signalEnumeratorOnce in ChangeWatcher.
//
// withCallbackOnce and ResumeOnceBox are in-module (OneLake sources are
// compiled directly into this test bundle), so no import is needed.
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
        // BoolBox is @unchecked Sendable so it can be mutated inside a
        // @Sendable work closure without a Swift 6 concurrency error.
        let ran = BoolBox()
        try await withCallbackOnce { deliver in
            ran.set()
            deliver(nil)
        }
        XCTAssertTrue(ran.value, "work closure must have run")
    }

    // MARK: - 2. Normal failure

    func testFailurePath_throwsSuppliedError() async throws {
        struct Sentinel: Error {}
        let ran = BoolBox()
        do {
            try await withCallbackOnce { deliver in
                ran.set()
                deliver(Sentinel())
            }
            XCTFail("Expected withCallbackOnce to throw Sentinel")
        } catch is Sentinel {
            // Expected.
        }
        XCTAssertTrue(ran.value, "work closure must have run before throwing")
    }

    // MARK: - 3. Completion fires first, then task cancelled

    func testCompletionThenCancellation_taskSucceeds_noDoubleResume() async throws {
        let deliverBox = DeliverBox()

        let task = Task<Void, Error> {
            try await withCallbackOnce { deliver in
                deliverBox.store(deliver)
            }
        }

        await deliverBox.waitUntilStored()
        deliverBox.fire(error: nil)
        task.cancel()

        // task must complete successfully (not throw CancellationError)
        try await task.value
    }

    // MARK: - 4. Concurrent race: completion and cancellation simultaneously

    func testConcurrentCompletionAndCancellation_noDoubleResume() async {
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

    func testCancellationBeforeCompletion_callerGetsCancellationError() async {
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

    /// The task is already cancelled before withCallbackOnce is entered.
    /// withTaskCancellationHandler fires onCancel synchronously before the
    /// body, so box.take() in onCancel sees nil (nothing stored yet).
    /// The post-store Task.isCancelled check must self-resume with
    /// CancellationError even when the callback never fires.
    func testPreCancelledTask_callerGetsCancellationError_evenWhenCallbackNeverFires() async {
        let expectation = XCTestExpectation(description: "pre-cancelled task exits")

        let cancelledTask = Task<Void, Error> {
            do {
                try await withCallbackOnce { _ in
                    // Never call deliver.
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
                try await withCallbackOnce { _ in }
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
        let resumeCount = CounterBox()
        try await withCallbackOnce { deliver in
            deliver(nil) // first deliver: resumes the continuation
            deliver(nil) // second deliver: must be a silent no-op
            resumeCount.increment()
        }
        XCTAssertEqual(resumeCount.value, 1, "work closure body must complete once")
    }
}

// MARK: - Test helpers

/// Minimal @unchecked Sendable bool flag for use in @Sendable work closures.
private final class BoolBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = false

    func set() {
        lock.withLock { _value = true }
    }

    var value: Bool {
        lock.withLock { _value }
    }
}

/// Minimal @unchecked Sendable integer counter for use in @Sendable closures.
private final class CounterBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _count = 0

    func increment() {
        lock.withLock { _count += 1 }
    }

    var value: Int {
        lock.withLock { _count }
    }
}

/// Thread-safe store for the deliver closure passed by withCallbackOnce.
/// `fire()` captures and invokes deliver OUTSIDE the lock to avoid the
/// reentrancy deadlock that arises when `deliver` internally takes a lock.
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
