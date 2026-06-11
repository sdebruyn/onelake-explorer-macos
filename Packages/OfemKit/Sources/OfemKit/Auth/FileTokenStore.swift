import Foundation
import os.log

// MARK: - FileTokenStore

/// File-backed token store that holds per-account opaque byte blobs under
/// `<configDir>/tokens/<hex-encoded-alias>.bin`.
///
/// **Thread safety**: all public methods are safe for concurrent use within
/// a single process (protected by an in-process `NSLock`) **and** across
/// the host-app and File Provider Extension processes (protected by a
/// per-path `fcntl(2)` advisory record lock, following the same pattern as
/// ``OfemConfigStore``).
///
/// **Cross-process safety**: the host app and the FPE may both write token
/// blobs for the same alias concurrently (interactive refresh in host-app;
/// silent refresh in FPE). Each write acquires an exclusive `F_SETLK` record
/// lock on a per-alias sidecar `.lock` file before reading, modifying, and
/// writing the blob — preventing last-writer-wins clobbering of freshly
/// minted refresh tokens.
///
/// **Path layout**: the alias is hex-encoded so any byte sequence (including
/// slashes and non-ASCII characters) maps to a safe, unique filename. The
/// resulting filename is the lowercase hex encoding of the UTF-8 byte
/// sequence of the alias, suffixed with `.bin`.
///
/// **Atomic writes**: `write` writes to a temp file in the same directory
/// and then renames it, so a crash mid-write can never leave a half-written
/// token blob at the canonical path. The file is `chmod`'d to 0600 before
/// the rename so the destination always has restricted permissions.
///
/// **Empty-value semantics**: calling `write` with `Data()` or a zero-length
/// buffer is equivalent to `delete` — the existing entry is removed and no
/// new file is written.
public final class FileTokenStore: Sendable {
    private let root: URL
    private let lock = NSLock()
    private static let log = Logger(subsystem: "dev.debruyn.ofem", category: "FileTokenStore")

    // MARK: - Process-wide intra-process serialisation registry

    /// Registry lock (guards `_queueRegistry`).
    private static let registryLock = NSLock()
    /// Map from canonical tokens-dir path → serial DispatchQueue.
    /// All `FileTokenStore` instances for the same directory share one queue,
    /// so concurrent writes within the same process are serialised without
    /// relying on `fcntl` (which is per-process, not per-fd).
    private static nonisolated(unsafe) var _queueRegistry: [String: DispatchQueue] = [:]

    private static func sharedQueue(for root: URL) -> DispatchQueue {
        let key = root.resolvingSymlinksInPath().path(percentEncoded: false)
        return registryLock.withLock {
            if let q = _queueRegistry[key] { return q }
            let q = DispatchQueue(label: "dev.debruyn.ofem.tokens.\(key.hash)", qos: .utility)
            _queueRegistry[key] = q
            return q
        }
    }

    // Store the per-path serial queue as a property for use in write/delete.
    private let serialQueue: DispatchQueue

    // MARK: - Initialisers

    /// Creates a `FileTokenStore` rooted at `<configDir>/tokens/`.
    /// The directory is created (0700) if it does not exist.
    ///
    /// - Throws: ``FileTokenStoreError/createDirectoryFailed(_:)`` if the
    ///   directory cannot be created.
    public convenience init() throws {
        try self.init(tokensDir: OfemPaths().tokensDir)
    }

    /// Creates a `FileTokenStore` rooted at an explicit directory. Use this
    /// from sandboxed processes or tests that need a custom root.
    ///
    /// - Parameter tokensDir: Directory under which token files are stored.
    /// - Throws: ``FileTokenStoreError/createDirectoryFailed(_:)`` if the
    ///   directory cannot be created.
    public init(tokensDir: URL) throws {
        self.root = tokensDir
        self.serialQueue = Self.sharedQueue(for: tokensDir)
        do {
            try FileManager.default.createDirectory(
                at: tokensDir,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            throw FileTokenStoreError.createDirectoryFailed(error)
        }
    }

    // MARK: - Public API

    /// Reads the opaque byte blob previously stored for `alias`.
    ///
    /// - Parameter alias: The user-chosen account alias.
    /// - Returns: The stored bytes.
    /// - Throws: ``FileTokenStoreError/notFound(_:)`` when no entry exists for
    ///   `alias`; ``FileTokenStoreError/readFailed(_:_:)`` for other I/O failures.
    public func read(alias: String) throws -> Data {
        let url = tokenURL(for: alias)
        do {
            return try Data(contentsOf: url)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            throw FileTokenStoreError.notFound(alias)
        } catch {
            throw FileTokenStoreError.readFailed(alias, error)
        }
    }

    /// Stores `data` for `alias`. Passing an empty `Data()` is equivalent to
    /// calling ``delete(alias:)``.
    ///
    /// Protected by a per-process serial queue (intra-process) and a
    /// per-alias `fcntl` record lock (cross-process) to prevent concurrent
    /// writers from clobbering each other's refresh-token blobs.
    ///
    /// - Parameters:
    ///   - alias: The user-chosen account alias.
    ///   - data: The opaque byte blob to store.
    /// - Throws: ``FileTokenStoreError`` variants on I/O failures.
    public func write(alias: String, data: Data) throws {
        guard !data.isEmpty else {
            try delete(alias: alias)
            return
        }

        let dest = tokenURL(for: alias)
        var writeError: Error?

        // Intra-process serialisation: the per-path serial queue ensures
        // at most one write is in flight per process for this tokens dir.
        serialQueue.sync {
            do {
                // Cross-process exclusion: acquire a POSIX advisory record lock
                // on a per-alias sidecar file.
                let lockFD = try acquireAliasLock(alias: alias)
                defer { releaseAliasLock(lockFD) }

                let tmpURL = root.appending(
                    path: ".tmp-\(ProcessInfo.processInfo.globallyUniqueString).bin",
                    directoryHint: .notDirectory
                )
                let fm = FileManager.default

                do {
                    try data.write(to: tmpURL)
                } catch {
                    throw FileTokenStoreError.writeFailed(alias, error)
                }

                do {
                    try fm.setAttributes(
                        [.posixPermissions: 0o600],
                        ofItemAtPath: tmpURL.path(percentEncoded: false)
                    )
                } catch {
                    try? fm.removeItem(at: tmpURL)
                    throw FileTokenStoreError.chmodFailed(alias, error)
                }

                do {
                    _ = try fm.replaceItemAt(dest, withItemAt: tmpURL)
                } catch {
                    try? fm.removeItem(at: tmpURL)
                    throw FileTokenStoreError.renameFailed(alias, error)
                }
            } catch {
                writeError = error
            }
        }
        if let e = writeError { throw e }
    }

    /// Removes the stored entry for `alias`. Deleting a missing entry is a
    /// no-op (not an error).
    ///
    /// - Parameter alias: The user-chosen account alias.
    /// - Throws: ``FileTokenStoreError/deleteFailed(_:_:)`` on unexpected
    ///   I/O errors.
    public func delete(alias: String) throws {
        let url = tokenURL(for: alias)
        var deleteError: Error?
        serialQueue.sync {
            do {
                try FileManager.default.removeItem(at: url)
                // Also clean up the lock file if it exists.
                let lockURL = aliasLockURL(alias: alias)
                try? FileManager.default.removeItem(at: lockURL)
            } catch let error as CocoaError where error.code == .fileNoSuchFile {
                // Missing entry — no-op.
            } catch {
                deleteError = FileTokenStoreError.deleteFailed(alias, error)
            }
        }
        if let e = deleteError { throw e }
    }

    // MARK: - Cross-process alias lock

    /// Maximum total wait time for the cross-process per-alias lock.
    private static let lockTimeoutNs: UInt64 = 5_000_000_000 // 5 seconds

    /// Returns the URL of the per-alias lock sidecar file.
    private func aliasLockURL(alias: String) -> URL {
        let hex = Data(alias.utf8).map { String(format: "%02x", $0) }.joined()
        return root.appending(path: "\(hex).lock", directoryHint: .notDirectory)
    }

    /// Acquires an exclusive POSIX advisory `fcntl` record lock on the
    /// per-alias `.lock` sidecar file.
    ///
    /// Uses non-blocking `F_SETLK` with exponential back-off (same pattern as
    /// ``OfemConfigStore``). Total cap ~5 s; throws on timeout.
    private func acquireAliasLock(alias: String) throws -> Int32 {
        let lockURL = aliasLockURL(alias: alias)
        let fd = Darwin.open(lockURL.path(percentEncoded: false), O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard fd >= 0 else {
            throw FileTokenStoreError.lockFailed(alias,
                NSError(domain: NSPOSIXErrorDomain, code: Int(Darwin.errno)))
        }

        var lk = Darwin.flock()
        lk.l_type   = Int16(F_WRLCK)
        lk.l_whence = Int16(SEEK_SET)
        lk.l_start  = 0
        lk.l_len    = 0

        let deadline = DispatchTime.now() + .nanoseconds(Int(Self.lockTimeoutNs))
        var sleepNs: UInt64 = 10_000_000 // 10 ms initial
        while true {
            if Darwin.fcntl(fd, F_SETLK, &lk) == 0 {
                return fd
            }
            let err = Darwin.errno
            guard err == EAGAIN || err == EACCES else {
                Darwin.close(fd)
                throw FileTokenStoreError.lockFailed(alias,
                    NSError(domain: NSPOSIXErrorDomain, code: Int(err)))
            }
            if DispatchTime.now() >= deadline {
                Darwin.close(fd)
                throw FileTokenStoreError.lockTimeout(alias)
            }
            Thread.sleep(forTimeInterval: Double(sleepNs) / 1_000_000_000)
            sleepNs = min(sleepNs * 2, 640_000_000)
        }
    }

    /// Releases the POSIX advisory lock and closes the file descriptor.
    private func releaseAliasLock(_ fd: Int32) {
        var lk = Darwin.flock()
        lk.l_type   = Int16(F_UNLCK)
        lk.l_whence = Int16(SEEK_SET)
        lk.l_start  = 0
        lk.l_len    = 0
        Darwin.fcntl(fd, F_SETLK, &lk)
        Darwin.close(fd)
    }

    // MARK: - Private helpers

    /// Returns the file URL for an alias's token blob.
    ///
    /// The alias is hex-encoded so any byte value (including `/`) produces a
    /// valid, unique filename.
    private func tokenURL(for alias: String) -> URL {
        let hex = Data(alias.utf8).map { String(format: "%02x", $0) }.joined()
        return root.appending(path: "\(hex).bin", directoryHint: .notDirectory)
    }
}

// MARK: - Errors

/// Errors thrown by ``FileTokenStore``.
public enum FileTokenStoreError: Error {
    /// No token is stored for the given alias.
    case notFound(String)
    /// The token file could not be read.
    case readFailed(String, Error)
    /// The token file could not be written.
    case writeFailed(String, Error)
    /// `chmod 0600` on the temp file failed.
    case chmodFailed(String, Error)
    /// Renaming the temp file to the canonical path failed.
    case renameFailed(String, Error)
    /// The token file could not be deleted for an alias.
    case deleteFailed(String, Error)
    /// The tokens directory could not be created.
    case createDirectoryFailed(Error)
    /// A cross-process `fcntl` lock could not be acquired (I/O error).
    case lockFailed(String, Error)
    /// The cross-process `fcntl` lock was not released within ~5 s.
    case lockTimeout(String)
}
