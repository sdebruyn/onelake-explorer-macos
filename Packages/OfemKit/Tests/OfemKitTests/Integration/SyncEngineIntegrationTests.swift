import Foundation
import Testing

@testable import OfemKit

// MARK: - SyncEngine Integration Tests

/// End-to-end integration tests for ``SyncEngine`` against a live Fabric
/// lakehouse.
///
/// Each test:
///  1. ARRANGEs known data under a unique `Files/ofem-ci/<UUID>` directory via
///     ``OneLakeClient`` (the real data-plane client).
///  2. ACTs through the real ``SyncEngine`` backed by live clients.
///  3. ASSERTs via ``CacheStore`` to verify the engine reconciled state
///     correctly into the metadata cache.
///
/// Every test cleans up its per-run OneLake directory, its temp `CacheStore`
/// root, and its `scratchBase` even on failure (do/catch + rethrow pattern).
///
/// Serialized: tests share one live workspace and we want modest concurrency
/// on the remote endpoint.
@Suite("SyncEngine integration", .integration, .serialized)
struct SyncEngineIntegrationTests {

    // MARK: - LiveLakehouse helper

    /// Binds live workspace + lakehouse coordinates and wraps the raw
    /// ``OneLakeClient`` calls into concise helpers, mirroring the pattern
    /// established in `OneLakeIntegrationTests`.
    private struct LiveLakehouse {
        let client: OneLakeClient
        let workspace: String
        let item: String
        let alias = "ci"

        func mkdir(_ path: String) async throws {
            try await client.createDirectory(
                alias: alias, workspaceGUID: workspace, itemGUID: item, path: path
            )
        }

        func write(_ path: String, _ data: Data) async throws {
            try await client.write(
                alias: alias, workspaceGUID: workspace, itemGUID: item,
                path: path, content: data, size: Int64(data.count)
            )
        }

        func rm(_ path: String) async throws {
            try await client.delete(
                alias: alias, workspaceGUID: workspace, itemGUID: item,
                path: path, recursive: true
            )
        }

        /// Best-effort cleanup — never throws. Call this inside a `defer` after
        /// the main do/catch block so failures are always cleaned up.
        func rmBestEffort(_ path: String) async {
            try? await rm(path)
        }
    }

    // MARK: - Engine + store factory

    /// Returns a wired (engine, store, scratchBase) triple.
    ///
    /// Callers must clean up `store.root` and `scratchBase` in their `defer`
    /// blocks.
    private func makeEngineAndStore(lake: LiveLakehouse) throws -> (SyncEngine, CacheStore, URL) {
        let store = try makeTempStore()
        let scratchBase = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let onelake = lake.client as any OneLakeClientProtocol
        let fabric: any FabricClientProtocol = FabricClient(
            http: HTTPClient(), tokenProvider: EnvVarTokenProvider()
        )
        let engine = SyncEngine(
            cache: store,
            onelake: onelake,
            fabric: fabric,
            scratchBase: scratchBase
        )
        return (engine, store, scratchBase)
    }

    /// Returns a ``LiveLakehouse`` loaded from the environment.
    private func liveLakehouse() throws -> LiveLakehouse {
        let config = try IntegrationConfig.fromEnvironment()
        let client = OneLakeClient(http: HTTPClient(), tokenProvider: EnvVarTokenProvider())
        return LiveLakehouse(client: client, workspace: config.workspaceID, item: config.lakehouseID)
    }

    /// Returns a ``CacheKey`` for the given path inside the live lakehouse.
    private func cacheKey(lake: LiveLakehouse, path: String) -> CacheKey {
        CacheKey(
            accountAlias: lake.alias,
            workspaceID: lake.workspace,
            itemID: lake.item,
            path: path
        )
    }

    // MARK: - Test 1: refreshFolder reads a prepared flat directory into the cache

    @Test("refreshFolder reads a prepared flat directory into the cache")
    func testRefreshFolderFlatDirectory() async throws {
        let lake = try liveLakehouse()
        let (engine, store, scratchBase) = try makeEngineAndStore(lake: lake)
        let dir = "Files/ofem-ci/\(UUID().uuidString)"

        defer {
            try? FileManager.default.removeItem(at: store.root)
            try? FileManager.default.removeItem(at: scratchBase)
        }

        // Prepare 3 files with known names and sizes.
        let files: [(name: String, data: Data)] = [
            ("alpha.bin",   Data(repeating: 0x01, count: 100)),
            ("beta.bin",    Data(repeating: 0x02, count: 200)),
            ("gamma.bin",   Data(repeating: 0x03, count: 300)),
        ]

        do {
            try await lake.mkdir(dir)
            for (name, data) in files {
                try await lake.write("\(dir)/\(name)", data)
            }

            let key = cacheKey(lake: lake, path: dir)
            let diff = try await engine.refreshFolder(key: key)

            #expect(diff.added == 3)

            let kids = try await store.children(of: key)
            #expect(kids.count == 3)

            for (name, data) in files {
                let record = kids.first { $0.name == name }
                #expect(record != nil, "expected child named \(name)")
                if let record {
                    #expect(!record.isDir, "\(name) should not be a directory")
                    #expect(record.contentLength == Int64(data.count))
                    #expect(!record.etag.isEmpty, "\(name) should have a non-empty etag")
                    #expect(record.syncedAtNs > 0, "\(name) should have a non-zero syncedAtNs")
                }
            }
        } catch {
            await lake.rmBestEffort(dir)
            throw error
        }
        try await lake.rm(dir)
    }

    // MARK: - Test 2: refreshFolder distinguishes files from subdirectories

    @Test("refreshFolder distinguishes files from subdirectories")
    func testRefreshFolderFileVsSubdirectory() async throws {
        let lake = try liveLakehouse()
        let (engine, store, scratchBase) = try makeEngineAndStore(lake: lake)
        let dir = "Files/ofem-ci/\(UUID().uuidString)"

        defer {
            try? FileManager.default.removeItem(at: store.root)
            try? FileManager.default.removeItem(at: scratchBase)
        }

        do {
            try await lake.mkdir(dir)
            // A plain file at the top level of dir.
            try await lake.write("\(dir)/file.bin", Data(repeating: 0xAA, count: 42))
            // A subdirectory (need at least one child so the path exists on OneLake).
            try await lake.mkdir("\(dir)/sub")
            try await lake.write("\(dir)/sub/child.bin", Data(repeating: 0xBB, count: 10))

            let key = cacheKey(lake: lake, path: dir)
            _ = try await engine.refreshFolder(key: key)

            let kids = try await store.children(of: key)
            let fileRecord = kids.first { $0.name == "file.bin" }
            let dirRecord  = kids.first { $0.name == "sub" }

            #expect(fileRecord != nil, "expected child named file.bin")
            #expect(dirRecord  != nil, "expected child named sub")
            if let f = fileRecord {
                #expect(!f.isDir, "file.bin should not be a directory")
            }
            if let d = dirRecord {
                #expect(d.isDir, "sub should be a directory")
            }
        } catch {
            await lake.rmBestEffort(dir)
            throw error
        }
        try await lake.rm(dir)
    }

    // MARK: - Test 3: enumerate returns the same children after a refresh (cache fast-path)

    @Test("enumerate returns the same children after a refresh (cache fast-path)")
    func testEnumerateReturnsSameChildrenAsCacheAfterRefresh() async throws {
        let lake = try liveLakehouse()
        let (engine, store, scratchBase) = try makeEngineAndStore(lake: lake)
        let dir = "Files/ofem-ci/\(UUID().uuidString)"

        defer {
            try? FileManager.default.removeItem(at: store.root)
            try? FileManager.default.removeItem(at: scratchBase)
        }

        do {
            try await lake.mkdir(dir)
            try await lake.write("\(dir)/one.txt",   Data(repeating: 0x11, count: 50))
            try await lake.write("\(dir)/two.txt",   Data(repeating: 0x22, count: 50))
            try await lake.write("\(dir)/three.txt", Data(repeating: 0x33, count: 50))

            let key = cacheKey(lake: lake, path: dir)
            _ = try await engine.refreshFolder(key: key)

            // Ask the store directly first.
            let storeKids = try await store.children(of: key)
            let storeNames = Set(storeKids.map(\.name))

            // enumerate() should serve from the now-fresh cache.
            let enumKids = try await engine.enumerate(key: key)
            let enumNames = Set(enumKids.map(\.name))

            #expect(enumNames == storeNames)
        } catch {
            await lake.rmBestEffort(dir)
            throw error
        }
        try await lake.rm(dir)
    }

    // MARK: - Test 4: refreshFolder detects a remote deletion

    @Test("refreshFolder detects a remote deletion")
    func testRefreshFolderDetectsRemoteDeletion() async throws {
        let lake = try liveLakehouse()
        let (engine, store, scratchBase) = try makeEngineAndStore(lake: lake)
        let dir = "Files/ofem-ci/\(UUID().uuidString)"

        defer {
            try? FileManager.default.removeItem(at: store.root)
            try? FileManager.default.removeItem(at: scratchBase)
        }

        do {
            try await lake.mkdir(dir)
            try await lake.write("\(dir)/keep.bin",   Data(repeating: 0x01, count: 10))
            try await lake.write("\(dir)/delete.bin", Data(repeating: 0x02, count: 10))

            let key = cacheKey(lake: lake, path: dir)

            // First refresh — cache should record both files.
            let diff1 = try await engine.refreshFolder(key: key)
            #expect(diff1.added == 2)

            // Delete one file directly on OneLake (bypass the engine).
            try await lake.client.delete(
                alias: lake.alias,
                workspaceGUID: lake.workspace,
                itemGUID: lake.item,
                path: "\(dir)/delete.bin",
                recursive: false
            )

            // Second refresh — engine should detect the deletion.
            let diff2 = try await engine.refreshFolder(key: key)
            #expect(diff2.removed == 1)

            let kidsAfter = try await store.children(of: key)
            let names = kidsAfter.map(\.name)
            #expect(names.contains("keep.bin"),   "keep.bin should still be present")
            #expect(!names.contains("delete.bin"), "delete.bin should have been removed")
        } catch {
            await lake.rmBestEffort(dir)
            throw error
        }
        try await lake.rm(dir)
    }

    // MARK: - Test 5: engine filters macOS metadata against the live service

    @Test("Engine filters macOS metadata against the live service")
    func testMacOSMetadataFilteredAgainstLiveService() async throws {
        let lake = try liveLakehouse()
        let (engine, store, scratchBase) = try makeEngineAndStore(lake: lake)
        let dir = "Files/ofem-ci/\(UUID().uuidString)"

        defer {
            try? FileManager.default.removeItem(at: store.root)
            try? FileManager.default.removeItem(at: scratchBase)
        }

        do {
            try await lake.mkdir(dir)
            // The file that should survive the filter.
            try await lake.write("\(dir)/keep.bin",     Data(repeating: 0xAA, count: 20))
            // macOS metadata artifacts that the engine must discard.
            try await lake.write("\(dir)/.DS_Store",    Data(repeating: 0x00, count: 4))
            try await lake.write("\(dir)/._keep.bin",   Data(repeating: 0x00, count: 4))

            let key = cacheKey(lake: lake, path: dir)
            _ = try await engine.refreshFolder(key: key)

            let kids = try await store.children(of: key)
            let names = kids.map(\.name)

            #expect(names.contains("keep.bin"),    "keep.bin should be present in cache")
            #expect(!names.contains(".DS_Store"),  ".DS_Store must be filtered out")
            #expect(!names.contains("._keep.bin"), "._keep.bin must be filtered out")
        } catch {
            await lake.rmBestEffort(dir)
            throw error
        }
        try await lake.rm(dir)
    }

    // MARK: - Test 6: open downloads a prepared file byte-for-byte and caches the blob

    @Test("open downloads a prepared file byte-for-byte and caches the blob")
    func testOpenDownloadsFileBytesForByte() async throws {
        let lake = try liveLakehouse()
        let (engine, store, scratchBase) = try makeEngineAndStore(lake: lake)
        let dir = "Files/ofem-ci/\(UUID().uuidString)"

        defer {
            try? FileManager.default.removeItem(at: store.root)
            try? FileManager.default.removeItem(at: scratchBase)
        }

        // 128 KiB of non-trivial bytes.
        let payload = Data((0..<(128 * 1024)).map { UInt8($0 % 251) })

        do {
            try await lake.mkdir(dir)
            try await lake.write("\(dir)/payload.bin", payload)

            // Refresh the parent directory so the file's metadata is cached
            // before we call open().
            let dirKey  = cacheKey(lake: lake, path: dir)
            _ = try await engine.refreshFolder(key: dirKey)

            // Now open the file via the engine.
            let fileKey = cacheKey(lake: lake, path: "\(dir)/payload.bin")
            let url = try await engine.open(key: fileKey)

            // Verify byte-for-byte equality.
            let downloaded = try Data(contentsOf: url)
            #expect(downloaded == payload)

            // Verify the cache record was populated correctly.
            let rec = try await store.fetch(key: fileKey)
            #expect(rec.contentLength == Int64(payload.count))
            // blobSHA256 is populated after a successful blob store.
            #expect(!rec.blobSHA256.isEmpty, "blobSHA256 should be non-empty after open()")
        } catch {
            await lake.rmBestEffort(dir)
            throw error
        }
        try await lake.rm(dir)
    }

    // MARK: - Test 7: put uploads a local file and the engine then re-enumerates it

    @Test("put uploads a local file and the engine then re-enumerates it")
    func testPutUploadsThenEnumerates() async throws {
        let lake = try liveLakehouse()
        let (engine, store, scratchBase) = try makeEngineAndStore(lake: lake)
        let dir = "Files/ofem-ci/\(UUID().uuidString)"

        // We also need a local temp file to upload from.
        let localTempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)

        defer {
            try? FileManager.default.removeItem(at: store.root)
            try? FileManager.default.removeItem(at: scratchBase)
            try? FileManager.default.removeItem(at: localTempDir)
        }

        let uploadPayload = Data((0..<512).map { UInt8($0 % 127) })

        do {
            // Create the destination directory on OneLake first.
            try await lake.mkdir(dir)

            // Create the CacheKey for the upload destination.
            let dirKey  = cacheKey(lake: lake, path: dir)
            let fileKey = cacheKey(lake: lake, path: "\(dir)/uploaded.bin")

            // Seed the engine's cache view of the directory with a refreshFolder
            // call so subsequent children() queries work correctly.  We do NOT
            // call engine.mkdir() here because createDirectory on an already-
            // existing ADLS Gen2 path returns 409 PathAlreadyExists, which would
            // throw and abort the test.
            _ = try await engine.refreshFolder(key: dirKey)

            // Write the local temp file.
            try FileManager.default.createDirectory(at: localTempDir, withIntermediateDirectories: true)
            let localURL = localTempDir.appendingPathComponent("uploaded.bin")
            try uploadPayload.write(to: localURL)

            // Upload via the engine.
            try await engine.put(key: fileKey, sourceURL: localURL)

            // Force a fresh listing from OneLake to verify the file landed.
            let diff = try await engine.refreshFolder(key: dirKey)

            // The uploaded file must appear as a new entry if the cache was
            // empty for this directory before, or as updated/added depending
            // on engine state.  Either way the total change count must be >= 1.
            #expect(diff.total >= 1)

            let kids = try await store.children(of: dirKey)
            let uploadedRecord = kids.first { $0.name == "uploaded.bin" }
            #expect(uploadedRecord != nil, "uploaded.bin should appear after refreshFolder")
            if let r = uploadedRecord {
                #expect(r.contentLength == Int64(uploadPayload.count))
            }
        } catch {
            await lake.rmBestEffort(dir)
            throw error
        }
        try await lake.rm(dir)
    }
}
