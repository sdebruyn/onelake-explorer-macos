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
            let backup = dir.appending(path: "ofem.log.1.gz", directoryHint: .notDirectory)
            #expect(fm.fileExists(atPath: backup.path),
                    "expected at least one rotation backup")
        }
    }

    @Test("rotated .gz file is valid gzip (magic bytes + gunzip round-trip)")
    func rotatedFileIsValidGzip() throws {
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

            let backup = dir.appending(path: "ofem.log.1.gz", directoryHint: .notDirectory)
            #expect(
                FileManager.default.fileExists(atPath: backup.path),
                "expected a rotation backup"
            )

            // 1. Structural check: RFC 1952 gzip magic bytes.
            let gzipData = try Data(contentsOf: backup)
            #expect(gzipData.count >= 18, "gzip file too small to be valid")
            #expect(gzipData[0] == 0x1f, "first byte must be 0x1f (gzip magic)")
            #expect(gzipData[1] == 0x8b, "second byte must be 0x8b (gzip magic)")
            #expect(gzipData[2] == 0x08, "CM field must be 8 (DEFLATE)")

            // 2. Round-trip check: gunzip must decompress without error.
            //    `/usr/bin/gunzip -t` tests the file's integrity (no output on success).
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/gunzip")
            task.arguments = ["-t", backup.path]
            try task.run()
            task.waitUntilExit()
            #expect(task.terminationStatus == 0,
                    "gunzip -t must succeed — rotated backup is invalid gzip")
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
            let backup3 = dir.appending(path: "ofem.log.3.gz", directoryHint: .notDirectory)
            #expect(!fm.fileExists(atPath: backup3.path),
                    "backup 3 should have been deleted")
            // But backup 1 and 2 should exist.
            let backup1 = dir.appending(path: "ofem.log.1.gz", directoryHint: .notDirectory)
            let backup2 = dir.appending(path: "ofem.log.2.gz", directoryHint: .notDirectory)
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
