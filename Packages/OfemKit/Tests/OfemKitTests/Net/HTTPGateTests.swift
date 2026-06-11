import Foundation
import Testing
@testable import OfemKit

// MARK: - FakeGateClock

/// Deterministic clock for HTTPGate tests.
///
/// Time only advances when `advance(by:)` is called. All `sleep(for:)` calls
/// park their continuation; advancing time resumes any sleeper whose wake
/// instant has arrived, in deadline order.
final class FakeGateClock: GateClock, @unchecked Sendable {

    // Access to mutable state is serialised through `lock`.
    private let lock = NSLock()

    private var _now: ContinuousClock.Instant
    private var sleepers: [(wakeAt: ContinuousClock.Instant, resume: (Error?) -> Void)] = []

    init(now: ContinuousClock.Instant = ContinuousClock.now) {
        _now = now
    }

    func now() -> ContinuousClock.Instant {
        lock.withLock { _now }
    }

    func sleep(for duration: Duration) async throws {
        let wakeAt = lock.withLock { _now + duration }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                lock.withLock {
                    // If already past, resume immediately.
                    if wakeAt <= _now {
                        cont.resume()
                    } else {
                        sleepers.append((wakeAt: wakeAt, resume: { err in
                            if let e = err { cont.resume(throwing: e) }
                            else { cont.resume() }
                        }))
                        sleepers.sort { $0.wakeAt < $1.wakeAt }
                    }
                }
            }
        } onCancel: {
            // Wake with CancellationError on task cancellation.
            self.lock.withLock {
                let idx = self.sleepers.firstIndex(where: { $0.wakeAt == wakeAt })
                if let idx {
                    let r = self.sleepers.remove(at: idx).resume
                    r(CancellationError())
                }
            }
        }
    }

    /// Advances the fake clock by `delta`, resuming all sleepers whose
    /// deadlines are now past.
    func advance(by delta: Duration) {
        var toResume: [(Error?) -> Void] = []
        lock.withLock {
            _now = _now + delta
            var remaining: [(wakeAt: ContinuousClock.Instant, resume: (Error?) -> Void)] = []
            for s in sleepers {
                if s.wakeAt <= _now {
                    toResume.append(s.resume)
                } else {
                    remaining.append(s)
                }
            }
            sleepers = remaining
        }
        for r in toResume { r(nil) }
    }

    /// Cancels all pending sleepers with `CancellationError`.
    func cancelAll() {
        var all: [(Error?) -> Void] = []
        lock.withLock {
            all = sleepers.map { $0.resume }
            sleepers = []
        }
        for r in all { r(CancellationError()) }
    }
}

// MARK: - HTTPGateTests

@Suite("HTTPGate")
struct HTTPGateTests {

    // MARK: - Token refill (fake clock, asserting)

    @Test("blocked waiter resumes after clock advances past refill instant")
    func tokenRefillResumesWaiter() async throws {
        // 1 token/sec, burst 1, maxConcurrent 10 — drains in one acquire.
        let clock = FakeGateClock()
        let gate = HTTPGate(
            host: "refill.example.com",
            maxConcurrent: 10,
            tokensPerSecond: 1.0,
            burst: 1,
            clock: clock
        )

        // Drain the single burst token — bucket is now empty (no time elapsed → no refill).
        try await gate.acquire()
        await gate.release()

        // Next acquire must block — bucket is empty.
        let resumeFlag = LockedCounter()   // 0 = not resumed, 1 = resumed
        let waiterTask = Task {
            try await gate.acquire()
            resumeFlag.incrementAndLoad()
            await gate.release()
        }

        // Yield briefly so the waiter parks.
        await Task.yield()
        await Task.yield()
        #expect(resumeFlag.load() == 0, "Waiter should not have resumed before clock advance")

        // Advance clock by 1 second — enough to refill 1 token.
        clock.advance(by: .seconds(1))

        // Give the refill-timer task time to fire and wake the waiter.
        try await Task.sleep(for: .milliseconds(50), clock: ContinuousClock())

        try await waiterTask.value
        #expect(resumeFlag.load() == 1, "Waiter must resume after clock advances past refill instant")
    }

    // MARK: - FIFO ordering

    @Test("token waiters are resumed in FIFO order")
    func tokenWaitersFIFO() async throws {
        // burst 1 — single token. Enough concurrency so cap is never the limiter.
        // tps=1: one new token per second.
        let clock = FakeGateClock()
        let gate = HTTPGate(
            host: "fifo.example.com",
            maxConcurrent: 10,
            tokensPerSecond: 1.0,
            burst: 1,
            clock: clock
        )

        // Drain the token so the bucket is empty (burst=1, no time elapsed → no refill).
        try await gate.acquire()
        await gate.release()

        let orderTracker = OrderTracker()

        // Queue two waiters.  t1 parks first, t2 parks second.
        let t1 = Task {
            try await gate.acquire()
            await orderTracker.append(1)
            await gate.release()
        }
        // Small yield so t1 parks before t2.
        await Task.yield()
        let t2 = Task {
            try await gate.acquire()
            await orderTracker.append(2)
            await gate.release()
        }

        await Task.yield()
        await Task.yield()

        // First advance: refills 1 token → wakes t1.
        clock.advance(by: .seconds(1))
        try await Task.sleep(for: .milliseconds(50), clock: ContinuousClock())

        // After t1 acquires and releases, the refill timer for t2 is scheduled
        // for 1 second of fake time. Advance again to wake t2.
        clock.advance(by: .seconds(1))
        try await Task.sleep(for: .milliseconds(100), clock: ContinuousClock())

        try await t1.value
        try await t2.value

        let order = await orderTracker.values
        #expect(order == [1, 2], "Waiters must be resumed in FIFO order; got \(order)")
    }

    // MARK: - Concurrency cap

    @Test("concurrency cap limits simultaneous in-flight with high-water mark")
    func concurrencyCap() async throws {
        let cap = 3
        let gate = HTTPGate(
            host: "cap.example.com",
            maxConcurrent: cap,
            tokensPerSecond: 100,
            burst: 100
        )

        let counter = LockedCounter()
        let hwm = LockedCounter()

        let tasks = (0..<8).map { _ in
            Task {
                try await gate.acquire()
                let current = counter.incrementAndLoad()
                // Track high-water mark.
                var prev = hwm.load()
                while current > prev {
                    let (exchanged, _) = hwm.compareExchange(expected: prev, desired: current)
                    if exchanged { break }
                    prev = hwm.load()
                }
                // Hold briefly so other tasks see the concurrency.
                await Task.yield()
                counter.decrementAndLoad()
                await gate.release()
            }
        }
        for t in tasks { try await t.value }

        let peak = hwm.load()
        #expect(peak <= cap, "Peak in-flight \(peak) exceeded cap \(cap)")
        #expect(peak > 0, "At least one task must have run")
    }

    // MARK: - Cancellation

    @Test("cancellation while queued throws CancellationError and leaves gate intact")
    func cancellationWhileQueued() async throws {
        // burst 1, tps 0.01 (very slow) — first acquire drains the token and
        // the second will be stuck as a token waiter until we cancel it.
        let clock = FakeGateClock()
        let gate = HTTPGate(
            host: "cancel.example.com",
            maxConcurrent: 10,
            tokensPerSecond: 0.01,
            burst: 1,
            clock: clock
        )

        // Drain token (burst=1, no time elapsed → no refill).
        try await gate.acquire()
        await gate.release()

        // This task will queue as a token waiter.
        let waiterTask = Task {
            try await gate.acquire()
        }
        await Task.yield()
        await Task.yield()

        // Cancel it.
        waiterTask.cancel()

        do {
            try await waiterTask.value
            #expect(Bool(false), "Expected CancellationError but got normal return")
        } catch is CancellationError {
            // Expected.
        }

        // Gate must be in a clean state: a subsequent acquire (after advancing
        // time to refill) must succeed without hanging.
        clock.advance(by: .seconds(200))
        try await Task.sleep(for: .milliseconds(50), clock: ContinuousClock())
        try await gate.acquire()
        await gate.release()
    }

    @Test("cancelled concurrency waiter throws CancellationError")
    func cancellationConcurrencyWaiter() async throws {
        // Fill up the concurrency cap.
        let gate = HTTPGate(
            host: "cancelcap.example.com",
            maxConcurrent: 1,
            tokensPerSecond: 100,
            burst: 100
        )

        // Acquire and hold the single slot.
        try await gate.acquire()

        // This task parks as a concurrency waiter.
        let waiterTask = Task {
            try await gate.acquire()
        }
        await Task.yield()
        await Task.yield()

        waiterTask.cancel()

        do {
            try await waiterTask.value
            #expect(Bool(false), "Expected CancellationError but got normal return")
        } catch is CancellationError {
            // Expected.
        }

        // Release the held slot — gate must be usable afterward.
        await gate.release()
        try await gate.acquire()
        await gate.release()
    }

    // MARK: - Penalty / pause window (fake clock)

    @Test("penalty blocks acquire until fake clock advances past deadline")
    func penaltyBlocksAcquireFakeClock() async throws {
        let clock = FakeGateClock()
        let gate = HTTPGate(
            host: "penalty.example.com",
            maxConcurrent: 10,
            tokensPerSecond: 100,
            burst: 100,
            clock: clock
        )
        let deadline = clock.now() + .milliseconds(200)
        await gate.penalty(until: deadline)

        let resumeFlag = LockedCounter()
        let acquireTask = Task {
            try await gate.acquire()
            resumeFlag.incrementAndLoad()
            await gate.release()
        }

        await Task.yield()
        await Task.yield()
        #expect(resumeFlag.load() == 0, "acquire must not complete before penalty deadline")

        clock.advance(by: .milliseconds(200))
        try await Task.sleep(for: .milliseconds(50), clock: ContinuousClock())

        try await acquireTask.value
        #expect(resumeFlag.load() == 1, "acquire must complete after penalty deadline")
    }

    @Test("penalty in past is ignored (fake clock)")
    func penaltyInPastIgnoredFakeClock() async throws {
        let clock = FakeGateClock()
        let gate = HTTPGate(
            host: "pastpenalty.example.com",
            maxConcurrent: 10,
            tokensPerSecond: 100,
            burst: 100,
            clock: clock
        )
        // Deadline is in the past relative to the fake clock.
        let past = clock.now() - .seconds(1)
        await gate.penalty(until: past)

        // acquire must complete without any clock advance.
        try await gate.acquire()
        await gate.release()
    }

    @Test("latest penalty deadline wins (fake clock)")
    func latestPenaltyWinsFakeClock() async throws {
        let clock = FakeGateClock()
        let gate = HTTPGate(
            host: "latestpenalty.example.com",
            maxConcurrent: 10,
            tokensPerSecond: 100,
            burst: 100,
            clock: clock
        )
        let now = clock.now()
        let short = now + .milliseconds(50)
        let long  = now + .milliseconds(500)

        await gate.penalty(until: long)
        await gate.penalty(until: short)   // Earlier — must be ignored.

        let resumeFlag = LockedCounter()
        let acquireTask = Task {
            try await gate.acquire()
            resumeFlag.incrementAndLoad()
            await gate.release()
        }

        await Task.yield()
        await Task.yield()

        // Advance past the short deadline but not the long one.
        clock.advance(by: .milliseconds(100))
        try await Task.sleep(for: .milliseconds(30), clock: ContinuousClock())
        #expect(resumeFlag.load() == 0, "acquire must still be blocked (long deadline not passed)")

        // Now advance past the long deadline.
        clock.advance(by: .milliseconds(500))
        try await Task.sleep(for: .milliseconds(50), clock: ContinuousClock())
        try await acquireTask.value
        #expect(resumeFlag.load() == 1, "acquire must complete after long deadline passes")
    }

    // MARK: - Token not leaked on post-pause cancellation

    @Test("token not leaked when acquire is cancelled after token phase")
    func tokenNotLeakedOnPostPauseCancel() async throws {
        let clock = FakeGateClock()
        let gate = HTTPGate(
            host: "tokenrefund.example.com",
            maxConcurrent: 10,
            tokensPerSecond: 1.0,
            burst: 2,
            clock: clock
        )

        // Post a penalty so acquire will sleep in the second waitForPause.
        let deadline = clock.now() + .milliseconds(500)
        await gate.penalty(until: deadline)

        // Start an acquire — it will pass the token phase then block on the
        // second pause check.
        let t = Task {
            try await gate.acquire()
        }

        await Task.yield()
        await Task.yield()
        t.cancel()

        do {
            try await t.value
            #expect(Bool(false), "Expected CancellationError")
        } catch is CancellationError {
            // Expected.
        }

        // Gate tokens must have been refunded. Advance past penalty so we can
        // verify acquire works normally.
        clock.advance(by: .seconds(1))
        try await Task.sleep(for: .milliseconds(50), clock: ContinuousClock())

        // Both tokens in the burst should be acquirable.
        try await gate.acquire()
        try await gate.acquire()
        await gate.release()
        await gate.release()
    }

    // MARK: - State snapshot

    @Test("state snapshot reflects inflight count")
    func stateInflight() async throws {
        let gate = HTTPGate(host: "state.example.com", maxConcurrent: 5, tokensPerSecond: 100, burst: 10)

        try await gate.acquire()
        let s1 = await gate.state()
        #expect(s1.inFlight == 1)

        try await gate.acquire()
        let s2 = await gate.state()
        #expect(s2.inFlight == 2)

        await gate.release()
        await gate.release()
        let s3 = await gate.state()
        #expect(s3.inFlight == 0)
    }

    // MARK: - Clamping

    @Test("zero maxConcurrent is clamped to 1")
    func clampMaxConcurrent() async {
        let gate = HTTPGate(host: "clamp.example.com", maxConcurrent: 0, tokensPerSecond: 1, burst: 1)
        let s = await gate.state()
        #expect(s.maxConcurrent == 1)
    }

    @Test("zero tokensPerSecond is clamped")
    func clampTokensPerSecond() async {
        let gate = HTTPGate(host: "clampqps.example.com", maxConcurrent: 1, tokensPerSecond: 0, burst: 1)
        let s = await gate.state()
        #expect(s.tokensPerSecond > 0)
    }
}

// MARK: - HTTPGateRegistryTests

@Suite("HTTPGateRegistry")
struct HTTPGateRegistryTests {
    @Test("returns same gate for same host")
    func sameGateForSameHost() async {
        let reg = HTTPGateRegistry(defaults: HTTPGateDefaults(maxConcurrent: 4, tokensPerSecond: 4, burst: 4))
        let g1 = await reg.gate(for: "a.example.com")
        let g2 = await reg.gate(for: "a.example.com")
        #expect(g1 === g2)
    }

    @Test("registered gate takes precedence over auto-created")
    func registeredGateTakesPrecedence() async {
        let reg = HTTPGateRegistry(defaults: HTTPGateDefaults(maxConcurrent: 1, tokensPerSecond: 1, burst: 1))
        let registered = await reg.register(host: "host.example.com", maxConcurrent: 8, tokensPerSecond: 8, burst: 8)
        let fetched = await reg.gate(for: "host.example.com")
        #expect(registered === fetched)
        let s = await fetched.state()
        #expect(s.maxConcurrent == 8)
    }

    @Test("auto-created gate uses defaults")
    func autoCreatedGateUsesDefaults() async {
        let reg = HTTPGateRegistry(defaults: HTTPGateDefaults(maxConcurrent: 3, tokensPerSecond: 3, burst: 3))
        let g = await reg.gate(for: "new.example.com")
        let s = await g.state()
        #expect(s.maxConcurrent == 3)
    }

    @Test("states returns sorted snapshots")
    func statesAreSorted() async {
        let reg = HTTPGateRegistry(defaults: HTTPGateDefaults(maxConcurrent: 2, tokensPerSecond: 2, burst: 2))
        await reg.register(host: "z.example.com", maxConcurrent: 2, tokensPerSecond: 2, burst: 2)
        await reg.register(host: "a.example.com", maxConcurrent: 2, tokensPerSecond: 2, burst: 2)
        await reg.register(host: "m.example.com", maxConcurrent: 2, tokensPerSecond: 2, burst: 2)
        let snapshots = await reg.states()
        let hosts = snapshots.map { $0.host }
        #expect(hosts == hosts.sorted())
    }

    @Test("makeDefault registers curated gates synchronously (no registration race)")
    func makeDefaultRegistersGatesSynchronously() async {
        // makeDefault must return a registry where the OneLake and Fabric gates
        // are already present with their curated budgets — not with defaults —
        // before any async work runs.
        let reg = HTTPGateRegistry.makeDefault()
        let fabricGate = await reg.gate(for: httpGateHostFabric)
        let onelakeGate = await reg.gate(for: httpGateHostOneLake)

        let fs = await fabricGate.state()
        let os = await onelakeGate.state()

        // Curated OneLake budget is 16/8/16; defaults are 8/2/4.
        #expect(os.maxConcurrent == 16, "OneLake gate must have curated maxConcurrent=16, got \(os.maxConcurrent)")
        #expect(os.burst == 16, "OneLake gate must have curated burst=16, got \(os.burst)")

        // Curated Fabric budget: 8/2/4.
        #expect(fs.maxConcurrent == 8, "Fabric gate must have curated maxConcurrent=8, got \(fs.maxConcurrent)")
    }
}

// MARK: - OrderTracker actor for FIFO tests

private actor OrderTracker {
    private var _values: [Int] = []
    func append(_ v: Int) { _values.append(v) }
    var values: [Int] { _values }
}

// MARK: - Minimal lock-backed counter for high-water-mark tracking in tests

/// A lock-backed integer counter, sufficient for HWM tracking in tests.
/// Avoids the need for the Atomics package.
private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int

    init(_ initial: Int = 0) { value = initial }

    func load() -> Int { lock.withLock { value } }

    @discardableResult
    func incrementAndLoad() -> Int {
        lock.withLock {
            value += 1
            return value
        }
    }

    @discardableResult
    func decrementAndLoad() -> Int {
        lock.withLock {
            value -= 1
            return value
        }
    }

    /// Sets the stored value to `desired` if it equals `expected`.
    /// Returns `(exchanged, previousValue)`.
    func compareExchange(expected: Int, desired: Int) -> (exchanged: Bool, original: Int) {
        lock.withLock {
            if value == expected {
                value = desired
                return (true, expected)
            }
            return (false, value)
        }
    }
}
