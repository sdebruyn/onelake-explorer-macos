import Darwin
import Foundation

// MARK: - ConfigFileLock

//
// Cross-process advisory file lock backed by `fcntl(2)` record locking.
//
// ## Why a dedicated thread instead of F_SETLK + sleep retry
//
// The previous implementation used `F_SETLK` (non-blocking) with
// `Thread.sleep` retries on the shared per-path serial DispatchQueue.
// That blocked the queue's worker thread for up to 5 s while waiting on a
// peer process, stalling all intra-process writers that share the queue.
//
// The replacement uses `F_SETLKW` (blocking) on a *dedicated* OS thread
// (started via `Thread { }.start()`). The calling GCD worker thread is
// released back to the pool immediately; the dedicated thread blocks
// indefinitely inside the kernel until the peer releases the lock. A
// separate timeout timer cancels the wait via `F_UNLCK + close` on the fd
// from a timer callback.
//
// ## Cross-process safety
//
// `fcntl` record locks are owned by the *process*, not the fd. Two
// `ConfigFileLock` instances in the *same* process do not exclude each
// other — the kernel always grants the second acquire immediately. Intra-
// process serialisation is the responsibility of the caller
// (`OfemConfigStore` uses a per-path serial `DispatchQueue` registry).
//
// ## Lock-fd / tmp-file cleanup on error (config-08)
//
// `acquire()` opens the fd before spawning the blocking thread, and the
// thread closes/releases the fd on every exit path (success, timeout,
// system error). `OfemConfigStore.updateAndSave` wraps the held lock in a
// `defer { lock.release() }` block, so the fd is always closed even when
// `mutator` or `save` throws.

/// A scoped handle for a held `fcntl` exclusive record lock.
///
/// Obtain via ``ConfigFileLock/acquire(paths:timeout:)``. Release via
/// ``release()`` or use ``withLock(_:)`` for automatic scoping.
final class ConfigFileLock: @unchecked Sendable {
    private let fd: Int32

    private init(fd: Int32) {
        self.fd = fd
    }

    /// Releases the advisory lock and closes the file descriptor.
    func release() {
        var lk = Darwin.flock()
        lk.l_type = Int16(F_UNLCK)
        lk.l_whence = Int16(SEEK_SET)
        lk.l_start = 0
        lk.l_len = 0
        _ = Darwin.fcntl(fd, F_SETLK, &lk)
        Darwin.close(fd)
    }

    // periphery:ignore
    /// Acquires the lock, executes `body`, then releases the lock.
    @discardableResult
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        defer { release() }
        return try body()
    }

    // MARK: - Acquisition

    /// Maximum total wait time for acquiring the cross-process file lock.
    static let defaultTimeoutNs: UInt64 = 5_000_000_000 // 5 seconds

    /// Acquires an exclusive POSIX advisory `fcntl` record lock on
    /// `.config.lock` in the same directory as `config.toml`.
    ///
    /// Uses `F_SETLKW` (blocking) on a *dedicated* OS thread so the caller's
    /// GCD worker thread is not blocked during contention. The lock is granted
    /// as soon as the peer process releases it. A timeout cancels the wait by
    /// closing the fd from the timer thread, causing `F_SETLKW` to return
    /// `EBADF`; in that case ``OfemConfigError/lockTimeout`` is thrown.
    ///
    /// - Parameters:
    ///   - paths: Canonical OFEM paths; the lock file lives in `paths.configDir`.
    ///   - timeoutNs: Maximum nanoseconds to wait (default 5 s).
    /// - Returns: A `ConfigFileLock` handle. The caller must call `release()`.
    /// - Throws: ``OfemConfigError/lockTimeout`` after the timeout; other
    ///   ``OfemConfigError/lockFailed(_:)`` on unexpected POSIX errors.
    static func acquire(paths: OfemPaths, timeoutNs: UInt64 = defaultTimeoutNs) async throws -> ConfigFileLock {
        let lockURL = paths.configDir.appending(
            path: ".config.lock",
            directoryHint: .notDirectory
        )

        // Ensure the config directory exists before opening the lock file.
        let fm = FileManager.default
        if !fm.fileExists(atPath: paths.configDir.path(percentEncoded: false)) {
            do {
                try fm.createDirectory(
                    at: paths.configDir,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
            } catch {
                throw OfemConfigError.createDirectoryFailed(error)
            }
        }

        // O_CREAT | O_RDWR — create the lock file if it doesn't exist.
        let fd = Darwin.open(
            lockURL.path(percentEncoded: false),
            O_CREAT | O_RDWR,
            S_IRUSR | S_IWUSR
        )
        guard fd >= 0 else {
            throw OfemConfigError.lockFailed(
                NSError(domain: NSPOSIXErrorDomain, code: Int(Darwin.errno))
            )
        }

        // Run F_SETLKW on a dedicated OS thread so the calling GCD thread is
        // not blocked. The continuation resumes when the lock is granted or
        // the timeout fires.
        return try await withCheckedThrowingContinuation { continuation in
            // Set up a timeout: after `timeoutNs` nanoseconds, close the fd
            // from the timer thread. This causes the blocking F_SETLKW on the
            // lock thread to return EBADF, which we map to lockTimeout.
            let timer = DispatchSource.makeTimerSource(queue: .global())
            timer.schedule(deadline: .now() + .nanoseconds(Int(timeoutNs)))
            // `fdState` is the single arbiter of fd ownership.
            // Transitions (all via compareExchange to prevent races):
            //   .open  → .acquiredByThread  (lock thread, on F_SETLKW success)
            //   .open  → .closedByTimer     (timer handler, on timeout fire)
            // Only the transition winner may touch the fd after the exchange.
            let fdState = AtomicFDState(.open)
            timer.setEventHandler {
                if fdState.compareExchange(expected: .open, desired: .closedByTimer) {
                    // We won the race — close the fd so F_SETLKW returns EBADF.
                    Darwin.close(fd)
                }
                // If the lock thread already took ownership (.acquiredByThread),
                // the timer fires harmlessly after cancel() was already called.
            }
            timer.resume()

            // Dedicated OS thread: blocks inside F_SETLKW until granted or fd closed.
            let t = Thread {
                var lk = Darwin.flock()
                lk.l_type = Int16(F_WRLCK)
                lk.l_whence = Int16(SEEK_SET)
                lk.l_start = 0
                lk.l_len = 0 // Lock the whole file.

                // EINTR-aware acquire loop: F_SETLKW can return -1/EINTR when a
                // signal is delivered to this thread. Retry transparently, but
                // check first that the timer hasn't already fired — if it has,
                // bail out immediately so a late signal can't spin forever.
                var fcntlResult: Int32
                repeat {
                    fcntlResult = Darwin.fcntl(fd, F_SETLKW, &lk)
                } while fcntlResult != 0
                    && Darwin.errno == EINTR
                    && fdState.load() != .closedByTimer

                if fcntlResult == 0 {
                    // F_SETLKW returned success. Claim fd ownership atomically.
                    // If the timer already closed the fd (.closedByTimer), then
                    // fcntl should not have returned 0 — but even if it did in
                    // some edge case, we detect it here and surface lockTimeout.
                    if fdState.compareExchange(expected: .open, desired: .acquiredByThread) {
                        timer.cancel()
                        continuation.resume(returning: ConfigFileLock(fd: fd))
                    } else {
                        // Timer won the race and closed fd just before fcntl
                        // returned — treat as timeout (fd is already closed).
                        timer.cancel()
                        continuation.resume(throwing: OfemConfigError.lockTimeout)
                    }
                } else {
                    let err = Darwin.errno
                    timer.cancel()
                    if fdState.load() == .closedByTimer {
                        // fd was closed by the timer; fd is already closed.
                        continuation.resume(throwing: OfemConfigError.lockTimeout)
                    } else {
                        // Unexpected error — close fd before surfacing.
                        Darwin.close(fd)
                        continuation.resume(throwing: OfemConfigError.lockFailed(
                            NSError(domain: NSPOSIXErrorDomain, code: Int(err))
                        ))
                    }
                }
            }
            t.name = "dev.debruyn.ofem.config-lock"
            t.qualityOfService = .utility
            t.start()
        }
    }
}

// MARK: - AtomicFDState helper

private enum FDState { case open, acquiredByThread, closedByTimer }

/// Minimal thread-safe state machine for the fd lifecycle during lock acquisition.
private final class AtomicFDState: @unchecked Sendable {
    private var _lock = os_unfair_lock()
    private var _state: FDState

    init(_ initial: FDState) {
        _state = initial
    }

    func load() -> FDState {
        os_unfair_lock_lock(&_lock)
        defer { os_unfair_lock_unlock(&_lock) }
        return _state
    }

    /// Transitions from `expected` to `desired` atomically.
    /// - Returns: `true` if the transition succeeded.
    @discardableResult
    func compareExchange(expected: FDState, desired: FDState) -> Bool {
        os_unfair_lock_lock(&_lock)
        defer { os_unfair_lock_unlock(&_lock) }
        guard _state == expected else { return false }
        _state = desired
        return true
    }
}
