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

    // MARK: - Privacy redaction on the file sink (logging-01)

    @Test("OfemLogger redacts metadata values containing path separators in file sink")
    func fileWriterRedactsPathInMetadata() throws {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "ofem-log-redact-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: dir) }

        let writer = RotatingFileWriter(logDirectory: dir)
        let config = LogConfiguration(level: .debug, fileWriter: writer)
        let logger = OfemLogger(configuration: config)

        logger.info("sync complete", metadata: [
            "filePath": "/Users/sam/Files/budget.csv",
            "tenantId": "9064c167-4885-40ef-9f34-1853218aea86",
        ])
        writer.close()

        let logFile = dir.appending(path: "ofem.log", directoryHint: .notDirectory)
        let content = try String(contentsOf: logFile, encoding: .utf8)
        let firstLine = content.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init) ?? ""
        let data = try #require(firstLine.data(using: .utf8))
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        // File path must be redacted; GUID must pass through.
        #expect(json?["filePath"] as? String == "redacted",
                "path containing '/' must be redacted in the file sink")
        #expect(json?["tenantId"] as? String == "9064c167-4885-40ef-9f34-1853218aea86",
                "GUID must pass through the file sink unchanged")
    }

    @Test("OfemLogger redacts metadata values containing UPN in file sink")
    func fileWriterRedactsUPNInMetadata() throws {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "ofem-log-upn-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: dir) }

        let writer = RotatingFileWriter(logDirectory: dir)
        let config = LogConfiguration(level: .debug, fileWriter: writer)
        let logger = OfemLogger(configuration: config)

        logger.warn("auth event", metadata: ["user": "sam@debruyn.dev"])
        writer.close()

        let logFile = dir.appending(path: "ofem.log", directoryHint: .notDirectory)
        let content = try String(contentsOf: logFile, encoding: .utf8)
        let firstLine = content.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init) ?? ""
        let data = try #require(firstLine.data(using: .utf8))
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        #expect(json?["user"] as? String == "redacted",
                "UPN in metadata must be redacted in the file sink")
    }

    @Test("OfemLogger writes valid JSON even when metadata value contains quotes (logging-02)")
    func fileWriterEscapesSpecialCharsInFallback() throws {
        // The primary path uses JSONSerialization which handles escaping.
        // Verify that a value that would break hand-concatenated JSON is
        // safely handled — it will be redacted via Privacy.scrubLogValue
        // because it contains characters outside the safe charset.
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "ofem-log-escape-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: dir) }

        let writer = RotatingFileWriter(logDirectory: dir)
        let config = LogConfiguration(level: .debug, fileWriter: writer)
        let logger = OfemLogger(configuration: config)

        // A value with a double-quote would break naive string concat.
        logger.info("special chars", metadata: ["val": "a\"b\\c"])
        writer.close()

        let logFile = dir.appending(path: "ofem.log", directoryHint: .notDirectory)
        let content = try String(contentsOf: logFile, encoding: .utf8)
        let firstLine = content.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init) ?? ""
        // Must be parseable JSON — not a crash or broken line.
        let data = try #require(firstLine.data(using: .utf8))
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(json != nil, "line must be valid JSON")
        // The value with quotes is not in the safe charset → redacted.
        #expect(json?["val"] as? String == "redacted")
    }

    // MARK: - Named constants (logging-07)

    @Test("RotatingFileWriter default constants are named and accessible")
    func rotatingFileWriterNamedConstants() {
        #expect(RotatingFileWriter.defaultMaxFileSizeBytes == 10 * 1024 * 1024)
        #expect(RotatingFileWriter.defaultMaxBackups == 5)
    }

    // MARK: - Rotation atomicity (logging-03 / logging-04)

    @Test("concurrent writes with small threshold do not corrupt lines (logging-03/04)")
    func rotationAtomicityUnderConcurrency() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "ofem-log-atomic-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: dir) }

        // Each line is ~55 bytes.  With threshold=1024 and maxBackups=10
        // we can hold up to ~11 × 18 = ~198 lines without losing any to
        // backup overflow, giving a clean "all lines survive" assertion.
        let lineSize = 55
        let lineCount = 100
        let threshold = lineSize * 8          // ~440 bytes → ~12 rotations
        let maxBackups = 20                   // retain 20 backups (enough for 100 lines)
        let writer = RotatingFileWriter(
            logDirectory: dir,
            maxFileSizeBytes: threshold,
            maxBackups: maxBackups
        )

        await withTaskGroup(of: Void.self) { group in
            for i in 0..<lineCount {
                group.addTask {
                    writer.write("concurrent-\(String(format: "%04d", i))-padding-padding!!!")
                }
            }
        }
        writer.close()

        // Collect all lines from the active file and every retained backup.
        let fm = FileManager.default
        var allLines: Set<String> = []
        let activeURL = dir.appending(path: "ofem.log", directoryHint: .notDirectory)
        if let text = try? String(contentsOf: activeURL, encoding: .utf8) {
            allLines.formUnion(text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init))
        }
        for i in 1...maxBackups {
            let backupURL = dir.appending(path: "ofem.log.\(i)", directoryHint: .notDirectory)
            if fm.fileExists(atPath: backupURL.path),
               let text = try? String(contentsOf: backupURL, encoding: .utf8) {
                allLines.formUnion(text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init))
            }
        }

        // Every line must be present exactly once (no corruption, no loss).
        #expect(allLines.count == lineCount,
                "all \(lineCount) lines must survive concurrent writes without corruption; found \(allLines.count)")
    }

    // MARK: - deinit closes file handle (logging-08)

    @Test("RotatingFileWriter closes file handle on deinit (no fd leak)")
    func rotatingFileWriterDeinit() throws {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "ofem-log-deinit-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: dir) }

        do {
            let writer = RotatingFileWriter(logDirectory: dir)
            writer.write("hello")
            // writer goes out of scope here — deinit must close the fd.
        }

        // After deinit the log file must be fully written and readable.
        let logFile = dir.appending(path: "ofem.log", directoryHint: .notDirectory)
        let content = try String(contentsOf: logFile, encoding: .utf8)
        #expect(content.contains("hello"), "file must be readable after writer deinit")
    }

    // MARK: - End-to-end redaction (logging-09)

    /// Exercises the full path from a public `OfemLogger` call with PII in
    /// metadata through to the written JSON line, asserting that the PII never
    /// reaches disk and the `"redacted"` marker does.
    ///
    /// The safe charset is `[A-Za-z0-9_.:-]`.  Values that contain characters
    /// outside this set (UPNs with `@`, paths with `/`, names with spaces)
    /// are collapsed to `"redacted"`.  Values entirely within the charset
    /// (e.g. a GUID) pass through unchanged.
    @Test("OfemLogger end-to-end: PII in metadata is redacted in the on-disk JSON line (logging-09)")
    func endToEndRedactionIntegration() throws {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "ofem-log-e2e-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: dir) }

        let writer = RotatingFileWriter(logDirectory: dir, maxFileSizeBytes: 1024 * 1024, maxBackups: 1)
        let config = LogConfiguration(level: .info, fileWriter: writer)
        let logger = OfemLogger(configuration: config)

        // Log via the public API with PII in metadata values.
        // - "upn" contains '@' → must be redacted
        // - "workspaceName" contains a space → must be redacted
        // - "filePath" contains '/' → must be redacted
        // - "tenantId" is a GUID (all safe chars) → must pass through unchanged
        // The message itself is a static string (as the contract requires).
        logger.info("user action completed", metadata: [
            "upn":           "user@contoso.com",
            "workspaceName": "Sales Data Warehouse",
            "filePath":      "/Users/sam/OneLake/Contoso/budget.parquet",
            "tenantId":      "9064c167-4885-40ef-9f34-1853218aea86",
        ])
        writer.close()

        let logFile = dir.appending(path: "ofem.log", directoryHint: .notDirectory)
        let raw = try String(contentsOf: logFile, encoding: .utf8)
        let firstLine = raw
            .split(separator: "\n", omittingEmptySubsequences: true)
            .first
            .map(String.init) ?? ""

        // Must be valid JSON.
        let data = try #require(firstLine.data(using: .utf8))
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(json != nil, "written line must be valid JSON")

        // The static message must appear verbatim (it carries no PII).
        #expect(json?["msg"] as? String == "user action completed",
                "static log message must reach disk verbatim")

        // Strings that contain chars outside [A-Za-z0-9_.:-] must not appear
        // verbatim in the raw output.
        let piiTerms = ["user@contoso.com", "Sales Data Warehouse", "/Users/sam", "budget.parquet"]
        for term in piiTerms {
            #expect(!raw.contains(term),
                    "PII term '\(term)' must not appear in the written log line")
        }

        // Each PII-bearing metadata key must be present but collapsed to "redacted".
        #expect(json?["upn"] as? String == "redacted",
                "UPN (contains '@') must be redacted")
        #expect(json?["workspaceName"] as? String == "redacted",
                "workspace name (contains space) must be redacted")
        #expect(json?["filePath"] as? String == "redacted",
                "file path (contains '/') must be redacted")

        // Safe values must pass through unchanged.
        #expect(json?["tenantId"] as? String == "9064c167-4885-40ef-9f34-1853218aea86",
                "GUID tenantId must reach disk verbatim (all chars are in safe charset)")

        // The redaction marker must appear at least 3 times (one per PII key).
        let redactedCount = (firstLine.components(separatedBy: "\"redacted\"").count - 1)
        #expect(redactedCount >= 3,
                "at least 3 'redacted' markers expected; found \(redactedCount)")
    }
}
