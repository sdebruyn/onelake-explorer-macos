import Foundation
import Testing

@testable import OfemKit

// MARK: - CacheLoggerTests

/// Verifies that `CacheStore` / `CacheReader` emit the expected debug-level
/// structured log entries for cache hit and miss paths.
///
/// Strategy: inject an `OfemLogger` backed by a `RotatingFileWriter` that
/// writes to a temp directory, then assert the JSON log lines contain the
/// expected fields after the operations complete.
@Suite("CacheLogger")
struct CacheLoggerTests {

    // MARK: - Helpers

    /// Creates a temp directory, an `OfemLogger` that writes JSON to it at
    /// `.debug` level, and an `OfemLogger` + log-dir URL pair for later
    /// inspection.
    private static func makeSpyLogger() throws -> (logger: OfemLogger, logDir: URL) {
        let logDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ofem-log-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
        let writer = RotatingFileWriter(logDirectory: logDir)
        let logger = OfemLogger(configuration: LogConfiguration(
            subsystem: "dev.debruyn.ofem",
            category: "cache-test",
            level: .debug,
            fileWriter: writer
        ))
        return (logger, logDir)
    }

    /// Reads the active log file and returns all non-empty lines.
    private static func readLogLines(from logDir: URL) throws -> [String] {
        let logFile = logDir.appendingPathComponent("ofem.log")
        let text = try String(contentsOf: logFile, encoding: .utf8)
        return text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    }

    // MARK: - Tests

    @Test("fetch logs a hit when the row exists")
    func fetchLogsHit() async throws {
        let (spyLogger, logDir) = try Self.makeSpyLogger()
        defer { try? FileManager.default.removeItem(at: logDir) }

        let store = try makeTempStore(logger: spyLogger)
        defer { try? FileManager.default.removeItem(at: store.root) }

        let key = CacheKey(accountAlias: "a1", workspaceID: "ws1", itemID: "it1", path: "hit.txt")
        try await store.upsert(MetadataRecord(
            accountAlias: "a1", workspaceID: "ws1", itemID: "it1",
            path: "hit.txt", parentPath: "", name: "hit.txt", isDir: false
        ))
        _ = try await store.fetch(key: key)

        let lines = try Self.readLogLines(from: logDir)
        let hitLine = lines.first(where: { $0.contains("\"msg\":\"cache fetch\"") && $0.contains("\"hit\"") })
        #expect(hitLine != nil, "expected a 'cache fetch' hit log line")
    }

    @Test("fetch logs a miss when the row does not exist")
    func fetchLogsMiss() async throws {
        let (spyLogger, logDir) = try Self.makeSpyLogger()
        defer { try? FileManager.default.removeItem(at: logDir) }

        let store = try makeTempStore(logger: spyLogger)
        defer { try? FileManager.default.removeItem(at: store.root) }

        let key = CacheKey(accountAlias: "a1", workspaceID: "ws1", itemID: "it1", path: "no-such-file.txt")
        do {
            _ = try await store.fetch(key: key)
            Issue.record("Expected notFound to be thrown")
        } catch CacheError.notFound {
            // Expected — fall through to assertion.
        }

        let lines = try Self.readLogLines(from: logDir)
        let missLine = lines.first(where: { $0.contains("\"msg\":\"cache fetch\"") && $0.contains("\"miss\"") })
        #expect(missLine != nil, "expected a 'cache fetch' miss log line")
    }
}
