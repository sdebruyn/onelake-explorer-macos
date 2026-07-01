import Foundation
@testable import OfemKit
import Testing

// MARK: - SyncOverlapTracker

/// Synchronous counterpart to `AsyncPathMutexTests`'s actor-based
/// `OverlapTracker`, usable from inside `updateAndSave`'s synchronous
/// `mutator` closure (which cannot `await` an actor). NSLock-guarded,
/// mirroring the registry-lock pattern used throughout `OfemKit` itself.
private final class SyncOverlapTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var current = 0
    private(set) var maxConcurrent = 0
    private(set) var totalEntries = 0

    func enter() {
        lock.withLock {
            current += 1
            totalEntries += 1
            maxConcurrent = max(maxConcurrent, current)
        }
    }

    func exit() {
        lock.withLock { current -= 1 }
    }
}

// MARK: - OfemConfigTests

@Suite("OfemConfig + OfemConfigStore")
struct OfemConfigTests {
    // MARK: - Helpers

    private func makePaths() -> OfemPaths {
        let tmp = FileManager.default.temporaryDirectory
            .appending(path: "ofem-config-test-\(UUID().uuidString)", directoryHint: .isDirectory)
            .resolvingSymlinksInPath()
        return OfemPaths(root: tmp)
    }

    private func writeFile(_ content: String, at url: URL) throws {
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard let data = content.data(using: .utf8) else {
            Issue.record("Could not encode TOML string as UTF-8")
            return
        }
        try data.write(to: url)
    }

    // MARK: - makeDefault()

    @Test("makeDefault: telemetry is true (opt-out)")
    func defaultTelemetryIsTrue() {
        #expect(OfemConfig.makeDefault().telemetry == true)
    }

    @Test("makeDefault: cache.maxSizeGB is 10")
    func defaultCacheSizeGB() {
        #expect(OfemConfig.makeDefault().cache.maxSizeGB == CacheConfig.defaultSizeGB)
    }

    @Test("makeDefault: cache.maxBytes is 10 GiB")
    func defaultCacheMaxBytes() {
        let expected: Int64 = 10 * 1024 * 1024 * 1024
        #expect(OfemConfig.makeDefault().cache.maxBytes == expected)
    }

    @Test("makeDefault: log.level is info")
    func defaultLogLevel() {
        #expect(OfemConfig.makeDefault().log.level == "info")
    }

    @Test("makeDefault: accounts is empty")
    func defaultAccountsEmpty() {
        #expect(OfemConfig.makeDefault().accounts.isEmpty)
    }

    // MARK: - CacheConfig.maxBytes

    @Test("CacheConfig.maxBytes: 1 GB = 1 GiB")
    func maxBytes1GB() {
        #expect(CacheConfig(maxSizeGB: 1).maxBytes == Int64(1) << 30)
    }

    @Test("CacheConfig.maxBytes: 10 GB = 10 GiB")
    func maxBytes10GB() {
        #expect(CacheConfig(maxSizeGB: 10).maxBytes == Int64(10) << 30)
    }

    @Test("CacheConfig.maxBytes: 0 GB = 0 (no limit)")
    func maxBytes0GB() {
        #expect(CacheConfig(maxSizeGB: 0).maxBytes == 0)
    }

    // MARK: - Round-trip: TOML → struct → TOML

    @Test("round-trip: canonical config survives encode/decode")
    func roundTripCanonical() async throws {
        let paths = makePaths()
        let store = try OfemConfigStore(paths: paths)

        try await store.updateAndSave { cfg in
            cfg.installID = "abc-123"
            cfg.telemetry = false
            cfg.defaultAccount = "work"
            cfg.cache.maxSizeGB = 25
            cfg.net.maxConcurrentUploadsPerAccount = 6
            cfg.net.maxConcurrentDownloadsPerAccount = 12
            cfg.log.level = "debug"
            cfg.accounts["work"] = Account(
                alias: "work",
                tenantID: "tenant-guid",
                homeAccountID: "user.tenant",
                username: "user@example.com",
                addedAt: "2026-05-23T12:00:00Z"
            )
        }

        // Load a second store from the same path to verify on-disk round-trip.
        let store2 = try OfemConfigStore(paths: paths)
        let snap = store2.snapshot()

        #expect(snap.installID == "abc-123")
        #expect(snap.telemetry == false)
        #expect(snap.defaultAccount == "work")
        #expect(snap.cache.maxSizeGB == 25)
        #expect(snap.net.maxConcurrentUploadsPerAccount == 6)
        #expect(snap.net.maxConcurrentDownloadsPerAccount == 12)
        #expect(snap.log.level == "debug")
        #expect(snap.accounts["work"]?.tenantID == "tenant-guid")
        #expect(snap.accounts["work"]?.username == "user@example.com")
    }

    @Test("round-trip: file permissions are 0600")
    func roundTripFilePermissions() async throws {
        let paths = makePaths()
        let store = try OfemConfigStore(paths: paths)
        try await store.updateAndSave { cfg in cfg.installID = "perm-test" }

        let attrs = try FileManager.default.attributesOfItem(
            atPath: paths.configFile.path(percentEncoded: false)
        )
        let mode = attrs[.posixPermissions] as? Int
        #expect(mode == 0o600, "config file must be 0600, got \(String(format: "%o", mode ?? 0))")
    }

    @Test("round-trip: optional Account fields survive")
    func roundTripOptionalAccountFields() async throws {
        let paths = makePaths()
        let store = try OfemConfigStore(paths: paths)

        try await store.updateAndSave { cfg in
            cfg.accounts["byo"] = Account(
                alias: "byo",
                tenantID: "t2",
                tenantName: "Contoso",
                homeAccountID: "u2.t2",
                username: "admin@contoso.com",
                addedAt: "2026-06-01T00:00:00Z",
                clientID: "custom-client-id"
            )
        }

        let store2 = try OfemConfigStore(paths: paths)
        let account = store2.snapshot().accounts["byo"]
        #expect(account?.tenantName == "Contoso")
        #expect(account?.clientID == "custom-client-id")
    }

    // MARK: - Missing file → default

    @Test("missing config file returns default")
    func missingFileReturnsDefault() throws {
        let paths = makePaths()
        // Do NOT write a config file.
        let store = try OfemConfigStore(paths: paths)
        let snap = store.snapshot()
        #expect(snap.telemetry == true)
        #expect(snap.cache.maxSizeGB == CacheConfig.defaultSizeGB)
        #expect(snap.accounts.isEmpty)
    }

    // MARK: - max_size_gb

    @Test("max_size_gb is honoured verbatim")
    func maxSizeGBHonoured() throws {
        let paths = makePaths()
        let toml = "[cache]\nmax_size_gb = 25\n"
        try writeFile(toml, at: paths.configFile)

        let store = try OfemConfigStore(paths: paths)
        #expect(store.snapshot().cache.maxSizeGB == 25)
    }

    @Test("absent [cache] section seeds default")
    func absentCacheSeedsDefault() throws {
        let paths = makePaths()
        try writeFile("install_id = \"x\"\n", at: paths.configFile)

        let store = try OfemConfigStore(paths: paths)
        #expect(store.snapshot().cache.maxSizeGB == CacheConfig.defaultSizeGB)
    }

    // MARK: - Corrupted / invalid TOML

    @Test("corrupted TOML throws parseFailed")
    func corruptedTOMLThrowsParseFailed() throws {
        let paths = makePaths()
        // Write TOML that is syntactically valid but has wrong types for known keys
        // (install_id expects a string, not an integer) — TOMLKit decodes successfully
        // but Swift's Codable decode fails with a type mismatch.
        try writeFile("install_id = 12345\n", at: paths.configFile)

        #expect(throws: OfemConfigError.self) {
            _ = try OfemConfigStore(paths: paths)
        }
        do {
            _ = try OfemConfigStore(paths: paths)
            Issue.record("Expected parseFailed error but no error was thrown")
        } catch OfemConfigError.parseFailed {
            // Expected — pass.
        } catch {
            Issue.record("Expected OfemConfigError.parseFailed, got \(error)")
        }
    }

    // MARK: - Snapshot isolation

    @Test("snapshot returns an independent copy")
    func snapshotIsIndependent() throws {
        let paths = makePaths()
        let store = try OfemConfigStore(paths: paths)

        var snap1 = store.snapshot()
        snap1.installID = "mutated"

        let snap2 = store.snapshot()
        #expect(snap2.installID != "mutated", "store must not be affected by mutations on snapshot")
    }

    // MARK: - updateAndSave concurrency

    @Test("concurrent updateAndSave calls do not corrupt the file")
    func concurrentUpdates() async throws {
        let paths = makePaths()
        let store = try OfemConfigStore(paths: paths)

        // Fire off 20 concurrent mutations. Each writes a distinct installID;
        // we don't care which one wins — we only care that the file can be
        // re-read cleanly afterwards.
        await withTaskGroup(of: Void.self) { group in
            for i in 0 ..< 20 {
                group.addTask {
                    _ = try? await store.updateAndSave { cfg in
                        cfg.installID = "run-\(i)"
                    }
                }
            }
        }

        // Must not throw.
        let store2 = try OfemConfigStore(paths: paths)
        #expect(!store2.snapshot().installID.isEmpty)
    }

    // MARK: - updateAndSave / AsyncPathMutex integration sanity check

    /// **What this test does *not* prove**: the specific F12 fix — that
    /// `ConfigFileLock.release()` now happens-before the resumed Task can
    /// call `AsyncPathMutex.shared.release(path:)` — is *not*, and cannot
    /// be, verified here. `updateAndSave`'s read-modify-write body always
    /// runs on `serialQueue`, a single serial `DispatchQueue`; GCD
    /// guarantees blocks on a serial queue run strictly one at a time
    /// regardless of what any other synchronisation does or doesn't
    /// guarantee. So two overlapping `updateAndSave` calls could never let
    /// their mutator closures truly overlap even *before* this PR's fix —
    /// this test would pass identically against the old, buggy ordering.
    /// The F12 fix itself is established by code reasoning, not a test:
    /// `lock.release()` runs synchronously, on the same GCD thread, before
    /// each `continuation.resume(...)` call (see the comments at the
    /// `updateAndSave` call site and in `ConfigFileLock.swift`) — a
    /// same-process test has no way to observe whether a *peer process*
    /// could have slipped in during the old, racier ordering.
    ///
    /// **What this test *does* prove**: `updateAndSave`'s `AsyncPathMutex`
    /// integration doesn't deadlock or leak a turn under contention. A
    /// double-release-style bug (like the one this review caught during
    /// development) corrupts `AsyncPathMutex`'s internal bookkeeping and
    /// manifests here as a hang, exactly as it did in the analogous
    /// `FileTokenStoreTests` regression test. The `maxConcurrent <= 1`
    /// assertion is a sanity check on the pre-existing `serialQueue`
    /// invariant, not evidence of the fcntl-ordering fix.
    @Test("concurrent updateAndSave calls on the same path do not deadlock or overlap their mutator")
    func concurrentUpdateAndSaveDoesNotDeadlockOrOverlapMutator() async throws {
        let paths = makePaths()
        let store = try OfemConfigStore(paths: paths)
        let tracker = SyncOverlapTracker()

        await withTaskGroup(of: Void.self) { group in
            for i in 0 ..< 15 {
                group.addTask {
                    _ = try? await store.updateAndSave { cfg in
                        tracker.enter()
                        cfg.installID = "run-\(i)"
                        tracker.exit()
                    }
                }
            }
        }

        #expect(tracker.maxConcurrent <= 1,
                "updateAndSave's mutator must never run concurrently for the same path")
        #expect(tracker.totalEntries == 15,
                "all 15 turns must complete — a hang here means a lost/duplicated release")

        let store2 = try OfemConfigStore(paths: paths)
        #expect(!store2.snapshot().installID.isEmpty)
    }

    // MARK: - Intra-process write safety (arch-01 / auth-01)

    //
    // Two OfemConfigStore instances opened over the same path in the *same*
    // process share a process-wide serial DispatchQueue (keyed by the
    // canonical config-file path). This ensures their updateAndSave calls are
    // properly serialised within the process without relying on fcntl record
    // locks, which are per-process and would therefore not exclude two stores
    // in the same process from each other.
    //
    // Cross-process exclusion (host app vs FPE) is handled by the fcntl
    // record locks in acquireFileLock — that path cannot be exercised in an
    // in-process unit test because a single process always gets the lock
    // immediately regardless of other file descriptors it holds.

    @Test("two stores over one file: interleaved writes to different fields both survive")
    func twoStoresInterleavedWrites() async throws {
        let paths = makePaths()

        // Seed the file with known values.
        let seed = try OfemConfigStore(paths: paths)
        try await seed.updateAndSave { cfg in
            cfg.installID = "seed"
            cfg.telemetry = true
            cfg.log.level = "info"
        }

        // storeA and storeB share the same process-wide serial queue for
        // this path, so their concurrent updateAndSave calls are serialised
        // via the intra-process registry — not via fcntl.
        let storeA = try OfemConfigStore(paths: paths)
        let storeB = try OfemConfigStore(paths: paths)

        // Run 10 rounds of interleaved writes.
        // storeA writes telemetry=false; storeB writes log.level="debug".
        // Both are different fields — neither write should revert the other.
        await withTaskGroup(of: Void.self) { group in
            for _ in 0 ..< 10 {
                group.addTask {
                    _ = try? await storeA.updateAndSave { cfg in cfg.telemetry = false }
                }
                group.addTask {
                    _ = try? await storeB.updateAndSave { cfg in cfg.log.level = "debug" }
                }
            }
        }

        // Re-read from disk — both mutations must be present.
        let final = try OfemConfigStore(paths: paths)
        let snap = final.snapshot()
        #expect(snap.telemetry == false, "storeA's telemetry write must survive storeB's concurrent writes")
        #expect(snap.log.level == "debug", "storeB's log.level write must survive storeA's concurrent writes")
    }

    @Test("two stores over one file: account written by storeA is not erased by storeB")
    func twoStoresAccountNotErased() async throws {
        let paths = makePaths()

        // storeA writes an account.
        let storeA = try OfemConfigStore(paths: paths)
        try await storeA.updateAndSave { cfg in
            cfg.accounts["work"] = Account(
                alias: "work",
                tenantID: "t1",
                homeAccountID: "u1.t1",
                username: "alice@contoso.com",
                addedAt: "2026-06-01T00:00:00Z"
            )
        }

        // storeB was opened BEFORE storeA wrote the account (stale snapshot).
        // It writes a different field. The account must still be present
        // because updateAndSave re-reads the on-disk state before applying
        // the mutation (read-merge-write), and both stores share the
        // intra-process serial queue, so the writes are properly ordered.
        let storeB = try OfemConfigStore(paths: paths)
        try await storeB.updateAndSave { cfg in
            cfg.cache.maxSizeGB = 20
        }

        let final = try OfemConfigStore(paths: paths)
        let snap = final.snapshot()
        #expect(snap.accounts["work"] != nil, "account written by storeA must survive storeB's write")
        #expect(snap.cache.maxSizeGB == 20, "storeB's cache write must be present")
    }

    // MARK: - max_size_gb = 0 honoured as no-limit (auth-07)

    @Test("max_size_gb = 0 is preserved as no-limit sentinel, not rewritten to default")
    func maxSizeGBZeroIsNoLimit() throws {
        let paths = makePaths()
        let toml = "[cache]\nmax_size_gb = 0\n"
        try writeFile(toml, at: paths.configFile)

        let store = try OfemConfigStore(paths: paths)
        #expect(store.snapshot().cache.maxSizeGB == 0, "max_size_gb = 0 must be preserved, not rewritten to \(CacheConfig.defaultSizeGB)")
        #expect(store.snapshot().cache.maxBytes == 0, "maxBytes must be 0 when maxSizeGB is 0 (no-limit)")
    }

    @Test("absent max_size_gb still seeds default (not 0)")
    func absentMaxSizeGBSeedsDefault() throws {
        let paths = makePaths()
        try writeFile("install_id = \"x\"\n", at: paths.configFile)

        let store = try OfemConfigStore(paths: paths)
        #expect(store.snapshot().cache.maxSizeGB == CacheConfig.defaultSizeGB)
    }

    // MARK: - Cache bounds enforced at load time (auth-08)

    @Test("max_size_gb below minSizeGB is clamped up to minSizeGB at load")
    func maxSizeGBClampedToMin() throws {
        let paths = makePaths()
        // A value of -5 is below the minimum (1 GB) — must be clamped.
        let toml = "[cache]\nmax_size_gb = -5\n"
        try writeFile(toml, at: paths.configFile)

        let store = try OfemConfigStore(paths: paths)
        #expect(store.snapshot().cache.maxSizeGB == CacheConfig.minSizeGB,
                "negative max_size_gb must be clamped to \(CacheConfig.minSizeGB)")
    }

    @Test("max_size_gb above maxSizeGB is clamped down to maxSizeGB at load")
    func maxSizeGBClampedToMax() throws {
        let paths = makePaths()
        // A value of 999 exceeds the maximum (100 GB) — must be clamped.
        let toml = "[cache]\nmax_size_gb = 999\n"
        try writeFile(toml, at: paths.configFile)

        let store = try OfemConfigStore(paths: paths)
        #expect(store.snapshot().cache.maxSizeGB == CacheConfig.maxSizeGB,
                "huge max_size_gb must be clamped to \(CacheConfig.maxSizeGB)")
    }

    @Test("CacheConfig.maxBytes does not overflow on absurdly large maxSizeGB")
    func maxBytesOverflowGuard() {
        // Int64.max / bytesPerGB is approximately 8_589_934_591 GB.
        // A value well above that must not overflow to a negative number.
        let absurd = CacheConfig(maxSizeGB: Int.max)
        #expect(absurd.maxBytes >= 0, "maxBytes must not overflow to a negative value")
        #expect(absurd.maxBytes == Int64.max, "absurd maxSizeGB must clamp maxBytes to Int64.max")
    }

    // MARK: - Defaults single source of truth (auth-15)

    @Test("RawConfig missing fields fall back to makeDefault() values, not separate literals")
    func rawConfigDefaultsMatchMakeDefault() throws {
        let paths = makePaths()
        // Write a TOML with only install_id — all other fields absent.
        try writeFile("install_id = \"abc\"\n", at: paths.configFile)

        let store = try OfemConfigStore(paths: paths)
        let snap = store.snapshot()
        let def = OfemConfig.makeDefault()

        // Every field that has a default must match makeDefault().
        #expect(snap.telemetry == def.telemetry)
        #expect(snap.net.maxConcurrentUploadsPerAccount == def.net.maxConcurrentUploadsPerAccount)
        #expect(snap.net.maxConcurrentDownloadsPerAccount == def.net.maxConcurrentDownloadsPerAccount)
        #expect(snap.log.level == def.log.level)
        #expect(snap.cache.maxSizeGB == def.cache.maxSizeGB)
    }

    // MARK: - SyncConfig.selfHealIntervalM

    @Test("selfHealIntervalM: absent key defaults to 30")
    func selfHealIntervalMDefaultsTo30() throws {
        let paths = makePaths()
        try writeFile("install_id = \"x\"\n", at: paths.configFile)

        let store = try OfemConfigStore(paths: paths)
        #expect(store.snapshot().sync.selfHealIntervalM == SyncConfig.defaultSelfHealIntervalM,
                "absent self_heal_interval_m must default to \(SyncConfig.defaultSelfHealIntervalM)")
    }

    @Test("selfHealIntervalM: 0 is preserved as disabled sentinel")
    func selfHealIntervalMZeroDisabled() throws {
        let paths = makePaths()
        let toml = "[sync]\nself_heal_interval_m = 0\n"
        try writeFile(toml, at: paths.configFile)

        let store = try OfemConfigStore(paths: paths)
        #expect(store.snapshot().sync.selfHealIntervalM == 0,
                "self_heal_interval_m = 0 must be preserved as the disabled sentinel")
    }

    @Test("selfHealIntervalM: 5 (below min) clamps up to 10")
    func selfHealIntervalMClampsBelowMinToMin() throws {
        let paths = makePaths()
        let toml = "[sync]\nself_heal_interval_m = 5\n"
        try writeFile(toml, at: paths.configFile)

        let store = try OfemConfigStore(paths: paths)
        #expect(store.snapshot().sync.selfHealIntervalM == SyncConfig.minSelfHealIntervalM,
                "value 5 (below min \(SyncConfig.minSelfHealIntervalM)) must clamp up to min")
    }

    @Test("selfHealIntervalM: 90 (above max) clamps down to 60")
    func selfHealIntervalMClampsAboveMaxToMax() throws {
        let paths = makePaths()
        let toml = "[sync]\nself_heal_interval_m = 90\n"
        try writeFile(toml, at: paths.configFile)

        let store = try OfemConfigStore(paths: paths)
        #expect(store.snapshot().sync.selfHealIntervalM == SyncConfig.maxSelfHealIntervalM,
                "value 90 (above max \(SyncConfig.maxSelfHealIntervalM)) must clamp down to max")
    }

    @Test("selfHealIntervalM: 10 (exact min) stays 10")
    func selfHealIntervalMAtMinPreserved() throws {
        let paths = makePaths()
        let toml = "[sync]\nself_heal_interval_m = 10\n"
        try writeFile(toml, at: paths.configFile)

        let store = try OfemConfigStore(paths: paths)
        #expect(store.snapshot().sync.selfHealIntervalM == 10,
                "exact min value \(SyncConfig.minSelfHealIntervalM) must not be clamped further")
    }

    @Test("selfHealIntervalM: 60 (exact max) stays 60")
    func selfHealIntervalMAtMaxPreserved() throws {
        let paths = makePaths()
        let toml = "[sync]\nself_heal_interval_m = 60\n"
        try writeFile(toml, at: paths.configFile)

        let store = try OfemConfigStore(paths: paths)
        #expect(store.snapshot().sync.selfHealIntervalM == 60,
                "exact max value \(SyncConfig.maxSelfHealIntervalM) must not be clamped further")
    }

    @Test("selfHealIntervalM: 30 stays 30")
    func selfHealIntervalMInRangePreserved() throws {
        let paths = makePaths()
        let toml = "[sync]\nself_heal_interval_m = 30\n"
        try writeFile(toml, at: paths.configFile)

        let store = try OfemConfigStore(paths: paths)
        #expect(store.snapshot().sync.selfHealIntervalM == 30,
                "in-range value 30 must be preserved as-is")
    }

    @Test("selfHealIntervalM: round-trips through encode/decode")
    func selfHealIntervalMRoundTrips() async throws {
        let paths = makePaths()
        let store = try OfemConfigStore(paths: paths)

        try await store.updateAndSave { cfg in
            cfg.sync.selfHealIntervalM = 45
        }

        let store2 = try OfemConfigStore(paths: paths)
        #expect(store2.snapshot().sync.selfHealIntervalM == 45,
                "selfHealIntervalM = 45 must survive an encode/decode round-trip")
    }

    @Test("selfHealIntervalM: 0 round-trips through encode/decode")
    func selfHealIntervalMZeroRoundTrips() async throws {
        let paths = makePaths()
        let store = try OfemConfigStore(paths: paths)

        try await store.updateAndSave { cfg in
            cfg.sync.selfHealIntervalM = 0
        }

        let store2 = try OfemConfigStore(paths: paths)
        #expect(store2.snapshot().sync.selfHealIntervalM == 0,
                "selfHealIntervalM = 0 (disabled) must survive an encode/decode round-trip")
    }
}
