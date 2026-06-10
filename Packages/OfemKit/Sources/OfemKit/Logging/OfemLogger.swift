import Foundation
import os.log

/// Structured logger façade for OFEM's Swift targets.
///
/// `OfemLogger` wraps Apple's `os.Logger` (Unified Logging System) and adds
/// an optional `RotatingFileWriter` so the same messages appear in both
/// Console.app / `log stream` and a rotating JSON-structured file.
///
/// `OfemLogger` is `Sendable` because all mutable state (the file writer's
/// file handle) is protected by `NSLock` inside `RotatingFileWriter`.
///
/// ### Usage
///
/// ```swift
/// let logger = OfemLogger(configuration:.init(level:.debug))
/// logger.info("workspace listed", metadata: ["tenantId": "9064c167-…"])
/// ```
public struct OfemLogger: Sendable {
    // MARK: - State

    private let configuration: LogConfiguration
    private let osLogger: Logger

    // MARK: - Init

    /// Creates an `OfemLogger` with the given configuration.
    public init(configuration: LogConfiguration = .init()) {
        self.configuration = configuration
        self.osLogger = Logger(
            subsystem: configuration.subsystem,
            category: configuration.category
        )
    }

    // MARK: - Logging methods

    /// Logs a debug-level message.
    public func debug(_ message: String, metadata: [String: String] = [:]) {
        log(level: .debug, message: message, metadata: metadata)
    }

    /// Logs an info-level message.
    public func info(_ message: String, metadata: [String: String] = [:]) {
        log(level: .info, message: message, metadata: metadata)
    }

    /// Logs a warning-level message.
    public func warn(_ message: String, metadata: [String: String] = [:]) {
        log(level: .warn, message: message, metadata: metadata)
    }

    /// Logs an error-level message.
    public func error(_ message: String, metadata: [String: String] = [:]) {
        log(level: .error, message: message, metadata: metadata)
    }

    // MARK: - Core

    private func log(level: LogLevel, message: String, metadata: [String: String]) {
        guard level >= configuration.level else { return }

        // os.Logger — visible in Console.app, `log stream`, and Instruments.
        // store-16: map warn→.error and error→.error (not .fault); .fault is
        // reserved for programmer faults and is always persisted to disk.
        let osMessage = metadata.isEmpty
            ? message
            : "\(message) \(formatMeta(metadata))"

        switch level {
        case .debug:
            osLogger.debug("\(osMessage, privacy: .public)")
        case .info:
            osLogger.info("\(osMessage, privacy: .public)")
        case .warn:
            osLogger.error("\(osMessage, privacy: .public)")
        case .error:
            osLogger.error("\(osMessage, privacy: .public)")
        }

        // Rotating file — JSON-structured.
        if let writer = configuration.fileWriter {
            let line = jsonLine(level: level, message: message, metadata: metadata)
            writer.write(line)
        }
    }

    // MARK: - Formatting

    private func formatMeta(_ meta: [String: String]) -> String {
        meta.sorted(by: { $0.key < $1.key })
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: " ")
    }

    /// Emits a single JSON line with `time`, `level`, `msg`, and any
    /// caller-supplied metadata keys.
    ///
    /// Reserved keys (`time`, `level`, `msg`) always win — a caller metadata
    /// key with the same name is silently dropped. (store-17)
    ///
    /// Example:
    /// ```json
    /// {"time":"2026-06-07T14:03:12.000Z","level":"INFO","msg":"workspace listed","tenantId":"9064c167"}
    /// ```
    private func jsonLine(level: LogLevel, message: String, metadata: [String: String]) -> String {
        // store-17: build caller metadata first, then overwrite with reserved
        // keys so reserved keys always win.
        var dict: [String: Any] = [:]
        for (k, v) in metadata {
            dict[k] = v
        }
        // Reserved keys overwrite any same-named metadata key.
        dict["time"] = Self.isoTimestamp()
        dict["level"] = levelLabel(level)
        dict["msg"] = message

        guard
            let data = try? JSONSerialization.data(
                withJSONObject: dict,
                options: [.sortedKeys]
            ),
            let str = String(data: data, encoding: .utf8)
        else {
            return "{\"time\":\"\(Self.isoTimestamp())\",\"level\":\"\(levelLabel(level))\",\"msg\":\"\(message)\"}"
        }
        return str
    }

    // MARK: - Shared ISO 8601 formatter (store-15)

    /// Thread-safe shared formatter. `ISO8601DateFormatter` is documented as
    /// thread-safe after its format options are set.
    private static let iso8601Formatter: ISO8601DateFormatter = {
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fmt
    }()

    static func isoTimestamp() -> String {
        iso8601Formatter.string(from: Date())
    }

    private func levelLabel(_ level: LogLevel) -> String {
        switch level {
        case .debug: return "DEBUG"
        case .info:  return "INFO"
        case .warn:  return "WARN"
        case .error: return "ERROR"
        }
    }
}
