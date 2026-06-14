import Foundation

/// A thread-safe, disk-backed log writer that rotates the active file when it
/// exceeds a configurable size limit and keeps a bounded number of rotated
/// files.
///
/// Thread safety is provided by `NSLock` so that multiple threads or Swift
/// Concurrency tasks can call `write(_:)` concurrently without interleaving
/// partial lines.
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

    // MARK: - Constants

    private static let fileName = "ofem.log"

    /// Default rotate-at size (10 MB).
    public static let defaultMaxFileSizeBytes: Int = 10 * 1_024 * 1_024

    /// Default number of rotated backups to retain.
    public static let defaultMaxBackups: Int = 5

    // MARK: - State

    private let lock = NSLock()
    private var fileHandle: FileHandle?
    private var currentSize: Int = 0

    // MARK: - Init

    /// Creates a `RotatingFileWriter`.
    ///
    /// - Parameters:
    ///   - logDirectory:     Directory for log files. Created if absent.
    ///   - maxFileSizeBytes: Rotate when the active file exceeds this size.
    ///   - maxBackups:       Number of backup files to retain.
    public init(
        logDirectory: URL,
        maxFileSizeBytes: Int = RotatingFileWriter.defaultMaxFileSizeBytes,
        maxBackups: Int = RotatingFileWriter.defaultMaxBackups
    ) {
        self.logDirectory = logDirectory
        self.maxFileSizeBytes = maxFileSizeBytes
        self.maxBackups = maxBackups
    }

    deinit {
        // Best-effort: flush and close on deallocation so callers that do not
        // explicitly call close() do not leak file descriptors.
        try? fileHandle?.synchronize()
        try? fileHandle?.close()
    }

    // MARK: - Public API

    /// Appends `line` (plus a newline) to the active log file, rotating first
    /// if the current size would exceed `maxFileSizeBytes`.
    ///
    /// The size check, the rotation, and the subsequent write all happen under
    /// a single lock acquisition so that concurrent callers cannot both trigger
    /// a rotation and cannot interleave writes between the rotate and the first
    /// write to the new file.
    ///
    /// This method is safe to call from any thread or Swift Concurrency task.
    public func write(_ line: String) {
        let bytes = (line + "\n").data(using: .utf8) ?? Data()

        lock.lock()
        defer { lock.unlock() }

        // Rotate under the lock: if the pending write would push us over the
        // threshold, perform the rotation before opening the new active file.
        if currentSize + bytes.count > maxFileSizeBytes {
            rotateUnlocked()
        }

        do {
            let handle = try fileHandleUnlocked()
            try handle.write(contentsOf: bytes)
            currentSize += bytes.count
        } catch {
            // Best-effort: if we cannot write (e.g. disk full), skip silently.
            // os.Logger is still logging; the file is a secondary channel.
        }
    }

    /// Closes the active file handle. Subsequent `write(_:)` calls will
    /// re-open the file.
    public func close() {
        lock.lock()
        defer { lock.unlock() }
        try? fileHandle?.synchronize()
        try? fileHandle?.close()
        fileHandle = nil
    }

    // MARK: - Private helpers (must be called under `lock`)

    private var activeFileURL: URL {
        logDirectory.appending(path: Self.fileName, directoryHint: .notDirectory)
    }

    /// Opens (or returns the cached) file handle.
    /// **Must be called under `lock`.**
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
        let offset = try handle.seekToEnd()
        currentSize = Int(offset)
        fileHandle = handle
        return handle
    }

    /// Rotates the active log file.
    /// **Must be called under `lock`.**
    ///
    /// Closes the current handle, shifts existing backups up by one index
    /// (deleting any that would exceed `maxBackups`), and moves the active
    /// file to `ofem.log.1`.  The next `fileHandleUnlocked()` call will
    /// create a fresh active file.
    private func rotateUnlocked() {
        try? fileHandle?.synchronize()
        try? fileHandle?.close()
        fileHandle = nil
        currentSize = 0

        let fm = FileManager.default
        let active = activeFileURL

        guard fm.fileExists(atPath: active.path) else { return }

        // Shift existing backups: ofem.log.N → ofem.log.(N+1),
        // deleting those that exceed maxBackups.
        for i in stride(from: maxBackups, through: 1, by: -1) {
            let src = backupURL(index: i)
            guard fm.fileExists(atPath: src.path) else { continue }
            if i == maxBackups {
                try? fm.removeItem(at: src)
            } else {
                let dst = backupURL(index: i + 1)
                try? fm.moveItem(at: src, to: dst)
            }
        }

        // Move active file → ofem.log.1.
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
