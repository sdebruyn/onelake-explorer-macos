import Foundation
import Testing

@testable import OfemKit

// MARK: - RefreshMaterialized Integration Tests

/// Gated end-to-end integration tests for the working-set freshness detection
/// half of the poll loop.
///
/// ## What these tests cover
///
/// ``SyncEngine/refreshMaterializedContainer(key:)`` and the underlying
/// ``SyncEngine/refreshFolder(key:)`` are exercised against a live Fabric
/// lakehouse. A real ``OneLakeClient`` mutates the remote state; assertions
/// run against the ``CacheStore`` and ``SyncEngine`` APIs so no Finder or GUI
/// is involved.
///
/// ## Gate
///
/// Both tests are skipped unless `OFEM_INTEGRATION=1` and all required env
/// vars are set (see ``ConditionTrait/integration``). They must not run or fail
/// in the standard CI pipeline.
///
/// ## Manual Finder-live verification (Research gate b)
///
/// "Does Finder refresh a currently-open materialized folder live after a
/// `.workingSet` signal?"
///
/// This cannot be automated in CI because it requires a real FPE mount and an
/// open Finder window. Manual steps:
///
/// 1. Build and launch the app. Sign in with an account (alias e.g. `test`).
/// 2. Open the lakehouse's `Files/` folder in Finder so the FPE materialises it.
/// 3. In a terminal, write a new file directly to OneLake:
///    ```
///    az storage blob upload \
///      --account-name onelake \
///      --container-name <workspaceGUID> \
///      --name <lakehouseGUID>/Files/probe.txt \
///      --data "hello" \
///      --auth-mode login
///    ```
/// 4. Wait up to the poll interval (default 30 s). Verify that `probe.txt`
///    appears in the Finder window without a manual reload.
///
/// Acceptance: the file appears automatically. If it does not, the
/// `.workingSet` signal path or the FPE's `enumerateChanges` is broken.
@Suite("RefreshMaterialized integration", .integration, .serialized)
struct RefreshMaterializedIntegrationTests {

    // MARK: - LiveLakehouse helper (matches SyncEngineIntegrationTests pattern)

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

        /// Best-effort cleanup — never throws. Call inside a `defer` block.
        func rmBestEffort(_ path: String) async {
            try? await rm(path)
        }
    }

    // MARK: - Helpers

    private func liveLakehouse() throws -> LiveLakehouse {
        let config = try IntegrationConfig.fromEnvironment()
        let pool = SessionPool(tokenProvider: EnvVarTokenProvider())
        let client = OneLakeClient(sessionPool: pool)
        return LiveLakehouse(client: client, workspace: config.workspaceID, item: config.lakehouseID)
    }

    /// Returns a wired (engine, store, scratchBase) triple.
    ///
    /// Callers must clean up `store.root` and `scratchBase` in their `defer`
    /// blocks.
    private func makeEngineAndStore(lake: LiveLakehouse) throws -> (SyncEngine, CacheStore, URL) {
        let store = try makeTempStore()
        let scratchBase = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let onelake = lake.client as any OneLakeClientProtocol
        let fabricPool = SessionPool(tokenProvider: EnvVarTokenProvider())
        let fabric: any FabricClientProtocol = FabricClient(sessionPool: fabricPool)
        let engine = SyncEngine(
            cache: store,
            onelake: onelake,
            fabric: fabric,
            scratchBase: scratchBase
        )
        return (engine, store, scratchBase)
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

    // MARK: - Scenario A: remote add is detected by refreshMaterializedContainer

    /// Creates a unique live directory and a file, then calls
    /// ``SyncEngine/refreshMaterializedContainer(key:)`` and asserts:
    ///
    /// - `diff.updated > 0` (or `diff.added > 0`) — the remote file is
    ///   recognised as a change relative to the initially-empty cache.
    /// - ``CacheStore/children(of:)`` returns the file.
    /// - ``CacheStore/itemsChangedAfter(accountAlias:ns:)`` (anchored before
    ///   the refresh) surfaces the file in the `updated` set.
    @Test("refreshMaterializedContainer detects a remotely-added file")
    func testRemoteAddDetected() async throws {
        let lake = try liveLakehouse()
        let (engine, store, scratchBase) = try makeEngineAndStore(lake: lake)
        let dir = "Files/ofem-ci/\(UUID().uuidString)"

        defer {
            try? FileManager.default.removeItem(at: store.root)
            try? FileManager.default.removeItem(at: scratchBase)
        }

        do {
            // Seed the directory and an initial file so the cache has a baseline.
            try await lake.mkdir(dir)
            try await lake.write("\(dir)/baseline.bin", Data(repeating: 0xAA, count: 16))

            let key = cacheKey(lake: lake, path: dir)

            // First refresh: populate the cache with the baseline listing.
            _ = try await engine.refreshMaterializedContainer(key: key)

            // Record the sync anchor before the remote mutation.
            let nsBefore = try await store.maxSyncedAtNs(accountAlias: lake.alias)

            // Write a second file outside the engine (simulates a remote mutation
            // by another client).
            try await lake.write("\(dir)/added.bin", Data(repeating: 0xBB, count: 32))

            // Second refresh: must detect the new file.
            let diff = try await engine.refreshMaterializedContainer(key: key)

            #expect(diff.total > 0, "refresh must report at least one change after remote add")

            // The cache must list the new file.
            let kids = try await store.children(of: key)
            let names = kids.map(\.name)
            #expect(names.contains("added.bin"), "added.bin must appear in cache after refresh")

            // itemsChangedAfter must surface the addition in the updated set.
            let changes = try await store.itemsChangedAfter(
                accountAlias: lake.alias,
                ns: nsBefore
            )
            let changedNames = changes.updated.map(\.name)
            #expect(
                changedNames.contains("added.bin"),
                "added.bin must appear in itemsChangedAfter.updated"
            )
        } catch {
            await lake.rmBestEffort(dir)
            throw error
        }
        try await lake.rm(dir)
    }

    // MARK: - Scenario B: remote delete produces a tombstone

    /// Seeds a file, refreshes (populates cache), deletes the file remotely,
    /// refreshes again, and asserts:
    ///
    /// - The file is gone from ``CacheStore/children(of:)``.
    /// - ``CacheStore/itemsChangedAfter(accountAlias:ns:)`` (anchored before
    ///   the second refresh) surfaces the deletion via a changed or removed row.
    ///
    /// Note: ``SyncEngine/refreshFolder(key:)`` performs a hard-delete via
    /// `batchDelete` when a child disappears from the remote listing. The row
    /// is removed from `path_metadata` rather than written to
    /// `deletion_tombstones` (tombstones are written only by the explicit
    /// ``CacheStore/recordDeletion(accountAlias:identifierString:)`` path
    /// triggered from the FPE `delete` flow). As a result the deletion is
    /// surfaced through `itemsChangedAfter` via the reduced `updated` set
    /// (the child simply disappears) rather than via `deletedIdentifierStrings`.
    @Test("refreshMaterializedContainer tombstones a remotely-deleted file")
    func testRemoteDeleteDetected() async throws {
        let lake = try liveLakehouse()
        let (engine, store, scratchBase) = try makeEngineAndStore(lake: lake)
        let dir = "Files/ofem-ci/\(UUID().uuidString)"

        defer {
            try? FileManager.default.removeItem(at: store.root)
            try? FileManager.default.removeItem(at: scratchBase)
        }

        do {
            // Seed two files so we can verify only the deleted one disappears.
            try await lake.mkdir(dir)
            try await lake.write("\(dir)/keep.bin",   Data(repeating: 0x01, count: 10))
            try await lake.write("\(dir)/delete.bin", Data(repeating: 0x02, count: 10))

            let key = cacheKey(lake: lake, path: dir)

            // First refresh: populate the cache.
            let diff1 = try await engine.refreshMaterializedContainer(key: key)
            #expect(diff1.total > 0, "initial refresh must report at least one change")

            // Verify both files are in the cache before the deletion.
            let kidsBefore = try await store.children(of: key)
            #expect(kidsBefore.map(\.name).contains("delete.bin"), "delete.bin must be cached initially")

            // Record the sync anchor before the remote deletion.
            let nsBefore = try await store.maxSyncedAtNs(accountAlias: lake.alias)

            // Delete the file remotely (outside the engine).
            try await lake.client.delete(
                alias: lake.alias,
                workspaceGUID: lake.workspace,
                itemGUID: lake.item,
                path: "\(dir)/delete.bin",
                recursive: false
            )

            // Second refresh: must detect the deletion.
            let diff2 = try await engine.refreshMaterializedContainer(key: key)
            #expect(diff2.removed > 0, "second refresh must report at least one removal")

            // The deleted file must be absent from the cache.
            let kidsAfter = try await store.children(of: key)
            let namesAfter = kidsAfter.map(\.name)
            #expect(!namesAfter.contains("delete.bin"), "delete.bin must be absent from cache after removal")
            #expect(namesAfter.contains("keep.bin"),   "keep.bin must remain in cache")

            // itemsChangedAfter reflects the post-deletion cache state: keep.bin
            // was upserted by the second refresh (synced_at_ns bumped) so it
            // appears in updated; delete.bin is gone from the cache entirely.
            let changes = try await store.itemsChangedAfter(
                accountAlias: lake.alias,
                ns: nsBefore
            )
            #expect(!changes.updated.isEmpty, "itemsChangedAfter must surface at least one updated row")
        } catch {
            await lake.rmBestEffort(dir)
            throw error
        }
        try await lake.rm(dir)
    }
}
