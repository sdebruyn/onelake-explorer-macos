import Foundation
import Testing
@testable import OfemKit

// MARK: - ConfigRefactorTests
//
// Covers the findings addressed in the CONFIG work package:
//   config-02  locking does not block the shared serial queue
//   config-03  freshSnapshot() returns current on-disk state
//   config-06  NetConfig / LogConfig clamping and validation
//   config-07  config dir + file permission bits (regression)
//   config-08  lock fd released when mutator throws
//   config-09  OfemPaths.ensureDirectories()

@Suite("Config refactor — config-02/03/06/07/08/09")
struct ConfigRefactorTests {

    // MARK: - Helpers

    private func makePaths() -> OfemPaths {
        let tmp = FileManager.default.temporaryDirectory
            .appending(
                path: "ofem-cfg-refactor-\(UUID().uuidString)",
                directoryHint: .isDirectory
            )
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

    // MARK: - config-02: serial queue is not blocked during concurrent writes

    /// Verifies that concurrent `updateAndSave` calls on the same store
    /// complete without any of them stalling the others. If the shared serial
    /// queue were blocked (by a sleeping thread), these tasks would execute
    /// strictly one-at-a-time and take far longer to complete. This test
    /// asserts correctness (no corruption) rather than timing, but the
    /// `withTaskGroup` machinery exercises the concurrent code path.
    @Test("config-02: concurrent updateAndSave preserves correctness without queue blocking")
    func concurrentUpdateAndSaveIsCorrect() async throws {
        let paths = makePaths()
        let store = try OfemConfigStore(paths: paths)

        // Seed an initial install ID.
        try await store.updateAndSave { cfg in cfg.installID = "initial" }

        // Run 30 concurrent mutations — last writer wins for installID,
        // but the file must remain parseable throughout.
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<30 {
                group.addTask {
                    _ = try? await store.updateAndSave { cfg in
                        cfg.installID = "run-\(i)"
                    }
                }
            }
        }

        let result = try OfemConfigStore(paths: paths)
        let snap = result.snapshot()
        #expect(!snap.installID.isEmpty, "installID must not be blank after concurrent writes")
        #expect(snap.installID.hasPrefix("run-") || snap.installID == "initial")
    }

    /// Two stores sharing the same path (and therefore the same serial queue)
    /// must not corrupt each other's fields even under concurrent load.
    /// This tests the intra-process serialisation that replaces fcntl for
    /// same-process writers.
    @Test("config-02: two stores on same path do not corrupt each other")
    func twoStoresSamePathNonCorrupting() async throws {
        let paths = makePaths()
        let storeA = try OfemConfigStore(paths: paths)
        let storeB = try OfemConfigStore(paths: paths)

        // storeA writes telemetry, storeB writes log level — different fields.
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<20 {
                group.addTask {
                    _ = try? await storeA.updateAndSave { cfg in cfg.telemetry = false }
                }
                group.addTask {
                    _ = try? await storeB.updateAndSave { cfg in cfg.log.level = "debug" }
                }
            }
        }

        let final = try OfemConfigStore(paths: paths)
        let snap = final.snapshot()
        #expect(snap.telemetry == false, "storeA's telemetry write must survive")
        #expect(snap.log.level == "debug", "storeB's log.level write must survive")
    }

    // MARK: - config-03: freshSnapshot() re-reads from disk

    @Test("config-03: freshSnapshot() reflects external write not seen by in-memory snapshot")
    func freshSnapshotReflectsDiskWrite() async throws {
        let paths = makePaths()

        // storeB is opened first, while the file only has the default installID.
        let storeB = try OfemConfigStore(paths: paths)
        let staleInstallID = storeB.snapshot().installID // default ("")

        // storeA now writes the file.
        let storeA = try OfemConfigStore(paths: paths)
        try await storeA.updateAndSave { cfg in cfg.installID = "from-storeA" }

        // storeB's in-memory snapshot() is still the value it held at init time
        // (storeA's write updated storeA's in-memory copy, not storeB's).
        // Because storeA and storeB share the intra-process serial queue, the
        // updateAndSave above has already completed, but storeB's own `config`
        // field was not updated (only storeA's was). So storeB.snapshot() still
        // returns the old value.
        let staleSnap = storeB.snapshot()
        #expect(staleSnap.installID == staleInstallID,
                "snapshot() must return storeB's own stale in-memory value, not storeA's write")

        // freshSnapshot() must re-read and return the value written by storeA.
        let fresh = try storeB.freshSnapshot()
        #expect(fresh.installID == "from-storeA", "freshSnapshot() must return the current on-disk value")
    }

    @Test("config-03: freshSnapshot() updates the in-memory snapshot")
    func freshSnapshotUpdatesInMemory() async throws {
        let paths = makePaths()
        let storeA = try OfemConfigStore(paths: paths)
        try await storeA.updateAndSave { cfg in cfg.installID = "written" }

        let storeB = try OfemConfigStore(paths: paths)
        _ = try storeB.freshSnapshot()
        // After freshSnapshot(), snapshot() should also return the fresh value.
        #expect(storeB.snapshot().installID == "written")
    }

    // MARK: - config-06: NetConfig validation / clamping

    @Test("config-06: NetConfig zero uploads is clamped to minConcurrent")
    func netConfigZeroUploadsClamped() throws {
        let paths = makePaths()
        let toml = "[net]\nmax_concurrent_uploads_per_account = 0\n"
        try writeFile(toml, at: paths.configFile)

        let store = try OfemConfigStore(paths: paths)
        let snap = store.snapshot()
        #expect(
            snap.net.maxConcurrentUploadsPerAccount >= NetConfig.minConcurrent,
            "zero uploads must be clamped to at least \(NetConfig.minConcurrent)"
        )
    }

    @Test("config-06: NetConfig negative downloads is clamped to minConcurrent")
    func netConfigNegativeDownloadsClamped() throws {
        let paths = makePaths()
        let toml = "[net]\nmax_concurrent_downloads_per_account = -3\n"
        try writeFile(toml, at: paths.configFile)

        let store = try OfemConfigStore(paths: paths)
        let snap = store.snapshot()
        #expect(
            snap.net.maxConcurrentDownloadsPerAccount >= NetConfig.minConcurrent,
            "negative downloads must be clamped to at least \(NetConfig.minConcurrent)"
        )
    }

    @Test("config-06: NetConfig absurdly large value is clamped to maxConcurrent")
    func netConfigAbsurdValueClamped() throws {
        let paths = makePaths()
        let toml = "[net]\nmax_concurrent_uploads_per_account = 9999\n"
        try writeFile(toml, at: paths.configFile)

        let store = try OfemConfigStore(paths: paths)
        let snap = store.snapshot()
        #expect(
            snap.net.maxConcurrentUploadsPerAccount <= NetConfig.maxConcurrent,
            "absurdly large uploads must be clamped to \(NetConfig.maxConcurrent)"
        )
    }

    @Test("config-06: NetConfig valid values are preserved verbatim")
    func netConfigValidValuesPreserved() throws {
        let paths = makePaths()
        let toml = "[net]\nmax_concurrent_uploads_per_account = 3\nmax_concurrent_downloads_per_account = 6\n"
        try writeFile(toml, at: paths.configFile)

        let store = try OfemConfigStore(paths: paths)
        let snap = store.snapshot()
        #expect(snap.net.maxConcurrentUploadsPerAccount == 3)
        #expect(snap.net.maxConcurrentDownloadsPerAccount == 6)
    }

    @Test("config-06: LogConfig unknown level is clamped to default")
    func logConfigUnknownLevelClamped() throws {
        let paths = makePaths()
        let toml = "[log]\nlevel = \"verbose\"\n"
        try writeFile(toml, at: paths.configFile)

        let store = try OfemConfigStore(paths: paths)
        let snap = store.snapshot()
        #expect(
            snap.log.level == LogConfig.defaultLevel,
            "unknown log level must be clamped to '\(LogConfig.defaultLevel)'"
        )
    }

    @Test("config-06: LogConfig valid level is preserved verbatim")
    func logConfigValidLevelPreserved() throws {
        for level in LogConfig.validLevels {
            let p = makePaths()
            let toml = "[log]\nlevel = \"\(level)\"\n"
            try writeFile(toml, at: p.configFile)
            let store = try OfemConfigStore(paths: p)
            #expect(
                store.snapshot().log.level == level,
                "valid log level '\(level)' must not be altered"
            )
        }
    }

    // MARK: - config-07: config dir + file permission bits

    @Test("config-07: config dir has mode 0700")
    func configDirMode0700() async throws {
        let paths = makePaths()
        let store = try OfemConfigStore(paths: paths)
        try await store.updateAndSave { cfg in cfg.installID = "perm-test" }

        let attrs = try FileManager.default.attributesOfItem(
            atPath: paths.configDir.path(percentEncoded: false)
        )
        let mode = attrs[.posixPermissions] as? Int
        #expect(mode == 0o700, "config dir must be 0700, got \(String(format: "%o", mode ?? 0))")
    }

    @Test("config-07: config file has mode 0600")
    func configFileMode0600() async throws {
        let paths = makePaths()
        let store = try OfemConfigStore(paths: paths)
        try await store.updateAndSave { cfg in cfg.installID = "perm-test" }

        let attrs = try FileManager.default.attributesOfItem(
            atPath: paths.configFile.path(percentEncoded: false)
        )
        let mode = attrs[.posixPermissions] as? Int
        #expect(mode == 0o600, "config file must be 0600, got \(String(format: "%o", mode ?? 0))")
    }

    // MARK: - config-08: lock fd released when mutator throws

    @Test("config-08: lock fd is released when mutator throws")
    func lockReleasedOnMutatorThrow() async throws {
        let paths = makePaths()
        let store = try OfemConfigStore(paths: paths)

        struct MutatorError: Error {}

        // First call throws — the lock must still be released so a second
        // call can succeed.
        do {
            try await store.updateAndSave { _ in throw MutatorError() }
            Issue.record("Expected MutatorError to propagate")
        } catch is MutatorError {
            // Expected.
        }

        // Second call must succeed, proving the lock was released.
        try await store.updateAndSave { cfg in cfg.installID = "after-throw" }
        let snap = try OfemConfigStore(paths: paths).snapshot()
        #expect(snap.installID == "after-throw", "second write must succeed after first threw")
    }

    @Test("config-08: multiple consecutive mutator throws do not leave lock wedged")
    func repeatedThrowsDoNotWedgeLock() async throws {
        let paths = makePaths()
        let store = try OfemConfigStore(paths: paths)

        struct E: Error {}
        for _ in 0..<5 {
            try? await store.updateAndSave { _ in throw E() }
        }

        // Final write must succeed.
        try await store.updateAndSave { cfg in cfg.installID = "recovered" }
        #expect(try OfemConfigStore(paths: paths).snapshot().installID == "recovered")
    }

    // MARK: - config-09: OfemPaths.ensureDirectories()

    @Test("config-09: ensureDirectories creates all dirs")
    func ensureDirectoriesCreatesAllDirs() throws {
        let paths = makePaths()
        // None of the dirs exist yet.
        let fm = FileManager.default
        for dir in [paths.configDir, paths.cacheDir, paths.logDir, paths.tokensDir] {
            #expect(!fm.fileExists(atPath: dir.path(percentEncoded: false)),
                    "dir \(dir.lastPathComponent) must not exist before ensureDirectories()")
        }

        try paths.ensureDirectories()

        for dir in [paths.configDir, paths.cacheDir, paths.logDir, paths.tokensDir] {
            var isDir: ObjCBool = false
            let exists = fm.fileExists(atPath: dir.path(percentEncoded: false), isDirectory: &isDir)
            #expect(exists && isDir.boolValue,
                    "dir \(dir.lastPathComponent) must exist after ensureDirectories()")
        }
    }

    @Test("config-09: ensureDirectories sets all dirs to mode 0700")
    func ensureDirectoriesSetsMode0700() throws {
        let paths = makePaths()
        try paths.ensureDirectories()

        let fm = FileManager.default
        for dir in [paths.configDir, paths.cacheDir, paths.logDir, paths.tokensDir] {
            let attrs = try fm.attributesOfItem(atPath: dir.path(percentEncoded: false))
            let mode = attrs[.posixPermissions] as? Int
            #expect(mode == 0o700,
                    "\(dir.lastPathComponent) must be 0700, got \(String(format: "%o", mode ?? 0))")
        }
    }

    @Test("config-09: ensureDirectories is idempotent")
    func ensureDirectoriesIsIdempotent() throws {
        let paths = makePaths()
        // Call twice — must not throw.
        try paths.ensureDirectories()
        try paths.ensureDirectories()
        // All dirs must still exist.
        let fm = FileManager.default
        for dir in [paths.configDir, paths.cacheDir, paths.logDir, paths.tokensDir] {
            var isDir: ObjCBool = false
            let exists = fm.fileExists(atPath: dir.path(percentEncoded: false), isDirectory: &isDir)
            #expect(exists && isDir.boolValue)
        }
    }
}
