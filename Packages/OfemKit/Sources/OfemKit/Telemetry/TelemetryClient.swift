import Foundation
import os.log

// MARK: - TelemetrySink protocol

/// Transport that ships a batch of events somewhere.
///
///
/// `AppInsightsSink` (production), `NoopTelemetrySink` (disabled state),
/// and `MemoryTelemetrySink` (tests).
public protocol TelemetrySink: Sendable {
    /// Delivers `events` to the backend. Throws if the backend rejects the batch.
    func send(_ events: [TelemetryEvent]) async throws
}

// MARK: - NoopTelemetrySink

/// A `TelemetrySink` that silently discards every event.
///
/// Used when telemetry is disabled (env var, config flag, or missing
/// connection string).
public struct NoopTelemetrySink: TelemetrySink {
    public init() {}
    public func send(_: [TelemetryEvent]) async throws {}
}

// MARK: - TelemetryConfiguration

/// Configuration for `TelemetryClient`.
///
///
public struct TelemetryConfiguration: Sendable {
    /// When `true` the client uses `NoopTelemetrySink` regardless of the
    /// provided sink. Set this from the user's opt-out preference or the
    /// `OFEM_TELEMETRY=0` environment variable.
    public let optOut: Bool

    /// Maximum in-memory event count. When the buffer reaches this size, the
    /// oldest event is dropped to make room. Default: 1000.
    public let maxBatchSize: Int

    /// Background flush interval. Default: 10 seconds.
    public let flushInterval: Duration

    /// macOS version string for the common properties. If empty the client
    /// reads `kern.osproductversion` via `ProcessInfo`.
    public let osVersion: String

    /// Platform override (default: `"darwin"`).
    public let platform: String

    /// Architecture override (default: `"arm64"`).
    public let arch: String

    public init(
        optOut: Bool = false,
        maxBatchSize: Int = 1000,
        flushInterval: Duration = .seconds(10),
        osVersion: String = "",
        platform: String = "",
        arch: String = ""
    ) {
        self.optOut = optOut
        self.maxBatchSize = maxBatchSize
        self.flushInterval = flushInterval
        self.osVersion = osVersion
        self.platform = platform
        self.arch = arch
    }
}

// MARK: - TelemetryClient

/// Public telemetry façade.
///
/// `track(_:)` enqueues events; a Swift Concurrency `Task` drives periodic
/// flushes to the configured `TelemetrySink`.
/// - Non-blocking enqueue with oldest-event-drop on overflow.
/// - Background flush on a timer or on buffer-full signal. (store-18)
/// - `flush()` is synchronous from the caller's perspective but performed
/// via the actor's executor.
/// - `shutdown()` cancels the timer and performs a final flush.
///
/// `TelemetryClient` is an `actor` so all mutable state is automatically
/// serialised without explicit locking.
public actor TelemetryClient {
    // MARK: - State

    private let sink: any TelemetrySink
    private let batch: TelemetryBatch
    private let commonProps: [String: String]
    private let configuration: TelemetryConfiguration

    private var flushTask: Task<Void, Never>?
    private var isClosed = false

    private let log = Logger(subsystem: "dev.debruyn.ofem", category: "TelemetryClient")

    // MARK: - Init

    /// Creates a `TelemetryClient`.
    ///
    /// - Parameters:
    /// - sink: The transport. Required.
    /// - appVersion: OFEM release version (typically `BuildInfo.version`).
    /// - installID: Per-install UUID string.
    /// - configuration: Tuning knobs. Defaults to sensible values.
    public init(
        sink: any TelemetrySink,
        appVersion: String,
        installID: String,
        configuration: TelemetryConfiguration = TelemetryConfiguration()
    ) {
        let effectiveSink: any TelemetrySink = configuration.optOut
            ? NoopTelemetrySink()
            : sink

        self.sink = effectiveSink
        self.configuration = configuration
        self.batch = TelemetryBatch(maxSize: configuration.maxBatchSize)

        let platform = configuration.platform.isEmpty ? "darwin" : configuration.platform
        let arch = configuration.arch.isEmpty ? "arm64" : configuration.arch
        let osVersion = configuration.osVersion.isEmpty
            ? Self.resolveOSVersion()
            : configuration.osVersion

        self.commonProps = [
            "installId": installID,
            "appVersion": appVersion,
            "platform": platform,
            "arch": arch,
            "osVersion": osVersion,
        ]
    }

    // MARK: - Lifecycle

    /// Starts the background flush timer. Call once after construction.
    ///
    /// No-op when the sink is `NoopTelemetrySink` (disabled state).
    public func start() {
        guard !(sink is NoopTelemetrySink) else { return }
        guard flushTask == nil, !isClosed else { return }

        let interval = configuration.flushInterval
        flushTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled else { break }
                await self?.flush()
            }
        }
    }

    /// Cancels the background flush timer and performs a final flush.
    ///
    /// After `shutdown()`, `track(_:)` is a no-op.
    public func shutdown() async {
        guard !isClosed else { return }
        isClosed = true
        flushTask?.cancel()
        flushTask = nil
        await flush()
    }

    // MARK: - Track

    /// Enqueues `event`. Common properties are merged in; `time` defaults to
    /// `Date()` when absent. Non-blocking from the caller; the actor
    /// serialises access internally.
    public func track(_ event: TelemetryEvent) async {
        guard !isClosed else { return }

        var ev = event
        if ev.time == nil { ev.time = Date() }

        // Apply common-prop allowlist + merge, matching Track in client.go.
        var merged: [String: String] = [:]
        for (k, v) in ev.commonProps where allowedCommonPropKeys.contains(k) {
            merged[k] = v
        }
        for (k, v) in commonProps where merged[k] == nil {
            merged[k] = v
        }
        ev.commonProps = merged

        // store-18: honor the buffer-full signal — trigger an immediate flush
        // so callers do not silently lose events when the buffer fills.
        let bufferFull = await batch.enqueue(ev)
        if bufferFull {
            await flush()
        }
    }

    /// Convenience shorthand for emitting the `"error"` event.
    ///
    /// store-19: emit `<domain>:<code>` (taxonomy safe) instead of passing
    /// `localizedDescription` through `safeErrorCode`, which redacts every
    /// human sentence to `"redacted"`. Domain + numeric code satisfies the
    /// PII constraint (no UPN, workspace, or file name).
    public func trackError(_ error: Error, op: String) async {
        let ns = error as NSError
        let errorCode = TelemetryRedaction.safeErrorCode("\(ns.domain):\(ns.code)")
        await track(TelemetryEvent(
            name: "error",
            errorCode: errorCode,
            commonProps: ["failedOp": op]
        ))
    }

    // MARK: - Flush

    /// Ships all buffered events to the sink synchronously (within actor isolation).
    ///
    /// On a partial rejection (`AppInsightsSinkError.partialReject`) only the
    /// retriable rejected events are re-queued; already-accepted events are
    /// discarded. (store-20)
    public func flush() async {
        let events = await batch.drain()
        guard !events.isEmpty else { return }
        do {
            try await sink.send(events)
        } catch AppInsightsSinkError.partialReject(_, _, let retriable) {
            // store-20: re-queue only the retriable rejected events, not the
            // whole batch.
            if !retriable.isEmpty {
                await batch.requeue(retriable)
            }
            log.warning(
                "telemetry partial flush: \(retriable.count, privacy: .public) events re-queued"
            )
        } catch {
            // Other errors: re-queue the entire batch.
            await batch.requeue(events)
            log.warning("telemetry flush failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - OS version

    private static func resolveOSVersion() -> String {
        // `ProcessInfo.operatingSystemVersionString` returns a localised
        // string like "Version 14.5.1 (Build 23F79)"; extract just the
        // numeric version with a regex-free split.
        let info = ProcessInfo.processInfo.operatingSystemVersion
        return "\(info.majorVersion).\(info.minorVersion).\(info.patchVersion)"
    }
}
