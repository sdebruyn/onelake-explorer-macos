import Foundation

/// A thread-safe, disk-backed log writer that rotates the active file when it
/// exceeds a configurable size limit, keeps a bounded number of rotated files,
/// and gzip-compresses older rotations.
///
/// This is the Swift equivalent of the `lumberjack` rotating log writer used
/// by `internal/logging/logging.go`. The Go daemon writes JSON-structured
/// log lines; the Swift runtime writes plain `String` lines, which the
/// `OfemLogger` façade formats before calling `write(_:)`.
///
/// Thread safety is provided by an `NSLock` so that multiple threads (or
/// Swift Concurrency tasks running on different threads) can call `write(_:)`
/// concurrently without interleaving partial lines.
///
/// ### File layout
///
/// ```
/// <logDir>/
///   ofem.log            — active file (appended to)
///   ofem.log.1.gz       — most recent rotation
///   ofem.log.2.gz
///   …
///   ofem.log.<maxBackups>.gz
/// ```
///
/// Rotations older than `maxBackups` are deleted on each rotate.
public final class RotatingFileWriter: @unchecked Sendable {
    // MARK: - Configuration

    /// Directory that holds `ofem.log` and its rotations.
    public let logDirectory: URL

    /// Rotate the active file when its size exceeds this threshold (bytes).
    /// Default: 10 MB.
    public let maxFileSizeBytes: Int

    /// Maximum number of compressed backup files to keep.
    /// Default: 5.
    public let maxBackups: Int

    // MARK: - State

    private let lock = NSLock()
    private var fileHandle: FileHandle?
    private var currentSize: Int = 0

    // MARK: - Constants

    private static let fileName = "ofem.log"

    // MARK: - Init

    /// Creates a `RotatingFileWriter`.
    ///
    /// - Parameters:
    ///   - logDirectory:    Directory for log files. Created if absent.
    ///   - maxFileSizeBytes: Rotate when the active file exceeds this size.
    ///   - maxBackups:       Number of compressed backup files to retain.
    public init(
        logDirectory: URL,
        maxFileSizeBytes: Int = 10 * 1024 * 1024,
        maxBackups: Int = 5
    ) {
        self.logDirectory = logDirectory
        self.maxFileSizeBytes = maxFileSizeBytes
        self.maxBackups = maxBackups
    }

    // MARK: - Public API

    /// Appends `line` (plus a newline) to the active log file, rotating first
    /// if the file would exceed `maxFileSizeBytes`.
    ///
    /// This method is safe to call from any thread or Swift Concurrency task.
    public func write(_ line: String) {
        lock.lock()
        defer { lock.unlock() }

        let bytes = (line + "\n").data(using: .utf8) ?? Data()
        if currentSize + bytes.count > maxFileSizeBytes {
            rotateUnlocked()
        }
        do {
            let handle = try fileHandleUnlocked()
            handle.write(bytes)
            currentSize += bytes.count
        } catch {
            // Best-effort: if we cannot write, skip silently.
        }
    }

    /// Closes the active file handle. Subsequent `write(_:)` calls will
    /// re-open the file.
    public func close() {
        lock.lock()
        defer { lock.unlock() }
        try? fileHandle?.close()
        fileHandle = nil
    }

    // MARK: - Internal helpers (called under lock)

    private var activeFileURL: URL {
        logDirectory.appending(path: Self.fileName, directoryHint: .notDirectory)
    }

    private func fileHandleUnlocked() throws -> FileHandle {
        if let handle = fileHandle {
            return handle
        }
        // Ensure the log directory exists.
        try FileManager.default.createDirectory(
            at: logDirectory,
            withIntermediateDirectories: true
        )
        let url = activeFileURL
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: url)
        handle.seekToEndOfFile()
        currentSize = Int(handle.offsetInFile)
        fileHandle = handle
        return handle
    }

    /// Rotates the active log file. Must be called under `lock`.
    private func rotateUnlocked() {
        // Close the current handle.
        try? fileHandle?.close()
        fileHandle = nil
        currentSize = 0

        let fm = FileManager.default
        let active = activeFileURL

        guard fm.fileExists(atPath: active.path) else { return }

        // Shift existing backups: ofem.log.N.gz → ofem.log.(N+1).gz,
        // deleting those that exceed maxBackups.
        for i in stride(from: maxBackups, through: 1, by: -1) {
            let src = backupURL(index: i)
            let dst = backupURL(index: i + 1)
            if fm.fileExists(atPath: src.path) {
                if i == maxBackups {
                    try? fm.removeItem(at: src)
                } else {
                    try? fm.moveItem(at: src, to: dst)
                }
            }
        }

        // Compress active file → ofem.log.1.gz
        let dest = backupURL(index: 1)
        compressFile(from: active, to: dest)

        // Remove the uncompressed active file (compressFile wrote to dest).
        try? fm.removeItem(at: active)
    }

    private func backupURL(index: Int) -> URL {
        logDirectory.appending(
            path: "\(Self.fileName).\(index).gz",
            directoryHint: .notDirectory
        )
    }

    /// Gzip-compresses `source` into `destination` using `Data`-level zlib.
    ///
    /// Apple's `NSData` compression infrastructure is used rather than a
    /// third-party dependency. Despite the `.zlib` algorithm name,
    /// `NSData.compressed(.zlib)` on macOS produces raw DEFLATE (RFC 1951)
    /// without a zlib wrapper — exactly what the gzip format (RFC 1952)
    /// requires as its compressed payload. The gzip envelope (10-byte
    /// header + CRC-32/ISIZE trailer) is assembled manually so that
    /// standard `gunzip` / log viewers can open the rotated files.
    ///
    /// If compression fails the raw bytes are copied verbatim so that no log
    /// data is lost.
    private func compressFile(from source: URL, to destination: URL) {
        guard let data = try? Data(contentsOf: source, options: .mappedIfSafe) else { return }
        let compressed: Data
        do {
            compressed = try (data as NSData).compressed(using: .zlib) as Data
            // Wrap in a minimal gzip envelope (RFC 1952).
            var gzip = gzipHeader(originalSize: data.count)
            gzip.append(compressed)
            gzip.append(gzipTrailer(crc32: crc32(data), originalSize: data.count))
            try gzip.write(to: destination, options: .atomic)
        } catch {
            // Compression failed: save raw bytes with a .gz extension anyway.
            try? data.write(to: destination, options: .atomic)
        }
    }

    // MARK: - Gzip helpers

    private func gzipHeader(originalSize _: Int) -> Data {
        // RFC 1952 § 2.3.1 fixed header (10 bytes):
        // ID1=0x1f ID2=0x8b CM=8 FLG=0 MTIME=0 XFL=0 OS=3 (Unix)
        return Data([0x1f, 0x8b, 0x08, 0x00,
                     0x00, 0x00, 0x00, 0x00,
                     0x00, 0x03])
    }

    private func gzipTrailer(crc32 checksum: UInt32, originalSize: Int) -> Data {
        var data = Data(count: 8)
        let size = UInt32(originalSize & 0xFFFF_FFFF)
        data.withUnsafeMutableBytes { ptr in
            ptr.storeBytes(of: checksum.littleEndian, toByteOffset: 0, as: UInt32.self)
            ptr.storeBytes(of: size.littleEndian, toByteOffset: 4, as: UInt32.self)
        }
        return data
    }

    /// Simple CRC-32 (IEEE polynomial) implementation.
    private func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                if crc & 1 == 1 {
                    crc = (crc >> 1) ^ 0xEDB8_8320
                } else {
                    crc >>= 1
                }
            }
        }
        return crc ^ 0xFFFF_FFFF
    }
}
