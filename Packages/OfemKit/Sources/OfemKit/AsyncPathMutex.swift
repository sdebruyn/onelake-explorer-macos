// MARK: - AsyncPathMutex

/// A process-wide, per-path async mutex used to serialise **in-process**
/// callers *before* they open/lock a file with a cross-process `fcntl`
/// advisory record lock.
///
/// ## Why this exists (F12)
///
/// POSIX `fcntl` record locks are owned by the *process*, not the file
/// descriptor. A second `open()` + `F_SETLKW` from the *same* process, on a
/// file it already holds the lock on, is granted immediately — locks held
/// by one process never conflict with themselves. Worse, `close()` on *any*
/// fd for that file drops *every* lock the process holds on it, not just
/// the one tied to the fd being closed.
///
/// `FileTokenStore` and `OfemConfigStore` used to acquire the cross-process
/// lock first and rely on an in-process `DispatchQueue` only for the I/O
/// section that followed. Two overlapping same-process writers (e.g. two
/// MSAL `didWriteCache` callbacks racing a storage- and a Fabric-scope
/// token refresh) were both "granted" the fcntl lock immediately, per the
/// paragraph above. When the first writer's `defer`-triggered `close(fd)`
/// ran, it silently dropped the lock for the *whole process* — including
/// the second writer, which was still mid-write. The cross-process
/// protection window closed before the second write finished, so a peer
/// process (host app or File Provider Extension) could interleave a write
/// in the middle of it, clobbering a freshly minted refresh token or a
/// config mutation.
///
/// The fix: acquire this mutex, keyed by the same canonical path used for
/// the fcntl lock file, *before* opening/locking that file. At most one
/// in-process caller ever holds an open fcntl-lock fd for a given path at a
/// time, so one caller's fcntl-acquire → I/O → fcntl-release sequence can
/// never overlap with a same-process sibling's — closing the first
/// caller's fd can no longer clip a sibling's lock, because there is no
/// sibling in flight.
///
/// Waiting callers suspend their `Task` (via `withCheckedContinuation`); no
/// OS thread is blocked while waiting for a turn, mirroring the
/// non-blocking design of `ConfigFileLock` and `FileTokenStore`'s
/// `acquireAliasLockAsync`.
///
/// ## Usage
///
/// `acquire`/`release` are separate actor-isolated methods (not a
/// higher-order `withLock` wrapper) so that callers can release from a
/// plain `catch` block — `defer` bodies cannot contain `await`, so a
/// closure-based scoped-lock API would force an unstructured `Task {}` on
/// the release path, which this design avoids:
///
/// ```swift
/// await AsyncPathMutex.shared.acquire(path: key)
/// do {
///     // ... acquire the fcntl lock, do the I/O, release the fcntl lock ...
///     await AsyncPathMutex.shared.release(path: key)
/// } catch {
///     await AsyncPathMutex.shared.release(path: key)
///     throw error
/// }
/// ```
///
/// ## Cancellation
///
/// `acquire` is **deliberately not cancellation-aware** — it suspends on a
/// plain `Void, Never` continuation with no `withTaskCancellationHandler`,
/// so a cancelled caller keeps waiting for its turn like everyone else in
/// the FIFO queue. This is the opposite of ``AsyncSemaphore``, whose
/// `wait()` observes cancellation and throws `CancellationError` instead of
/// granting the slot.
///
/// The asymmetry is intentional. `AsyncSemaphore` bounds *concurrency*
/// (e.g. "at most N uploads at once"), where a cancelled waiter can simply
/// give up its place — no one is depending on it having run. `AsyncPathMutex`
/// instead serialises a *must-complete* critical section: acquire → take the
/// cross-process fcntl lock → do the I/O → release the fcntl lock → release
/// (see "Why this exists" above). If a queued caller could abandon its turn
/// on cancellation, the turn would simply pass to the next waiter as normal —
/// but the *cancelled* caller's own fcntl-acquire/I-O/fcntl-release sequence
/// would never run, silently skipping work its caller may still be
/// depending on completing (e.g. a token write already committed to the
/// in-memory cache). Making `acquire` uncancellable keeps "the turn was
/// granted" and "the critical section will run" the same guarantee.
actor AsyncPathMutex {
    /// Process-wide singleton — all callers in this process share one
    /// registry of per-path turns.
    static let shared = AsyncPathMutex()

    /// Paths currently "held" (someone is in their turn).
    private var held: Set<String> = []
    /// FIFO queue of waiters per path, resumed in arrival order.
    private var waiters: [String: [CheckedContinuation<Void, Never>]] = [:]

    private init() {}

    /// Suspends until the caller holds the turn for `path`. Must be paired
    /// with a matching ``release(path:)`` on every exit path (including
    /// thrown errors).
    func acquire(path: String) async {
        guard held.contains(path) else {
            held.insert(path)
            return
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            waiters[path, default: []].append(continuation)
        }
    }

    /// Releases the turn for `path`, handing it directly to the next FIFO
    /// waiter (if any) or marking `path` free.
    func release(path: String) {
        guard var queue = waiters[path], !queue.isEmpty else {
            held.remove(path)
            return
        }
        let next = queue.removeFirst()
        waiters[path] = queue.isEmpty ? nil : queue
        // Ownership transfers directly to `next` — `path` stays in `held`.
        next.resume()
    }
}
