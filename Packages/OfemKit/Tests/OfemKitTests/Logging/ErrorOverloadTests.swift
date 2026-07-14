import Foundation
@testable import OfemKit
import Testing

// MARK: - ErrorOverloadTests

@Suite("OfemLogger error-taking overloads")
struct ErrorOverloadTests {
    // MARK: - warn(_:error:)

    @Test("warn(_:error:) writes level=WARN with errorCode and errorDescription")
    func warnErrorOverloadWritesWarnLevel() async throws {
        try await withTempDir { dir in
            let logger = makeCapturingLogger(directory: dir)
            let err = NSError(domain: "TestDomain", code: 42, userInfo: [
                NSLocalizedDescriptionKey: "something went wrong",
            ])
            logger.warn("test warning", error: err)
            let lines = try capturedLines(directory: dir)
            #expect(lines.count == 1)
            let line = try #require(lines.first)
            #expect(line["level"] == "WARN")
            #expect(line["msg"] == "test warning")
            #expect(line["errorCode"] == "TestDomain.42")
            #expect(line["errorDescription"] != nil)
        }
    }

    // MARK: - error(_:error:)

    @Test("error(_:error:) writes level=ERROR with errorCode")
    func errorErrorOverloadWritesErrorLevel() async throws {
        try await withTempDir { dir in
            let logger = makeCapturingLogger(directory: dir)
            let err = NSError(domain: "com.example.Engine", code: 7)
            logger.error("engine failed", error: err)
            let lines = try capturedLines(directory: dir)
            #expect(lines.count == 1)
            let line = try #require(lines.first)
            #expect(line["level"] == "ERROR")
            #expect(line["msg"] == "engine failed")
            #expect(line["errorCode"] == "com.example.Engine.7")
        }
    }

    // MARK: - errorCode safe-charset

    @Test("errorCode with safe-charset characters survives redaction")
    func errorCodePassesSafeCharset() async throws {
        try await withTempDir { dir in
            let logger = makeCapturingLogger(directory: dir)
            // domain uses only [A-Za-z0-9_.:-] — all safe
            let err = NSError(domain: "NSCocoaErrorDomain", code: 256)
            logger.warn("redaction test", error: err)
            let lines = try capturedLines(directory: dir)
            let line = try #require(lines.first)
            // errorCode is "NSCocoaErrorDomain.256" — safe charset, written verbatim
            #expect(line["errorCode"] == "NSCocoaErrorDomain.256")
        }
    }

    // MARK: - errorDescription redaction

    @Test("errorDescription with unsafe characters is redacted in release configuration")
    func errorDescriptionWithUnsafeCharsIsRedactedByPrivacy() {
        // The Privacy.scrubLogValue path is exercised directly — safe charset
        // keeps the value, unsafe chars collapse to "redacted".
        let unsafe = "path/to/file with spaces"
        let safe = "NSPOSIXErrorDomain.2"
        #expect(Privacy.scrubLogValue(unsafe) == "redacted")
        #expect(Privacy.scrubLogValue(safe) == safe)
    }

    // MARK: - caller-supplied metadata is preserved

    @Test("warn(_:error:metadata:) preserves caller-supplied metadata keys")
    func warnErrorPreservesCallerMetadata() async throws {
        try await withTempDir { dir in
            let logger = makeCapturingLogger(directory: dir)
            let err = NSError(domain: "TestDomain", code: 1)
            logger.warn("operation failed", error: err, metadata: ["alias": "dev"])
            let lines = try capturedLines(directory: dir)
            let line = try #require(lines.first)
            #expect(line["alias"] == "dev")
            #expect(line["errorCode"] != nil)
        }
    }
}

// MARK: - Helpers (mirrored from DebugLoggingTests.swift)

private func makeCapturingLogger(directory: URL) -> OfemLogger {
    let writer = RotatingFileWriter(logDirectory: directory)
    let config = LogConfiguration(
        subsystem: "dev.debruyn.ofem.test",
        category: "test",
        level: .debug,
        fileWriter: writer
    )
    return OfemLogger(configuration: config)
}

private func capturedLines(directory: URL) throws -> [[String: String]] {
    let logURL = directory.appendingPathComponent("ofem.log")
    guard FileManager.default.fileExists(atPath: logURL.path) else { return [] }
    let raw = try String(contentsOf: logURL, encoding: .utf8)
    var result: [[String: String]] = []
    for line in raw.split(separator: "\n", omittingEmptySubsequences: true) {
        let lineStr = String(line)
        guard let data = lineStr.data(using: .utf8) else { continue }
        guard
            let parsed = try? JSONSerialization.jsonObject(with: data),
            let obj = parsed as? [String: Any]
        else { continue }
        result.append(obj.mapValues { v -> String in
            if let s = v as? String { return s }
            return String(describing: v)
        })
    }
    return result
}

private func withTempDir(_ body: (URL) async throws -> Void) async throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("ofem-error-overload-test-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try await body(dir)
}
