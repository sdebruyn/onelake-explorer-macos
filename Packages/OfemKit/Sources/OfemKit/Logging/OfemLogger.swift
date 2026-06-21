import Foundation
import os.log

// MARK: - OfemLogger

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
/// Both sinks use a compile-time `#if DEBUG` gate so it is impossible to
/// accidentally ship un-redacted values in a distributed build.
///
/// os.Logger messages: static format strings and level/category are
/// `.public`; dynamically interpolated values use a `#if DEBUG` gate:
///   - **DEBUG** builds: `.public` — un-redacted so `log show` / `log stream`
///     show real values during local development.
///   - **release** builds: `.private` — redacted in the system log, matching
///     the telemetry privacy stance.
///
/// On-disk JSON file: metadata values use the same `#if DEBUG` gate:
///   - **DEBUG** builds: written verbatim — paths, UPNs, and workspace names
///     appear in the file so developers can inspect real values locally.
///   - **release** builds: all metadata values are passed through
///     `Privacy.scrubLogValue(_:)` before being written, so PII never reaches
///     a distributed log file.
///
/// The `msg` field is written verbatim in both configurations because
/// call-site log messages must be static string constants that never carry
/// PII — callers must place dynamic data in `metadata`.
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
        osLogger = Logger(
            subsystem: configuration.subsystem,
            category: configuration.category
        )
    }

    // MARK: - Level check

    /// Returns `true` when the configured level is `.debug`.
    ///
    /// Use this at call sites on hot paths to skip metadata allocation when
    /// debug logging is off:
    /// ```swift
    /// if logger.isDebugEnabled {
    ///     logger.debug("cache fetch", metadata: [...])
    /// }
    /// ```
    public var isDebugEnabled: Bool {
        configuration.level <= .debug
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
        // values (call-site messages) use a compile-time #if DEBUG gate:
        //   DEBUG build   → .public  (un-redacted for local development)
        //   release build → .private (redacted; matches telemetry privacy stance)
        //
        // os_log's privacy: argument must be a static/literal value — the Swift
        // compiler rejects runtime OSLogPrivacy variables — so the #if DEBUG
        // block is duplicated per level rather than stored in a variable.
        //
        // Mapping: warn → .error, error → .error.  .fault is reserved for
        // programmer faults and is always persisted to disk unconditionally.
        let levelLabel = Self.levelLabel(level)
        #if DEBUG
            switch level {
            case .debug:
                osLogger.debug("[\(levelLabel, privacy: .public)] \(message, privacy: .public)")
            case .info:
                osLogger.info("[\(levelLabel, privacy: .public)] \(message, privacy: .public)")
            case .warn:
                osLogger.error("[\(levelLabel, privacy: .public)] \(message, privacy: .public)")
            case .error:
                osLogger.error("[\(levelLabel, privacy: .public)] \(message, privacy: .public)")
            }
        #else
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
        #endif

        // Rotating file — JSON-structured, redacted at the Privacy boundary.
        if let writer = configuration.fileWriter {
            let line = jsonLine(level: level, message: message, metadata: metadata)
            writer.write(line)
        }
    }

    // MARK: - Formatting

    /// Returns `value` verbatim when `redact` is `false`, or the result of
    /// `Privacy.scrubLogValue(_:)` when `redact` is `true`.
    ///
    /// Centralising the redaction decision here keeps `jsonLine` to a single
    /// loop and makes the scrub path testable in DEBUG (CI) builds: pass
    /// `redact: true` to exercise the release code path in any configuration.
    static func metadataValue(_ value: String, redact: Bool) -> String {
        redact ? Privacy.scrubLogValue(value) : value
    }

    /// Builds a single JSON log line.
    ///
    /// Reserved keys (`time`, `level`, `msg`) always win over same-named
    /// metadata keys.  Metadata values use a `#if DEBUG` gate:
    ///   - **DEBUG** builds: values are written verbatim so developers can
    ///     inspect real paths, UPNs, and workspace names in local log files.
    ///   - **release** builds: values are routed through
    ///     `Privacy.scrubLogValue(_:)` so PII never reaches a distributed log.
    ///
    /// Example:
    /// ```json
    /// {"level":"INFO","msg":"workspace listed","tenantId":"9064c167","time":"2026-06-07T14:03:12.000Z"}
    /// ```
    private func jsonLine(level: LogLevel, message: String, metadata: [String: String]) -> String {
        // Build the dictionary with caller metadata first, then overwrite with
        // reserved keys so reserved keys always win.
        //
        // DEBUG builds write metadata verbatim for local development;
        // release builds scrub values through Privacy.scrubLogValue(_:).
        #if DEBUG
            let redact = false
        #else
            let redact = true
        #endif
        var dict: [String: Any] = [:]
        for (k, v) in metadata {
            dict[k] = Self.metadataValue(v, redact: redact)
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
    private nonisolated(unsafe) static let iso8601Formatter: ISO8601DateFormatter = {
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fmt
    }()

    private static func isoTimestamp() -> String {
        iso8601Formatter.string(from: Date())
    }

    private static func levelLabel(_ level: LogLevel) -> String {
        switch level {
        case .debug: "DEBUG"
        case .info: "INFO"
        case .warn: "WARN"
        case .error: "ERROR"
        }
    }
}
