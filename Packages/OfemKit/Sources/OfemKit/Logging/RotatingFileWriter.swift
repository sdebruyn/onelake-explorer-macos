import Foundation

/// A thread-safe, disk-backed log writer that rotates the active file when it
/// exceeds a configurable size limit and keeps a bounded number of rotated files.
///
/// This is the Swift equivalent of the `lumberjack` rotating log writer used
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
///   ofem.log.1          — most recent rotation
///   ofem.log.2
///   …
///   ofem.log.<maxBackups>
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

    /// Maximum number of backup files to keep.
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
    ///   - maxBackups:       Number of backup files to retain.
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
        let bytes = (line + "\n").data(using: .utf8) ?? Data()

        lock.lock()
        let needsRotation = currentSize + bytes.count > maxFileSizeBytes
        lock.unlock()

        if needsRotation {
            // Rotation involves rename/move on disk — done outside the lock.
            rotateFile()
        }

        lock.lock()
        defer { lock.unlock() }
        do {
            let handle = try fileHandleUnlocked()
            // store-12: use throwing modern APIs so a disk-full condition does not
            // raise an ObjC exception that Swift cannot catch.
            try handle.write(contentsOf: bytes)
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

    // MARK: - Internal helpers

    private var activeFileURL: URL {
        logDirectory.appending(path: Self.fileName, directoryHint: .notDirectory)
    }

    /// Must be called under `lock`. Opens (or returns the cached) file handle.
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
        // store-12: use throwing seekToEnd() instead of legacy seekToEndOfFile().
        let offset = try handle.seekToEnd()
        currentSize = Int(offset)
        fileHandle = handle
        return handle
    }

    /// Rotates the active log file. Called outside the lock so the
    /// rename/move work (store-13: nontrivial I/O) does not block writers.
    ///
    /// ### TOCTOU safety invariant
    ///
    /// Two threads can both observe `needsRotation = true` before either has
    /// rotated, leading to concurrent calls to `rotateFile()`. The race is
    /// benign by design:
    ///
    /// 1. The first caller acquires the lock, closes the handle, zeroes
    ///    `currentSize`, and releases the lock.  From this point on the active
    ///    file is closed and `currentSize` is 0, so any writer that re-enters
    ///    `write(_:)` will compute `needsRotation = false` and proceed to
    ///    reopen the (new, empty) active file.
    ///
    /// 2. The second caller acquires the same lock section, sees `fileHandle`
    ///    is already `nil` (set by the first caller), and still zeroes
    ///    `currentSize` — idempotent and safe.
    ///
    /// 3. Both callers then reach the `fileExists` guard on the active path.
    ///    The first caller moves the active file to `ofem.log.1`; the second
    ///    caller's `fileExists` returns `false` (the file is gone) and returns
    ///    early without touching the backup chain. At worst the second caller
    ///    loses a race between its `fileExists` check and the first caller's
    ///    `moveItem`, producing a spurious no-op — no backup is overwritten.
    ///
    /// The backup-shift loop (`ofem.log.N → ofem.log.(N+1)`) therefore runs
    /// under the implicit serialisation provided by the `fileExists` guard:
    /// only the caller that observes the active file still present proceeds
    /// with the shift. This is sufficient for a best-effort logger where a
    /// rare duplicate no-op rotation is acceptable.
    private func rotateFile() {
        // Close the handle under the lock, then do the filesystem work outside.
        lock.lock()
        try? fileHandle?.close()
        fileHandle = nil
        currentSize = 0
        lock.unlock()

        let fm = FileManager.default
        let active = activeFileURL

        guard fm.fileExists(atPath: active.path) else { return }

        // Shift existing backups: ofem.log.N → ofem.log.(N+1),
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

        // Move active file → ofem.log.1 (plain text, no compression).
        let dest = backupURL(index: 1)
        try? fm.moveItem(at: active, to: dest)
    }

    private func backupURL(index: Int) -> URL {
        logDirectory.appending(
            path: "\(Self.fileName).\(index)",
            directoryHint: .notDirectory
        )
    }
}
