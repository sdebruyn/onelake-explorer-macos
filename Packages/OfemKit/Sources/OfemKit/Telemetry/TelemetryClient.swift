import Foundation
import os.log

// MARK: - TelemetrySink protocol

/// Transport that ships a batch of events somewhere.
///
/// Conforming types: `AppInsightsSink` (production), `NoopTelemetrySink`
/// (disabled state), and `MemoryTelemetrySink` (tests).
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
public struct TelemetryConfiguration: Sendable {
    /// When `true` the client uses `NoopTelemetrySink` regardless of the
    /// provided sink. Set this from the user's opt-out preference.
    ///
    /// The `OFEM_TELEMETRY=0` (or `OFEM_TELEMETRY=false`) environment variable
    /// is also honoured: `TelemetryClient.init` reads it and forces `optOut`
    /// when the variable is set to a falsy value.  Set the variable to `1` or
    /// `true` (or leave it unset) to keep telemetry enabled.
    public let optOut: Bool

    /// Maximum in-memory event count. When the buffer reaches this size, the
    /// oldest event is dropped to make room. Default: 1000.
    public let maxBatchSize: Int

    /// Background flush interval. Default: 10 seconds.
    public let flushInterval: Duration

    /// macOS version string for the common properties. When empty the client
    /// reads `ProcessInfo.processInfo.operatingSystemVersion`.
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
/// - Background flush on a timer or on buffer-full signal.
/// - `flush()` is synchronous from the caller's perspective but performed
///   via the actor's executor.
/// - `shutdown()` cancels the timer and performs a final flush.
///
/// `TelemetryClient` is an `actor` so all mutable state is automatically
/// serialised without explicit locking.
///
/// ### Opt-out
///
/// Telemetry is disabled when:
/// - `TelemetryConfiguration.optOut == true`, **or**
/// - The environment variable `OFEM_TELEMETRY` is set to `0` or `false`.
///
/// When disabled the client uses `NoopTelemetrySink`, which silently discards
/// every event.  The background flush timer is not started.
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
    ///   - sink:          The transport. Required.
    ///   - appVersion:    OFEM release version (typically `BuildInfo.version`).
    ///   - installID:     Per-install UUID string.
    ///   - configuration: Tuning knobs. Defaults to sensible values.
    public init(
        sink: any TelemetrySink,
        appVersion: String,
        installID: String,
        configuration: TelemetryConfiguration = TelemetryConfiguration()
    ) {
        // Honour the OFEM_TELEMETRY env-var opt-out in addition to the config
        // flag.  Any value other than "1" / "true" (case-insensitive) disables
        // telemetry when the variable is set.
        let envOptOut = Self.isOptedOutViaEnv()
        let effectiveOptOut = configuration.optOut || envOptOut

        let effectiveSink: any TelemetrySink = effectiveOptOut
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
        // Capture `self` strongly inside the task — the actor guarantees that
        // `self` stays alive as long as any task holds a reference to it, so
        // `weak self` here would cause the task to silently stop flushing when
        // the caller no longer holds an external reference.
        flushTask = Task { [self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled else { break }
                await flush()
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

        // Apply common-prop allowlist + merge.
        var merged: [String: String] = [:]
        for (k, v) in ev.commonProps where allowedCommonPropKeys.contains(k) {
            merged[k] = v
        }
        for (k, v) in commonProps where merged[k] == nil {
            merged[k] = v
        }
        ev.commonProps = merged

        // Honor the buffer-full signal — trigger an immediate flush
        // so callers do not silently lose events when the buffer fills.
        let bufferFull = await batch.enqueue(ev)
        if bufferFull {
            await flush()
        }
    }

    /// Emits the `"error"` event with a PII-safe error code.
    ///
    /// Formats the code as `<domain>:<code>` (taxonomy-safe) so the sync
    /// engine's error vocabulary (e.g. `NSURLErrorDomain:-1001`) survives
    /// redaction without passing `localizedDescription` (which may contain
    /// workspace names or file paths).
    ///
    /// `failedOp` is passed through `TelemetryRedaction.scrubProperty` so
    /// only operation names drawn from the safe charset reach the sink.
    // periphery:ignore
    public func trackError(_ error: Error, op: String) async {
        let ns = error as NSError
        let errorCode = TelemetryRedaction.safeErrorCode("\(ns.domain):\(ns.code)")
        let safeOp = TelemetryRedaction.scrubProperty(op)
        await track(TelemetryEvent(
            name: "error",
            errorCode: errorCode,
            commonProps: ["failedOp": safeOp]
        ))
    }

    // MARK: - Flush

    /// Ships all buffered events to the sink synchronously (within actor isolation).
    ///
    /// On a partial rejection (`AppInsightsSinkError.partialReject`) only the
    /// retriable rejected events are re-queued; already-accepted events are
    /// discarded.
    public func flush() async {
        let events = await batch.drain()
        guard !events.isEmpty else { return }
        do {
            try await sink.send(events)
        } catch let AppInsightsSinkError.partialReject(_, _, retriable) {
            if !retriable.isEmpty {
                await batch.requeue(retriable)
            }
            log.warning(
                "telemetry partial flush: \(retriable.count, privacy: .public) events re-queued"
            )
        } catch {
            // Other errors: re-queue the entire batch.
            await batch.requeue(events)
            // Log only the error category (domain:code), never the localised
            // description which may contain PII from the underlying transport.
            let ns = error as NSError
            log.warning(
                "telemetry flush failed: \(ns.domain, privacy: .public):\(ns.code, privacy: .public)"
            )
        }
    }

    // MARK: - Env-var opt-out

    /// Returns `true` when the `OFEM_TELEMETRY` environment variable is set
    /// to a falsy value (`"0"` or `"false"`, case-insensitive).
    ///
    /// Setting the variable to `"1"`, `"true"`, or leaving it unset keeps
    /// telemetry enabled.
    static func isOptedOutViaEnv() -> Bool {
        guard let raw = ProcessInfo.processInfo.environment["OFEM_TELEMETRY"] else {
            return false
        }
        let lower = raw.trimmingCharacters(in: .whitespaces).lowercased()
        return lower == "0" || lower == "false"
    }

    // MARK: - OS version

    private static func resolveOSVersion() -> String {
        // `ProcessInfo.processInfo.operatingSystemVersion` returns the numeric
        // version components directly without the localised prefix and build
        // number that `operatingSystemVersionString` includes.
        let info = ProcessInfo.processInfo.operatingSystemVersion
        return "\(info.majorVersion).\(info.minorVersion).\(info.patchVersion)"
    }
}
