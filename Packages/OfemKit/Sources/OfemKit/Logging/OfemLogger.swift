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
/// ### Privacy model
///
/// os.Logger messages: static format strings and level/category are
/// `.public`; every dynamically interpolated value is `.private` so it
/// is redacted in the system log on non-development builds.
///
/// On-disk JSON file: all metadata values are passed through
/// `Privacy.scrubLogValue(_:)` before being written.  The `msg` field is
/// written verbatim because call-site log messages must be static string
/// constants that never carry PII — callers must place dynamic data in
/// `metadata`, where the redaction boundary applies.
///
/// ### Usage
///
/// ```swift
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
        //
        // Static format strings and the level label use .public; dynamic
        // values (call-site messages, metadata) use .private so they are
        // redacted in the system log on non-development builds.
        //
        // Mapping: warn → .error, error → .error.  .fault is reserved for
        // programmer faults and is always persisted to disk unconditionally.
        let levelLabel = Self.levelLabel(level)
        switch level {
        case .debug:
            osLogger.debug("[\(levelLabel, privacy: .public)] \(message, privacy: .private)")
        case .info:
            osLogger.info("[\(levelLabel, privacy: .public)] \(message, privacy: .private)")
        case .warn:
            osLogger.error("[\(levelLabel, privacy: .public)] \(message, privacy: .private)")
        case .error:
            osLogger.error("[\(levelLabel, privacy: .public)] \(message, privacy: .private)")
        }

        // Rotating file — JSON-structured, redacted at the Privacy boundary.
        if let writer = configuration.fileWriter {
            let line = jsonLine(level: level, message: message, metadata: metadata)
            writer.write(line)
        }
    }

    // MARK: - Formatting

    /// Builds a single JSON log line.
    ///
    /// Reserved keys (`time`, `level`, `msg`) always win over same-named
    /// metadata keys.  All metadata values are routed through
    /// `Privacy.scrubLogValue(_:)` before being written to disk so that
    /// paths, UPNs, and workspace names cannot appear verbatim.
    ///
    /// Example:
    /// ```json
    /// {"level":"INFO","msg":"workspace listed","tenantId":"9064c167","time":"2026-06-07T14:03:12.000Z"}
    /// ```
    private func jsonLine(level: LogLevel, message: String, metadata: [String: String]) -> String {
        // Build the dictionary with caller metadata first (redacted), then
        // overwrite with reserved keys so reserved keys always win.
        var dict: [String: Any] = [:]
        for (k, v) in metadata {
            dict[k] = Privacy.scrubLogValue(v)
        }
        dict["time"] = Self.isoTimestamp()
        dict["level"] = Self.levelLabel(level)
        dict["msg"] = message

        guard
            let data = try? JSONSerialization.data(
                withJSONObject: dict,
                options: [.sortedKeys]
            ),
            let str = String(data: data, encoding: .utf8)
        else {
            // Fallback: emit a minimal valid JSON object using only the
            // known-safe reserved fields; skip metadata to avoid invalid JSON.
            // JSONSerialization only fails when the object graph is not
            // JSON-serializable, which cannot happen here given our types.
            let safeTime = Self.isoTimestamp()
                .replacingOccurrences(of: "\"", with: "")
            let safeLevel = Self.levelLabel(level)
                .replacingOccurrences(of: "\"", with: "")
            let safeMsg = message
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            return "{\"time\":\"\(safeTime)\",\"level\":\"\(safeLevel)\",\"msg\":\"\(safeMsg)\"}"
        }
        return str
    }

    // MARK: - Shared ISO 8601 formatter

    /// Thread-safe shared formatter. `ISO8601DateFormatter` is documented as
    /// thread-safe after its format options are set; `nonisolated(unsafe)` tells
    /// the Swift concurrency checker we have verified this invariant.
    nonisolated(unsafe) private static let iso8601Formatter: ISO8601DateFormatter = {
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fmt
    }()

    static func isoTimestamp() -> String {
        iso8601Formatter.string(from: Date())
    }

    private static func levelLabel(_ level: LogLevel) -> String {
        switch level {
        case .debug: return "DEBUG"
        case .info:  return "INFO"
        case .warn:  return "WARN"
        case .error: return "ERROR"
        }
    }
}
