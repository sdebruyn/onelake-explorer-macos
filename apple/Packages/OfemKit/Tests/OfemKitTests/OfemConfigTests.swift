import Foundation
import Testing
@testable import OfemKit

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
    func roundTripCanonical() throws {
        let paths = makePaths()
        let store = try OfemConfigStore(paths: paths)

        try store.updateAndSave { cfg in
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
    func roundTripFilePermissions() throws {
        let paths = makePaths()
        let store = try OfemConfigStore(paths: paths)
        try store.updateAndSave { cfg in cfg.installID = "perm-test" }

        let attrs = try FileManager.default.attributesOfItem(
            atPath: paths.configFile.path(percentEncoded: false)
        )
        let mode = attrs[.posixPermissions] as? Int
        #expect(mode == 0o600, "config file must be 0600, got \(String(format: "%o", mode ?? 0))")
    }

    @Test("round-trip: optional Account fields survive")
    func roundTripOptionalAccountFields() throws {
        let paths = makePaths()
        let store = try OfemConfigStore(paths: paths)

        try store.updateAndSave { cfg in
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

    // MARK: - Legacy max_size_bytes migration

    @Test("legacy max_size_bytes = 5 GiB → max_size_gb = 5")
    func migrateExact5GiB() throws {
        let paths = makePaths()
        let toml = """
        install_id = "legacy-install"
        telemetry = false
        default_account = "work"

        [cache]
        max_size_bytes = 5368709120

        [accounts.work]
        alias = "work"
        tenant_id = "t1"
        home_account_id = "h1"
        username = "u@example.com"
        added_at = "2026-05-01T00:00:00Z"
        """
        try writeFile(toml, at: paths.configFile)

        let store = try OfemConfigStore(paths: paths)
        let snap = store.snapshot()

        #expect(snap.cache.maxSizeGB == 5)
        #expect(snap.installID == "legacy-install")
        #expect(snap.telemetry == false)
        #expect(snap.accounts["work"] != nil)
    }

    @Test("legacy max_size_bytes just over 10 GiB → rounds up to 11")
    func migrateCeilsUp() throws {
        let paths = makePaths()
        // 10 GiB + 1 byte = 10737418241 bytes
        let toml = "[cache]\nmax_size_bytes = 10737418241\n"
        try writeFile(toml, at: paths.configFile)

        let store = try OfemConfigStore(paths: paths)
        #expect(store.snapshot().cache.maxSizeGB == 11)
    }

    @Test("legacy max_size_bytes = 0 (unlimited) → seeds default")
    func migrateLegacyZeroBecomesDefault() throws {
        let paths = makePaths()
        let toml = "[cache]\nmax_size_bytes = 0\n"
        try writeFile(toml, at: paths.configFile)

        let store = try OfemConfigStore(paths: paths)
        #expect(store.snapshot().cache.maxSizeGB == CacheConfig.defaultSizeGB)
    }

    @Test("new-schema max_size_gb is honoured verbatim (no migration)")
    func newSchemaHonoured() throws {
        let paths = makePaths()
        let toml = "[cache]\nmax_size_gb = 25\n"
        try writeFile(toml, at: paths.configFile)

        let store = try OfemConfigStore(paths: paths)
        #expect(store.snapshot().cache.maxSizeGB == 25)
    }

    @Test("after migration save, legacy key is gone and new key is present")
    func afterMigrationLegacyKeyRemoved() throws {
        let paths = makePaths()
        let toml = "[cache]\nmax_size_bytes = 5368709120\n"
        try writeFile(toml, at: paths.configFile)

        let store = try OfemConfigStore(paths: paths)
        // Trigger a save so the migrated config is persisted.
        try store.updateAndSave { _ in }

        let raw = try String(contentsOf: paths.configFile, encoding: .utf8)
        #expect(!raw.contains("max_size_bytes"), "legacy key must be removed after save")
        #expect(raw.contains("max_size_gb"), "canonical key must be present after save")
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
            for i in 0..<20 {
                group.addTask {
                    try? store.updateAndSave { cfg in
                        cfg.installID = "run-\(i)"
                    }
                }
            }
        }

        // Must not throw.
        let store2 = try OfemConfigStore(paths: paths)
        #expect(!store2.snapshot().installID.isEmpty)
    }
}
