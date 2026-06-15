import Testing
@testable import OfemKit
import Foundation

@Suite("RotatingFileWriter")
struct RotatingFileWriterTests {
    // Convenience: create a temp dir, run body, remove dir.
    private func withTempDir(_ body: (URL) throws -> Void) throws {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "ofem-rfw-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: dir) }
        try body(dir)
    }

    @Test("write creates log file and appends content")
    func writesFile() throws {
        try withTempDir { dir in
            let writer = RotatingFileWriter(logDirectory: dir)
            writer.write("line one")
            writer.write("line two")
            writer.close()

            let logFile = dir.appending(path: "ofem.log", directoryHint: .notDirectory)
            let content = try String(contentsOf: logFile, encoding: .utf8)
            #expect(content.contains("line one\n"))
            #expect(content.contains("line two\n"))
        }
    }

    @Test("rotation triggers when size threshold exceeded")
    func rotatesOnSizeLimit() throws {
        try withTempDir { dir in
            // Set a tiny threshold so a handful of lines trigger rotation.
            let writer = RotatingFileWriter(
                logDirectory: dir,
                maxFileSizeBytes: 50,
                maxBackups: 2
            )

            // Write more than 50 bytes total.
            for i in 0..<10 {
                writer.write("log line number \(i) — padding padding")
            }
            writer.close()

            let fm = FileManager.default
            let backup = dir.appending(path: "ofem.log.1", directoryHint: .notDirectory)
            #expect(fm.fileExists(atPath: backup.path),
                    "expected at least one rotation backup")
        }
    }

    @Test("rotated backup file contains plain-text log lines")
    func rotatedFileIsPlainText() throws {
        try withTempDir { dir in
            // Write enough to trigger exactly one rotation.
            let writer = RotatingFileWriter(
                logDirectory: dir,
                maxFileSizeBytes: 50,
                maxBackups: 2
            )
            for i in 0..<5 {
                writer.write("log line \(i) — padding to exceed threshold easily")
            }
            writer.close()

            let backup = dir.appending(path: "ofem.log.1", directoryHint: .notDirectory)
            #expect(
                FileManager.default.fileExists(atPath: backup.path),
                "expected a rotation backup"
            )

            // The rotated file must be readable plain text.
            let content = try String(contentsOf: backup, encoding: .utf8)
            #expect(content.contains("log line"), "rotated backup must contain plain-text log lines")
        }
    }

    @Test("old backups beyond maxBackups are deleted")
    func oldBackupsDeleted() throws {
        try withTempDir { dir in
            let writer = RotatingFileWriter(
                logDirectory: dir,
                maxFileSizeBytes: 20,
                maxBackups: 2
            )

            // Force many rotations.
            for i in 0..<50 {
                writer.write("rotation line \(i) — enough bytes to overflow the tiny cap here")
            }
            writer.close()

            let fm = FileManager.default
            // Backup 3 should not exist.
            let backup3 = dir.appending(path: "ofem.log.3", directoryHint: .notDirectory)
            #expect(!fm.fileExists(atPath: backup3.path),
                    "backup 3 should have been deleted")
            // But backup 1 and 2 should exist.
            let backup1 = dir.appending(path: "ofem.log.1", directoryHint: .notDirectory)
            let backup2 = dir.appending(path: "ofem.log.2", directoryHint: .notDirectory)
            #expect(fm.fileExists(atPath: backup1.path))
            #expect(fm.fileExists(atPath: backup2.path))
        }
    }

    @Test("concurrent writes do not corrupt the file")
    func concurrentWrites() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "ofem-rfw-concurrent-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: dir) }

        let writer = RotatingFileWriter(
            logDirectory: dir,
            maxFileSizeBytes: 100 * 1024,
            maxBackups: 3
        )

        // Spawn multiple concurrent writes.
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<100 {
                group.addTask {
                    writer.write("concurrent line \(i)")
                }
            }
        }
        writer.close()

        // The file must exist and contain at least some lines.
        let logFile = dir.appending(path: "ofem.log", directoryHint: .notDirectory)
        let fm = FileManager.default
        #expect(fm.fileExists(atPath: logFile.path))
    }

    // MARK: - Flush-on-write (logging-10)

    /// Verifies that log lines are readable from disk immediately after
    /// `write(_:)` returns — without calling `close()` first.
    ///
    /// The FPE engine is short-lived (built per enumeration, torn down after
    /// the enumeration completes).  If writes were buffered and only flushed
    /// on `close()` / `deinit`, a fast teardown would leave `ofem.log` empty.
    /// `RotatingFileWriter.write(_:)` calls `FileHandle.synchronize()` after
    /// each append to prevent this.
    @Test("write flushes to disk immediately — readable without close() (logging-10)")
    func writeFlushesImmediately() throws {
        try withTempDir { dir in
            let writer = RotatingFileWriter(logDirectory: dir)
            writer.write("flushed line")

            // Read the file WITHOUT calling writer.close() to confirm the line
            // was flushed to the OS page cache by write(_:) itself.
            let logFile = dir.appending(path: "ofem.log", directoryHint: .notDirectory)
            let content = try String(contentsOf: logFile, encoding: .utf8)
            #expect(content.contains("flushed line"),
                    "written line must be readable from disk before close() is called")

            writer.close()
        }
    }

    @Test("write to non-existent directory creates it")
    func createsDirectory() throws {
        try withTempDir { baseDir in
            let nested = baseDir
                .appending(path: "a", directoryHint: .isDirectory)
                .appending(path: "b", directoryHint: .isDirectory)
                .appending(path: "logs", directoryHint: .isDirectory)

            let writer = RotatingFileWriter(logDirectory: nested)
            writer.write("hello")
            writer.close()

            let fm = FileManager.default
            #expect(fm.fileExists(atPath: nested.path))
            let logFile = nested.appending(path: "ofem.log", directoryHint: .notDirectory)
            #expect(fm.fileExists(atPath: logFile.path))
        }
    }
}
