import Foundation
import GRDB
import os.log

// MARK: - CacheStore

/// Top-level façade for the OFEM metadata + blob cache.
///
/// `CacheStore` is a Swift `actor` that serialises all writes through a single
/// GRDB `DatabasePool`. Reads can proceed concurrently via GRDB's WAL snapshot
/// isolation; the ``reader`` property returns a `CacheReader` that any number
/// of tasks may query in parallel.
///
/// ## Directory layout
///
/// ```
/// <root>/
/// cache.sqlite ← GRDB DatabasePool (WAL mode)
/// cache.sqlite-wal
/// cache.sqlite-shm
/// blobs/
/// <2-hex>/
/// <62-hex> ← blob content
/// ```
public actor CacheStore {
    // MARK: - Constants

    /// Name of the SQLite file inside the root directory.
    public static let sqliteFile = "cache.sqlite"

    /// POSIX permission mode for the cache root directory (owner rwx only).
    private static let rootDirectoryMode: Int = 0o700

    /// SQLite busy-wait timeout in milliseconds.
    private static let busyTimeoutMs: Int = 5000

    /// Grace window for the init-time orphan sweep, in seconds.
    ///
    /// A blob file or `*.tmp` scratch file whose modification time is within
    /// this interval of the sweep is spared: it may belong to a concurrent,
    /// in-flight ``storeBlob(key:data:)`` / ``storeBlobFromURL(_:key:)`` whose
    /// disk write has landed but whose DB commit (or, for a `*.tmp`, whose
    /// rename into the shard) has not happened yet. Genuine crash-orphans were
    /// written by a prior process and are older than this window, so they are
    /// still reclaimed. Comfortably larger than any realistic file-write→DB-
    /// commit gap; a spuriously spared orphan self-heals on a later sweep,
    /// whereas a spuriously deleted valid blob is the bug this window closes.
    ///
    /// 60 s is a deliberate, probabilistic bound rather than a proof: a
    /// write→commit stall beyond it is unrealistic given the 5 s DB busy
    /// timeout (``busyTimeoutMs``), and a genuine orphan younger than the
    /// window is merely deferred to a later launch's sweep, never lost.
    private static let orphanSweepGraceInterval: TimeInterval = 60

    // MARK: - Private state

    // Internal so test targets can run direct SQL assertions.
    let dbPool: DatabasePool
    let blobs: BlobShardCache
    /// LRU eviction threshold for blob bytes. `var` (not `let`) so
    /// ``setMaxBlobBytes(_:)`` can update the budget live. Actor isolation
    /// serialises reads and writes made from actor-isolated code (e.g. the
    /// `guard maxBlobBytes > 0` checks in ``storeBlob(key:data:)`` and
    /// ``storeBlobFromURL(_:key:)``) — but it does **not** protect a read
    /// made from inside a `dbPool.write { }` closure, which runs on GRDB's
    /// writer queue, off this actor. ``evictToLimit()`` snapshots the value
    /// into a local `let` before entering any of its (possibly several)
    /// `dbPool.write { }` passes, for exactly this reason; do not reintroduce
    /// a direct `maxBlobBytes` reference inside a `dbPool.write { }` /
    /// `dbPool.read { }` closure.
    var maxBlobBytes: Int64

    /// Clock injection seam: returns the current time as Unix nanoseconds.
    /// Defaults to wall clock; override in tests for deterministic ordering.
    let clock: () -> Int64

    static let log = Logger(subsystem: "dev.debruyn.ofem", category: "CacheStore")

    /// Structured logger for debug-level cache diagnostics.
    let logger: OfemLogger

    // MARK: - Public state

    /// The root directory passed at construction time.
    // periphery:ignore
    public nonisolated let root: URL

    /// The blob root directory (`<root>/blobs`).
    // periphery:ignore
    public nonisolated let blobRoot: URL

    // MARK: - Initialiser

    /// Opens (or creates) the cache at `root`.
    ///
    /// - Parameters:
    ///   - root: Directory that holds `cache.sqlite` and `blobs/`. Created
    ///     with mode 0o700 if missing.
    ///   - maxBlobBytes: LRU eviction threshold for blob bytes. Zero = no
    ///     eviction (``evictToLimit()`` becomes a no-op).
    ///   - clock: Closure that returns the current time as Unix nanoseconds.
    ///     Inject a deterministic clock in tests; omit for wall-clock production behaviour.
    ///
    /// The database is opened in **WAL mode** with `synchronous = NORMAL` and
    /// a 5-second busy timeout. An orphan-sweep runs at initialisation time to
    /// remove any blob files that have no matching metadata row.
    /// Note: the default clock closure duplicates the wallClockNs formula rather than
    /// referencing it directly because wallClockNs is internal and this init is public;
    /// Swift requires default argument expressions to be at least as visible as the
    /// declaration they appear in.
    public init(
        root: URL,
        maxBlobBytes: Int64 = 0,
        clock: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1_000_000_000) },
        logger: OfemLogger = .init()
    ) throws {
        self.root = root
        self.maxBlobBytes = maxBlobBytes
        self.clock = clock
        self.logger = logger

        // Create root directory.
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: Self.rootDirectoryMode]
        )

        // Initialise blob store.
        let blobRootURL = root.appendingPathComponent(BlobShardCache.blobsSubdir, isDirectory: true)
        blobs = try BlobShardCache(blobRoot: blobRootURL)
        blobRoot = blobRootURL

        // Open database pool.
        let dbURL = root.appendingPathComponent(CacheStore.sqliteFile)
        var config = Configuration()
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA journal_mode = WAL")
            try db.execute(sql: "PRAGMA synchronous = NORMAL")
            try db.execute(sql: "PRAGMA busy_timeout = \(CacheStore.busyTimeoutMs)")
            try db.execute(sql: "PRAGMA foreign_keys = ON")
            try Self.enableCaseSensitiveLike(db)
        }
        dbPool = try DatabasePool(path: dbURL.path, configuration: config)

        // Apply any pending migrations.
        let m = CacheSchema.migrator()
        try m.migrate(dbPool)

        // Kick off the orphan sweep asynchronously so that init never blocks
        // the calling thread on a directory walk + db write.
        //
        // The sweep logs warnings on failure rather than discarding them with
        // try? — errors are surfaced to the log but do not abort the actor.
        // The sweep spares any blob (or *.tmp) file modified within
        // orphanSweepGraceInterval of it, so a blob written by a concurrent,
        // in-flight storeBlob/storeBlobFromURL — whose disk file exists but
        // whose DB UPDATE has not yet committed — is never mistaken for an
        // orphan and deleted. Only files older than that window (genuine
        // crash-orphans from a prior process) are reaped.
        let blobsCapture = blobs
        let dbCapture = dbPool
        Task { [blobsCapture, dbCapture] in
            do {
                try Self.sweepOrphanBlobs(blobs: blobsCapture, dbPool: dbCapture)
            } catch {
                Self.log.warning("CacheStore: init-time orphan sweep failed: \(error, privacy: .public)")
            }
        }
    }

    // MARK: - Reader

    /// Returns a read-only view over the pool. Any number of tasks can hold
    /// a `CacheReader` simultaneously; reads never block writers (WAL snapshot
    /// isolation).
    public nonisolated func reader() -> CacheReader {
        CacheReader(db: dbPool, logger: logger)
    }

    // MARK: - Live budget update

    /// Updates the LRU eviction budget live, without recreating `CacheStore`.
    ///
    /// The new limit applies on the next ``storeBlob(key:data:)`` /
    /// ``storeBlobFromURL(_:key:)`` write (both call ``evictToLimit()``
    /// automatically) or the next explicit ``evictToLimit()`` call — it does
    /// not retroactively evict already-cached blobs the moment this is
    /// called. `0` disables eviction (matches the `init` semantics).
    ///
    /// Actor isolation serialises this write against concurrent calls made
    /// from other actor-isolated code — no separate lock needed for *that*.
    /// It does **not**, by itself, make every existing read of
    /// `maxBlobBytes` safe; see the property's doc comment for the one call
    /// site (inside a `dbPool.write { }` closure) that has to snapshot the
    /// value instead of reading `self.maxBlobBytes` directly.
    ///
    /// Called by `FPEEngineHost.reloadEngine()` after a
    /// `setConfig(cache.max_size_gb:)` XPC call so the budget takes effect
    /// immediately — the shared `CacheStore` singleton is not rebuilt on
    /// reload.
    public func setMaxBlobBytes(_ value: Int64) {
        maxBlobBytes = value
    }

    #if DEBUG
        // periphery:ignore
        /// Current eviction budget. Test-only introspection — production
        /// callers have no legitimate need to read this back (they only ever
        /// set it). Exposed so `FPEEngineHostTests` can assert that
        /// `reloadEngine()` actually propagates a config change to the shared
        /// `CacheStore` without needing to write gigabyte-scale blob data to
        /// observe eviction behaviour (`cache.max_size_gb` is whole-GB
        /// granularity).
        ///
        /// `#if DEBUG`-gated (matching `FPEEngineHost`'s `*ForTesting` seams)
        /// so this test-only surface never ships in a Release build.
        public var maxBlobBytesForTesting: Int64 {
            maxBlobBytes
        }
    #endif

    // MARK: - Read-only factory (host process)

    /// Opens the cache at `root` in read-only mode and returns a `CacheReader`.
    ///
    /// Unlike the full `CacheStore.init`, this factory does **not** run the
    /// orphan-blob sweep — a write transaction that competes with the FPE
    /// process's writes.  Use this in the host app, which only needs to read
    /// the workspace cache; the FPE is the sole writer.
    ///
    /// `config.readonly = true` makes this an actual enforcement, not just an
    /// API-shape convention: the connection is opened with `SQLITE_OPEN_READONLY`,
    /// so a write attempted through it — including one that reached the raw
    /// `Database` inside a `.read { }` closure, bypassing `CacheReader`'s
    /// `DatabaseReader`-typed surface — is rejected by SQLite itself, not just
    /// by the absence of a write method on `CacheReader`. `CacheReader` never
    /// calls `.write()` (it only wraps `DatabaseReader`, which has no write
    /// API), and its one host-app caller (`ChangeWatcher.getOrOpenCacheReader()`)
    /// only ever reads through it — the FPE remains the sole writer.
    ///
    /// Returns `nil` when the SQLite file cannot be opened. Usually this means
    /// the FPE has not yet created the database; more rarely it means the
    /// database exists but a read-only connection can't open it cleanly right
    /// now — e.g. a crash left an uncheckpointed `-wal` with a stale or absent
    /// `-shm` before the FPE (the sole writer) has relaunched to run recovery,
    /// which a read-only connection cannot do itself. Either way this is
    /// self-healing: the caller (`ChangeWatcher`) treats `nil` as "skip this
    /// tick" and retries on the next poll, by which point the FPE has
    /// recovered the database.
    public static func openReadOnly(root: URL, logger: OfemLogger = .init()) -> CacheReader? {
        guard let pool = openReadOnlyPool(root: root) else { return nil }
        return CacheReader(db: pool, logger: logger)
    }

    /// Shared read-only pool construction for ``openReadOnly(root:logger:)``
    /// and the DEBUG-only ``openReadOnlyPoolForTesting(root:)`` seam — kept in
    /// one place so the two never drift apart.
    private static func openReadOnlyPool(root: URL) -> DatabasePool? {
        let dbURL = root.appendingPathComponent(CacheStore.sqliteFile)
        guard FileManager.default.fileExists(atPath: dbURL.path) else { return nil }
        var config = Configuration()
        config.readonly = true
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA journal_mode = WAL")
            try db.execute(sql: "PRAGMA busy_timeout = \(CacheStore.busyTimeoutMs)")
            try Self.enableCaseSensitiveLike(db)
        }
        return try? DatabasePool(path: dbURL.path, configuration: config)
    }

    #if DEBUG
        // periphery:ignore
        /// Test-only: like ``openReadOnly(root:logger:)`` but returns the raw
        /// `DatabasePool` instead of a `CacheReader`, so tests can assert that
        /// a write attempted directly through the pool — not merely absent
        /// from `CacheReader`'s API surface — is rejected by SQLite. Confirms
        /// `config.readonly = true` above is real enforcement.
        static func openReadOnlyPoolForTesting(root: URL) -> DatabasePool? {
            openReadOnlyPool(root: root)
        }
    #endif

    // MARK: - Orphan sweep

    // periphery:ignore
    /// Runs the orphan-blob sweep synchronously (blocking the actor).
    ///
    /// The background `Task` started at `init` time runs the same sweep but
    /// may not have completed yet. Call this from tests or maintenance paths
    /// that need the sweep to have completed before proceeding.
    public func sweepOrphans() throws {
        try Self.sweepOrphanBlobs(blobs: blobs, dbPool: dbPool)
    }

    // MARK: Orphan sweep

    /// Removes blob files on disk that have no corresponding metadata row.
    ///
    /// Also removes orphaned `*.tmp` scratch files left behind by a crash
    /// during ``BlobShardCache/store(_:)`` — these are never referenced by the
    /// DB and would otherwise accumulate unbounded.
    ///
    /// Called once at initialisation time to reconcile shard-dir contents
    /// against DB references and eliminate files orphaned by prior crashes
    /// or bugs.
    ///
    /// ## Concurrency invariant
    ///
    /// A blob *written* by a concurrent, in-flight ``storeBlob(key:data:)`` /
    /// ``storeBlobFromURL(_:key:)`` — one whose file lands on disk while, or
    /// after, this sweep runs — is spared. Both operations write the blob file
    /// first and commit the `blob_sha256` row second, so between those two
    /// non-atomic steps the file exists on disk with no DB reference and is, by
    /// DB state alone, indistinguishable from a genuine orphan. The sweep
    /// therefore reaps only files whose modification time predates a cutoff of
    /// `now - orphanSweepGraceInterval`; anything newer (ties included) is
    /// spared. A freshly written blob has a fresh mtime and is kept; genuine
    /// crash-orphans come from a prior process, predate the window, and are
    /// still reclaimed. The write-transaction referenced query below is a
    /// secondary guard that serialises against a concurrent DB commit; on its
    /// own it does not cover the file-written-before-commit gap — the grace
    /// window does.
    ///
    /// Known limitation (out of scope here, self-healing): an *old* (> grace)
    /// unreferenced orphan that a concurrent store re-references via
    /// ``BlobShardCache/store(_:)``'s dedup path — which reuses the existing
    /// file and so does **not** refresh its mtime — can still be deleted if the
    /// sweep's referenced-SELECT transaction commits before that store's
    /// `blob_sha256` UPDATE. The write-txn serialises the two but does not order
    /// them, so the sweep may unlink a blob that is about to be referenced. This
    /// race is pre-existing and heals on the next fetch (cache miss →
    /// re-download); it is tracked separately, not addressed by this guard.
    private static func sweepOrphanBlobs(blobs: BlobShardCache, dbPool: DatabasePool) throws {
        // Walk the blob root and collect all SHA-256 values present on disk.
        guard FileManager.default.fileExists(atPath: blobs.blobRoot.path) else { return }

        // Files modified at/after this cutoff are spared — see the concurrency
        // invariant above. Captured once, up front, so a file written while the
        // walk is still running is measured against a stable boundary.
        let cutoff = Date().addingTimeInterval(-orphanSweepGraceInterval)

        let enumerator = FileManager.default.enumerator(
            at: blobs.blobRoot,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )
        var onDisk: [String] = []
        while let url = enumerator?.nextObject() as? URL {
            // Read the prefetched resource values once (the enumerator loaded
            // both keys above) so the grace check does not re-stat the file.
            let vals = try? url.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey])

            // Spare anything freshly written: it may belong to a concurrent
            // in-flight store (its blob or its *.tmp scratch file), not a stale
            // orphan. This is the primary guard for the file-before-commit gap.
            if isWithinGraceWindow(mtime: vals?.contentModificationDate, cutoff: cutoff) { continue }

            // Remove orphaned *.tmp scratch files — written by BlobShardCache.store
            // but never renamed into place (crash mid-write).  They are never DB-
            // referenced and must not accumulate.
            if url.pathExtension == "tmp" {
                try? FileManager.default.removeItem(at: url)
                continue
            }
            guard vals?.isRegularFile == true else { continue }
            // Reconstruct SHA from shard-prefix + filename using the single
            // source-of-truth helper on BlobShardCache (not an ad-hoc `prefix(2)`).
            let shard = url.deletingLastPathComponent().lastPathComponent
            let file = url.lastPathComponent
            guard let sha = blobs.sha(fromShard: shard, file: file) else { continue }
            onDisk.append(sha)
        }

        guard !onDisk.isEmpty else { return }

        // Ask the DB which of those are actually referenced.
        //
        // Secondary guard: use a write transaction (not a snapshot read) so a
        // concurrent storeBlob that has already committed serialises ahead of
        // this query rather than being missed by a stale snapshot. The primary
        // protection against the file-written-but-not-yet-committed window is the
        // grace cutoff above; this serialiser only narrows the DB-visibility race
        // for candidates already older than that window. Matches the pattern used
        // by deleteUnreferencedBlobs.
        let referenced: Set<String> = try dbPool.write { db in
            let rows = try String.fetchAll(db, sql: """
            SELECT DISTINCT blob_sha256 FROM path_metadata WHERE blob_sha256 != ''
            """)
            return Set(rows)
        }

        for sha in onDisk where !referenced.contains(sha) {
            do {
                try blobs.delete(sha256: sha)
            } catch {
                Self.log.warning("CacheStore: sweep failed to delete sha=\(sha, privacy: .public): \(error, privacy: .public)")
            }
        }
    }

    /// Returns `true` when a file whose modification time is `mtime` falls
    /// inside the sweep's grace window — `mtime` is `nil` (unreadable) or
    /// at/after `cutoff` — and must therefore be spared. An unreadable mtime is
    /// treated as fresh: keeping a file a concurrent writer may have just
    /// produced is safer than deleting it.
    static func isWithinGraceWindow(mtime: Date?, cutoff: Date) -> Bool {
        guard let mtime else { return true }
        return mtime >= cutoff
    }

    // MARK: - Private helpers

    // MARK: LIKE case-sensitivity (#426)

    /// Sets `case_sensitive_like = ON` for one connection.
    ///
    /// OneLake paths are case-sensitive, but SQLite's `LIKE` operator is
    /// ASCII-case-insensitive by default. Every subtree/prefix match in this
    /// file — ``delete(key:)``, ``batchDelete(_:recordTombstones:)``,
    /// ``renamePathPrefix(accountAlias:workspaceID:itemID:oldPath:newPath:newName:)``,
    /// ``removeMaterialized(alias:identifierPrefix:)`` — matches descendants
    /// with `path LIKE prefix || '/%'` (or the `identifier_string` equivalent).
    /// Without this pragma, two siblings differing only in ASCII case
    /// (`Reports/…` vs `reports/…`) would cross-match: deleting, renaming, or
    /// unmaterializing one would incorrectly touch the other's cached rows.
    ///
    /// Called from `prepareDatabase` (once per pooled connection, both the
    /// read-write pool in `init` and the read-only pool in ``openReadOnly(root:logger:)``)
    /// rather than qualifying each call site individually — a grep of every
    /// `LIKE` in this file (and of `CacheReader`, which has none) confirms no
    /// query anywhere relies on the case-insensitive default, so a single
    /// connection-wide pragma is safe.
    ///
    /// This also does not trade away the index: SQLite's LIKE-to-range-scan
    /// optimization only converts a `LIKE 'prefix%'` into a `>= / <` B-tree
    /// range bound when the column is BINARY-collated AND
    /// `case_sensitive_like` is ON — with the default OFF, a BINARY-collated
    /// column (which `path` and `identifier_string` are; neither declares
    /// `COLLATE NOCASE`) could never use that optimization against
    /// `idx_pm_path` in the first place. Enabling the pragma is therefore a
    /// net win for the index, not a tradeoff against it.
    ///
    /// Assumption: ``removeMaterialized(alias:identifierPrefix:)`` and
    /// ``renamePathPrefix(accountAlias:workspaceID:itemID:oldPath:newPath:newName:)``'s
    /// destination-tombstone clear build their LIKE prefix directly from
    /// `workspaceID`/`itemID` GUIDs, with no case normalization anywhere in
    /// this file. Both rely on Fabric never echoing a workspace/item GUID
    /// back in different letter casing than when the row was first written.
    /// This is not a new exposure from this pragma: the exact-match branch
    /// in those same queries (`identifier_string = ?`) is BINARY-collated
    /// and has always been case-sensitive regardless of `LIKE`'s
    /// case-folding, so GUID-casing drift would already have broken exact
    /// cleanup before #426 — this pragma only makes descendant matching
    /// consistent with that pre-existing exact-match behaviour.
    private static func enableCaseSensitiveLike(_ db: Database) throws {
        try db.execute(sql: "PRAGMA case_sensitive_like = ON")
    }

    // MARK: SQL escape helper

    /// Escapes SQL LIKE wildcards using `\` as the escape character.
    static func escapeLike(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }
}

// MARK: - Module-level helpers

/// Validates that `key` has all required non-empty components.
///
/// `internal` so both `CacheStore` and `CacheReader` can call it without duplication.
func validateKey(_ key: CacheKey) throws {
    if key.accountAlias.isEmpty { throw CacheError.missingArgument("accountAlias") }
    if key.workspaceID.isEmpty { throw CacheError.missingArgument("workspaceID") }
    if key.itemID.isEmpty { throw CacheError.missingArgument("itemID") }
}

/// Returns the current time as Unix nanoseconds (wall clock).
///
/// Exposed at module scope so test helpers can reference it by name without
/// duplicating the conversion formula.
// periphery:ignore
func wallClockNs() -> Int64 {
    Int64(Date().timeIntervalSince1970 * 1_000_000_000)
}
