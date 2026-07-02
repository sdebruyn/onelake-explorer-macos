import Foundation
@testable import OfemKit
import Testing

// MARK: - refreshFolder pure-phase tests

/// Unit tests for the pure static phases extracted from
/// ``SyncEngine/refreshFolder(key:)``: ``SyncEngine/buildUpsertBatch`` (the
/// conditional-upsert core) and ``SyncEngine/buildDeleteBatch`` (the
/// vanished-child reconcile). These exercise the reconcile logic directly,
/// without a cache or network, and pin the invariants the orchestrator relies
/// on — most importantly that unchanged-but-present children are never bumped
/// and never tombstoned.
struct SyncEngineRefreshFolderPhasesTests {
    // MARK: - Constants

    private static let key = CacheKey(accountAlias: "acct", workspaceID: "ws-1", itemID: "item-1", path: "Files")
    private static let itemType = "Lakehouse"
    private static let nowNs: Int64 = 5_000_000_000

    /// A cached file row that exactly matches `fileEntry(...)` under `itemType`,
    /// i.e. one for which `entryChanged` reports no change.
    private static func cachedFile(
        path: String,
        etag: String = "e1",
        contentLength: Int64 = 100,
        lastModifiedNs: Int64 = 1_000_000_000_000,
        itemType: String = itemType,
        blobSHA256: String = "",
        blobSize: Int64 = 0,
        contentType: String = "",
        createdNs: Int64 = 0,
        lastAccessedNs: Int64 = 42,
        childrenSyncedAtNs: Int64 = 0
    ) -> MetadataRecord {
        MetadataRecord(
            accountAlias: key.accountAlias,
            workspaceID: key.workspaceID,
            itemID: key.itemID,
            path: path,
            parentPath: key.path,
            name: Enumerator.baseName(path),
            isDir: false,
            contentLength: contentLength,
            etag: etag,
            lastModifiedNs: lastModifiedNs,
            contentType: contentType,
            blobSHA256: blobSHA256,
            blobSize: blobSize,
            lastAccessedNs: lastAccessedNs,
            syncedAtNs: 1,
            childrenSyncedAtNs: childrenSyncedAtNs,
            itemType: itemType,
            createdNs: createdNs
        )
    }

    /// A file ``PathEntry`` whose defaults match `cachedFile(...)` (lastModified
    /// 1000 s → 1_000_000_000_000 ns, no creation date).
    private static func fileEntry(
        name: String,
        etag: String = "e1",
        size: Int64 = 100,
        lastModified: Date = Date(timeIntervalSince1970: 1000)
    ) -> PathEntry {
        PathEntry(name: name, isDirectory: false, contentLength: size, eTag: etag, lastModified: lastModified)
    }

    /// A directory ``PathEntry`` carrying a real etag (the value harvested as the
    /// #380 subtree token); `PathEntry.directory` forces `eTag: ""`.
    private static func dirEntry(name: String, etag: String) -> PathEntry {
        PathEntry(name: name, isDirectory: true, contentLength: 0, eTag: etag, lastModified: Date(timeIntervalSince1970: 0))
    }

    // MARK: - buildUpsertBatch: new entries

    @Test func buildUpsertBatchCountsNewFile() throws {
        let entry = Self.fileEntry(name: "Files/a.txt")
        let (batch, added, updated) = SyncEngine.buildUpsertBatch(
            key: Self.key,
            remoteChildren: ["Files/a.txt": entry],
            cachedByPath: [:],
            folderItemType: Self.itemType,
            nowNs: Self.nowNs
        )
        #expect(added == 1)
        #expect(updated == 0)
        #expect(batch.count == 1)
        let row = try #require(batch.first)
        #expect(row.path == "Files/a.txt")
        #expect(row.name == "a.txt")
        #expect(row.parentPath == "Files")
        #expect(row.isDir == false)
        #expect(row.contentLength == 100)
        #expect(row.etag == "e1")
        #expect(row.itemType == Self.itemType)
        #expect(row.syncedAtNs == Self.nowNs)
        // A new row with no cached predecessor takes nowNs for lastAccessedNs.
        #expect(row.lastAccessedNs == Self.nowNs)
        // A file carries no subtree token.
        #expect(row.subtreeEtag == "")
    }

    @Test func buildUpsertBatchNewDirectoryCarriesSubtreeEtag() throws {
        let entry = Self.dirEntry(name: "Files/sub", etag: "dir-etag-1")
        let (batch, added, _) = SyncEngine.buildUpsertBatch(
            key: Self.key,
            remoteChildren: ["Files/sub": entry],
            cachedByPath: [:],
            folderItemType: Self.itemType,
            nowNs: Self.nowNs
        )
        #expect(added == 1)
        let row = try #require(batch.first)
        #expect(row.isDir == true)
        // #380: a directory child's own etag is harvested onto its row as the
        // subtree skip-gate token.
        #expect(row.subtreeEtag == "dir-etag-1")
    }

    // MARK: - buildUpsertBatch: unchanged entries are dropped

    @Test func buildUpsertBatchDropsUnchangedFile() {
        // A cached file that matches the remote entry exactly must NOT be
        // rewritten — bumping its syncedAtNs on every poll is the phantom-delta
        // regression this conditional upsert prevents.
        let entry = Self.fileEntry(name: "Files/a.txt")
        let cached = Self.cachedFile(path: "Files/a.txt")
        let (batch, added, updated) = SyncEngine.buildUpsertBatch(
            key: Self.key,
            remoteChildren: ["Files/a.txt": entry],
            cachedByPath: ["Files/a.txt": cached],
            folderItemType: Self.itemType,
            nowNs: Self.nowNs
        )
        #expect(added == 0)
        #expect(updated == 0)
        #expect(batch.isEmpty)
    }

    // MARK: - buildUpsertBatch: changed entries

    @Test func buildUpsertBatchCountsChangedFileByEtag() {
        let entry = Self.fileEntry(name: "Files/a.txt", etag: "e2")
        let cached = Self.cachedFile(path: "Files/a.txt", etag: "e1")
        let (batch, added, updated) = SyncEngine.buildUpsertBatch(
            key: Self.key,
            remoteChildren: ["Files/a.txt": entry],
            cachedByPath: ["Files/a.txt": cached],
            folderItemType: Self.itemType,
            nowNs: Self.nowNs
        )
        #expect(added == 0)
        #expect(updated == 1)
        #expect(batch.count == 1)
        #expect(batch.first?.etag == "e2")
    }

    @Test func buildUpsertBatchCarriesBlobLinkageWhenEtagMatches() throws {
        // etag matches (so the blob linkage is carried) but itemType differs, so
        // the row is still classified as changed and appears in the batch where
        // the carried fields are observable.
        let entry = Self.fileEntry(name: "Files/a.txt", etag: "e1")
        let cached = Self.cachedFile(
            path: "Files/a.txt",
            etag: "e1",
            itemType: "StaleType",
            blobSHA256: "deadbeef",
            blobSize: 4096,
            contentType: "text/csv"
        )
        let (batch, _, updated) = SyncEngine.buildUpsertBatch(
            key: Self.key,
            remoteChildren: ["Files/a.txt": entry],
            cachedByPath: ["Files/a.txt": cached],
            folderItemType: Self.itemType,
            nowNs: Self.nowNs
        )
        #expect(updated == 1)
        let row = try #require(batch.first)
        #expect(row.blobSHA256 == "deadbeef")
        #expect(row.blobSize == 4096)
        #expect(row.contentType == "text/csv")
        // The row still adopts the fresh folder item type.
        #expect(row.itemType == Self.itemType)
    }

    @Test func buildUpsertBatchDropsBlobLinkageWhenEtagDiffers() throws {
        let entry = Self.fileEntry(name: "Files/a.txt", etag: "e2")
        let cached = Self.cachedFile(
            path: "Files/a.txt",
            etag: "e1",
            blobSHA256: "deadbeef",
            blobSize: 4096,
            contentType: "text/csv"
        )
        let (batch, _, updated) = SyncEngine.buildUpsertBatch(
            key: Self.key,
            remoteChildren: ["Files/a.txt": entry],
            cachedByPath: ["Files/a.txt": cached],
            folderItemType: Self.itemType,
            nowNs: Self.nowNs
        )
        #expect(updated == 1)
        let row = try #require(batch.first)
        // A changed etag means the cached blob no longer describes the remote
        // bytes, so the linkage is not carried forward.
        #expect(row.blobSHA256 == "")
        #expect(row.blobSize == 0)
        #expect(row.contentType == "")
    }

    @Test func buildUpsertBatchCarriesForwardCachedTimestamps() throws {
        // A changed row must preserve the cached lastAccessedNs / childrenSyncedAtNs
        // rather than resetting them.
        let entry = Self.fileEntry(name: "Files/a.txt", etag: "e2")
        let cached = Self.cachedFile(
            path: "Files/a.txt",
            etag: "e1",
            lastAccessedNs: 777,
            childrenSyncedAtNs: 888
        )
        let (batch, _, _) = SyncEngine.buildUpsertBatch(
            key: Self.key,
            remoteChildren: ["Files/a.txt": entry],
            cachedByPath: ["Files/a.txt": cached],
            folderItemType: Self.itemType,
            nowNs: Self.nowNs
        )
        let row = try #require(batch.first)
        #expect(row.lastAccessedNs == 777)
        #expect(row.childrenSyncedAtNs == 888)
    }

    @Test func buildUpsertBatchMixedSetCounts() {
        let remote: [String: PathEntry] = [
            "Files/new.txt": Self.fileEntry(name: "Files/new.txt"),
            "Files/changed.txt": Self.fileEntry(name: "Files/changed.txt", etag: "e2"),
            "Files/same.txt": Self.fileEntry(name: "Files/same.txt"),
        ]
        let cached: [String: MetadataRecord] = [
            "Files/changed.txt": Self.cachedFile(path: "Files/changed.txt", etag: "e1"),
            "Files/same.txt": Self.cachedFile(path: "Files/same.txt"),
        ]
        let (batch, added, updated) = SyncEngine.buildUpsertBatch(
            key: Self.key,
            remoteChildren: remote,
            cachedByPath: cached,
            folderItemType: Self.itemType,
            nowNs: Self.nowNs
        )
        #expect(added == 1)
        #expect(updated == 1)
        #expect(batch.count == 2)
        #expect(Set(batch.map(\.path)) == ["Files/new.txt", "Files/changed.txt"])
    }

    // MARK: - buildUpsertBatch: createdNs handling

    @Test func buildUpsertBatchCarriesForwardCachedCreatedNs() throws {
        // DFS listings never return a creationDate, so entry.creationDate is nil.
        // A changed row must PRESERVE the cached createdNs (the creation time
        // captured earlier via HEAD/GET, #371), not reset it to 0. This is a
        // regression guard: if the pure static's `dateToNs` were to bind to the
        // global `(Date?) -> Int64` overload (which folds nil to 0) instead of the
        // nil-preserving `(Date?) -> Int64?`, the `?? cur?.createdNs` fallback
        // would be short-circuited and createdNs would come back as 0.
        let entry = Self.fileEntry(name: "Files/a.txt", etag: "e2")
        #expect(entry.creationDate == nil, "precondition: DFS entries carry no creationDate")
        let cached = Self.cachedFile(path: "Files/a.txt", etag: "e1", createdNs: 987_654_321)
        let (batch, _, updated) = SyncEngine.buildUpsertBatch(
            key: Self.key,
            remoteChildren: ["Files/a.txt": entry],
            cachedByPath: ["Files/a.txt": cached],
            folderItemType: Self.itemType,
            nowNs: Self.nowNs
        )
        #expect(updated == 1)
        let row = try #require(batch.first)
        #expect(row.createdNs == 987_654_321)
    }

    @Test func buildUpsertBatchNewRowWithoutCreatedNsIsZero() throws {
        // No cached predecessor and a nil creationDate → createdNs is the 0
        // "unset" sentinel (nil falls through to `?? 0`).
        let entry = Self.fileEntry(name: "Files/new.txt")
        let (batch, _, _) = SyncEngine.buildUpsertBatch(
            key: Self.key,
            remoteChildren: ["Files/new.txt": entry],
            cachedByPath: [:],
            folderItemType: Self.itemType,
            nowNs: Self.nowNs
        )
        let row = try #require(batch.first)
        #expect(row.createdNs == 0)
    }

    @Test func buildUpsertBatchClampsOutOfRangeLastModified() throws {
        // A hostile / out-of-range remote timestamp must clamp to 0 rather than
        // trapping in Int64(_:) — buildUpsertBatch feeds attacker-influenced DFS
        // timestamps, so it must tolerate one far beyond Int64 nanoseconds.
        let entry = Self.fileEntry(name: "Files/a.txt", lastModified: Date(timeIntervalSince1970: 1e30))
        let (batch, added, _) = SyncEngine.buildUpsertBatch(
            key: Self.key,
            remoteChildren: ["Files/a.txt": entry],
            cachedByPath: [:],
            folderItemType: Self.itemType,
            nowNs: Self.nowNs
        )
        #expect(added == 1)
        let row = try #require(batch.first)
        #expect(row.lastModifiedNs == 0)
    }

    // MARK: - buildDeleteBatch

    @Test func buildDeleteBatchTombstonesVanishedChild() throws {
        let cached: [String: MetadataRecord] = [
            "Files/gone.txt": Self.cachedFile(path: "Files/gone.txt"),
        ]
        let deletes = SyncEngine.buildDeleteBatch(
            key: Self.key,
            remoteChildren: [:],
            cachedByPath: cached
        )
        #expect(deletes.count == 1)
        let k = try #require(deletes.first)
        #expect(k.accountAlias == Self.key.accountAlias)
        #expect(k.workspaceID == Self.key.workspaceID)
        #expect(k.itemID == Self.key.itemID)
        #expect(k.path == "Files/gone.txt")
    }

    @Test func buildDeleteBatchKeepsRemotePresentChild() {
        // The F1 trap: a child that is present remotely but UNCHANGED (and thus
        // absent from any upsert batch) must never be tombstoned. buildDeleteBatch
        // references the full remote listing, so a remote-present path is kept.
        let cached: [String: MetadataRecord] = [
            "Files/keep.txt": Self.cachedFile(path: "Files/keep.txt"),
        ]
        let remote: [String: PathEntry] = [
            "Files/keep.txt": Self.fileEntry(name: "Files/keep.txt"),
        ]
        let deletes = SyncEngine.buildDeleteBatch(
            key: Self.key,
            remoteChildren: remote,
            cachedByPath: cached
        )
        #expect(deletes.isEmpty)
    }

    @Test func buildDeleteBatchDeletesOnlyTheVanishedSubset() {
        let cached: [String: MetadataRecord] = [
            "Files/keep.txt": Self.cachedFile(path: "Files/keep.txt"),
            "Files/gone1.txt": Self.cachedFile(path: "Files/gone1.txt"),
            "Files/gone2.txt": Self.cachedFile(path: "Files/gone2.txt"),
        ]
        let remote: [String: PathEntry] = [
            "Files/keep.txt": Self.fileEntry(name: "Files/keep.txt"),
        ]
        let deletes = SyncEngine.buildDeleteBatch(
            key: Self.key,
            remoteChildren: remote,
            cachedByPath: cached
        )
        #expect(Set(deletes.map(\.path)) == ["Files/gone1.txt", "Files/gone2.txt"])
    }

    @Test func buildDeleteBatchEmptyWhenNoCachedChildren() {
        let deletes = SyncEngine.buildDeleteBatch(
            key: Self.key,
            remoteChildren: ["Files/a.txt": Self.fileEntry(name: "Files/a.txt")],
            cachedByPath: [:]
        )
        #expect(deletes.isEmpty)
    }
}
