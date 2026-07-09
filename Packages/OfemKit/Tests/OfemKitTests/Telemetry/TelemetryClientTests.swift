import Foundation
@testable import OfemKit
import Testing

// MARK: - MemoryTelemetrySink

/// An in-memory `TelemetrySink` for testing.
final class MemoryTelemetrySink: TelemetrySink, @unchecked Sendable {
    private let lock = NSLock()
    private var _events: [TelemetryEvent] = []
    var shouldFail = false

    func send(_ events: [TelemetryEvent]) async throws {
        if shouldFail { throw TestSinkError.failed }
        lock.withLock { _events.append(contentsOf: events) }
    }

    func drain() -> [TelemetryEvent] {
        lock.withLock {
            defer { _events = [] }
            return _events
        }
    }

    var count: Int {
        lock.withLock { _events.count }
    }
}

enum TestSinkError: Error { case failed }

// MARK: - PartialRejectSink

/// A sink that always throws `AppInsightsSinkError.partialReject`, returning
/// the `retriable` slice provided at construction time.
final class PartialRejectSink: TelemetrySink, @unchecked Sendable {
    private let lock = NSLock()
    private var _sendCount = 0
    private(set) var lastReceived: [TelemetryEvent] = []

    /// Events returned as retriable on the first send; empty thereafter.
    var firstRetriable: [TelemetryEvent]

    init(firstRetriable: [TelemetryEvent]) {
        self.firstRetriable = firstRetriable
    }

    var sendCount: Int {
        lock.withLock { _sendCount }
    }

    func send(_ events: [TelemetryEvent]) async throws {
        lock.withLock {
            _sendCount += 1
            lastReceived = events
        }
        let retriable = lock.withLock { () -> [TelemetryEvent] in
            defer { firstRetriable = [] }
            return firstRetriable
        }
        guard !retriable.isEmpty else { return }
        throw AppInsightsSinkError.partialReject(
            accepted: events.count - retriable.count,
            received: events.count,
            retriable: retriable
        )
    }
}

// MARK: - BlockingTelemetrySink

/// A `TelemetrySink` whose `send(_:)` parks until either `release()` is
/// called or the enclosing `Task` is cancelled — used to deterministically
/// exercise the "opt-out lands while a flush is already mid-send" race
/// (`TelemetryClient` is a reentrant actor, so this window is real; see
/// `setOptOutCancelsInFlightSend` below). `MemoryTelemetrySink.send` returns
/// instantly and can never be caught mid-flight.
///
/// Cancellation is observed cooperatively via `Task.isCancelled`, matching
/// how the real `AppInsightsSink` observes cancellation through
/// `URLSession`'s async API — no `withTaskCancellationHandler` needed for
/// a polling loop this short-lived.
final class BlockingTelemetrySink: TelemetrySink, @unchecked Sendable {
    private let lock = NSLock()
    private var _sendStartedCount = 0
    private var _released = false
    private var _delivered: [TelemetryEvent] = []
    private var _cancelledCount = 0

    /// `true` once at least one `send(_:)` call has started and is parked,
    /// waiting.
    var sendStarted: Bool {
        lock.withLock { _sendStartedCount > 0 }
    }

    /// Number of `send(_:)` calls that have started (parked or since
    /// unblocked) — lets a test wait for N concurrent flushes to all be
    /// mid-send, not just "at least one" (#391 regression coverage below).
    var sendStartedCount: Int {
        lock.withLock { _sendStartedCount }
    }

    /// Events that reached the "delivered" branch (i.e. were NOT cancelled).
    var delivered: [TelemetryEvent] {
        lock.withLock { _delivered }
    }

    /// `true` if at least one parked `send(_:)` observed cancellation.
    var wasCancelled: Bool {
        lock.withLock { _cancelledCount > 0 }
    }

    /// Number of parked `send(_:)` calls that observed cancellation — used to
    /// prove that ALL concurrent sends were cancelled, not just one (#391).
    var cancelledCount: Int {
        lock.withLock { _cancelledCount }
    }

    /// Unblocks every parked `send(_:)` so each proceeds to "deliver" its events.
    func release() {
        lock.withLock { _released = true }
    }

    func send(_ events: [TelemetryEvent]) async throws {
        lock.withLock { _sendStartedCount += 1 }
        while true {
            if Task.isCancelled {
                lock.withLock { _cancelledCount += 1 }
                throw CancellationError()
            }
            if lock.withLock({ _released }) { break }
            try? await Task.sleep(for: .milliseconds(5))
        }
        lock.withLock { _delivered.append(contentsOf: events) }
    }
}

// MARK: - Tests

@Suite("TelemetryClient")
struct TelemetryClientTests {
    private func makeClient(
        sink: any TelemetrySink,
        maxBatchSize: Int = 1000,
        flushInterval: Duration = .seconds(3600),
        configuration: TelemetryConfiguration? = nil
    ) -> TelemetryClient {
        let config = configuration ?? TelemetryConfiguration(
            maxBatchSize: maxBatchSize,
            flushInterval: flushInterval,
            osVersion: "14.5.1",
            platform: "darwin",
            arch: "arm64"
        )
        return TelemetryClient(
            sink: sink,
            appVersion: "2026.05.1",
            installID: "test-install-id",
            configuration: config
        )
    }

    @Test("track merges common properties into the event")
    func trackMergesCommonProps() async {
        let sink = MemoryTelemetrySink()
        let client = makeClient(sink: sink)

        await client.track(TelemetryEvent(name: "app_start"))
        await client.flush()

        let events = sink.drain()
        #expect(events.count == 1)
        let ev = events[0]
        #expect(ev.commonProps["installId"] == "test-install-id")
        #expect(ev.commonProps["appVersion"] == "2026.05.1")
        #expect(ev.commonProps["platform"] == "darwin")
        #expect(ev.commonProps["arch"] == "arm64")
        #expect(ev.commonProps["osVersion"] == "14.5.1")
    }

    @Test("track sets timestamp when not provided")
    func trackSetsTimestamp() async {
        let sink = MemoryTelemetrySink()
        let client = makeClient(sink: sink)

        await client.track(TelemetryEvent(name: "app_start"))
        await client.flush()

        let ev = sink.drain().first
        #expect(ev?.time != nil)
    }

    // tests-20: noopSinkDiscards was removed — it only verified "no crash" and
    // could not assert that events were actually discarded (NoopTelemetrySink has
    // no observable state). The opt-out path is already covered by optOutUsesNoop
    // below, which asserts sink.count == 0 on a MemoryTelemetrySink.

    @Test("optOut configuration uses NoopTelemetrySink regardless of sink")
    func optOutUsesNoop() async {
        let sink = MemoryTelemetrySink()
        let config = TelemetryConfiguration(optOut: true, osVersion: "14.5.1")
        let client = TelemetryClient(
            sink: sink,
            appVersion: "2026.05.1",
            installID: "x",
            configuration: config
        )
        await client.track(TelemetryEvent(name: "app_start"))
        await client.flush()
        #expect(sink.count == 0, "opt-out client must not send to real sink")
    }

    // MARK: - Live opt-out (F4/A1: telemetry opt-out takes effect without restart)

    @Test("setOptOut(true) stops subsequent track() calls from reaching the sink")
    func setOptOutTrueStopsFutureTracking() async {
        let sink = MemoryTelemetrySink()
        let client = makeClient(sink: sink)

        // Telemetry starts enabled — a track() before opt-out reaches the sink.
        await client.track(TelemetryEvent(name: "before_opt_out"))
        await client.flush()
        #expect(sink.count == 1)

        await client.setOptOut(true)

        // No restart, no new TelemetryClient — the same actor instance now
        // drops every subsequent track() call.
        await client.track(TelemetryEvent(name: "after_opt_out"))
        await client.flush()
        #expect(sink.count == 1, "setOptOut(true) must stop further events from reaching the sink")
    }

    @Test("setOptOut(true) discards events already buffered but not yet flushed")
    func setOptOutTrueDropsBufferedEvents() async {
        let sink = MemoryTelemetrySink()
        // Long flush interval so the background timer cannot race the assertion.
        let client = makeClient(sink: sink, flushInterval: .seconds(3600))

        await client.track(TelemetryEvent(name: "queued_before_opt_out"))
        await client.setOptOut(true)
        await client.flush()

        #expect(sink.count == 0, "events queued before opt-out must not survive a post-opt-out flush")
    }

    @Test("setOptOut(false) re-enables tracking after a live opt-out")
    func setOptOutFalseReenablesTracking() async {
        let sink = MemoryTelemetrySink()
        let client = makeClient(sink: sink)

        await client.setOptOut(true)
        await client.track(TelemetryEvent(name: "dropped"))
        await client.flush()
        #expect(sink.count == 0)

        await client.setOptOut(false)
        await client.track(TelemetryEvent(name: "resumed"))
        await client.flush()
        #expect(sink.count == 1)
    }

    // MARK: - reconfigureSink (M3: runtime opt-in must swap off NoopTelemetrySink, #428)

    @Test("reconfigureSink(optOut: false) swaps an opted-out client's sink for a live one and starts flushing")
    func reconfigureSinkOptInSwapsNoopForLiveSink() async {
        // Models the exact bug (#428): a client memoized opted-out at launch
        // (`TelemetryConfiguration(optOut: true)`) the same way
        // `FPEEngineHost.sharedTelemetry()` does when `cfg.telemetry == false`
        // at first construction. `setOptOut(false)` alone (the pre-fix
        // behaviour) would flip the flag but leave the client parked on
        // whatever sink it was opted out with, and `start()` never having
        // launched a flush timer — track()+flush() would still silently
        // discard every event.
        let sink = MemoryTelemetrySink()
        let client = TelemetryClient(
            sink: sink,
            appVersion: "2026.06.1",
            installID: "x",
            configuration: TelemetryConfiguration(optOut: true, flushInterval: .seconds(3600))
        )

        let liveSink = MemoryTelemetrySink()
        await client.reconfigureSink(optOut: false) { liveSink }

        await client.track(TelemetryEvent(name: "resumed_after_opt_in"))
        await client.flush()

        #expect(sink.count == 0, "the original construction-time sink must never receive events post-swap")
        #expect(liveSink.count == 1, "reconfigureSink(optOut: false) must swap in the live sink and resume emitting")
    }

    @Test("reconfigureSink(optOut: false) does not rebuild the sink when one is already live")
    func reconfigureSinkOptInIsNoopWhenAlreadyLive() async {
        let sink = MemoryTelemetrySink()
        let client = makeClient(sink: sink) // opted-in by default, live sink from construction

        // If reconfigureSink wrongly rebuilt the sink on every reload, events
        // tracked afterwards would land here instead of `sink` (#428:
        // "no duplicate/second sink is started when telemetry was already on").
        let poison = MemoryTelemetrySink()
        await client.reconfigureSink(optOut: false) { poison }

        await client.track(TelemetryEvent(name: "still_original_sink"))
        await client.flush()
        #expect(sink.count == 1, "the original sink must still be in use")
        #expect(poison.count == 0, "makeLiveSink's result must not be installed when the sink is already live")
    }

    @Test("reconfigureSink(optOut: true) swaps the live sink to Noop and stops emission")
    func reconfigureSinkOptOutSwapsToNoop() async {
        let sink = MemoryTelemetrySink()
        let client = makeClient(sink: sink)

        await client.track(TelemetryEvent(name: "before_opt_out"))
        await client.flush()
        #expect(sink.count == 1)

        // The opt-out branch must never call makeLiveSink — if it did, this
        // poison sink would prove it by staying reachable through `sink`.
        let poison = MemoryTelemetrySink()
        await client.reconfigureSink(optOut: true) { poison }

        await client.track(TelemetryEvent(name: "after_opt_out"))
        await client.flush()
        #expect(sink.count == 1, "no new events must reach the original sink after opt-out")
        #expect(poison.count == 0, "the opt-out branch must never call makeLiveSink")
    }

    @Test("SinkState survives heavy concurrent opt-out/opt-in interleaving without corruption (#428 follow-up smoke test)")
    func reconfigureSinkConcurrentInterleavingStaysConsistent() async {
        // NOT a regression test: it would not have failed against the
        // pre-fix, two-field (`sink` + `optOut`) implementation either.
        // Independent review of #435 found a real reentrancy window there:
        // the opt-out branch called `await setOptOut(true)` — which
        // suspends at a cross-actor `await batch.drain()` — and only AFTER
        // that resumed did it separately write `sink = NoopTelemetrySink()`,
        // so a concurrent, all-synchronous opt-in call could land inside
        // that suspension and have its work clobbered on resume. But the
        // introspection this test reads (`sinkIsNoopForTesting`) and the
        // actual delivery target `flush()` uses were BOTH derived from the
        // very same field either way — `sink` pre-fix, `sinkState`
        // post-fix — so they can never independently disagree with each
        // other from outside the actor, in either version. Reproducing the
        // actual torn state (`optOut == false` while `sink is
        // NoopTelemetrySink`) would require re-introducing the old
        // two-field design by hand, which defeats the point: the fix's
        // whole value is that this state is now structurally
        // unrepresentable, not merely avoided by careful sequencing.
        //
        // What this test DOES verify: that firing opposite-valued
        // `reconfigureSink` calls concurrently, many times, never corrupts
        // `sinkState` into something where the enabled/live-sink invariant
        // fails to hold, and never crashes or deadlocks. Run many
        // iterations — actor scheduling is nondeterministic, so a single
        // run does not exercise every interleaving.
        for _ in 0 ..< 50 {
            let constructionSink = MemoryTelemetrySink()
            let client = TelemetryClient(
                sink: constructionSink,
                appVersion: "2026.06.1",
                installID: "race-test",
                configuration: TelemetryConfiguration(flushInterval: .seconds(3600))
            )

            // Both `makeLiveSink` closures return the SAME object, so no
            // matter which call's opt-in branch actually wins the race, a
            // successful delivery is observable through one fixed reference.
            let sharedLiveSink = MemoryTelemetrySink()
            async let optOutCall: Void = client.reconfigureSink(optOut: true) { sharedLiveSink }
            async let optInCall: Void = client.reconfigureSink(optOut: false) { sharedLiveSink }
            _ = await (optOutCall, optInCall)

            // Whichever call landed last, the client must be internally
            // consistent: "enabled" (non-Noop) implies a tracked event is
            // actually delivered; "opted out" implies nothing is.
            let isNoop = await client.sinkIsNoopForTesting
            await client.track(TelemetryEvent(name: "probe"))
            await client.flush()

            if isNoop {
                #expect(sharedLiveSink.count == 0, "reported opted-out but an event still reached the live sink")
            } else {
                #expect(sharedLiveSink.count == 1, "reported enabled but the probe event was never delivered")
            }
        }
    }

    @Test("setOptOut(true) cancels a flush already parked inside sink.send")
    func setOptOutCancelsInFlightSend() async throws {
        // Reproduces the reentrancy window: flush() drains the buffer and
        // calls sink.send BEFORE setOptOut(true) runs, so the post-drain
        // `!optOut` check in flush() cannot see it — only cancelling the
        // in-flight send closes this window.
        let sink = BlockingTelemetrySink()
        let client = makeClient(sink: sink, flushInterval: .seconds(3600))

        await client.track(TelemetryEvent(name: "in_flight"))

        // Run flush() concurrently so the test can observe it parked mid-send
        // (a plain `await client.flush()` here would deadlock the test itself).
        let flushTask = Task { await client.flush() }

        // Deterministic poll for "send() has started" — no fixed sleep-and-hope.
        while !sink.sendStarted {
            try await Task.sleep(for: .milliseconds(5))
        }

        await client.setOptOut(true)
        await flushTask.value

        #expect(sink.wasCancelled, "the parked send() must observe cancellation from setOptOut(true)")
        #expect(sink.delivered.isEmpty, "a cancelled send must not have delivered any events")

        // And the ordinary post-opt-out guarantee still holds on top of this.
        await client.track(TelemetryEvent(name: "after_opt_out"))
        await client.flush()
        #expect(sink.delivered.isEmpty)
    }

    @Test("setOptOut(true) cancels ALL concurrently in-flight sends, not just one slot's worth (#391)")
    func setOptOutCancelsAllConcurrentInFlightSends() async throws {
        // #391: flush() used to stash its send Task in a single shared slot.
        // A reentrant second flush() (TelemetryClient is a reentrant actor)
        // overwrote that slot with its own Task; the FIRST flush's `defer`
        // then nil'd out the SECOND flush's handle, so setOptOut(true) could
        // cancel at most one of two concurrently in-flight sends. The fix
        // keys `inFlightSendTasks` by a per-call generation so each flush
        // owns its own slot — this proves setOptOut cancels both.
        let sink = BlockingTelemetrySink()
        let client = makeClient(sink: sink, flushInterval: .seconds(3600))

        await client.track(TelemetryEvent(name: "batch_a"))
        let flushA = Task { await client.flush() }

        // Wait for the first flush to be parked in sink.send before starting
        // the second, so the two sends are provably concurrent, not just
        // sequential flushes racing ahead of each other.
        while sink.sendStartedCount < 1 {
            try await Task.sleep(for: .milliseconds(5))
        }

        await client.track(TelemetryEvent(name: "batch_b"))
        let flushB = Task { await client.flush() }

        // Wait for both sends to be parked mid-send.
        while sink.sendStartedCount < 2 {
            try await Task.sleep(for: .milliseconds(5))
        }

        await client.setOptOut(true)
        await flushA.value
        await flushB.value

        #expect(sink.cancelledCount == 2, "both concurrent sends must observe cancellation, not just one")
        #expect(sink.delivered.isEmpty, "no events from either flush may have been delivered")
    }

    @Test("buffer overflow triggers immediate flush so no events are dropped (store-18)")
    func bufferOverflowTriggersFlush() async {
        let sink = MemoryTelemetrySink()
        // maxBatchSize=3: filling the buffer triggers an immediate flush (store-18),
        // so events accumulate across flushes instead of being dropped.
        let client = makeClient(sink: sink, maxBatchSize: 3)

        for i in 0 ..< 5 {
            await client.track(TelemetryEvent(name: "ev\(i)"))
        }
        // Final flush for any remaining events.
        await client.flush()

        let events = sink.drain()
        // All 5 events must arrive (buffer-full → immediate flush, no drop).
        #expect(events.count == 5)
        let names = events.map { $0.name }
        for i in 0 ..< 5 {
            #expect(names.contains("ev\(i)"), "ev\(i) should have been flushed")
        }
    }

    @Test("shutdown performs final flush")
    func shutdownFlushes() async {
        let sink = MemoryTelemetrySink()
        let client = makeClient(sink: sink)
        await client.start()
        await client.track(TelemetryEvent(name: "app_stop"))
        await client.shutdown()
        #expect(sink.count == 1)
    }

    @Test("track after shutdown is a no-op")
    func trackAfterShutdownIsNoop() async {
        let sink = MemoryTelemetrySink()
        let client = makeClient(sink: sink)
        await client.start()
        await client.shutdown()
        await client.track(TelemetryEvent(name: "extra"))
        #expect(sink.count == 0, "post-shutdown Track must not enqueue events")
    }

    @Test("trackError emits error event with domain:code error code (store-19)")
    func trackError() async {
        let sink = MemoryTelemetrySink()
        let client = makeClient(sink: sink)
        // store-19: domain+code must survive redaction (not become "redacted").
        await client.trackError(NSError(domain: "BoomError", code: 42), op: "file_download")
        await client.flush()

        let events = sink.drain()
        #expect(events.count == 1)
        #expect(events[0].name == "error")
        #expect(events[0].commonProps["failedOp"] == "file_download")
        // Domain:code format — no localizedDescription, no "redacted".
        #expect(events[0].errorCode == "BoomError:42",
                "errorCode must be domain:numeric code, not a redacted description")
    }

    @Test("flush re-queues events on send failure")
    func flushRequeuesOnFailure() async {
        let sink = MemoryTelemetrySink()
        sink.shouldFail = true
        let client = makeClient(sink: sink, flushInterval: .seconds(3600))

        await client.track(TelemetryEvent(name: "ev1"))
        await client.track(TelemetryEvent(name: "ev2"))

        // First flush fails — events must be re-queued.
        await client.flush()
        #expect(sink.count == 0)

        // Fix the sink and flush again — should get both events.
        sink.shouldFail = false
        await client.flush()
        let events = sink.drain()
        #expect(events.count == 2)
        #expect(events[0].name == "ev1")
        #expect(events[1].name == "ev2")
    }

    @Test("track drops unknown CommonProp keys (key-level allowlist)")
    func trackDropsUnknownKeys() async {
        let sink = MemoryTelemetrySink()
        let client = makeClient(sink: sink)

        await client.track(TelemetryEvent(
            name: "error",
            commonProps: [
                "failedOp": "file_download", // allowed
                "unknownKey": "some-value", // NOT in allowlist
                "workspaceName": "SalesData", // NOT in allowlist
            ]
        ))
        await client.flush()

        let events = sink.drain()
        #expect(events.count == 1)
        let props = events[0].commonProps

        #expect(props["failedOp"] == "file_download", "allowed key must survive")
        #expect(props["unknownKey"] == nil, "unknown key must be dropped")
        #expect(props["workspaceName"] == nil, "unknown key must be dropped")
        // Standard common props injected by client must be present.
        #expect(props["installId"] == "test-install-id")
    }

    @Test("track does not mutate caller's commonProps map")
    func trackDoesNotMutateCallerMap() async {
        let sink = MemoryTelemetrySink()
        let client = makeClient(sink: sink)

        let callerProps = ["failedOp": "op"]
        await client.track(TelemetryEvent(name: "error", commonProps: callerProps))

        // The original dict must be unchanged.
        #expect(callerProps.count == 1)
        #expect(callerProps["installId"] == nil)
    }

    @Test("permanently-retriable event is dropped after maxRetries flushes (store-20 bounded retries)")
    func permanentRetriableEventDroppedAfterMaxRetries() async {
        // A sink that always fails forces events back into the buffer on
        // every flush. After TelemetryEvent.maxRetries re-queues the event
        // must be silently dropped and never reach the sink.
        let sink = MemoryTelemetrySink()
        sink.shouldFail = true
        let client = makeClient(sink: sink, flushInterval: .seconds(3600))

        await client.track(TelemetryEvent(name: "stuck_event"))

        // Flush (maxRetries + 1) times: the last flush should find an empty
        // buffer because the event was dropped after maxRetries re-queues.
        for _ in 0 ..< (TelemetryEvent.maxRetries + 1) {
            await client.flush()
        }

        // Now let the sink succeed — any remaining event would arrive here.
        sink.shouldFail = false
        await client.flush()

        #expect(
            sink.count == 0,
            "event must be dropped after \(TelemetryEvent.maxRetries) retries, not re-queued indefinitely"
        )
    }

    // MARK: - opt-out / disabled path

    @Test("opt-out client never sends events to the real sink after start+flush+shutdown")
    func optOutNeverSendsAfterLifecycle() async {
        let sink = MemoryTelemetrySink()
        let config = TelemetryConfiguration(
            optOut: true,
            osVersion: "14.5.1",
            platform: "darwin",
            arch: "arm64"
        )
        let client = TelemetryClient(
            sink: sink,
            appVersion: "2026.06.1",
            installID: "x",
            configuration: config
        )
        await client.start()
        await client.track(TelemetryEvent(name: "purchase"))
        await client.track(TelemetryEvent(name: "app_stop"))
        await client.flush()
        await client.shutdown()
        // Real sink must have received nothing — Noop swallows everything.
        #expect(sink.count == 0, "opt-out must never deliver events to the real sink")
    }

    @Test("opt-out client start is a no-op (NoopTelemetrySink guard)")
    func optOutStartIsNoop() async {
        // start() must return without launching a flush task when the effective
        // sink is NoopTelemetrySink.  We verify by checking that a second
        // start() call doesn't panic and that no events leak.
        let sink = MemoryTelemetrySink()
        let config = TelemetryConfiguration(optOut: true, osVersion: "14.5.1")
        let client = TelemetryClient(
            sink: sink,
            appVersion: "2026.06.1",
            installID: "x",
            configuration: config
        )
        // Call start() twice — must be idempotent and must not crash.
        await client.start()
        await client.start()
        await client.track(TelemetryEvent(name: "ev"))
        #expect(sink.count == 0)
    }

    // MARK: - shutdown idempotency

    @Test("shutdown is idempotent — second call is a no-op")
    func shutdownIdempotent() async {
        let sink = MemoryTelemetrySink()
        let client = makeClient(sink: sink)
        await client.start()
        await client.track(TelemetryEvent(name: "ev"))
        await client.shutdown()
        // Second shutdown must not flush again or crash.
        await client.shutdown()
        // Exactly one event must have arrived (from the first shutdown flush).
        let events = sink.drain()
        #expect(events.count == 1)
    }

    // MARK: - flush with empty buffer

    @Test("flush with empty buffer never calls sink.send")
    func flushEmptyBufferIsNoop() async {
        let sink = MemoryTelemetrySink()
        let client = makeClient(sink: sink)
        // No events tracked — flush should be a true no-op.
        await client.flush()
        await client.flush()
        #expect(sink.count == 0, "sink.send must not be called for an empty buffer")
    }

    // MARK: - timestamp preservation

    @Test("track preserves a caller-supplied timestamp")
    func trackPreservesTimestamp() async {
        let sink = MemoryTelemetrySink()
        let client = makeClient(sink: sink)
        let fixed = Date(timeIntervalSince1970: 1_000_000_000)
        await client.track(TelemetryEvent(name: "ev", time: fixed))
        await client.flush()
        let ev = sink.drain().first
        #expect(ev?.time == fixed, "client must not overwrite a caller-provided timestamp")
    }

    // MARK: - platform / arch / osVersion defaults

    @Test("empty platform defaults to 'darwin'")
    func emptyPlatformDefaultsDarwin() async {
        let sink = MemoryTelemetrySink()
        let config = TelemetryConfiguration(osVersion: "14.5.1", platform: "", arch: "arm64")
        let client = TelemetryClient(
            sink: sink, appVersion: "v", installID: "i", configuration: config
        )
        await client.track(TelemetryEvent(name: "ev"))
        await client.flush()
        let ev = sink.drain().first
        #expect(ev?.commonProps["platform"] == "darwin")
    }

    @Test("empty arch defaults to 'arm64'")
    func emptyArchDefaultsArm64() async {
        let sink = MemoryTelemetrySink()
        let config = TelemetryConfiguration(osVersion: "14.5.1", platform: "darwin", arch: "")
        let client = TelemetryClient(
            sink: sink, appVersion: "v", installID: "i", configuration: config
        )
        await client.track(TelemetryEvent(name: "ev"))
        await client.flush()
        let ev = sink.drain().first
        #expect(ev?.commonProps["arch"] == "arm64")
    }

    @Test("empty osVersion is filled from ProcessInfo (non-empty result)")
    func emptyOsVersionFallsBackToProcessInfo() async {
        let sink = MemoryTelemetrySink()
        let config = TelemetryConfiguration(osVersion: "", platform: "darwin", arch: "arm64")
        let client = TelemetryClient(
            sink: sink, appVersion: "v", installID: "i", configuration: config
        )
        await client.track(TelemetryEvent(name: "ev"))
        await client.flush()
        let ev = sink.drain().first
        let osVer = ev?.commonProps["osVersion"] ?? ""
        #expect(!osVer.isEmpty, "osVersion must be resolved from ProcessInfo when configuration provides empty string")
        // Must be in X.Y.Z format — no spaces, only digits and dots.
        #expect(osVer.split(separator: ".").count >= 2, "osVersion must be a dotted version string: \(osVer)")
    }

    // MARK: - commonProps client-value injection

    @Test("client commonProps fill gaps but do not override caller-provided allowed keys")
    func clientPropsDoNotOverrideCallerAllowedKeys() async {
        // The merge rule in track(): caller value is inserted first; client
        // value is only written when merged[k] == nil.
        // "failedOp" is in the allowlist, so a caller value survives.
        let sink = MemoryTelemetrySink()
        let client = makeClient(sink: sink)
        await client.track(TelemetryEvent(
            name: "error",
            commonProps: ["failedOp": "my_op"]
        ))
        await client.flush()
        let ev = sink.drain().first
        #expect(ev?.commonProps["failedOp"] == "my_op", "caller-supplied allowed key must be preserved")
        // installId must still come from the client.
        #expect(ev?.commonProps["installId"] == "test-install-id")
    }

    // MARK: - trackError redaction

    @Test("trackError redacts UPN in NSError domain — only domain:code reaches the sink (store-19)")
    func trackErrorRedactsUPNInDomain() async {
        // If someone creates an NSError whose domain happens to look like a
        // UPN ("user@example.com"), the resulting "user@example.com:42"
        // contains "@" which is not in the safe charset, so safeErrorCode
        // collapses it to "redacted".
        let sink = MemoryTelemetrySink()
        let client = makeClient(sink: sink)
        let error = NSError(domain: "user@example.com", code: 42)
        await client.trackError(error, op: "sync")
        await client.flush()

        let events = sink.drain()
        #expect(events.count == 1)
        // The "@" in the domain makes the composite "user@example.com:42"
        // fail the safe-charset check → "redacted".
        #expect(events[0].errorCode == "redacted",
                "UPN-like domain:code must be redacted; got '\(events[0].errorCode)'")
    }

    @Test("trackError with safe domain:code passes through unchanged (store-19)")
    func trackErrorSafeDomainCode() async {
        let sink = MemoryTelemetrySink()
        let client = makeClient(sink: sink)
        let error = NSError(domain: "NSURLErrorDomain", code: -1001)
        await client.trackError(error, op: "download")
        await client.flush()

        let events = sink.drain()
        #expect(events.count == 1)
        #expect(events[0].errorCode == "NSURLErrorDomain:-1001",
                "safe domain:code must not be redacted; got '\(events[0].errorCode)'")
        #expect(events[0].commonProps["failedOp"] == "download")
    }

    @Test("trackError does not emit UPN, workspace name, or file path (redaction invariant)")
    func trackErrorNoPIILeaks() async {
        // Construct an error whose localizedDescription would contain PII
        // (workspace name, file path). TelemetryClient must not forward it.
        let sink = MemoryTelemetrySink()
        let client = makeClient(sink: sink)
        let error = NSError(
            domain: "OfemSyncError",
            code: 403,
            userInfo: [NSLocalizedDescriptionKey: "Access denied for workspace 'SalesData' at /path/to/file.parquet"]
        )
        await client.trackError(error, op: "file_download")
        await client.flush()

        let events = sink.drain()
        #expect(events.count == 1)
        let code = events[0].errorCode
        // Must be "OfemSyncError:403" (safe) or "redacted" — never the localizedDescription.
        let piiTerms = ["SalesData", "workspace", "file.parquet", "/path"]
        for term in piiTerms {
            #expect(!code.contains(term),
                    "errorCode must not contain PII term '\(term)': got '\(code)'")
        }
    }

    // MARK: - partialReject re-queue in flush (store-20)

    @Test("flush re-queues only retriable events on partialReject (store-20)")
    func flushRequeuesOnPartialReject() async {
        // PartialRejectSink returns events[1] as retriable on first send.
        // On the second send (after re-queue) it succeeds.
        let events: [TelemetryEvent] = [
            TelemetryEvent(name: "ev0"),
            TelemetryEvent(name: "ev1_retriable"),
        ]
        let sink = PartialRejectSink(firstRetriable: [events[1]])
        let client = makeClient(sink: sink)

        // Enqueue and flush — first flush triggers partialReject.
        for ev in events {
            await client.track(ev)
        }
        await client.flush()

        // The retriable event (ev1) was re-queued; flush again to deliver it.
        await client.flush()

        // ev0 was accepted on first send; ev1 was re-queued and sent on second send.
        #expect(sink.sendCount == 2, "sink should have been called twice")
        // Last send should carry only the re-queued event.
        #expect(sink.lastReceived.count == 1)
        #expect(sink.lastReceived[0].name == "ev1_retriable")
    }

    @Test("flush does NOT re-queue on non-partialReject error (full re-queue path)")
    func flushRequeuesFullBatchOnGenericError() async {
        let sink = MemoryTelemetrySink()
        sink.shouldFail = true
        let client = makeClient(sink: sink)

        await client.track(TelemetryEvent(name: "a"))
        await client.track(TelemetryEvent(name: "b"))
        await client.flush() // fails → both re-queued
        #expect(sink.count == 0)

        sink.shouldFail = false
        await client.flush() // succeeds → both delivered
        let delivered = sink.drain()
        #expect(delivered.count == 2)
        let names = delivered.map { $0.name }
        #expect(names.contains("a"))
        #expect(names.contains("b"))
    }

    // MARK: - sequential flushes do not double-send

    @Test("two sequential flushes do not double-send the same events")
    func sequentialFlushesNoDuplicate() async {
        let sink = MemoryTelemetrySink()
        let client = makeClient(sink: sink)

        await client.track(TelemetryEvent(name: "once"))
        await client.flush() // drains the buffer
        await client.flush() // buffer is empty — must be a no-op

        let events = sink.drain()
        #expect(events.count == 1, "each event must be delivered exactly once")
    }

    // MARK: - OFEM_TELEMETRY env-var opt-out (telemetry-06)

    //
    // setenv/unsetenv are process-global, so all env-var mutation tests run
    // in a dedicated .serialized suite below (EnvOptOutTests) to prevent
    // races with other tests that run in parallel.

    // MARK: - failedOp redaction (telemetry-01)

    @Test("trackError scrubs failedOp — PII in op string is redacted")
    func trackErrorScrubsFailedOp() async {
        // A caller might accidentally pass a file path or workspace name as
        // the `op` parameter.  scrubProperty must collapse it to "redacted".
        let sink = MemoryTelemetrySink()
        let client = makeClient(sink: sink)
        let error = NSError(domain: "OfemSyncError", code: 403)
        // Pass a path-like op string — must be redacted.
        await client.trackError(error, op: "download/Files/budget.csv")
        await client.flush()

        let events = sink.drain()
        #expect(events.count == 1)
        let failedOp = events[0].commonProps["failedOp"] ?? ""
        #expect(failedOp == "redacted",
                "failedOp containing '/' must be redacted; got '\(failedOp)'")
    }

    @Test("trackError preserves safe op name unchanged")
    func trackErrorSafeOpPassthrough() async {
        let sink = MemoryTelemetrySink()
        let client = makeClient(sink: sink)
        let error = NSError(domain: "OfemSyncError", code: 500)
        await client.trackError(error, op: "file_download")
        await client.flush()

        let events = sink.drain()
        #expect(events.count == 1)
        #expect(events[0].commonProps["failedOp"] == "file_download",
                "safe op name must pass through unchanged")
    }

    // MARK: - iKey scrubbing (telemetry-04)

    @Test("AppInsightsEnvelope iKey is scrubbed at the redaction boundary")
    func envelopeIKeyScrubbed() {
        let event = TelemetryEvent(name: "app_start")
        // A GUID-format iKey passes the charset check and should be unchanged.
        let guidKey = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
        let envelope = AppInsightsEnvelope.from(
            event: event,
            iKey: guidKey,
            role: "ofem",
            installID: "",
            sdkTag: "ofem"
        )
        #expect(envelope.iKey == guidKey, "GUID iKey must pass through scrubProperty unchanged")
    }

    @Test("AppInsightsEnvelope iKey containing spaces is redacted")
    func envelopeIKeyWithSpaceRedacted() {
        let event = TelemetryEvent(name: "app_start")
        let envelope = AppInsightsEnvelope.from(
            event: event,
            iKey: "bad key with spaces",
            role: "ofem",
            installID: "",
            sdkTag: "ofem"
        )
        #expect(envelope.iKey == "redacted",
                "iKey with spaces must be redacted; got '\(envelope.iKey)'")
    }
}

// MARK: - Env-var opt-out tests (serialized to avoid process-global setenv races)

/// Tests that mutate `OFEM_TELEMETRY` via `setenv`/`unsetenv`.
///
/// `setenv`/`unsetenv` are process-global and Swift Testing runs tests in
/// parallel by default, so this suite is marked `.serialized` to prevent
/// races with other tests that read the environment.  Each test saves and
/// restores the original value so the env var is always left in its
/// pre-test state regardless of test ordering.
@Suite("TelemetryClient — OFEM_TELEMETRY env-var opt-out (telemetry-06)", .serialized)
struct EnvOptOutTests {
    private static let envKey = "OFEM_TELEMETRY"

    /// Temporarily sets (or clears) `OFEM_TELEMETRY`, runs `body`, restores
    /// the original value, and returns the result of `body`.
    @discardableResult
    private func withEnv<T>(_ value: String?, body: () throws -> T) rethrows -> T {
        let original = ProcessInfo.processInfo.environment[Self.envKey]
        if let value {
            setenv(Self.envKey, value, 1)
        } else {
            unsetenv(Self.envKey)
        }
        defer {
            if let original {
                setenv(Self.envKey, original, 1)
            } else {
                unsetenv(Self.envKey)
            }
        }
        return try body()
    }

    @Test("isOptedOutViaEnv returns false when OFEM_TELEMETRY is unset")
    func envOptOutUnset() {
        withEnv(nil) {
            #expect(TelemetryClient.isOptedOutViaEnv() == false,
                    "unset OFEM_TELEMETRY must not opt out")
        }
    }

    @Test("isOptedOutViaEnv returns true for '0'")
    func envOptOutZero() {
        withEnv("0") {
            #expect(TelemetryClient.isOptedOutViaEnv() == true,
                    "OFEM_TELEMETRY=0 must opt out")
        }
    }

    @Test("isOptedOutViaEnv returns true for 'false'")
    func envOptOutFalse() {
        withEnv("false") {
            #expect(TelemetryClient.isOptedOutViaEnv() == true,
                    "OFEM_TELEMETRY=false must opt out")
        }
    }

    @Test("isOptedOutViaEnv returns true for 'FALSE' (case-insensitive)")
    func envOptOutFalseUppercase() {
        withEnv("FALSE") {
            #expect(TelemetryClient.isOptedOutViaEnv() == true,
                    "OFEM_TELEMETRY=FALSE must opt out (case-insensitive)")
        }
    }

    @Test("isOptedOutViaEnv returns false for '1' (opt-in)")
    func envOptInOne() {
        withEnv("1") {
            #expect(TelemetryClient.isOptedOutViaEnv() == false,
                    "OFEM_TELEMETRY=1 must not opt out")
        }
    }

    @Test("isOptedOutViaEnv returns false for 'true' (opt-in)")
    func envOptInTrue() {
        withEnv("true") {
            #expect(TelemetryClient.isOptedOutViaEnv() == false,
                    "OFEM_TELEMETRY=true must not opt out")
        }
    }

    @Test("TelemetryClient with OFEM_TELEMETRY=0 suppresses emission to real sink")
    func clientSuppressesEmissionWhenEnvOptOut() async {
        let sink = MemoryTelemetrySink()
        // Build the client while the env var is set — TelemetryClient reads
        // OFEM_TELEMETRY at init time and swaps in NoopTelemetrySink.
        let client: TelemetryClient = withEnv("0") {
            TelemetryClient(
                sink: sink,
                appVersion: "2026.06.1",
                installID: "x",
                configuration: TelemetryConfiguration(osVersion: "14.5.1")
            )
        }
        // The env var has been restored by withEnv before these lines run.
        await client.track(TelemetryEvent(name: "purchase"))
        await client.flush()
        #expect(sink.count == 0,
                "OFEM_TELEMETRY=0 must suppress emission; sink received \(sink.count) events")
    }
}
