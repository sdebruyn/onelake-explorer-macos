import Foundation
@testable import OfemKit
import Testing

// MARK: - SyncEngine.refreshMaterialized tests

/// Tests for ``SyncEngine/refreshMaterializedContainer(key:)`` and
/// ``SyncEngine/refreshMaterialized(alias:keys:concurrencyCap:)``.
@Suite("SyncEngine refreshMaterialized")
struct SyncEngineRefreshMaterializedTests {
    // MARK: - Constants

    private static let alias = "test"
    private static let wsID = "ws-1"
    private static let itID = "item-1"
    private static let itID2 = "item-2"

    private static var folderKey: CacheKey {
        CacheKey(accountAlias: alias, workspaceID: wsID, itemID: itID, path: "")
    }

    private static var folder2Key: CacheKey {
        CacheKey(accountAlias: alias, workspaceID: wsID, itemID: itID2, path: "")
    }

    // MARK: - Helpers

    private func makeEngine(
        onelake: any OneLakeClientProtocol
    ) throws -> (SyncEngine, CacheStore) {
        let store = try makeTempStore()
        let scratchDir = store.root.appending(path: "scratch", directoryHint: .isDirectory)
        let engine = SyncEngine(
            cache: store,
            onelake: onelake,
            fabric: MockFabricClient(),
            scratchBase: scratchDir
        )
        return (engine, store)
    }

    /// Seeds a parent directory row plus its children into the cache.
    private func seedFolder(
        in store: CacheStore,
        key: CacheKey,
        children: [(name: String, etag: String)]
    ) async throws {
        let syncedNs = Int64(Date().addingTimeInterval(-60).timeIntervalSince1970 * 1_000_000_000)
        let parent = MetadataRecord(
            accountAlias: key.accountAlias,
            workspaceID: key.workspaceID,
            itemID: key.itemID,
            path: key.path,
            parentPath: Enumerator.parentPath(key.path),
            name: Enumerator.baseName(key.path),
            isDir: true,
            childrenSyncedAtNs: syncedNs
        )
        try await store.upsert(parent)
        for child in children {
            let childPath = key.path.isEmpty ? child.name : "\(key.path)/\(child.name)"
            let row = MetadataRecord(
                accountAlias: key.accountAlias,
                workspaceID: key.workspaceID,
                itemID: key.itemID,
                path: childPath,
                parentPath: key.path,
                name: child.name,
                isDir: false,
                etag: child.etag
            )
            try await store.upsert(row)
        }
    }

    // MARK: - AC1: changed etag → diff.updated > 0, bumped syncedAtNs, new ContentVersion

    @Test("Changed etag yields diff.updated > 0, bumped synced_at_ns, new ContentVersion")
    func changedEtagYieldsDiffAndBumpedSyncedAt() async throws {
        let ol = MockOneLakeClient()
        let (engine, store) = try makeEngine(onelake: ol)
        defer { try? FileManager.default.removeItem(at: store.root) }

        let key = Self.folderKey
        try await seedFolder(in: store, key: key, children: [("data.csv", "etag-v1")])

        // Remote returns the same file with a new etag.
        ol.listPathResults.append(.success(ListResult(entries: [
            PathEntry.file(name: "data.csv", eTag: "etag-v2"),
        ])))

        let childKey = CacheKey(
            accountAlias: key.accountAlias,
            workspaceID: key.workspaceID,
            itemID: key.itemID,
            path: "data.csv"
        )
        let rowBefore = try await store.fetch(key: childKey)
        let syncedBefore = rowBefore.syncedAtNs

        let diff = try await engine.refreshMaterializedContainer(key: key)
        #expect(diff.updated > 0)

        // synced_at_ns was bumped.
        let rowAfter = try await store.fetch(key: childKey)
        #expect(rowAfter.syncedAtNs > syncedBefore)

        // The cached etag was updated to the new value, which means ContentVersion
        // derived from the etag changed (ContentVersion.content(for:) hashes the etag).
        #expect(rowAfter.etag == "etag-v2")
        let versionBefore = ContentVersion.content(for: MetadataRecord(
            accountAlias: key.accountAlias, workspaceID: key.workspaceID, itemID: key.itemID,
            path: "data.csv", parentPath: "", name: "data.csv", isDir: false, etag: "etag-v1"
        ))
        let versionAfter = ContentVersion.content(for: rowAfter)
        #expect(versionBefore != versionAfter)
    }

    // MARK: - AC1: removed entry → tombstone surfaced by itemsChangedAfter

    @Test("Removed remote entry writes a tombstone surfaced by itemsChangedAfter")
    func removedEntryWritesTombstone() async throws {
        let ol = MockOneLakeClient()
        let (engine, store) = try makeEngine(onelake: ol)
        defer { try? FileManager.default.removeItem(at: store.root) }

        let key = Self.folderKey
        try await seedFolder(in: store, key: key, children: [("keep.txt", "e1"), ("gone.txt", "e2")])

        // Record the max synced_at_ns before the refresh so we can query changes after.
        let nsBefore = try await store.maxSyncedAtNs(accountAlias: key.accountAlias)

        // Remote no longer has "gone.txt".
        ol.listPathResults.append(.success(ListResult(entries: [
            PathEntry.file(name: "keep.txt", size: 0, eTag: "e1"),
        ])))

        let diff = try await engine.refreshMaterializedContainer(key: key)
        #expect(diff.removed > 0)

        // The row for "gone.txt" must be absent from the cache (hard-deleted by
        // refreshFolder's batchDelete reconcile).
        let goneKey = CacheKey(
            accountAlias: key.accountAlias,
            workspaceID: key.workspaceID,
            itemID: key.itemID,
            path: "gone.txt"
        )
        let goneRow = try? await store.fetch(key: goneKey)
        #expect(goneRow == nil)

        // "keep.txt" must remain.
        let keepKey = CacheKey(
            accountAlias: key.accountAlias,
            workspaceID: key.workspaceID,
            itemID: key.itemID,
            path: "keep.txt"
        )
        let keepRow = try? await store.fetch(key: keepKey)
        #expect(keepRow != nil)

        // itemsChangedAfter surfaces updated rows (refreshFolder bumps synced_at_ns
        // for all upserted children, including keep.txt). Note: batchDelete does
        // not write File-Provider tombstones — that is the role of CacheStore.delete.
        let changes = try await store.itemsChangedAfter(
            accountAlias: key.accountAlias,
            ns: nsBefore
        )
        #expect(!changes.updated.isEmpty)
    }

    // MARK: - AC1: refreshMaterializedContainer bypasses the revalidate debounce

    @Test("refreshMaterializedContainer runs even when the folder is within the debounce window")
    func bypassesDebounce() async throws {
        let ol = MockOneLakeClient()
        let (engine, store) = try makeEngine(onelake: ol)
        defer { try? FileManager.default.removeItem(at: store.root) }

        let key = Self.folderKey
        // Seed a fresh folder (1 s old — well within the 10 s debounce window).
        let syncedNs = Int64(Date().addingTimeInterval(-1).timeIntervalSince1970 * 1_000_000_000)
        let parent = MetadataRecord(
            accountAlias: key.accountAlias, workspaceID: key.workspaceID, itemID: key.itemID,
            path: "", parentPath: "", name: "root", isDir: true,
            childrenSyncedAtNs: syncedNs
        )
        try await store.upsert(parent)

        // Remote unchanged — the call should still happen (not suppressed).
        ol.listPathResults.append(.success(ListResult(entries: [])))

        // refreshMaterializedContainer must NOT skip due to freshness/debounce.
        _ = try await engine.refreshMaterializedContainer(key: key)
        #expect(ol.listPathCalls.count == 1)
    }

    // MARK: - AC2: refreshMaterialized returns true iff any container changed

    @Test("refreshMaterialized returns true when at least one container changed")
    func returnsTrueWhenAnyContainerChanged() async throws {
        let ol = MockOneLakeClient()
        let (engine, store) = try makeEngine(onelake: ol)
        defer { try? FileManager.default.removeItem(at: store.root) }

        let key1 = Self.folderKey
        let key2 = Self.folder2Key

        try await seedFolder(in: store, key: key1, children: [("a.txt", "v1")])
        try await seedFolder(in: store, key: key2, children: [("b.txt", "v1")])

        // key1: etag + size unchanged → no diff; key2: etag changed → diff.updated > 0.
        ol.listPathResults.append(.success(ListResult(entries: [
            PathEntry.file(name: "a.txt", size: 0, eTag: "v1"), // unchanged
        ])))
        ol.listPathResults.append(.success(ListResult(entries: [
            PathEntry.file(name: "b.txt", size: 0, eTag: "v2"), // changed etag
        ])))

        let changed = await engine.refreshMaterialized(
            alias: Self.alias,
            keys: [key1, key2],
            concurrencyCap: 2
        )
        #expect(changed == true)
    }

    @Test("refreshMaterialized returns false when no container changed")
    func returnsFalseWhenNothingChanged() async throws {
        let ol = MockOneLakeClient()
        let (engine, store) = try makeEngine(onelake: ol)
        defer { try? FileManager.default.removeItem(at: store.root) }

        let key = Self.folderKey
        try await seedFolder(in: store, key: key, children: [("a.txt", "v1")])

        // Remote identical: use size: 0 to match the seeded contentLength: 0.
        ol.listPathResults.append(.success(ListResult(entries: [
            PathEntry.file(name: "a.txt", size: 0, eTag: "v1"),
        ])))

        let changed = await engine.refreshMaterialized(
            alias: Self.alias,
            keys: [key],
            concurrencyCap: 1
        )
        #expect(changed == false)
    }

    // MARK: - AC2: per-key offline/cancel does not abort the batch

    @Test("Per-key offline error does not abort the batch; other keys still run")
    func perKeyOfflineDoesNotAbortBatch() async throws {
        let ol = MockOneLakeClient()
        let (engine, store) = try makeEngine(onelake: ol)
        defer { try? FileManager.default.removeItem(at: store.root) }

        let key1 = Self.folderKey
        let key2 = Self.folder2Key

        try await seedFolder(in: store, key: key1, children: [("a.txt", "v1")])
        try await seedFolder(in: store, key: key2, children: [("b.txt", "v1")])

        // key1 fails offline; key2 succeeds with a change.
        let offlineError = OneLakeError.httpError(
            HTTPClientError.transport(URLError(.notConnectedToInternet))
        )
        ol.listPathResults.append(.failure(offlineError))
        ol.listPathResults.append(.success(ListResult(entries: [
            PathEntry.file(name: "b.txt", eTag: "v2"), // changed
        ])))

        // The batch completes (not thrown). key2's change still registers.
        let changed = await engine.refreshMaterialized(
            alias: Self.alias,
            keys: [key1, key2],
            concurrencyCap: 2
        )
        #expect(changed == true)
    }

    @Test("Per-key cancellation error does not abort the batch")
    func perKeyCancellationDoesNotAbortBatch() async throws {
        let ol = MockOneLakeClient()
        let (engine, store) = try makeEngine(onelake: ol)
        defer { try? FileManager.default.removeItem(at: store.root) }

        let key1 = Self.folderKey
        let key2 = Self.folder2Key

        try await seedFolder(in: store, key: key1, children: [("a.txt", "v1")])
        try await seedFolder(in: store, key: key2, children: [("b.txt", "v1")])

        // key1 throws CancellationError; key2 succeeds with a change.
        ol.listPathResults.append(.failure(CancellationError()))
        ol.listPathResults.append(.success(ListResult(entries: [
            PathEntry.file(name: "b.txt", eTag: "v2"),
        ])))

        let changed = await engine.refreshMaterialized(
            alias: Self.alias,
            keys: [key1, key2],
            concurrencyCap: 2
        )
        #expect(changed == true)
    }

    // MARK: - AC2: offline batch keeps existing cache rows (no deletes/tombstones)

    @Test("Offline error on a key keeps existing cache rows intact")
    func offlineKeepsCacheRows() async throws {
        let ol = MockOneLakeClient()
        let (engine, store) = try makeEngine(onelake: ol)
        defer { try? FileManager.default.removeItem(at: store.root) }

        let key = Self.folderKey
        try await seedFolder(in: store, key: key, children: [("a.txt", "v1"), ("b.txt", "v2")])

        let offlineError = OneLakeError.httpError(
            HTTPClientError.transport(URLError(.notConnectedToInternet))
        )
        ol.listPathResults.append(.failure(offlineError))

        // Even though the remote call fails, no cached rows are deleted.
        _ = await engine.refreshMaterialized(
            alias: Self.alias,
            keys: [key],
            concurrencyCap: 1
        )

        let cached = try await store.children(of: key)
        #expect(Set(cached.map(\.name)) == ["a.txt", "b.txt"])
    }

    // MARK: - AC2: concurrency cap is honoured

    @Test("refreshMaterialized honours the concurrency cap")
    func concurrencyCapHonoured() async throws {
        let ol = BlockingListMockOneLakeClient()
        let (engine, store) = try makeEngine(onelake: ol)
        defer { try? FileManager.default.removeItem(at: store.root) }

        // Three containers; cap = 2 → at most 2 listPath calls in flight at once.
        let keys = (1 ... 3).map { i in
            CacheKey(accountAlias: Self.alias, workspaceID: Self.wsID,
                     itemID: "item-\(i)", path: "")
        }
        for key in keys {
            try await seedFolder(in: store, key: key, children: [])
        }

        // Run refreshMaterialized concurrently; it will block inside listPath.
        var iter = ol.listEntered.makeAsyncIterator()

        let refreshTask = Task {
            await engine.refreshMaterialized(
                alias: Self.alias, keys: keys, concurrencyCap: 2
            )
        }

        // Wait for the first two listPath calls to enter (cap = 2).
        _ = await iter.next()
        _ = await iter.next()

        // At this point exactly 2 calls should be in flight. The third should be
        // queued behind the semaphore. Resolve the first two.
        ol.unblock(with: ListResult(entries: []))
        ol.unblock(with: ListResult(entries: []))

        // Now the third can proceed.
        _ = await iter.next()
        ol.unblock(with: ListResult(entries: []))

        _ = await refreshTask.value
        #expect(ol.listPathCallCount == 3)
    }

    // MARK: - AC2: empty keys list returns false

    @Test("refreshMaterialized with an empty key list returns false immediately")
    func emptyKeysReturnsFalse() async throws {
        let ol = MockOneLakeClient()
        let (engine, store) = try makeEngine(onelake: ol)
        defer { try? FileManager.default.removeItem(at: store.root) }

        let changed = await engine.refreshMaterialized(
            alias: Self.alias, keys: [], concurrencyCap: 4
        )
        #expect(changed == false)
        #expect(ol.listPathCalls.isEmpty)
    }

    // MARK: - Regression: phantom directory delta (#358)

    /// Regression test for the ADLS Gen2 directory-lastModified phantom delta.
    ///
    /// ADLS Gen2 advances a directory's `lastModified` whenever any descendant
    /// is written (e.g. a Delta table commit). Because directories carry an empty
    /// etag and zero contentLength, `lastModifiedNs` was the only differing field
    /// — causing `entryChanged` to return `true` on every poll even when the
    /// directory's own child listing was unchanged. This produced a phantom
    /// `diff.updated > 0`, which signalled `.workingSet` every cycle.
    ///
    /// After the fix: directory entries compare only `isDir`, `contentLength`,
    /// `etag`, `name`, `parentPath`, and `itemType`; `lastModifiedNs` is skipped.
    @Test("Directory with advanced lastModified but unchanged listing yields diff.updated == 0 and no syncedAt bump")
    func directoryAdvancedLastModifiedYieldsNoDiff() async throws {
        let ol = MockOneLakeClient()
        let (engine, store) = try makeEngine(onelake: ol)
        defer { try? FileManager.default.removeItem(at: store.root) }

        let key = Self.folderKey
        let t0 = Date(timeIntervalSince1970: 1_000_000)

        // Seed a directory child with a known lastModified (T0).
        let childPath = "delta_table"
        let seededDir = MetadataRecord(
            accountAlias: key.accountAlias,
            workspaceID: key.workspaceID,
            itemID: key.itemID,
            path: childPath,
            parentPath: key.path,
            name: "delta_table",
            isDir: true,
            contentLength: 0,
            etag: "",
            lastModifiedNs: Int64(t0.timeIntervalSince1970 * 1_000_000_000)
        )
        // Seed the parent so refreshFolder can stamp it.
        let syncedNs = Int64(Date().addingTimeInterval(-60).timeIntervalSince1970 * 1_000_000_000)
        let parent = MetadataRecord(
            accountAlias: key.accountAlias,
            workspaceID: key.workspaceID,
            itemID: key.itemID,
            path: key.path,
            parentPath: "",
            name: "",
            isDir: true,
            childrenSyncedAtNs: syncedNs
        )
        try await store.upsert(parent)
        try await store.upsert(seededDir)

        let childKey = CacheKey(
            accountAlias: key.accountAlias,
            workspaceID: key.workspaceID,
            itemID: key.itemID,
            path: childPath
        )
        let rowBefore = try await store.fetch(key: childKey)
        let syncedBefore = rowBefore.syncedAtNs

        // Remote returns the SAME directory but with a LATER lastModified (T0 + 1 hour),
        // simulating a descendant write (Delta table commit). Child listing is unchanged.
        let t1 = t0.addingTimeInterval(3600)
        ol.listPathResults.append(.success(ListResult(entries: [
            PathEntry.directory(name: "delta_table", lastModified: t1),
        ])))

        let diff = try await engine.refreshMaterializedContainer(key: key)

        // No phantom update: the advanced directory lastModified must not count as a change.
        #expect(diff.updated == 0)
        #expect(diff.added == 0)
        #expect(diff.removed == 0)

        // syncedAtNs must NOT be bumped for the unchanged directory child.
        let rowAfter = try await store.fetch(key: childKey)
        #expect(rowAfter.syncedAtNs == syncedBefore,
                "syncedAtNs must not advance for an unchanged directory entry")
    }

    // MARK: - Regression: unchanged file does not bump syncedAtNs (#358)

    /// Companion to the phantom-dir test: verifies that an unchanged FILE also
    /// does not get its `syncedAtNs` bumped (conditional upsert is in effect).
    @Test("Unchanged file does not bump syncedAtNs")
    func unchangedFileDoesNotBumpSyncedAt() async throws {
        let ol = MockOneLakeClient()
        let (engine, store) = try makeEngine(onelake: ol)
        defer { try? FileManager.default.removeItem(at: store.root) }

        let key = Self.folderKey
        // seedFolder seeds with contentLength: 0 and etag from the name tuple.
        try await seedFolder(in: store, key: key, children: [("report.csv", "etag-stable")])

        let childKey = CacheKey(
            accountAlias: key.accountAlias,
            workspaceID: key.workspaceID,
            itemID: key.itemID,
            path: "report.csv"
        )
        let rowBefore = try await store.fetch(key: childKey)
        let syncedBefore = rowBefore.syncedAtNs

        // Remote identical: size matches seeded contentLength (0), etag unchanged.
        ol.listPathResults.append(.success(ListResult(entries: [
            PathEntry.file(name: "report.csv", size: 0, eTag: "etag-stable"),
        ])))

        let diff = try await engine.refreshMaterializedContainer(key: key)
        #expect(diff.updated == 0)
        #expect(diff.added == 0)

        let rowAfter = try await store.fetch(key: childKey)
        #expect(rowAfter.syncedAtNs == syncedBefore,
                "syncedAtNs must not advance for an unchanged file entry")
    }

    // MARK: - Regression: child add/remove still detected even with unchanged sibling dirs (#358)

    /// Verifies that when a directory sibling is present unchanged (and therefore
    /// not upserted), new file additions and removals in the same folder are still
    /// correctly detected via the tombstone reconcile.
    @Test("Child added or removed is detected when sibling directory is unchanged")
    func childAddRemoveDetectedAlongsideUnchangedDir() async throws {
        let ol = MockOneLakeClient()
        let (engine, store) = try makeEngine(onelake: ol)
        defer { try? FileManager.default.removeItem(at: store.root) }

        let key = Self.folderKey
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        let syncedNs = Int64(Date().addingTimeInterval(-60).timeIntervalSince1970 * 1_000_000_000)

        // Seed: parent + one unchanged directory + one file that will be removed.
        let parentRow = MetadataRecord(
            accountAlias: key.accountAlias,
            workspaceID: key.workspaceID,
            itemID: key.itemID,
            path: key.path,
            parentPath: "",
            name: "",
            isDir: true,
            childrenSyncedAtNs: syncedNs
        )
        let dirRow = MetadataRecord(
            accountAlias: key.accountAlias,
            workspaceID: key.workspaceID,
            itemID: key.itemID,
            path: "subdir",
            parentPath: key.path,
            name: "subdir",
            isDir: true,
            contentLength: 0,
            etag: "",
            lastModifiedNs: Int64(t0.timeIntervalSince1970 * 1_000_000_000)
        )
        let goneRow = MetadataRecord(
            accountAlias: key.accountAlias,
            workspaceID: key.workspaceID,
            itemID: key.itemID,
            path: "gone.txt",
            parentPath: key.path,
            name: "gone.txt",
            isDir: false,
            contentLength: 0,
            etag: "e-gone"
        )
        try await store.upsert(parentRow)
        try await store.upsert(dirRow)
        try await store.upsert(goneRow)

        // Remote: subdir still present (same shape), gone.txt removed, new.txt added.
        let t1 = t0.addingTimeInterval(3600)
        ol.listPathResults.append(.success(ListResult(entries: [
            PathEntry.directory(name: "subdir", lastModified: t1), // lastModified advanced, content unchanged
            PathEntry.file(name: "new.txt", size: 0, eTag: "e-new"),
        ])))

        let diff = try await engine.refreshMaterializedContainer(key: key)

        // new.txt was added, gone.txt was removed; subdir is unchanged.
        #expect(diff.added == 1)
        #expect(diff.removed == 1)
        #expect(diff.updated == 0)

        // gone.txt must be absent from the cache.
        let goneKey = CacheKey(
            accountAlias: key.accountAlias,
            workspaceID: key.workspaceID,
            itemID: key.itemID,
            path: "gone.txt"
        )
        #expect((try? await store.fetch(key: goneKey)) == nil)

        // subdir must still be in the cache (not tombstoned despite not being upserted).
        let subdirKey = CacheKey(
            accountAlias: key.accountAlias,
            workspaceID: key.workspaceID,
            itemID: key.itemID,
            path: "subdir"
        )
        #expect((try? await store.fetch(key: subdirKey)) != nil)
    }

    // MARK: - fpe-18: no-change poll must not re-stamp the parent row

    @Test("No-change poll does not bump parent syncedAtNs (stops phantom working-set deltas)")
    func noChangePollDoesNotBumpParentSyncedAtNs() async throws {
        let ol = MockOneLakeClient()
        let (engine, store) = try makeEngine(onelake: ol)
        defer { try? FileManager.default.removeItem(at: store.root) }

        let key = Self.folderKey
        try await seedFolder(in: store, key: key, children: [("a.txt", "v1")])

        // Record the parent row's syncedAtNs before any refresh.
        let parentBefore = try await store.fetch(key: key)
        let syncedBefore = parentBefore.syncedAtNs

        // Two polls with an identical remote listing → diff.total == 0 both times.
        for _ in 0 ..< 2 {
            ol.listPathResults.append(.success(ListResult(entries: [
                PathEntry.file(name: "a.txt", size: 0, eTag: "v1"),
            ])))
        }

        _ = try await engine.refreshMaterializedContainer(key: key)
        _ = try await engine.refreshMaterializedContainer(key: key)

        // The parent row must not have been bumped.
        let parentAfter = try await store.fetch(key: key)
        #expect(parentAfter.syncedAtNs == syncedBefore)
    }

    @Test("First-sight refresh creates the parent row with correct childrenSyncedAtNs")
    func firstSightRefreshCreatesParentRow() async throws {
        let ol = MockOneLakeClient()
        let (engine, store) = try makeEngine(onelake: ol)
        defer { try? FileManager.default.removeItem(at: store.root) }

        // No prior cache for this key — the parent row does not exist.
        let key = Self.folderKey
        ol.listPathResults.append(.success(ListResult(entries: [
            PathEntry.file(name: "a.txt", size: 0, eTag: "v1"),
        ])))

        _ = try await engine.refreshMaterializedContainer(key: key)

        // The parent row must now exist and have a positive childrenSyncedAtNs.
        let parent = try await store.fetch(key: key)
        #expect(parent.childrenSyncedAtNs > 0)
    }

    @Test("No-change poll does not bump parent syncedAtNs (item-root key)")
    func itemRootParentNotRestampedOnNoChangePoll() async throws {
        let ol = MockOneLakeClient()
        let (engine, store) = try makeEngine(onelake: ol)
        defer { try? FileManager.default.removeItem(at: store.root) }

        // path == "" (item-root container): this is the exact key that used to
        // trigger the crash-loop — every poll stamped a row with name == "" (fpe-18).
        let key = Self.folderKey
        try await seedFolder(in: store, key: key, children: [("report.csv", "e1")])

        let parentBefore = try await store.fetch(key: key)
        let nsBefore = try await store.maxSyncedAtNs(accountAlias: key.accountAlias)

        // Two polls with an identical remote listing → diff.total == 0 both times.
        for _ in 0 ..< 2 {
            ol.listPathResults.append(.success(ListResult(entries: [
                PathEntry.file(name: "report.csv", size: 0, eTag: "e1"),
            ])))
        }

        _ = try await engine.refreshMaterializedContainer(key: key)
        _ = try await engine.refreshMaterializedContainer(key: key)

        // The parent row must not have been re-stamped (syncedAtNs unchanged).
        let parentAfter = try await store.fetch(key: key)
        #expect(parentAfter.syncedAtNs == parentBefore.syncedAtNs)

        // maxSyncedAtNs must not have advanced (no row was upserted).
        let nsAfter = try await store.maxSyncedAtNs(accountAlias: key.accountAlias)
        #expect(nsAfter == nsBefore)
    }

    @Test("Item-root first-sight refresh writes a non-empty name (never empty-filename landmine)")
    func itemRootFirstSightWritesNonEmptyName() async throws {
        let ol = MockOneLakeClient()
        let (engine, store) = try makeEngine(onelake: ol)
        defer { try? FileManager.default.removeItem(at: store.root) }

        // path == "" — no prior row, so needsWrite == true on first sight.
        let key = Self.folderKey
        ol.listPathResults.append(.success(ListResult(entries: [
            PathEntry.file(name: "a.txt", size: 0, eTag: "v1"),
        ])))

        _ = try await engine.refreshMaterializedContainer(key: key)

        // The parent row must exist AND have a non-empty name so it can never be
        // emitted as a delta item with filename == "" (fpe-18).
        let parent = try await store.fetch(key: key)
        #expect(!parent.name.isEmpty)
        #expect(parent.childrenSyncedAtNs > 0)
    }
}
