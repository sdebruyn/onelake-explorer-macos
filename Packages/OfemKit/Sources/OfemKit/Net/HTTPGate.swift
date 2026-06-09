import Foundation
import os.log

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

    // MARK: - Token-bucket state

    private var availableTokens: Double
    private var lastRefill: ContinuousClock.Instant

    // MARK: - Concurrency state

    private var inFlight: Int = 0

    // MARK: - Pause-window state

    private var pauseUntil: ContinuousClock.Instant?

    // MARK: - Waiter queues

    /// Continuations waiting because `inFlight >= maxConcurrent`.
    private var concurrencyWaiters: [CheckedContinuation<Void, Never>] = []

    /// Continuations waiting because the token bucket is empty.
    /// Each entry carries the minimum number of tokens required; they are
    /// serviced in FIFO order once a refill makes enough tokens available.
    private var tokenWaiters: [CheckedContinuation<Void, Never>] = []

    private static let log = Logger(subsystem: "dev.debruyn.ofem", category: "HTTPGate")

    // MARK: - Initialisers

    /// Constructs an `HTTPGate` for `host`.
    ///
    /// Invalid values are clamped to sensible minimums so callers can pass
    /// zero defaults.
    public init(host: String, maxConcurrent: Int, tokensPerSecond: Double, burst: Int) {
        self.host = host
        self.maxConcurrent = max(1, maxConcurrent)
        self.tokensPerSecond = max(0.01, tokensPerSecond)
        self.burst = max(1, burst)
        self.availableTokens = Double(max(1, burst))
        self.lastRefill = .now
    }

    // MARK: - Acquire / Release

    /// Reserves one slot on the gate.
    ///
    /// Suspends until:
    /// - the current pause window (if any) has elapsed,
    /// - the concurrency cap admits one more in-flight caller, and
    /// - the token bucket grants a token.
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

        // 2. Wait for a concurrency slot.
        while inFlight >= maxConcurrent {
            try Task.checkCancellation()
            await withCheckedContinuation { continuation in
                concurrencyWaiters.append(continuation)
            }
        }

        // 3. Refill and wait for a token.
        refill()
        while availableTokens < 1.0 {
            try Task.checkCancellation()
            await withCheckedContinuation { continuation in
                tokenWaiters.append(continuation)
            }
            refill()
        }
        availableTokens -= 1.0

        // 4. Claim the concurrency slot before the second pause check so that
        // inFlight is always in sync with how many callers have passed the
        // gate. Without this, a concurrent release() + drainWaiters() during
        // the second waitForPause could allow a second caller past the
        // concurrency-cap while-loop, causing inFlight to exceed maxConcurrent.
        inFlight += 1

        // 5. Re-check pause after token acquisition — a Penalty posted
        // between step 1 and step 3 must still be honoured.
        do {
            try await waitForPause()
        } catch {
            // Undo the inFlight claim before propagating the cancellation so
            // the gate state remains consistent.
            inFlight -= 1
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
        guard deadline > .now else {
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

    /// Refills the token bucket based on elapsed wall-clock time.
    ///
    /// Called before every token-consumption or drain so the bucket is
    /// always current.
    private func refill() {
        let now = ContinuousClock.now
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
    private func drainWaiters() {
        // Wake one concurrency waiter if room has opened.
        if inFlight < maxConcurrent, !concurrencyWaiters.isEmpty {
            let w = concurrencyWaiters.removeFirst()
            w.resume()
        }
        // Wake one token waiter if the bucket has a token.
        if availableTokens >= 1.0, !tokenWaiters.isEmpty {
            let w = tokenWaiters.removeFirst()
            w.resume()
        }
    }

    /// Suspends until the pause window has elapsed.
    ///
    /// Loops because a concurrent ``penalty(until:)`` call may extend the
    /// deadline.
    ///
    /// Throws `CancellationError` immediately when the calling `Task` is
    /// cancelled, mirroring how Go's `waitPause` returns on `ctx.Done()`.
    private func waitForPause() async throws {
        while let until = pauseUntil {
            let now = ContinuousClock.now
            guard until > now else {
                // Pause has elapsed; clear it.
                pauseUntil = nil
                return
            }
            let waitDuration = now.duration(to: until)
            // Propagate CancellationError so callers are not stuck for the
            // full penalty window after their Task is cancelled. This mirrors
            // Go's select { case <-ctx.Done(): return ctx.Err() } in waitPause.
            try await Task.sleep(for: waitDuration, clock: ContinuousClock())
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
    public static func makeDefault() -> HTTPGateRegistry {
        let reg = HTTPGateRegistry(defaults: HTTPGateDefaults(
            maxConcurrent: 8,
            tokensPerSecond: 2,
            burst: 4,
            missingRetryAfter: .seconds(30)
        ))
        // Pre-registration is done via a detached Task because the actor
        // initialiser cannot be `async`. The registry is usable immediately
        // from the caller's perspective; gate creation races are safe because
        // `gate(for:)` is isolated to the actor.
        Task { [reg] in
            // Fabric REST — lower budget (conservative: no published RPS limit).
            await reg.register(host: httpGateHostFabric, maxConcurrent: 8, tokensPerSecond: 2, burst: 4)
            // OneLake DFS — ADLS Gen2 tolerates higher concurrency.
            await reg.register(host: httpGateHostOneLake, maxConcurrent: 16, tokensPerSecond: 8, burst: 16)
        }
        return reg
    }
}
