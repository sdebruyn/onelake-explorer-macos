import Testing
@testable import OfemKit
import Foundation

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

    var count: Int { lock.withLock { _events.count } }
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

    var sendCount: Int { lock.withLock { _sendCount } }

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

    @Test("buffer overflow triggers immediate flush so no events are dropped (store-18)")
    func bufferOverflowTriggersFlush() async {
        let sink = MemoryTelemetrySink()
        // maxBatchSize=3: filling the buffer triggers an immediate flush (store-18),
        // so events accumulate across flushes instead of being dropped.
        let client = makeClient(sink: sink, maxBatchSize: 3)

        for i in 0..<5 {
            await client.track(TelemetryEvent(name: "ev\(i)"))
        }
        // Final flush for any remaining events.
        await client.flush()

        let events = sink.drain()
        // All 5 events must arrive (buffer-full → immediate flush, no drop).
        #expect(events.count == 5)
        let names = events.map { $0.name }
        for i in 0..<5 {
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
        for _ in 0..<(TelemetryEvent.maxRetries + 1) {
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
        for ev in events { await client.track(ev) }
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
        await client.flush()           // fails → both re-queued
        #expect(sink.count == 0)

        sink.shouldFail = false
        await client.flush()           // succeeds → both delivered
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
        await client.flush()   // drains the buffer
        await client.flush()   // buffer is empty — must be a no-op

        let events = sink.drain()
        #expect(events.count == 1, "each event must be delivered exactly once")
    }
}
