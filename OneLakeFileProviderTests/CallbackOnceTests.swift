// CallbackOnceTests.swift
// Tests for withCallbackOnce and ResumeOnceBox: the resume-once guard
// primitives used by signalEnumeratorOnce in ContainerSignaller.
//
// withCallbackOnce and ResumeOnceBox are internal so they can be tested here
// without a real NSFileProviderManager.  Tests verify:
//   1. Normal success path resumes the caller once.
//   2. Normal failure path throws the supplied error.
//   3. Completion fires first, cancellation arrives after: no double-resume;
//      task succeeds (guard discards the second path).
//   4. Cancellation arrives before completion fires: caller receives
//      CancellationError; the subsequent deliver() call is a no-op.
//   5. Completion never fires: task cancellation releases the caller.

@testable import OneLakeFileProvider
import XCTest

final class CallbackOnceTests: XCTestCase {

    // MARK: - ResumeOnceBox: take() returns nil when empty

    func testResumeOnceBox_takeReturnsNilWhenEmpty() {
        let box = ResumeOnceBox()
        XCTAssertNil(box.take(), "take() must return nil when no continuation is stored")
    }

    // MARK: - Success

    func testSuccessPath_resumesNormally() async throws {
        try await withCallbackOnce { deliver in
            deliver(nil)
        }
        // Reaching this line without throwing means the test passes.
    }

    // MARK: - Failure

    func testFailurePath_throwsSuppliedError() async {
        struct SentinelError: Error {}
        do {
            try await withCallbackOnce { deliver in
                deliver(SentinelError())
            }
            XCTFail("Expected withCallbackOnce to throw")
        } catch is SentinelError {
            // Expected.
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    // MARK: - Completion then cancellation: no double-resume

    /// The completion handler fires (success), then the task is cancelled.
    /// The onCancel block must observe an already-nil box and be a silent no-op.
    /// If the guard is absent, CheckedContinuation traps on the second resume.
    func testCompletionThenCancellation_noDoubleResume() async throws {
        let deliverBox = DeliverBox()

        let task = Task {
            try await withCallbackOnce { deliver in
                deliverBox.store(deliver)
                // The test fires deliver externally; do NOT call it here.
            }
        }

        await deliverBox.waitUntilStored()

        // Path 1: completion fires successfully.
        deliverBox.fire(error: nil)
        // Path 2: task cancellation — onCancel must observe nil box and skip.
        task.cancel()

        // If the guard is correct the task completed via path 1 without error.
        try await task.value
    }

    // MARK: - Cancellation before completion: CancellationError delivered

    /// The task is cancelled while the completion handler has not yet fired.
    /// The caller must receive CancellationError.  A subsequent deliver() call
    /// (simulating a late fileproviderd callback) must be a no-op.
    func testCancellationBeforeCompletion_callerGetsCancellationError() async {
        let deliverBox = DeliverBox()
        let exited = ExitedFlag()

        let task = Task {
            do {
                try await withCallbackOnce { deliver in
                    deliverBox.store(deliver)
                }
                await exited.set()
            } catch is CancellationError {
                await exited.set()
            }
        }

        await deliverBox.waitUntilStored()

        // Cancel first — onCancel resumes with CancellationError.
        task.cancel()
        await exited.waitUntilSet()

        // Simulate a late deliver() from fileproviderd; must be a no-op.
        deliverBox.fire(error: nil)

        // Give any erroneous delayed effect a chance to surface before ending.
        try? await Task.sleep(nanoseconds: 10_000_000)
    }

    // MARK: - Never fires: task cancellation releases the caller

    /// If the completion handler never fires, cancelling the task must release
    /// the suspended caller with CancellationError (no continuation leak).
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

        // Give the task time to enter withCallbackOnce and suspend.
        try? await Task.sleep(nanoseconds: 5_000_000)
        task.cancel()

        await fulfillment(of: [expectation], timeout: 2)
    }
}

// MARK: - Test helpers

/// Thread-safe store for the deliver closure passed by withCallbackOnce.
/// Provides an async suspension point (`waitUntilStored`) so tests can wait
/// deterministically until withCallbackOnce has installed the continuation.
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

    /// Suspends until `store(_:)` has been called.
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

/// Actor-based flag used to await test completion across isolation domains.
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
