import Testing
@testable import OfemKit
import Foundation

@Suite("OfemLogger")
struct OfemLoggerTests {
    @Test("LogLevel string parsing — valid values")
    func logLevelParsing() {
        #expect(LogLevel(string: "") == .info)
        #expect(LogLevel(string: "info") == .info)
        #expect(LogLevel(string: "INFO") == .info)
        #expect(LogLevel(string: "debug") == .debug)
        #expect(LogLevel(string: "DEBUG") == .debug)
        #expect(LogLevel(string: "warn") == .warn)
        #expect(LogLevel(string: "warning") == .warn)
        #expect(LogLevel(string: "WARN") == .warn)
        #expect(LogLevel(string: "error") == .error)
        #expect(LogLevel(string: "ERROR") == .error)
    }

    @Test("LogLevel string parsing — invalid values return nil")
    func logLevelParsingInvalid() {
        #expect(LogLevel(string: "trace") == nil)
        #expect(LogLevel(string: "verbose") == nil)
        #expect(LogLevel(string: "fatal") == nil)
    }

    @Test("LogLevel Comparable ordering")
    func logLevelOrdering() {
        #expect(LogLevel.debug < LogLevel.info)
        #expect(LogLevel.info < LogLevel.warn)
        #expect(LogLevel.warn < LogLevel.error)
        #expect(!(LogLevel.error < LogLevel.warn))
    }

    @Test("OfemLogger initialises with default configuration")
    func defaultInit() {
        let logger = OfemLogger()
        // Should not crash.
        logger.debug("test debug message")
        logger.info("test info message")
        logger.warn("test warn message")
        logger.error("test error message")
    }

    @Test("OfemLogger with file writer writes to disk")
    func fileWriterIntegration() throws {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "ofem-log-test-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: dir) }

        let writer = RotatingFileWriter(logDirectory: dir, maxFileSizeBytes: 1024, maxBackups: 2)
        let config = LogConfiguration(level: .debug, fileWriter: writer)
        let logger = OfemLogger(configuration: config)

        logger.info("hello from test", metadata: ["key": "value"])
        writer.close()

        let logFile = dir.appending(path: "ofem.log", directoryHint: .notDirectory)
        let content = try String(contentsOf: logFile, encoding: .utf8)
        #expect(content.contains("hello from test"))
        #expect(content.contains("INFO"))
    }

    @Test("OfemLogger respects minimum level — debug suppressed at info level")
    func levelFiltering() throws {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "ofem-log-filter-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: dir) }

        let writer = RotatingFileWriter(logDirectory: dir)
        let config = LogConfiguration(level: .info, fileWriter: writer)
        let logger = OfemLogger(configuration: config)

        logger.debug("this should be suppressed")
        logger.info("this should appear")
        writer.close()

        let logFile = dir.appending(path: "ofem.log", directoryHint: .notDirectory)
        let content = try String(contentsOf: logFile, encoding: .utf8)
        #expect(!content.contains("this should be suppressed"))
        #expect(content.contains("this should appear"))
    }

    @Test("OfemLogger writes valid JSON lines when file writer present")
    func jsonLineFormat() throws {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "ofem-log-json-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: dir) }

        let writer = RotatingFileWriter(logDirectory: dir)
        let config = LogConfiguration(level: .debug, fileWriter: writer)
        let logger = OfemLogger(configuration: config)

        logger.info("structured message", metadata: ["tenantId": "abc123"])
        writer.close()

        let logFile = dir.appending(path: "ofem.log", directoryHint: .notDirectory)
        let content = try String(contentsOf: logFile, encoding: .utf8)
        let firstLine = content.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init) ?? ""
        // Must be parseable JSON.
        let data = firstLine.data(using: .utf8)!
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(json != nil)
        #expect(json?["msg"] as? String == "structured message")
        #expect(json?["level"] as? String == "INFO")
        #expect(json?["tenantId"] as? String == "abc123")
        #expect(json?["time"] != nil)
    }
}
