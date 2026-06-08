import Testing
@testable import OfemKit
import Foundation

// MARK: - MemoryTelemetrySink

/// An in-memory `TelemetrySink` for testing — mirrors `MemorySink` in
/// `internal/telemetry/memory.go`.
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

    var count: Int { lock.withLock { _events.count } }
}

enum TestSinkError: Error { case failed }

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

    @Test("NoopTelemetrySink discards events silently")
    func noopSinkDiscards() async {
        let client = makeClient(sink: NoopTelemetrySink())
        await client.start()
        for _ in 0..<10 { await client.track(TelemetryEvent(name: "app_start")) }
        await client.flush()
        await client.shutdown()
        // No crash, no assertions needed — just verify it completes.
    }

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

    @Test("buffer overflow drops oldest event")
    func bufferOverflowDropsOldest() async {
        let sink = MemoryTelemetrySink()
        let client = makeClient(sink: sink, maxBatchSize: 3)

        for i in 0..<5 {
            await client.track(TelemetryEvent(name: "ev\(i)"))
        }
        await client.flush()

        let events = sink.drain()
        #expect(events.count == 3)
        // Oldest two (ev0, ev1) should have been dropped.
        #expect(events[0].name == "ev2")
        #expect(events[1].name == "ev3")
        #expect(events[2].name == "ev4")
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

    @Test("trackError emits error event with scrubbed code")
    func trackError() async {
        let sink = MemoryTelemetrySink()
        let client = makeClient(sink: sink)
        await client.trackError(NSError(domain: "BoomError", code: 1), op: "file_download")
        await client.flush()

        let events = sink.drain()
        #expect(events.count == 1)
        #expect(events[0].name == "error")
        #expect(events[0].commonProps["failedOp"] == "file_download")
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
                "failedOp":      "file_download", // allowed
                "unknownKey":    "some-value",    // NOT in allowlist
                "workspaceName": "SalesData",     // NOT in allowlist
            ]
        ))
        await client.flush()

        let events = sink.drain()
        #expect(events.count == 1)
        let props = events[0].commonProps

        #expect(props["failedOp"] == "file_download", "allowed key must survive")
        #expect(props["unknownKey"] == nil,    "unknown key must be dropped")
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
}
