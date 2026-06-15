// WarehouseIntegrationTests.swift
//
// Read-only integration tests against a Fabric Warehouse item whose table
// (`ofem_ci_orders`, schema `dbo`) is seeded out-of-band by
// `scripts/prep_warehouse.sql` before this suite runs in CI.
//
// These tests NEVER write to, nor delete from, the warehouse.

import Foundation
import Testing

@testable import OfemKit

@Suite("Warehouse integration", .warehouse, .serialized)
struct WarehouseIntegrationTests {

    // MARK: - Helpers

    private struct LiveWarehouse {
        let onelakeClient: OneLakeClient
        let fabricClient: FabricClient
        let workspaceID: String
        let itemID: String
        let alias = "ci"
        let schema = "dbo"
        let table: String

        /// Item-relative directory for the table's Delta folder.
        var tableDir: String { "Tables/\(schema)/\(table)" }
        /// Item-relative directory for the Delta transaction log.
        var deltaLogDir: String { "Tables/\(schema)/\(table)/_delta_log" }
    }

    /// Loads live coordinates from the environment.
    private func liveWarehouse() throws -> LiveWarehouse {
        let c = try IntegrationConfig.fromEnvironment()
        let wh = try c.requireWarehouseID()
        let table = ProcessInfo.processInfo.environment["OFEM_TEST_WH_TABLE"]
            .flatMap { $0.isEmpty ? nil : $0 } ?? "ofem_ci_orders"
        return LiveWarehouse(
            onelakeClient: OneLakeClient(http: HTTPClient(), tokenProvider: EnvVarTokenProvider()),
            fabricClient: FabricClient(http: HTTPClient(), tokenProvider: EnvVarTokenProvider()),
            workspaceID: c.workspaceID,
            itemID: wh,
            table: table
        )
    }

    /// Returns a `(SyncEngine, CacheStore, scratchBase)` triple wired to the
    /// warehouse item. Callers must `defer` removal of `store.root` and
    /// `scratchBase`.
    private func makeEngineAndStore(wh: LiveWarehouse) throws -> (SyncEngine, CacheStore, URL) {
        let store = try makeTempStore()
        let scratchBase = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let engine = SyncEngine(
            cache: store,
            onelake: wh.onelakeClient as any OneLakeClientProtocol,
            fabric: wh.fabricClient as any FabricClientProtocol,
            scratchBase: scratchBase
        )
        return (engine, store, scratchBase)
    }

    /// Polls `listPath(recursive: true)` on `directory` until at least one
    /// entry appears, retrying up to `attempts` times with `delay` seconds
    /// between each. Returns the final non-empty listing or throws the last
    /// error.
    private func pollListing(
        wh: LiveWarehouse,
        directory: String,
        attempts: Int = 6,
        delay: Duration = .seconds(5)
    ) async throws -> ListResult {
        var lastResult: ListResult?
        var lastError: Error?
        for attempt in 0..<attempts {
            do {
                let result = try await wh.onelakeClient.listPath(
                    alias: wh.alias,
                    workspaceGUID: wh.workspaceID,
                    itemGUID: wh.itemID,
                    directory: directory,
                    recursive: true
                )
                if !result.entries.isEmpty {
                    return result
                }
                lastResult = result
            } catch {
                lastError = error
            }
            if attempt < attempts - 1 {
                try await Task.sleep(for: delay)
            }
        }
        if let result = lastResult, !result.entries.isEmpty {
            return result
        }
        if let result = lastResult {
            return result
        }
        throw lastError ?? CocoaError(.fileReadUnknown)
    }

    /// Resolves a Parquet data file's item-relative path by following the Delta
    /// transaction log's `add` actions — the authoritative pointer a Delta
    /// reader uses. OneLake's recursive listing does not descend into the
    /// warehouse's managed data directory, so the log is the reliable source.
    /// Returns "" when no data file is referenced yet.
    private func parquetDataPath(wh: LiveWarehouse) async throws -> String {
        let logListing = try await pollListing(wh: wh, directory: wh.deltaLogDir)
        let commits = logListing.entries
            .filter { !$0.isDirectory && $0.name.hasSuffix(".json") && $0.contentLength > 0 }
            .sorted { $0.name < $1.name }
        // Newest commit first — the add for the inserted rows lives there.
        for entry in commits.reversed() {
            let relPath = entry.name
            let (data, _) = try await wh.onelakeClient.read(
                alias: wh.alias, workspaceGUID: wh.workspaceID, itemGUID: wh.itemID, path: relPath
            )
            guard let text = String(data: data, encoding: .utf8) else { continue }
            for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
                guard let lineData = line.data(using: .utf8),
                    let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                    let add = obj["add"] as? [String: Any],
                    let path = add["path"] as? String,
                    path.hasSuffix(".parquet")
                else { continue }
                return "\(wh.tableDir)/\(path)"
            }
        }
        return ""
    }

    // MARK: - 1. The warehouse item is discoverable and typed Warehouse

    @Test("warehouse item is discoverable via Fabric REST and typed Warehouse")
    func warehouseItemIsDiscoverable() async throws {
        let wh = try liveWarehouse()
        let item = try await wh.fabricClient.getItem(
            alias: wh.alias,
            workspaceID: wh.workspaceID,
            itemID: wh.itemID
        )
        #expect(item.id == wh.itemID)
        #expect(item.type == "Warehouse")
    }

    // MARK: - 2. The prepared table exposes a Delta log in OneLake

    @Test("prepared table exposes a Delta log directory with JSON commit files in OneLake")
    func tableExposedDeltaLogInOneLake() async throws {
        let wh = try liveWarehouse()

        // Poll until the listing is non-empty — OneLake can lag slightly after
        // the SQL-side table prep.
        let listing = try await pollListing(wh: wh, directory: wh.tableDir)

        // There must be a _delta_log directory entry.
        let hasDeltaLogDir = listing.entries.contains { entry in
            entry.isDirectory && entry.name.contains("_delta_log")
        }
        #expect(hasDeltaLogDir, "expected a _delta_log directory in the recursive listing")

        // At least one .json commit file must exist inside _delta_log.
        let hasCommitJSON = listing.entries.contains { entry in
            !entry.isDirectory
                && entry.name.contains("_delta_log")
                && entry.name.hasSuffix(".json")
                && entry.contentLength > 0
        }
        #expect(hasCommitJSON, "expected at least one non-empty .json commit file under _delta_log")
    }

    // MARK: - 3. A Parquet data file is present and downloads byte-exact with valid magic

    @Test("Parquet data file downloads byte-exact with PAR1 magic bytes at head and tail")
    func parquetFileDownloadsByteExact() async throws {
        let wh = try liveWarehouse()

        // The data file's path comes from the Delta log's `add` action — the
        // recursive listing does not descend into the managed data directory.
        let parquetPath = try await parquetDataPath(wh: wh)
        try #require(!parquetPath.isEmpty, "the Delta log references no Parquet data file")

        let (data, props) = try await wh.onelakeClient.read(
            alias: wh.alias,
            workspaceGUID: wh.workspaceID,
            itemGUID: wh.itemID,
            path: parquetPath
        )

        #expect(!data.isEmpty, "Parquet file data must be non-empty")
        #expect(
            props.contentLength == Int64(data.count),
            "downloaded byte count must match the reported content length"
        )

        // Parquet files begin AND end with the 4-byte magic "PAR1".
        let magic = Array("PAR1".utf8)
        #expect(Array(data.prefix(4)) == magic, "Parquet file must start with PAR1 magic bytes")
        #expect(Array(data.suffix(4)) == magic, "Parquet file must end with PAR1 magic bytes")
    }

    // MARK: - 4. A Delta log commit downloads byte-exact and parses as JSON

    @Test("Delta log commit file downloads byte-exact and first line parses as a JSON object")
    func deltaLogCommitParsesAsJSON() async throws {
        let wh = try liveWarehouse()

        let listing = try await pollListing(wh: wh, directory: wh.deltaLogDir)

        guard let jsonEntry = listing.entries.first(where: {
            !$0.isDirectory
                && $0.name.hasSuffix(".json")
                && $0.contentLength > 0
        }) else {
            Issue.record("No .json commit file found under \(wh.deltaLogDir)")
            return
        }

        let itemRelativePath = jsonEntry.name

        let (data, _) = try await wh.onelakeClient.read(
            alias: wh.alias,
            workspaceGUID: wh.workspaceID,
            itemGUID: wh.itemID,
            path: itemRelativePath
        )

        #expect(!data.isEmpty, "Delta log commit file must be non-empty")

        // Delta log files are newline-delimited JSON. Parse the first line.
        guard let rawString = String(data: data, encoding: .utf8) else {
            Issue.record("Delta log commit file is not valid UTF-8")
            return
        }
        let firstLine = rawString
            .split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: true)
            .first
            .map(String.init) ?? rawString

        guard let lineData = firstLine.data(using: .utf8) else {
            Issue.record("Could not re-encode first line to UTF-8")
            return
        }
        let parsed = try JSONSerialization.jsonObject(with: lineData)
        #expect(parsed is [String: Any], "first line of Delta log commit must be a JSON object")
    }

    // MARK: - 5. The engine enumerates the table's Delta log into the cache

    @Test("engine refreshFolder populates the cache with Delta log commit files")
    func engineEnumeratesDeltaLog() async throws {
        let wh = try liveWarehouse()
        let (engine, store, scratchBase) = try makeEngineAndStore(wh: wh)

        defer {
            try? FileManager.default.removeItem(at: store.root)
            try? FileManager.default.removeItem(at: scratchBase)
        }

        // Ensure the listing is live before asking the engine to refresh.
        _ = try await pollListing(wh: wh, directory: wh.deltaLogDir)

        let key = CacheKey(
            accountAlias: wh.alias,
            workspaceID: wh.workspaceID,
            itemID: wh.itemID,
            path: wh.deltaLogDir
        )

        _ = try await engine.refreshFolder(key: key)

        let children = try await store.children(of: key)

        // At least one .json commit file must be cached.
        let commitFiles = children.filter { $0.name.hasSuffix(".json") }
        #expect(!commitFiles.isEmpty, "engine must cache at least one .json commit file from _delta_log")

        for record in commitFiles {
            #expect(!record.isDir, "\(record.name) should be cached as a file, not a directory")
            #expect(record.contentLength > 0, "\(record.name) must have a positive contentLength in the cache")
        }
    }

    // MARK: - 6. The engine sees the table folder's structure

    @Test("engine refreshFolder sees _delta_log as a directory child of the table folder")
    func engineSeesTableFolderStructure() async throws {
        let wh = try liveWarehouse()
        let (engine, store, scratchBase) = try makeEngineAndStore(wh: wh)

        defer {
            try? FileManager.default.removeItem(at: store.root)
            try? FileManager.default.removeItem(at: scratchBase)
        }

        // Ensure the table is visible before the engine refresh.
        _ = try await pollListing(wh: wh, directory: wh.tableDir)

        let key = CacheKey(
            accountAlias: wh.alias,
            workspaceID: wh.workspaceID,
            itemID: wh.itemID,
            path: wh.tableDir
        )

        _ = try await engine.refreshFolder(key: key)

        let children = try await store.children(of: key)

        guard let deltaLogRecord = children.first(where: { $0.name == "_delta_log" }) else {
            Issue.record("engine cache for \(wh.tableDir) does not include a _delta_log child")
            return
        }

        #expect(deltaLogRecord.isDir, "_delta_log must be cached as a directory")
    }
}
