import Foundation
@testable import OfemKit

// MARK: - Shared log-capture helpers for Logging test suites

/// Creates a debug-level OfemLogger that writes JSON lines to `directory`.
func makeCapturingLogger(directory: URL) -> OfemLogger {
    let writer = RotatingFileWriter(logDirectory: directory)
    let config = LogConfiguration(
        subsystem: "dev.debruyn.ofem.test",
        category: "test",
        level: .debug,
        fileWriter: writer
    )
    return OfemLogger(configuration: config)
}

/// Reads all JSON log lines from `directory/ofem.log` and returns them as
/// `[String: String]` dictionaries.
func capturedLines(directory: URL) throws -> [[String: String]] {
    let logURL = directory.appendingPathComponent("ofem.log")
    guard FileManager.default.fileExists(atPath: logURL.path) else { return [] }
    let raw = try String(contentsOf: logURL, encoding: .utf8)
    var result: [[String: String]] = []
    for line in raw.split(separator: "\n", omittingEmptySubsequences: true) {
        let lineStr = String(line)
        guard let data = lineStr.data(using: .utf8) else {
            throw CaptureError.invalidUTF8(lineStr)
        }
        do {
            let parsed = try JSONSerialization.jsonObject(with: data)
            guard let obj = parsed as? [String: Any] else {
                throw CaptureError.malformedJSON(lineStr)
            }
            result.append(obj.mapValues { v -> String in
                if let s = v as? String { return s }
                return String(describing: v)
            })
        } catch let err as CaptureError {
            throw err
        } catch {
            throw CaptureError.malformedJSON(lineStr)
        }
    }
    return result
}

enum CaptureError: Error, CustomStringConvertible {
    case invalidUTF8(String)
    case malformedJSON(String)

    var description: String {
        switch self {
        case let .invalidUTF8(line):
            "capturedLines: line is not valid UTF-8: \(line)"
        case let .malformedJSON(line):
            "capturedLines: line failed JSON parsing — logger format regression? Line: \(line)"
        }
    }
}

/// Creates a temporary directory, passes its URL to `body`, then removes the
/// directory when `body` returns.
func withTempDir(_ body: (URL) async throws -> Void) async throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("ofem-log-test-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try await body(dir)
}
