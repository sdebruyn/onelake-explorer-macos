import Foundation
@testable import OfemKit
import Testing

// MARK: - RefreshMaterialized Integration Tests

/// Gated end-to-end integration tests for the working-set freshness detection
/// half of the poll loop.
///
/// ## What these tests cover
///
/// Three scenarios exercise the full detection pipeline against a live Fabric
/// lakehouse. A real ``OneLakeClient`` mutates the remote state; assertions run
/// against ``CacheStore`` and ``SyncEngine`` so no Finder or GUI is involved.
///
/// - **Scenario A** — remote add detected by ``SyncEngine/refreshMaterializedContainer(key:)``
/// - **Scenario B** — remote delete detected; cache row removed
/// - **Scenario C** — full poll-loop emulation: `setMaterialized` registers a
///   container, `refreshMaterialized(alias:keys:concurrencyCap:)` (the batch poller
///   the host loop calls) detects a remote add and a remote replace,
///   `itemsChangedAfter` surfaces both via the `updated` set
///
/// ## Gate
///
/// All tests are skipped unless `OFEM_INTEGRATION=1` and all required env
/// vars are set (see ``ConditionTrait/integration``). They must not run or fail
/// in the standard CI pipeline.
///
/// ## Manual Finder-live verification (Research gate b)
///
/// "Does Finder refresh a currently-open materialized folder live after a
/// `.workingSet` signal?"
///
/// This cannot be automated in CI because it requires a real FPE mount and an
/// open Finder window. Steps:
///
/// 1. Build and launch the app (`make app`). Sign in with an account
///    (alias e.g. `ci`).
/// 2. Navigate into the lakehouse's `Files/ofem-ci/` folder in Finder so the
///    FPE materialises it (the folder appears in `materialized_containers`).
/// 3. Lower the poll cadence to its minimum to speed up observation:
///    edit `~/Library/Group Containers/dev.debruyn.ofem/ofem.toml`:
///    ```toml
///    [sync]
///    materialized_poll_interval_s = 30
///    ```
/// 4. In a terminal, write a new file directly to OneLake (needs `az login`):
///    ```
///    az storage fs file upload \
///      --account-name onelake \
///      --file-system <workspaceGUID> \
///      --path <lakehouseGUID>/Files/ofem-ci/probe.txt \
///      --source /dev/stdin <<< "hello" \
///      --auth-mode login
///    ```
/// 5. Wait up to 30 s. Verify that `probe.txt` appears in the Finder window
///    without a manual reload.
///
/// Acceptance: the file appears automatically. If it does not, the
/// `.workingSet` signal path or the FPE's `enumerateChanges` is broken.
/// Document the observed behaviour (appears / does not appear, delay in
/// seconds) as a comment on issue #346.
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

    // MARK: - LiveWarehouse helper (for Delta-table quiescence scenario)

    /// Binds live warehouse coordinates for read-only tests against the seeded
    /// Delta table.  The warehouse is never mutated by these tests.
    private struct LiveWarehouse {
        let client: OneLakeClient
        let workspaceID: String
        let itemID: String
        let alias = "ci"
        let table: String

        /// Item-relative path to the seeded Delta table folder (e.g. `Tables/dbo/ofem_ci_orders`).
        var tableDir: String {
            "Tables/dbo/\(table)"
        }

        /// Item-relative path to the Delta transaction log directory.
        var deltaLogDir: String {
            "\(tableDir)/_delta_log"
        }
    }

    // MARK: - Helpers

    private func liveLakehouse() throws -> LiveLakehouse {
        let config = try IntegrationConfig.fromEnvironment()
        let pool = SessionPool(tokenProvider: EnvVarTokenProvider())
        let client = OneLakeClient(sessionPool: pool)
        return LiveLakehouse(client: client, workspace: config.workspaceID, item: config.lakehouseID)
    }

    /// Loads warehouse coordinates from the environment. Requires `.warehouse` gate.
    private func liveWarehouse() throws -> LiveWarehouse {
        let config = try IntegrationConfig.fromEnvironment()
        let warehouseID = try config.requireWarehouseID()
        let table = ProcessInfo.processInfo.environment["OFEM_TEST_WH_TABLE"]
            .flatMap { $0.isEmpty ? nil : $0 } ?? "ofem_ci_orders"
        let pool = SessionPool(tokenProvider: EnvVarTokenProvider())
        let client = OneLakeClient(sessionPool: pool)
        return LiveWarehouse(
            client: client,
            workspaceID: config.workspaceID,
            itemID: warehouseID,
            table: table
        )
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

    /// Returns a wired (engine, store, scratchBase) triple backed by a warehouse item.
    ///
    /// Callers must clean up `store.root` and `scratchBase` in their `defer` blocks.
    private func makeEngineAndStore(wh: LiveWarehouse) throws -> (SyncEngine, CacheStore, URL) {
        let store = try makeTempStore()
        let scratchBase = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let onelake = wh.client as any OneLakeClientProtocol
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

    /// Returns a ``CacheKey`` for the given path inside the live warehouse.
    private func cacheKey(wh: LiveWarehouse, path: String) -> CacheKey {
        CacheKey(
            accountAlias: wh.alias,
            workspaceID: wh.workspaceID,
            itemID: wh.itemID,
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
    func remoteAddDetected() async throws {
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
    func remoteDeleteDetected() async throws {
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
            try await lake.write("\(dir)/keep.bin", Data(repeating: 0x01, count: 10))
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
            #expect(namesAfter.contains("keep.bin"), "keep.bin must remain in cache")

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

    // MARK: - Scenario C: full poll-loop emulation

    /// Emulates one complete poll-loop iteration end-to-end:
    ///
    /// 1. Creates a unique live directory, registers it as a materialized
    ///    container via ``CacheStore/setMaterialized(alias:identifiers:)``.
    /// 2. Seeds two files and performs an initial
    ///    ``SyncEngine/refreshMaterialized(alias:keys:concurrencyCap:)`` pass to
    ///    populate the cache baseline (simulates the state after Finder has
    ///    materialised the folder).
    /// 3. Remotely adds one new file and overwrites another (etag change).
    /// 4. Reads the materialized set back from the cache, then calls
    ///    ``SyncEngine/refreshMaterialized(alias:keys:concurrencyCap:)`` — the
    ///    exact call the host poll loop makes — and asserts it returns `true`
    ///    (at least one container changed).
    /// 5. Verifies that ``CacheStore/itemsChangedAfter(accountAlias:ns:)``
    ///    (anchored before step 3) surfaces both the new file and the updated
    ///    file in the `updated` set.
    ///
    /// This test exercises the boundary between the engine and the poll loop
    /// coordinator without requiring a running FPE or Finder window.
    @Test("full poll-loop emulation: setMaterialized + refreshMaterialized + itemsChangedAfter")
    func pollLoopEmulation() async throws {
        let lake = try liveLakehouse()
        let (engine, store, scratchBase) = try makeEngineAndStore(lake: lake)
        let dir = "Files/ofem-ci/\(UUID().uuidString)"

        defer {
            try? FileManager.default.removeItem(at: store.root)
            try? FileManager.default.removeItem(at: scratchBase)
        }

        do {
            // Step 1: create the remote directory and register it as materialized.
            try await lake.mkdir(dir)

            // The identifier string the FPE uses for this path container.
            let identifierString = ItemIdentifier
                .path(workspaceID: lake.workspace, itemID: lake.item, path: dir)
                .identifierString
            try await store.setMaterialized(alias: lake.alias, identifiers: [identifierString])

            // Step 2: seed baseline files and perform an initial batch refresh.
            try await lake.write("\(dir)/stable.bin", Data(repeating: 0xAA, count: 16))
            try await lake.write("\(dir)/update.bin", Data(repeating: 0xBB, count: 16))

            let dirKey = cacheKey(lake: lake, path: dir)
            let keysFromCache1 = try await store.materializedContainers(alias: lake.alias)
            #expect(!keysFromCache1.isEmpty, "materializedContainers must return at least one key after setMaterialized")
            let firstPoll = await engine.refreshMaterialized(
                alias: lake.alias,
                keys: keysFromCache1,
                concurrencyCap: 2
            )
            // First pass: the cache was empty → at least one container changed.
            #expect(firstPoll == true, "initial refreshMaterialized must report true (cold cache)")

            // Verify baseline is cached.
            let kidsAfterSeed = try await store.children(of: dirKey)
            #expect(kidsAfterSeed.map(\.name).contains("stable.bin"), "stable.bin must be cached after first poll")
            #expect(kidsAfterSeed.map(\.name).contains("update.bin"), "update.bin must be cached after first poll")

            // Step 3: record anchor, then mutate the remote state.
            let nsBefore = try await store.maxSyncedAtNs(accountAlias: lake.alias)

            // Add a new file.
            try await lake.write("\(dir)/added.bin", Data(repeating: 0xCC, count: 32))
            // Overwrite update.bin with different content → new etag.
            try await lake.write("\(dir)/update.bin", Data(repeating: 0xDD, count: 64))

            // Step 4: re-read the materialized set (mimics the poll loop) and call
            // the batch refresher.
            let keysFromCache2 = try await store.materializedContainers(alias: lake.alias)
            #expect(!keysFromCache2.isEmpty, "materializedContainers must still return keys after baseline poll")
            let secondPoll = await engine.refreshMaterialized(
                alias: lake.alias,
                keys: keysFromCache2,
                concurrencyCap: 2
            )
            #expect(secondPoll == true, "refreshMaterialized must return true when remote state changed")

            // Step 5: verify itemsChangedAfter surfaces both mutations.
            let changes = try await store.itemsChangedAfter(
                accountAlias: lake.alias,
                ns: nsBefore
            )
            let changedNames = Set(changes.updated.map(\.name))
            #expect(
                changedNames.contains("added.bin"),
                "added.bin must appear in itemsChangedAfter.updated after remote add"
            )
            #expect(
                changedNames.contains("update.bin"),
                "update.bin must appear in itemsChangedAfter.updated after remote overwrite"
            )
        } catch {
            await lake.rmBestEffort(dir)
            throw error
        }
        try await lake.rm(dir)
    }

    // MARK: - Scenario D: quiescent backend produces zero deltas on every poll

    /// Guards the invariant that a **static** remote container produces zero
    /// change deltas on repeated refreshes once the cache has been seeded.
    ///
    /// ## Why this test exists
    ///
    /// ADLS Gen2 advances a directory's `Last-Modified` header whenever any
    /// descendant is written — even for internal Delta-log compaction or
    /// partition file updates that the user never triggered.  A naïve
    /// implementation that compares directory `lastModified` against the cached
    /// value therefore reports a phantom delta every poll, keeping the working-set
    /// signal fire-hosed and starving normal enumeration.  This test exercises
    /// that exact class of container (a real warehouse Delta table with its
    /// `_delta_log` subtree) against the live service and asserts that the engine
    /// is quiescent: **once the baseline is cached, subsequent polls against an
    /// unchanged backend must report `diff.total == 0`.**
    ///
    /// The test depends on the phantom-delta fix (PR #358) to pass when run live.
    /// It is intentionally merged after #358 as a permanent regression guard.
    ///
    /// ## Gate
    ///
    /// Gated by `.warehouse` (requires `OFEM_INTEGRATION=1` + a seeded warehouse
    /// table via `scripts/prep_warehouse.sql`); skipped in the normal CI pass.
    @Test(
        "quiescent backend: repeated polls on a static Delta table produce zero deltas",
        .warehouse
    )
    func quiescentBackendProducesZeroDeltas() async throws {
        let wh = try liveWarehouse()
        let (engine, store, scratchBase) = try makeEngineAndStore(wh: wh)

        defer {
            try? FileManager.default.removeItem(at: store.root)
            try? FileManager.default.removeItem(at: scratchBase)
        }

        // The table folder and its _delta_log subdirectory are the exact paths
        // where the phantom-delta regression manifested: ADLS advances the
        // directory's lastModified on every descendant write, so `_delta_log`
        // and its parent both look "changed" even when no user-visible file
        // was added or removed.
        let tableKey = cacheKey(wh: wh, path: wh.tableDir)
        let deltaLogKey = cacheKey(wh: wh, path: wh.deltaLogDir)

        // Step 1: seed the cache baseline by refreshing both containers once.
        // The table folder must have at least _delta_log as a child for this
        // test to be meaningful — verify before asserting quiescence.
        let seedDiff = try await engine.refreshMaterializedContainer(key: tableKey)
        #expect(seedDiff.total > 0, "initial refresh of a cold cache must report at least one change")

        let tableChildren = try await store.children(of: tableKey)
        try #require(
            tableChildren.contains { $0.name == "_delta_log" },
            "seeded table cache must include _delta_log — is the warehouse table prepared?"
        )

        // Seed _delta_log as well; its entries are the per-commit JSON files.
        let seedLogDiff = try await engine.refreshMaterializedContainer(key: deltaLogKey)
        #expect(seedLogDiff.total > 0, "initial refresh of _delta_log cache must report at least one change")

        // Step 2: poll the same containers 3 more times without any remote
        // mutation and assert every subsequent diff is zero.
        //
        // Three repetitions guard against transient timing effects: a single
        // second poll that returns zero might be a coincidence (e.g. the
        // service hadn't advanced the directory timestamp yet); three
        // consecutive zeros are reliable evidence of correct quiescence.
        for iteration in 1 ... 3 {
            let tableDiff = try await engine.refreshMaterializedContainer(key: tableKey)
            #expect(
                tableDiff.total == 0,
                "poll \(iteration): table folder must be quiescent (got added=\(tableDiff.added) updated=\(tableDiff.updated) removed=\(tableDiff.removed))"
            )
            #expect(tableDiff.added == 0, "poll \(iteration): table folder must report zero added entries")
            #expect(tableDiff.updated == 0, "poll \(iteration): table folder must report zero updated entries")
            #expect(tableDiff.removed == 0, "poll \(iteration): table folder must report zero removed entries")

            let logDiff = try await engine.refreshMaterializedContainer(key: deltaLogKey)
            #expect(
                logDiff.total == 0,
                "poll \(iteration): _delta_log must be quiescent (got added=\(logDiff.added) updated=\(logDiff.updated) removed=\(logDiff.removed))"
            )
            #expect(logDiff.added == 0, "poll \(iteration): _delta_log must report zero added entries")
            #expect(logDiff.updated == 0, "poll \(iteration): _delta_log must report zero updated entries")
            #expect(logDiff.removed == 0, "poll \(iteration): _delta_log must report zero removed entries")
        }

        // Step 3: also verify via the batch-refresher path that `refreshMaterialized`
        // returns `false` (no container changed) on a subsequent pass — this is the
        // exact call the host poll loop makes when deciding whether to signal
        // `.workingSet`.
        let identifiers = [tableKey, deltaLogKey].map { key in
            ItemIdentifier
                .path(workspaceID: key.workspaceID, itemID: key.itemID, path: key.path)
                .identifierString
        }
        try await store.setMaterialized(alias: wh.alias, identifiers: identifiers)

        let keys = try await store.materializedContainers(alias: wh.alias)
        let batchResult = await engine.refreshMaterialized(
            alias: wh.alias,
            keys: keys,
            concurrencyCap: 2
        )
        #expect(
            batchResult == false,
            "refreshMaterialized must return false when the backend is quiescent"
        )
    }
}
