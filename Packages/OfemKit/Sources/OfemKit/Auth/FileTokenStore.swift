import Darwin
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
/// silent refresh in FPE). Each write acquires an exclusive `F_SETLKW` record
/// lock on a per-alias sidecar `.lock` file before reading, modifying, and
/// writing the blob — preventing last-writer-wins clobbering of freshly
/// minted refresh tokens.
///
/// **Path layout**: the alias is hex-encoded so any byte sequence (including
/// slashes and non-ASCII characters) maps to a safe, unique filename. The
/// resulting filename is the lowercase hex encoding of the UTF-8 byte
/// sequence of the alias, suffixed with `.bin`. The `.lock` sidecar uses the
/// same stem (`hexStem(alias:)`), ensuring the two paths always agree.
///
/// **Atomic writes**: `write` writes to a temp file in the same directory
/// and then renames it, so a crash mid-write can never leave a half-written
/// token blob at the canonical path. The file is `chmod`'d to 0600 before
/// the rename so the destination always has restricted permissions.
///
/// **Empty-value semantics**: calling `write` with `Data()` or a zero-length
/// buffer is equivalent to `delete` — the existing entry is removed and no
/// new file is written.
///
/// **Lock acquisition — no blocking sleep on cooperative pool threads**:
/// `atomicUpdate`, `write`, and `delete` acquire the cross-process lock via
/// `acquireAliasLockAsync`, which uses `F_SETLKW` on a *dedicated* OS thread
/// (not on a Swift cooperative-pool thread). This mirrors the pattern used by
/// `ConfigFileLock` in `Config/ConfigFileLock.swift`. The methods are `async`
/// so callers on actor/async contexts do not block the cooperative pool.
/// `FileTokenStoreCacheDelegate` bridges these async methods back to the
/// synchronous MSAL delegate calls via `DispatchSemaphore` on MSAL's own
/// internal (non-cooperative) thread.
public final class FileTokenStore: Sendable {
    private let root: URL
    private static let log = Logger(subsystem: "dev.debruyn.ofem", category: "FileTokenStore")

    // MARK: - Process-wide intra-process serialisation registry

    /// Registry lock (guards `_queueRegistry`).
    private static let registryLock = NSLock()
    /// Map from canonical tokens-dir path → serial DispatchQueue.
    /// All `FileTokenStore` instances for the same directory share one queue,
    /// so concurrent writes within the same process are serialised without
    /// relying on `fcntl` (which is per-process, not per-fd).
    private nonisolated(unsafe) static var _queueRegistry: [String: DispatchQueue] = [:]

    private static func sharedQueue(for root: URL) -> DispatchQueue {
        let key = root.resolvingSymlinksInPath().path(percentEncoded: false)
        return registryLock.withLock {
            if let q = _queueRegistry[key] { return q }
            let q = DispatchQueue(label: "dev.debruyn.ofem.tokens.\(key.hash)", qos: .utility)
            _queueRegistry[key] = q
            return q
        }
    }

    /// Store the per-path serial queue as a property for use in write/delete.
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
        root = tokensDir
        serialQueue = Self.sharedQueue(for: tokensDir)
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

    /// Atomically reads the current blob, applies `transform` (which may
    /// deserialize, mutate, and re-serialize the in-memory cache), then writes
    /// the result back — all while holding the per-alias `fcntl` cross-process
    /// lock and the intra-process serial queue.
    ///
    /// This is the correct primitive for MSAL's "read → merge → write" token
    /// cache update: it guarantees that no other process can slip a write
    /// between the read and the write, closing the TOCTOU gap that existed
    /// when `willWriteCache` (read) and `didWriteCache` (write) each acquired
    /// the lock independently.
    ///
    /// - Parameters:
    ///   - alias: The user-chosen account alias.
    ///   - transform: A closure that receives the existing bytes (empty `Data`
    ///     if no entry exists yet) and returns the new bytes to persist, or
    ///     `nil` to leave the store unchanged. The closure is called on the
    ///     intra-process serial queue while the cross-process lock is held.
    /// - Throws: ``FileTokenStoreError`` variants on I/O failures.
    public func atomicUpdate(alias: String, transform: (Data) throws -> Data?) async throws {
        let dest = tokenURL(for: alias)

        // Acquire the cross-process lock asynchronously (F_SETLKW on dedicated thread).
        let lockFD = try await acquireAliasLockAsync(alias: alias)
        defer { releaseAliasLock(lockFD) }

        // Intra-process serialisation: the per-path serial queue ensures
        // at most one write is in flight per process for this tokens dir.
        var outerError: Error?
        serialQueue.sync {
            do {
                // Read existing bytes (empty Data if none).
                let existing: Data
                do {
                    existing = try Data(contentsOf: dest)
                } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
                    existing = Data()
                } catch {
                    throw FileTokenStoreError.readFailed(alias, error)
                }

                // Apply the transform.
                let newData: Data? = try transform(existing)
                guard let data = newData, !data.isEmpty else { return }

                // Write atomically (tmp + rename).
                let tmpURL = root.appending(
                    path: ".tmp-\(ProcessInfo.processInfo.globallyUniqueString).bin",
                    directoryHint: .notDirectory
                )
                let fm = FileManager.default

                do { try data.write(to: tmpURL) } catch {
                    throw FileTokenStoreError.writeFailed(alias, error)
                }
                do {
                    try fm.setAttributes([.posixPermissions: 0o600],
                                         ofItemAtPath: tmpURL.path(percentEncoded: false))
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
                outerError = error
            }
        }
        if let e = outerError { throw e }
    }

    /// Reads the opaque byte blob previously stored for `alias`.
    ///
    /// This is a synchronous point read with no lock: reads are lock-free and
    /// safe to call from any context. Only the write path requires the
    /// cross-process lock.
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
    public func write(alias: String, data: Data) async throws {
        guard !data.isEmpty else {
            try await delete(alias: alias)
            return
        }

        let dest = tokenURL(for: alias)

        // Acquire the cross-process lock asynchronously (F_SETLKW on dedicated thread).
        let lockFD = try await acquireAliasLockAsync(alias: alias)
        defer { releaseAliasLock(lockFD) }

        // Intra-process serialisation: the per-path serial queue ensures
        // at most one write is in flight per process for this tokens dir.
        var writeError: Error?
        serialQueue.sync {
            do {
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
    /// Protected by the same per-alias `fcntl` cross-process lock and the
    /// intra-process serial queue used by ``write(alias:data:)`` and
    /// ``atomicUpdate(alias:transform:)``, so a concurrent write from another
    /// process cannot race with the removal.
    ///
    /// Note: the per-alias `.lock` sidecar file is intentionally NOT deleted.
    /// Deleting it while another process holds a lock on the same inode would
    /// allow a third process to open a fresh inode for the same path and acquire
    /// a lock without contending with the original holder.
    ///
    /// - Parameter alias: The user-chosen account alias.
    /// - Throws: ``FileTokenStoreError/deleteFailed(_:_:)`` on unexpected
    ///   I/O errors.
    public func delete(alias: String) async throws {
        let url = tokenURL(for: alias)

        // Acquire the cross-process lock asynchronously (F_SETLKW on dedicated thread).
        let lockFD = try await acquireAliasLockAsync(alias: alias)
        defer { releaseAliasLock(lockFD) }

        var deleteError: Error?
        serialQueue.sync {
            do {
                do {
                    try FileManager.default.removeItem(at: url)
                } catch let error as CocoaError where error.code == .fileNoSuchFile {
                    // Missing entry — no-op.
                } catch {
                    throw FileTokenStoreError.deleteFailed(alias, error)
                }
            } catch {
                deleteError = error
            }
        }
        if let e = deleteError { throw e }
    }

    // MARK: - Cross-process alias lock

    /// Maximum total wait time for the cross-process per-alias lock.
    static let lockTimeoutNs: UInt64 = 5_000_000_000 // 5 seconds

    /// Returns the URL of the per-alias lock sidecar file.
    private func aliasLockURL(alias: String) -> URL {
        root.appending(path: "\(Self.hexStem(alias: alias)).lock", directoryHint: .notDirectory)
    }

    /// Acquires an exclusive POSIX advisory `fcntl` record lock on the
    /// per-alias `.lock` sidecar file.
    ///
    /// Uses `F_SETLKW` (blocking) on a *dedicated* OS thread, mirroring the
    /// `ConfigFileLock` pattern from `Config/ConfigFileLock.swift`. The calling
    /// task's cooperative-pool thread is released back to the pool immediately;
    /// the dedicated thread blocks inside the kernel until the peer releases the
    /// lock. A timeout timer cancels the wait via fd-close (causing `F_SETLKW`
    /// to return `EBADF`) after `lockTimeoutNs` nanoseconds.
    func acquireAliasLockAsync(alias: String) async throws -> Int32 {
        let lockURL = aliasLockURL(alias: alias)
        let fd = Darwin.open(lockURL.path(percentEncoded: false), O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard fd >= 0 else {
            throw FileTokenStoreError.lockFailed(alias,
                                                 NSError(domain: NSPOSIXErrorDomain, code: Int(Darwin.errno)))
        }

        return try await withCheckedThrowingContinuation { continuation in
            // fdState arbitrates fd ownership between the lock thread and timer.
            // Transitions (via compareExchange, same pattern as ConfigFileLock):
            //   .open  → .acquiredByThread  (lock thread, on F_SETLKW success)
            //   .open  → .closedByTimer     (timer handler, on timeout)
            let fdState = TokenLockFDState(.open)

            let timer = DispatchSource.makeTimerSource(queue: .global())
            timer.schedule(deadline: .now() + .nanoseconds(Int(Self.lockTimeoutNs)))
            timer.setEventHandler {
                if fdState.compareExchange(expected: .open, desired: .closedByTimer) {
                    Darwin.close(fd)
                }
            }
            timer.resume()

            let t = Thread {
                var lk = Darwin.flock()
                lk.l_type = Int16(F_WRLCK)
                lk.l_whence = Int16(SEEK_SET)
                lk.l_start = 0
                lk.l_len = 0

                // EINTR-aware loop: retry on signal delivery, bail if timer fired.
                var result: Int32
                repeat {
                    result = Darwin.fcntl(fd, F_SETLKW, &lk)
                } while result != 0
                    && Darwin.errno == EINTR
                    && fdState.load() != .closedByTimer

                if result == 0 {
                    if fdState.compareExchange(expected: .open, desired: .acquiredByThread) {
                        timer.cancel()
                        continuation.resume(returning: fd)
                    } else {
                        // Timer closed fd just before F_SETLKW returned.
                        timer.cancel()
                        continuation.resume(throwing: FileTokenStoreError.lockTimeout(alias))
                    }
                } else {
                    let err = Darwin.errno
                    timer.cancel()
                    if fdState.load() == .closedByTimer {
                        continuation.resume(throwing: FileTokenStoreError.lockTimeout(alias))
                    } else {
                        Darwin.close(fd)
                        continuation.resume(throwing: FileTokenStoreError.lockFailed(alias,
                                                                                     NSError(domain: NSPOSIXErrorDomain, code: Int(err))))
                    }
                }
            }
            t.name = "dev.debruyn.ofem.token-lock.\(alias)"
            t.qualityOfService = .utility
            t.start()
        }
    }

    /// Releases the POSIX advisory lock and closes the file descriptor.
    func releaseAliasLock(_ fd: Int32) {
        var lk = Darwin.flock()
        lk.l_type = Int16(F_UNLCK)
        lk.l_whence = Int16(SEEK_SET)
        lk.l_start = 0
        lk.l_len = 0
        _ = Darwin.fcntl(fd, F_SETLK, &lk)
        Darwin.close(fd)
    }

    // MARK: - Private helpers

    /// Returns the lowercase hex encoding of `alias`'s UTF-8 bytes.
    ///
    /// Used as the shared filename stem for both the `.bin` blob and the `.lock`
    /// sidecar so the two paths always agree and cannot drift independently.
    static func hexStem(alias: String) -> String {
        Data(alias.utf8).map { String(format: "%02x", $0) }.joined()
    }

    /// Returns the file URL for an alias's token blob.
    ///
    /// The alias is hex-encoded so any byte value (including `/`) produces a
    /// valid, unique filename.
    private func tokenURL(for alias: String) -> URL {
        root.appending(path: "\(Self.hexStem(alias: alias)).bin", directoryHint: .notDirectory)
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

// MARK: - TokenLockFDState

private enum TokenFDStateValue { case open, acquiredByThread, closedByTimer }

/// Minimal thread-safe state machine for the fd lifecycle during token lock acquisition.
///
/// Mirrors `AtomicFDState` in `Config/ConfigFileLock.swift` but is scoped to the
/// `Auth/` package to avoid coupling between the two subsystems.
private final class TokenLockFDState: @unchecked Sendable {
    private var _lock = os_unfair_lock()
    private var _state: TokenFDStateValue

    init(_ initial: TokenFDStateValue) {
        _state = initial
    }

    func load() -> TokenFDStateValue {
        os_unfair_lock_lock(&_lock)
        defer { os_unfair_lock_unlock(&_lock) }
        return _state
    }

    /// Returns `true` if the transition from `expected` → `desired` succeeded.
    @discardableResult
    func compareExchange(expected: TokenFDStateValue, desired: TokenFDStateValue) -> Bool {
        os_unfair_lock_lock(&_lock)
        defer { os_unfair_lock_unlock(&_lock) }
        guard _state == expected else { return false }
        _state = desired
        return true
    }
}
