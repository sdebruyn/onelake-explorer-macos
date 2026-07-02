import Foundation
import os.log

/// In-memory event buffer with background flush support.
///
/// Enqueues events, drains them on a timer or when the buffer hits
/// `maxSize`, and puts failed batches back at the front of the queue for
/// the next flush attempt.
///
/// This type is `internal` — the public surface is `TelemetryClient`.
actor TelemetryBatch {
    // MARK: - State

    private var buffer: [TelemetryEvent] = []
    private let maxSize: Int
    private let log = Logger(subsystem: "dev.debruyn.ofem", category: "TelemetryBatch")

    // MARK: - Init

    /// `maxSize` is clamped to at least `1` so a misconfigured (zero or
    /// negative) value can never make `enqueue` call `removeFirst()` on an
    /// empty buffer.
    init(maxSize: Int) {
        self.maxSize = max(1, maxSize)
    }

    // MARK: - Enqueue

    /// Appends `event` to the buffer, dropping the oldest event when the
    /// buffer is full (same overflow policy as the Go client).
    ///
    /// Returns `true` when the buffer hit `maxSize` (caller may signal a
    /// flush).
    @discardableResult
    func enqueue(_ event: TelemetryEvent) -> Bool {
        if buffer.count >= maxSize {
            let dropped = buffer.removeFirst()
            log.debug("telemetry buffer overflow; dropped oldest event: \(dropped.name, privacy: .public)")
        }
        buffer.append(event)
        return buffer.count >= maxSize
    }

    // MARK: - Drain / re-queue

    /// Removes and returns all buffered events.
    func drain() -> [TelemetryEvent] {
        defer { buffer = [] }
        return buffer
    }

    /// Re-queues `events` at the front of the buffer after a failed flush,
    /// trimming from the oldest end if the combined size exceeds `maxSize`.
    ///
    /// Each event's `retryCount` is incremented; events that have already
    /// reached `TelemetryEvent.maxRetries` are dropped so a permanently-
    /// rejected item cannot circulate indefinitely (store-20 bounded retries).
    ///
    /// Mirrors the re-queue path in `Client.Flush` in `client.go`.
    func requeue(_ events: [TelemetryEvent]) {
        var incremented: [TelemetryEvent] = []
        for var ev in events {
            ev.retryCount += 1
            if ev.retryCount <= TelemetryEvent.maxRetries {
                incremented.append(ev)
            } else {
                log.debug(
                    "telemetry event dropped after \(TelemetryEvent.maxRetries, privacy: .public) retries: \(ev.name, privacy: .public)"
                )
            }
        }
        buffer = incremented + buffer
        let over = buffer.count - maxSize
        if over > 0 {
            buffer.removeFirst(over)
            log.debug("telemetry buffer overflow after failed flush; dropped \(over, privacy: .public) oldest events")
        }
    }

    // periphery:ignore
    /// Current number of buffered events.
    var count: Int {
        buffer.count
    }
}
