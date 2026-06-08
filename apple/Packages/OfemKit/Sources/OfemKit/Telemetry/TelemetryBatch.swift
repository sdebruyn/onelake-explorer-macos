import Foundation
import os.log

/// In-memory event buffer with background flush support.
///
/// `TelemetryBatch` mirrors the buffering and overflow logic in
/// `internal/telemetry/client.go` — it enqueues events, drains them on a
/// timer or when the buffer hits `maxSize`, and puts failed batches back at
/// the front of the queue for the next flush attempt.
///
/// This type is `internal` — the public surface is `TelemetryClient`.
actor TelemetryBatch {
    // MARK: - State

    private var buffer: [TelemetryEvent] = []
    private let maxSize: Int
    private let log = Logger(subsystem: "dev.debruyn.ofem", category: "TelemetryBatch")

    // MARK: - Init

    init(maxSize: Int) {
        self.maxSize = maxSize
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
    /// Mirrors the re-queue path in `Client.Flush` in `client.go`.
    func requeue(_ events: [TelemetryEvent]) {
        buffer = events + buffer
        let over = buffer.count - maxSize
        if over > 0 {
            buffer.removeFirst(over)
            log.debug("telemetry buffer overflow after failed flush; dropped \(over, privacy: .public) oldest events")
        }
    }

    /// Current number of buffered events.
    var count: Int { buffer.count }
}
