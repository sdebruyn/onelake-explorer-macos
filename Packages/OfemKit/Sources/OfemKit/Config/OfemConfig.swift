import Foundation
import TOMLKit

// MARK: - OfemConfigStore

/// Thread-safe store that loads and saves ``OfemConfig`` from/to
/// `<configDir>/config.toml`.
///
/// ## Cross-process safety
///
/// The host app and the File Provider Extension both write to the same
/// `config.toml` in the shared App Group container. `updateAndSave` uses a
/// POSIX advisory `fcntl(2)` record lock (`F_SETLKW`, blocking on a dedicated
/// thread) on a sidecar `.config.lock` file to serialise writers across
/// processes:
///
/// 1. Acquire an exclusive lock on `.config.lock` via ``ConfigFileLock``.
///    The acquire runs `F_SETLKW` on a dedicated OS thread so the shared
///    per-path DispatchQueue is not blocked during cross-process contention.
///    Throws ``OfemConfigError/lockTimeout`` after ~5 s if the peer never
///    releases.
/// 2. Re-read `config.toml` from disk (discard the stale in-memory snapshot).
/// 3. Apply the caller's mutation closure to the freshly loaded state.
/// 4. Write the result atomically (temp file + rename).
/// 5. Update the in-memory snapshot and release the lock.
///
/// **Per-process caveat**: `fcntl` record locks are owned by the *process*, not
/// the file descriptor. Two `OfemConfigStore` instances in the *same* process
/// would not exclude each other via `fcntl` alone — the kernel grants the
/// lock to the same process immediately. To prevent intra-process split-brain,
/// a process-wide serial ``DispatchQueue`` registry (keyed by canonical
/// config-file path) serialises all `updateAndSave` calls for the same file
/// within one process, while `fcntl` handles cross-process exclusion.
///
/// **Lock acquisition order — in-process mutex before fcntl (F12)**: the
/// `DispatchQueue` above is only entered *after* `ConfigFileLock.acquire()`
/// has already been granted. Because `fcntl` locks are per-process, a second
/// same-process caller is granted the lock immediately too — and `close()`
/// on *any* fd for that file drops *every* lock the process holds on it. If
/// two same-process `updateAndSave` calls both "acquired" the fcntl lock
/// this way, the first caller's `lock.release()` would silently drop the
/// lock for the whole process while the second caller was still mid-write,
/// leaving that write unprotected against the peer process. To prevent
/// this, `updateAndSave` acquires a per-path in-process async mutex
/// (``AsyncPathMutex``) *before* calling `ConfigFileLock.acquire()`, so at
/// most one in-process caller ever holds an open lock fd for `config.toml`
/// at a time. See ``AsyncPathMutex`` for the full explanation.
public final class OfemConfigStore: Sendable {
    private let paths: OfemPaths
    /// Per-path process-wide serial queue (see ``sharedQueue(for:)``).
    private let serialQueue: DispatchQueue
    /// In-memory snapshot, mutated only while holding `serialQueue`.
    private nonisolated(unsafe) var config: OfemConfig

    // MARK: - Process-wide intra-process serialisation registry

    /// Registry lock (guards `_queueRegistry`).
    private static let registryLock = NSLock()
    /// Map from canonical config-file path → serial DispatchQueue.
    /// All `OfemConfigStore` instances for the *same* file share one queue,
    /// so concurrent `updateAndSave` calls within the same process are
    /// serialised without relying on `fcntl` (which is per-process, not
    /// per-fd). Cross-process exclusion is handled by `fcntl` record locks.
    private nonisolated(unsafe) static var _queueRegistry: [String: DispatchQueue] = [:]

    private static func sharedQueue(for configFile: URL) -> DispatchQueue {
        // Use the canonical path string as both the registry key and the
        // queue label. The path is stable and unique per file; using it
        // directly avoids the hash-collision risk of `String.hash` (which is
        // per-process-run salted and not suitable for identity).
        let key = configFile.resolvingSymlinksInPath().path(percentEncoded: false)
        return registryLock.withLock {
            if let q = _queueRegistry[key] { return q }
            let q = DispatchQueue(label: "dev.debruyn.ofem.config[\(key)]", qos: .utility)
            _queueRegistry[key] = q
            return q
        }
    }

    // MARK: - Initialisers

    /// Loads the config from the canonical paths. If the file does not exist
    /// a default config is returned; call ``updateAndSave(_:)`` to persist it.
    ///
    /// - Throws: ``OfemConfigError`` on TOML parse failures or I/O errors.
    public convenience init() throws {
        try self.init(paths: OfemPaths())
    }

    /// Loads from explicit paths. Use in tests or sandboxed callers that
    /// resolve their App Group container via Apple's API.
    ///
    /// - Throws: ``OfemConfigError`` on TOML parse failures or I/O errors.
    public init(paths: OfemPaths) throws {
        self.paths = paths
        self.serialQueue = Self.sharedQueue(for: paths.configFile)
        self.config = try Self.load(from: paths)
    }

    // MARK: - Public API

    /// Returns a snapshot copy of the **in-memory** config state.
    ///
    /// This value reflects the last `updateAndSave` performed by *this*
    /// store instance. When another process (e.g. the FPE) writes
    /// `config.toml` concurrently, the in-memory value goes stale until
    /// the next `updateAndSave` call re-reads from disk.
    ///
    /// For callers that need the *current on-disk* state, use
    /// ``freshSnapshot()`` instead.
    public func snapshot() -> OfemConfig {
        serialQueue.sync { config }
    }

    /// Returns a snapshot that is guaranteed to reflect the current on-disk
    /// state, including any writes made by the other process (host or FPE)
    /// since this store was last updated.
    ///
    /// This performs a disk read (under the intra-process serial queue, but
    /// *without* acquiring the cross-process `fcntl` lock — it is a
    /// best-effort read, not a transactional read-modify-write).
    ///
    /// Use ``updateAndSave(_:)`` when you need a consistent read-modify-write
    /// cycle across processes.
    ///
    // periphery:ignore
    /// - Throws: ``OfemConfigError`` on I/O or parse failure.
    public func freshSnapshot() throws -> OfemConfig {
        let paths = self.paths
        return try serialQueue.sync {
            let fresh = try Self.load(from: paths)
            self.config = fresh
            return fresh
        }
    }

    /// Applies `mutator` to the **freshly re-read on-disk state** and persists
    /// the result atomically. The calling Swift task suspends (not blocks)
    /// during cross-process lock contention — the shared serial queue is never
    /// blocked waiting for another process.
    ///
    /// The sequence is:
    /// 1. Acquire the cross-process `fcntl` file lock via ``ConfigFileLock``.
    ///    The lock thread (`F_SETLKW`) runs on a *dedicated* OS thread; the
    ///    calling Swift task suspends at the `await` without occupying any
    ///    thread while waiting. The shared serial queue is *not* involved
    ///    during lock contention.
    /// 2. Once the lock is held, the read-modify-write cycle runs
    ///    synchronously on the per-path serial queue (`queue.sync`) so
    ///    intra-process writers are serialised *only* during the fast I/O
    ///    section, not during cross-process contention.
    /// 3. Update the in-memory snapshot and release the lock.
    /// 4. Resume the caller with the saved config.
    ///
    /// Concurrent callers within the same process are serialised by the
    /// per-path `DispatchQueue` registry (step 2). Callers in different
    /// processes are serialised by `fcntl(2)` record locking (step 1).
    ///
    /// The mutator must not call back into the store.
    @discardableResult
    public func updateAndSave(_ mutator: @escaping @Sendable (inout OfemConfig) throws -> Void) async throws -> OfemConfig {
        let paths = self.paths
        let queue = self.serialQueue
        let mutexKey = Self.configMutexKey(paths: paths)

        // F12: serialise in-process callers BEFORE acquiring the
        // cross-process fcntl lock — see the type doc for why the ordering
        // here is load-bearing. `outcome` guarantees exactly one
        // `release(path:)` call regardless of success or failure —
        // releasing twice for a single `acquire` would hand the turn to a
        // waiter prematurely.
        await AsyncPathMutex.shared.acquire(path: mutexKey)
        let outcome: Result<OfemConfig, Error>
        do {
            // Step 1: acquire the cross-process file lock.
            // ConfigFileLock.acquire() suspends this Task (via a continuation +
            // dedicated OS thread for F_SETLKW) — no GCD thread is blocked.
            let lock = try await ConfigFileLock.acquire(paths: paths)

            // Step 2: hold the lock; run read-modify-write on the serial queue.
            // queue.sync is fast (just I/O, no sleeping) so blocking this thread
            // briefly is acceptable. The serial queue ensures intra-process
            // callers don't interleave their own read-modify-write cycles.
            // NOTE: `lock.release()` is called explicitly on both branches
            // below, immediately before `continuation.resume(...)` — NOT via
            // `defer`. `continuation.resume()` only *schedules* the awaiting
            // Task; it does not wait for the rest of this closure to finish.
            // A `defer { lock.release() }` placed after `resume()` would race
            // the resumed Task against this GCD thread: the resumed Task
            // could reach `AsyncPathMutex.shared.release(path:)` below and
            // free the mutex for a second in-process caller — which would
            // then acquire the (per-process) fcntl lock immediately — before
            // this thread's deferred `lock.release()` actually closes the
            // fd, reintroducing the exact F12 clobber this mutex exists to
            // prevent, just in a narrower window. Releasing the fcntl lock
            // *before* resuming establishes a genuine happens-before: the fd
            // is guaranteed closed before the resumed Task can possibly call
            // `AsyncPathMutex.shared.release(path:)`.
            let fresh: OfemConfig = try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    do {
                        var fresh = try Self.load(from: paths)
                        try mutator(&fresh)
                        try Self.save(fresh, to: paths)
                        self.config = fresh
                        lock.release()
                        continuation.resume(returning: fresh)
                    } catch {
                        lock.release()
                        continuation.resume(throwing: error)
                    }
                }
            }
            outcome = .success(fresh)
        } catch {
            outcome = .failure(error)
        }
        await AsyncPathMutex.shared.release(path: mutexKey)
        return try outcome.get()
    }

    /// Returns the canonical ``AsyncPathMutex`` key for this store's config
    /// file — the resolved path of the same `.config.lock` sidecar that
    /// ``ConfigFileLock/acquire(paths:timeoutNs:)`` opens (F12). Using this
    /// as the mutex key ensures the in-process mutex and the cross-process
    /// fcntl lock always agree on which resource they're protecting.
    private static func configMutexKey(paths: OfemPaths) -> String {
        paths.configDir
            .appending(path: ".config.lock", directoryHint: .notDirectory)
            .resolvingSymlinksInPath()
            .path(percentEncoded: false)
    }

    // MARK: - Private helpers

    /// `load` and `save` are `internal` (not `private`) so that `@testable
    /// import OfemKit` test targets can reach them directly. They are not part
    /// of the public API and must not be called outside this type.
    static func load(from paths: OfemPaths) throws -> OfemConfig {
        let data: Data
        do {
            data = try Data(contentsOf: paths.configFile)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return OfemConfig.makeDefault()
        } catch {
            throw OfemConfigError.readFailed(error)
        }

        guard let tomlString = String(data: data, encoding: .utf8) else {
            throw OfemConfigError.invalidUTF8
        }

        do {
            return try TOMLDecoder().decode(OfemConfig.self, from: tomlString)
        } catch {
            throw OfemConfigError.parseFailed(error)
        }
    }

    static func save(_ cfg: OfemConfig, to paths: OfemPaths) throws {
        let fm = FileManager.default

        // Ensure the config directory exists.
        do {
            try fm.createDirectory(
                at: paths.configDir,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            throw OfemConfigError.createDirectoryFailed(error)
        }

        // Encode to TOML.
        let tomlString: String
        do {
            tomlString = try TOMLEncoder().encode(cfg)
        } catch {
            throw OfemConfigError.encodeFailed(error)
        }

        guard let data = tomlString.data(using: .utf8) else {
            throw OfemConfigError.encodeFailed(
                NSError(domain: "OfemKit", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "TOML output is not valid UTF-8",
                ])
            )
        }

        // Write to a temp file in the same directory, set permissions, then
        // atomically rename. A crash between write and rename leaves an
        // orphan scratch file; a startup sweep could clean these up, but for
        // now the litter is accepted as a minor trade-off (config-08 nit).
        let tmpURL = paths.configDir.appending(
            path: "config.toml.\(ProcessInfo.processInfo.globallyUniqueString)",
            directoryHint: .notDirectory
        )

        do {
            try data.write(to: tmpURL)
        } catch {
            throw OfemConfigError.writeFailed(error)
        }

        do {
            try fm.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: tmpURL.path(percentEncoded: false)
            )
        } catch {
            try? fm.removeItem(at: tmpURL)
            throw OfemConfigError.chmodFailed(error)
        }

        do {
            _ = try fm.replaceItemAt(paths.configFile, withItemAt: tmpURL)
        } catch {
            try? fm.removeItem(at: tmpURL)
            throw OfemConfigError.renameFailed(error)
        }
    }
}
