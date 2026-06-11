import Foundation
import os.log

// MARK: - GateClock

/// A minimal clock seam for HTTPGate timing.
///
/// The default implementation (`ContinuousGateClock`) delegates to
/// `ContinuousClock`; tests inject `FakeGateClock` to drive time
/// deterministically without wall-clock sleeps.
public protocol GateClock: Sendable {
    /// Returns the current instant.
    func now() -> ContinuousClock.Instant
    /// Suspends the current task for `duration`. Throws `CancellationError` when
    /// the calling task is cancelled.
    func sleep(for duration: Duration) async throws
}

/// Production clock — thin wrapper around `ContinuousClock`.
public struct ContinuousGateClock: GateClock {
    public init() {}

    public func now() -> ContinuousClock.Instant { ContinuousClock.now }
    public func sleep(for duration: Duration) async throws {
        try await Task.sleep(for: duration, clock: ContinuousClock())
    }
}

// MARK: - HTTPGate

/// Per-host concurrency and rate-limit coordinator.
///
/// An `HTTPGate` combines three throttles applied in order on every
/// ``acquire()`` call:
///
/// 1. **Pause window** — if ``penalty(until:)`` was called with a deadline
/// in the future, `acquire` suspends until that deadline passes. All
/// concurrent callers share the same window, so a single 429 stalls
/// every in-flight request against the host.
/// 2. **Concurrency cap** — at most `maxConcurrent` callers may hold the
/// gate simultaneously; further calls suspend until one is released.
/// 3. **Token-bucket QPS budget** — callers leave the gate at
/// `tokensPerSecond` per second (up to `burst`), which smears a wave
/// of post-pause retries rather than releasing them all at once.
///
/// All mutable state lives inside the `actor` body; no external locking is
/// needed by callers.
public actor HTTPGate {
    // MARK: - Configuration

    /// Human-readable host this gate guards (for logging and ``state``).
    public let host: String

    private let maxConcurrent: Int
    private let tokensPerSecond: Double
    private let burst: Int
    private let clock: GateClock

    // MARK: - Token-bucket state

    private var availableTokens: Double
    private var lastRefill: ContinuousClock.Instant

    // MARK: - Concurrency state

    private var inFlight: Int = 0

    // MARK: - Pause-window state

    private var pauseUntil: ContinuousClock.Instant?

    // MARK: - Waiter queues

    /// A waiter entry: a unique ID plus a throwing continuation.
    /// The continuation throws `CancellationError` when the waiter is cancelled.
    private struct Waiter {
        let id: UInt64
        let continuation: CheckedContinuation<Void, Error>
    }

    /// Continuations waiting because `inFlight >= maxConcurrent`.
    private var concurrencyWaiters: [Waiter] = []

    /// Continuations waiting because the token bucket is empty.
    private var tokenWaiters: [Waiter] = []

    /// Monotonically increasing ID source for waiter entries.
    private var nextWaiterID: UInt64 = 0

    /// Whether a timer task has already been scheduled to wake token waiters
    /// at the next refill instant.
    private var refillTaskScheduled: Bool = false

    private static let log = Logger(subsystem: "dev.debruyn.ofem", category: "HTTPGate")

    // MARK: - Initialisers

    /// Constructs an `HTTPGate` for `host`.
    ///
    /// Invalid values are clamped to sensible minimums so callers can pass
    /// zero defaults. Pass a custom `clock` in tests for deterministic timing.
    public init(
        host: String,
        maxConcurrent: Int,
        tokensPerSecond: Double,
        burst: Int,
        clock: GateClock = ContinuousGateClock()
    ) {
        self.host = host
        self.maxConcurrent = max(1, maxConcurrent)
        self.tokensPerSecond = max(0.01, tokensPerSecond)
        self.burst = max(1, burst)
        self.availableTokens = Double(max(1, burst))
        self.lastRefill = clock.now()
        self.clock = clock
    }

    // MARK: - Acquire / Release

    /// Reserves one slot on the gate.
    ///
    /// Suspends until:
    /// - the current pause window (if any) has elapsed,
    /// - the concurrency cap admits one more in-flight caller, and
    /// - the token bucket grants a token.
    ///
    /// The three resources are acquired together at the moment `inFlight` is
    /// incremented, preventing cap overshoot: if a token waiter is parked and
    /// other callers exhaust the concurrency cap while waiting, the cap check
    /// is re-verified before committing.
    ///
    /// Throws `CancellationError` if the calling `Task` is cancelled while
    /// waiting in any of the three phases. Call ``release()`` only after a
    /// successful (non-throwing) return.
    ///
    /// Call ``release()`` exactly once when the round trip completes —
    /// success or failure.
    public func acquire() async throws {
        // 1. Wait out any pending pause window.
        try await waitForPause()

        // 2 + 3. Acquire one concurrency slot AND one token atomically.
        //
        // The outer loop repeats only when, after being woken from a token
        // wait, the concurrency cap has been consumed by other tasks — we then
        // refund the token and rejoin both queues.
        //
        // Waiting uses withTaskCancellationHandler so a cancelled task is
        // evicted from its queue immediately instead of occupying a dead slot
        // until some future release() happens to wake it.
        outerLoop: while true {
            // 2a. Wait for a concurrency slot.
            while inFlight >= maxConcurrent {
                let id = nextWaiterID
                nextWaiterID &+= 1
                try await withTaskCancellationHandler {
                    try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                        concurrencyWaiters.append(Waiter(id: id, continuation: cont))
                    }
                } onCancel: {
                    Task { [weak self] in
                        await self?.cancelConcurrencyWaiter(id: id)
                    }
                }
                // Re-check: another caller may have slipped in.
            }

            // 2b. Wait for a token.
            //     FIFO: queue even if tokens are available while waiters exist.
            //     When a waiter is woken by drainWaiters(), the token is already
            //     reserved (decremented) by the drain loop — do NOT decrement
            //     again.  On the fast path (no queuing) the caller decrements
            //     the token itself below.
            refill()
            if availableTokens < 1.0 || !tokenWaiters.isEmpty {
                let id = nextWaiterID
                nextWaiterID &+= 1
                scheduleRefillTaskIfNeeded()
                try await withTaskCancellationHandler {
                    try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                        tokenWaiters.append(Waiter(id: id, continuation: cont))
                    }
                } onCancel: {
                    Task { [weak self] in
                        await self?.cancelTokenWaiter(id: id)
                    }
                }
                // drainWaiters() already decremented availableTokens when it
                // woke us — token is reserved; skip the fast-path decrement.

                // 2c. Re-check concurrency cap (net-03).
                if inFlight < maxConcurrent {
                    break outerLoop
                }
                // Cap is full: refund the reserved token and retry.
                availableTokens += 1.0
                scheduleRefillTaskIfNeeded()
                continue outerLoop
            }

            // Fast path: token available and no other waiters ahead.
            availableTokens -= 1.0

            // 2c. Re-check concurrency cap (net-03).
            //
            // A caller parked in tokenWaiters holds no slot. Other callers may
            // have passed step 2a and claimed slots while we waited for the
            // token. If the cap is now full, refund the token and loop back
            // to wait again — this time we will queue as a concurrency waiter
            // and the token queue, in that order, with correct FIFO position.
            if inFlight < maxConcurrent {
                // Both resources secured — exit the loop.
                break outerLoop
            }
            // Cap is full: refund token and retry.
            availableTokens += 1.0
            scheduleRefillTaskIfNeeded()
        }

        // 3. Claim the slot atomically (both checks passed above).
        inFlight += 1

        // 4. Re-check pause after token acquisition — a penalty posted
        // between step 1 and step 2 must still be honoured.
        do {
            try await waitForPause()
        } catch {
            // Undo the inFlight claim and refund the token before propagating
            // so gate state remains consistent.
            inFlight -= 1
            availableTokens = min(availableTokens + 1.0, Double(burst))
            drainWaiters()
            throw error
        }
    }

    /// Releases one concurrency slot.
    ///
    /// Must be called exactly once for every successful ``acquire()``.
    public func release() {
        inFlight -= 1
        refill()
        drainWaiters()
    }

    // MARK: - Penalty

    /// Closes the gate until `deadline`.
    ///
    /// The latest of all posted deadlines wins; a deadline earlier than the
    /// currently stored one is silently dropped. A deadline in the past is
    /// a no-op.
    ///
    /// Does not suspend. Callers waiting in ``acquire()`` will observe the
    /// new pause on their next `waitForPause` iteration.
    public func penalty(until deadline: ContinuousClock.Instant) {
        guard deadline > clock.now() else {
            Self.log.debug("HTTPGate[\(self.host, privacy: .public)]: penalty in past, ignored")
            return
        }
        if let existing = pauseUntil, existing >= deadline {
            return
        }
        pauseUntil = deadline
        Self.log.info("HTTPGate[\(self.host, privacy: .public)]: pause window applied until \(String(describing: deadline), privacy: .public)")
    }

    // MARK: - State snapshot

    /// A point-in-time snapshot of the gate's internal counters.
    ///
    /// Cheap to call; safe to use from a status handler.
    public func state() -> HTTPGateState {
        refill()
        return HTTPGateState(
            host: host,
            pauseUntil: pauseUntil,
            inFlight: inFlight,
            maxConcurrent: maxConcurrent,
            availableTokens: max(0, min(availableTokens, Double(burst))),
            burst: burst,
            tokensPerSecond: tokensPerSecond
        )
    }

    // MARK: - Private helpers

    /// Refills the token bucket based on elapsed time (via the injected clock).
    ///
    /// Called before every token-consumption or drain so the bucket is always
    /// current.
    private func refill() {
        let now = clock.now()
        let elapsed = lastRefill.duration(to: now)
        let elapsedSeconds = Double(elapsed.components.seconds) +
            Double(elapsed.components.attoseconds) * 1e-18
        let newTokens = elapsedSeconds * tokensPerSecond
        if newTokens > 0 {
            availableTokens = min(availableTokens + newTokens, Double(burst))
            lastRefill = now
        }
    }

    /// Wakes suspended concurrency and token waiters that can now proceed.
    ///
    /// Drains as many waiters as the current state permits — not just one per
    /// call — so that when several tokens become available all eligible waiters
    /// are released in FIFO order.
    private func drainWaiters() {
        // Wake concurrency waiters while room exists.
        while inFlight < maxConcurrent, !concurrencyWaiters.isEmpty {
            let w = concurrencyWaiters.removeFirst()
            w.continuation.resume()
        }
        // Wake token waiters while the bucket has tokens.
        // Decrement availableTokens here so the loop condition stays accurate;
        // the waiter's own `availableTokens -= 1.0` then becomes a no-op delta
        // (we compensate by NOT decrementing in acquire after being woken).
        // Simpler: wake at most one waiter per available token, reserving the
        // token now so the woken waiter can proceed without re-checking.
        while availableTokens >= 1.0, !tokenWaiters.isEmpty {
            availableTokens -= 1.0
            let w = tokenWaiters.removeFirst()
            w.continuation.resume()
        }
    }

    /// Ensures a single background task exists that sleeps until the next
    /// token refill instant and then drains token waiters.
    ///
    /// Called whenever a caller parks in `tokenWaiters`. Only one timer task
    /// runs at a time; when it fires it clears the flag so the next waiter
    /// arrival schedules a fresh one if needed.
    private func scheduleRefillTaskIfNeeded() {
        guard !refillTaskScheduled else { return }
        refillTaskScheduled = true
        let tps = tokensPerSecond
        let needed = 1.0 - availableTokens
        // Duration to produce `needed` additional tokens at `tps` rate.
        let waitSeconds = max(needed / tps, 0)
        let waitDuration = Duration.nanoseconds(Int64(waitSeconds * 1_000_000_000))
        let clk = clock
        Task { [weak self] in
            try? await clk.sleep(for: waitDuration)
            await self?.refillTimerFired()
        }
    }

    /// Called by the scheduled refill task when the sleep completes.
    private func refillTimerFired() {
        refillTaskScheduled = false
        refill()
        drainWaiters()
        // If there are still token waiters (e.g. more arrived after the timer
        // was scheduled), reschedule immediately so they are not stranded.
        if !tokenWaiters.isEmpty {
            scheduleRefillTaskIfNeeded()
        }
    }

    /// Evicts a concurrency waiter from the queue and resumes it with
    /// `CancellationError`.
    private func cancelConcurrencyWaiter(id: UInt64) {
        if let idx = concurrencyWaiters.firstIndex(where: { $0.id == id }) {
            let w = concurrencyWaiters.remove(at: idx)
            w.continuation.resume(throwing: CancellationError())
        }
        // If not found, the waiter was already resumed normally — nothing to do.
    }

    /// Evicts a token waiter from the queue and resumes it with
    /// `CancellationError`.
    private func cancelTokenWaiter(id: UInt64) {
        if let idx = tokenWaiters.firstIndex(where: { $0.id == id }) {
            let w = tokenWaiters.remove(at: idx)
            w.continuation.resume(throwing: CancellationError())
        }
    }

    /// Suspends until the pause window has elapsed.
    ///
    /// Loops because a concurrent ``penalty(until:)`` call may extend the
    /// deadline. Throws `CancellationError` immediately when the calling task
    /// is cancelled, mirroring how Go's `waitPause` returns on `ctx.Done()`.
    private func waitForPause() async throws {
        while let until = pauseUntil {
            let now = clock.now()
            guard until > now else {
                pauseUntil = nil
                return
            }
            let waitDuration = now.duration(to: until)
            try await clock.sleep(for: waitDuration)
        // Loop: re-read pauseUntil in case it was extended while we slept.
        }
    }
}

// MARK: - HTTPGateState

/// Point-in-time snapshot of an ``HTTPGate``'s counters.
public struct HTTPGateState: Sendable {
    /// The host this gate guards.
    public let host: String
    /// The current pause deadline; `nil` when not paused.
    public let pauseUntil: ContinuousClock.Instant?
    /// Number of in-flight callers currently holding the gate.
    public let inFlight: Int
    /// Configured upper bound on `inFlight`.
    public let maxConcurrent: Int
    /// Integer number of tokens currently available in the bucket.
    public let availableTokens: Double
    /// Configured upper bound on `availableTokens`.
    public let burst: Int
    /// Configured steady-state throughput.
    public let tokensPerSecond: Double
}

// MARK: - HTTPGateRegistry

/// Process-wide map of host → ``HTTPGate``.
///
/// Pre-register expected hosts via ``register(host:maxConcurrent:tokensPerSecond:burst:)``
/// at startup to get curated budgets. Unknown hosts are lazily created with
/// the configured ``HTTPGateDefaults``.
public actor HTTPGateRegistry {
    // MARK: - State

    private let defaults: HTTPGateDefaults
    private var gates: [String: HTTPGate] = [:]

    // MARK: - Initialisers

    /// Constructs a registry with the given fallback defaults.
    public init(defaults: HTTPGateDefaults) {
        var d = defaults
        d.maxConcurrent = max(1, d.maxConcurrent)
        d.tokensPerSecond = max(0.01, d.tokensPerSecond)
        d.burst = max(1, d.burst)
        self.defaults = d
    }

    /// Constructs a registry pre-seeded with the provided gates.
    ///
    /// Use this initialiser (or the `seeded:` overload of `makeDefault`)
    /// to avoid the registration race where an early `gate(for:)` call
    /// returns an auto-created gate before explicit registration runs.
    init(defaults: HTTPGateDefaults, seeded: [HTTPGate]) {
        var d = defaults
        d.maxConcurrent = max(1, d.maxConcurrent)
        d.tokensPerSecond = max(0.01, d.tokensPerSecond)
        d.burst = max(1, d.burst)
        self.defaults = d
        var map: [String: HTTPGate] = [:]
        for gate in seeded {
            map[gate.host] = gate
        }
        self.gates = map
    }

    // MARK: - Registration

    /// Installs or replaces the gate for `host` with explicit budgets.
    @discardableResult
    public func register(
        host: String,
        maxConcurrent: Int,
        tokensPerSecond: Double,
        burst: Int
    ) -> HTTPGate {
        let g = HTTPGate(host: host, maxConcurrent: maxConcurrent, tokensPerSecond: tokensPerSecond, burst: burst)
        gates[host] = g
        return g
    }

    /// Returns the gate for `host`, creating one with the defaults if none
    /// was previously registered.
    ///
    /// Always returns non-nil.
    public func gate(for host: String) -> HTTPGate {
        if let g = gates[host] { return g }
        let g = HTTPGate(
            host: host,
            maxConcurrent: defaults.maxConcurrent,
            tokensPerSecond: defaults.tokensPerSecond,
            burst: defaults.burst
        )
        gates[host] = g
        return g
    }

    /// The configured defaults, for callers that need to compute a
    /// missing-Retry-After fallback duration.
    public var registryDefaults: HTTPGateDefaults { defaults }

    /// Returns snapshots of all gates, sorted by host.
    public func states() async -> [HTTPGateState] {
        var out: [HTTPGateState] = []
        for (_, gate) in gates {
            await out.append(gate.state())
        }
        return out.sorted { $0.host < $1.host }
    }
}

// MARK: - HTTPGateDefaults

/// Fall-back configuration for gates auto-created by ``HTTPGateRegistry``.
public struct HTTPGateDefaults: Sendable {
    /// In-flight cap for lazily created gates.
    public var maxConcurrent: Int
    /// Steady-state QPS for lazily created gates.
    public var tokensPerSecond: Double
    /// Token-bucket burst capacity for lazily created gates.
    public var burst: Int
    /// Pause applied when the server returns 429/503 with no `Retry-After`
    /// header. Zero disables the fallback.
    public var missingRetryAfter: Duration

    public init(
        maxConcurrent: Int,
        tokensPerSecond: Double,
        burst: Int,
        missingRetryAfter: Duration = .zero
    ) {
        self.maxConcurrent = maxConcurrent
        self.tokensPerSecond = tokensPerSecond
        self.burst = burst
        self.missingRetryAfter = missingRetryAfter
    }
}

// MARK: - Known hosts and default registry

/// Known OneLake DFS host.
public let httpGateHostOneLake = "onelake.dfs.fabric.microsoft.com"

/// Known Fabric REST host.
public let httpGateHostFabric = "api.fabric.microsoft.com"

extension HTTPGateRegistry {
    /// Builds a registry pre-registered with OneLake and Fabric gates using
    /// curated budgets.
    ///
    /// Registration is synchronous: the curated gates are inserted before
    /// this method returns, eliminating the race where early `gate(for:)`
    /// calls return auto-created gates with default budgets.
    public static func makeDefault() -> HTTPGateRegistry {
        let fabricGate = HTTPGate(
            host: httpGateHostFabric,
            maxConcurrent: 8,
            tokensPerSecond: 2,
            burst: 4
        )
        let oneLakeGate = HTTPGate(
            host: httpGateHostOneLake,
            maxConcurrent: 16,
            tokensPerSecond: 8,
            burst: 16
        )
        return HTTPGateRegistry(
            defaults: HTTPGateDefaults(
                maxConcurrent: 8,
                tokensPerSecond: 2,
                burst: 4,
                missingRetryAfter: .seconds(30)
            ),
            seeded: [fabricGate, oneLakeGate]
        )
    }
}
