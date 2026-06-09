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
