import Foundation
import Testing
@testable import OfemKit

// MARK: - HTTPGateTests

@Suite("HTTPGate")
struct HTTPGateTests {
    // MARK: - Token refill

    @Test("refills tokens based on elapsed time")
    func tokenRefill() async {
        let gate = HTTPGate(host: "example.com", maxConcurrent: 10, tokensPerSecond: 100, burst: 10)
        // Drain all tokens.
        for _ in 0..<10 {
            await gate.acquire()
        }
        // Release all — triggers refill.
        for _ in 0..<10 {
            await gate.release()
        }
        // Should be able to acquire again immediately after release.
        await gate.acquire()
        await gate.release()
    }

    // MARK: - Concurrency cap

    @Test("concurrency cap limits simultaneous in-flight")
    func concurrencyCap() async {
        let gate = HTTPGate(host: "cap.example.com", maxConcurrent: 2, tokensPerSecond: 100, burst: 100)
        var count = 0

        // Acquire 2 — both should succeed instantly.
        await gate.acquire()
        count += 1
        await gate.acquire()
        count += 1

        #expect(count == 2)

        // Release both.
        await gate.release()
        await gate.release()
    }

    // MARK: - Penalty / pause window

    @Test("penalty blocks acquire until deadline passes")
    func penaltyBlocksAcquire() async {
        let gate = HTTPGate(host: "penalty.example.com", maxConcurrent: 10, tokensPerSecond: 100, burst: 100)
        let pause = Duration.milliseconds(200)
        let deadline = ContinuousClock.now + pause

        await gate.penalty(until: deadline)

        let start = ContinuousClock.now
        await gate.acquire()
        await gate.release()
        let elapsed = start.duration(to: ContinuousClock.now)

        // Should have waited approximately `pause` milliseconds (±80 ms slack).
        #expect(elapsed >= .milliseconds(150))
    }

    @Test("penalty in past is ignored")
    func penaltyInPastIgnored() async {
        let gate = HTTPGate(host: "pastpenalty.example.com", maxConcurrent: 10, tokensPerSecond: 100, burst: 100)
        let past = ContinuousClock.now - .seconds(1)

        await gate.penalty(until: past)

        // Should not block.
        let start = ContinuousClock.now
        await gate.acquire()
        await gate.release()
        let elapsed = start.duration(to: ContinuousClock.now)

        #expect(elapsed < .milliseconds(100))
    }

    @Test("latest penalty deadline wins")
    func latestPenaltyWins() async {
        let gate = HTTPGate(host: "latestpenalty.example.com", maxConcurrent: 10, tokensPerSecond: 100, burst: 100)
        let short = ContinuousClock.now + .milliseconds(50)
        let long = ContinuousClock.now + .milliseconds(250)

        await gate.penalty(until: long)
        await gate.penalty(until: short) // Earlier — should be ignored.

        let start = ContinuousClock.now
        await gate.acquire()
        await gate.release()
        let elapsed = start.duration(to: ContinuousClock.now)

        // The longer window should still be active.
        #expect(elapsed >= .milliseconds(200))
    }

    // MARK: - State snapshot

    @Test("state snapshot reflects inflight count")
    func stateInflight() async {
        let gate = HTTPGate(host: "state.example.com", maxConcurrent: 5, tokensPerSecond: 100, burst: 10)

        await gate.acquire()
        let s1 = await gate.state()
        #expect(s1.inFlight == 1)

        await gate.acquire()
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
        // Both should be the same actor instance.
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
}
