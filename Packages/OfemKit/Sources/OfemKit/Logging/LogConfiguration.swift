import Foundation
import os.log

/// Log level for OFEM's structured logging façade.
///
/// Represented as a strongly-typed Swift enum so call sites cannot pass
/// arbitrary integers.
public enum LogLevel: Sendable, Comparable {
    /// Verbose messages useful for diagnosing issues. Off by default in
    /// production builds.
    case debug
    /// Normal informational messages (default level).
    case info
    /// Something unexpected but recoverable.
    case warn
    /// A failure that affects correctness.
    case error

    // MARK: - Comparable

    public static func < (lhs: LogLevel, rhs: LogLevel) -> Bool {
        lhs.rank < rhs.rank
    }

    private var rank: Int {
        switch self {
        case .debug: 0
        case .info: 1
        case .warn: 2
        case .error: 3
        }
    }

    // MARK: - String initialiser

    /// Parses a log-level string. Case-insensitive; defaults to `.info`
    /// on empty input.
    public init?(string: String) {
        switch string.lowercased().trimmingCharacters(in: .whitespaces) {
        case "", "info": self = .info
        case "debug": self = .debug
        case "warn", "warning": self = .warn
        case "error": self = .error
        default: return nil
        }
    }
}

/// Configuration for `OfemLogger`.
///
/// `os.Logger` carries every message to the macOS Unified Logging System;
/// when a `RotatingFileWriter` is also supplied, each message is written
/// as a JSON line to disk too.
public struct LogConfiguration: Sendable {
    /// The subsystem identifier passed to `os.Logger`.
    /// Defaults to `"dev.debruyn.ofem"`.
    public let subsystem: String

    /// The category identifier passed to `os.Logger`.
    /// Defaults to `"ofem"`.
    public let category: String

    /// Minimum level to emit. Messages below this level are suppressed.
    public let level: LogLevel

    /// When non-nil, log messages are also written to this rotating
    /// JSON-structured file writer.
    public let fileWriter: RotatingFileWriter?

    /// Creates a `LogConfiguration`.
    ///
    /// - Parameters:
    /// - subsystem: Reverse-DNS subsystem identifier.
    /// - category: Category within the subsystem.
    /// - level: Minimum log level.
    /// - fileWriter: Optional disk-backed rotating log writer.
    public init(
        subsystem: String = "dev.debruyn.ofem",
        category: String = "ofem",
        level: LogLevel = .info,
        fileWriter: RotatingFileWriter? = nil
    ) {
        self.subsystem = subsystem
        self.category = category
        self.level = level
        self.fileWriter = fileWriter
    }
}
