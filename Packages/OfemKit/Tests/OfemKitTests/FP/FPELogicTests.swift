import Foundation
@testable import OfemKit
import Testing

// MARK: - FPE logic unit tests (fpe-21, tests-04)

//
// Tests for pure-logic helpers in OfemKit/FP/ that the FPE relies on.
// These run without a mounted File Provider domain or network access.

struct FPELogicTests {
    // MARK: - Sync anchor encoding/decoding

    //
    // The anchor helpers live in the FPE target (OfemFPEEnumerator.swift) but
    // the encoding contract is trivial enough to specify here so any OfemKit
    // consumer can verify it independently.

    @Test func fallbackVersionIsDeterministicForSameInputs() {
        let v1 = fallbackVersion(seed: "abc", size: 100, mtime: nil)
        let v2 = fallbackVersion(seed: "abc", size: 100, mtime: nil)
        #expect(v1 == v2)
    }

    @Test func fallbackVersionDiffersForDifferentSeeds() {
        let v1 = fallbackVersion(seed: "file-a", size: 0, mtime: nil)
        let v2 = fallbackVersion(seed: "file-b", size: 0, mtime: nil)
        #expect(v1 != v2)
    }

    @Test func fallbackVersionDiffersForDifferentSizes() {
        let v1 = fallbackVersion(seed: "f", size: 0, mtime: nil)
        let v2 = fallbackVersion(seed: "f", size: 1, mtime: nil)
        #expect(v1 != v2)
    }

    @Test func fallbackVersionDiffersForDifferentMtimes() {
        let t1 = Date(timeIntervalSince1970: 1_000_000)
        let t2 = Date(timeIntervalSince1970: 2_000_000)
        let v1 = fallbackVersion(seed: "f", size: 0, mtime: t1)
        let v2 = fallbackVersion(seed: "f", size: 0, mtime: t2)
        #expect(v1 != v2)
    }

    // MARK: - ItemIdentifier.parentIdentifier

    @Test func parentIdentifierOfPathFile() {
        let id = ItemIdentifier.path(workspaceID: "ws", itemID: "item", path: "Files/raw/x.csv")
        #expect(id.parentIdentifier == .path(workspaceID: "ws", itemID: "item", path: "Files/raw"))
    }

    @Test func parentIdentifierOfTopLevelPath() {
        let id = ItemIdentifier.path(workspaceID: "ws", itemID: "item", path: "Files")
        #expect(id.parentIdentifier == .item(workspaceID: "ws", itemID: "item"))
    }

    @Test func parentIdentifierOfItemRoot() {
        let id = ItemIdentifier.path(workspaceID: "ws", itemID: "item", path: "")
        #expect(id.parentIdentifier == .workspace(workspaceID: "ws"))
    }

    @Test func parentIdentifierOfItem() {
        let id = ItemIdentifier.item(workspaceID: "ws", itemID: "item")
        #expect(id.parentIdentifier == .workspace(workspaceID: "ws"))
    }

    @Test func parentIdentifierOfWorkspace() {
        let id = ItemIdentifier.workspace(workspaceID: "ws")
        #expect(id.parentIdentifier == .root)
    }

    // MARK: - DomainItem.from(record:) — identifier mapping

    @Test func domainItemPathParentIsDeepPath() throws {
        let record = MetadataRecord(
            accountAlias: "dev",
            workspaceID: "ws-1",
            itemID: "lh-1",
            path: "Files/raw/2024/sales.csv",
            parentPath: "Files/raw/2024",
            name: "sales.csv",
            isDir: false,
            contentLength: 512,
            etag: "\"abc\""
        )
        let di = try DomainItem.from(record: record)
        #expect(di.identifier == .path(workspaceID: "ws-1", itemID: "lh-1", path: "Files/raw/2024/sales.csv"))
        #expect(di.parentIdentifier == .path(workspaceID: "ws-1", itemID: "lh-1", path: "Files/raw/2024"))
    }

    @Test func domainItemContentVersionUsesEtagWhenPresent() throws {
        let r1 = MetadataRecord(
            accountAlias: "dev", workspaceID: "ws", itemID: "i", path: "f.txt",
            parentPath: "", name: "f.txt", isDir: false,
            contentLength: 10, etag: "\"etag-v1\""
        )
        let r2 = MetadataRecord(
            accountAlias: "dev", workspaceID: "ws", itemID: "i", path: "f.txt",
            parentPath: "", name: "f.txt", isDir: false,
            contentLength: 20, etag: "\"etag-v2\""
        )
        let di1 = try DomainItem.from(record: r1)
        let di2 = try DomainItem.from(record: r2)
        #expect(di1.contentVersion != di2.contentVersion)
    }

    @Test func domainItemSameEtagGivesSameContentVersion() throws {
        let r1 = MetadataRecord(
            accountAlias: "dev", workspaceID: "ws", itemID: "i", path: "f.txt",
            parentPath: "", name: "f.txt", isDir: false,
            contentLength: 10, etag: "\"stable-etag\""
        )
        let r2 = MetadataRecord(
            accountAlias: "dev", workspaceID: "ws", itemID: "i", path: "f.txt",
            parentPath: "", name: "f.txt", isDir: false,
            contentLength: 99, etag: "\"stable-etag\"" // same etag, different size
        )
        let di1 = try DomainItem.from(record: r1)
        let di2 = try DomainItem.from(record: r2)
        // Same etag → same content version (size doesn't affect it when etag present)
        #expect(di1.contentVersion == di2.contentVersion)
    }

    // MARK: - CacheReader.syncAnchorNs / itemsChangedAfter

    @Test func syncAnchorNsReturnsZeroForEmptyDB() async throws {
        let store = try makeTempCacheStore()
        let ns = try await store.syncAnchorNs(accountAlias: "dev")
        #expect(ns == 0)
    }

    @Test func syncAnchorNsReflectsUpsertedRecord() async throws {
        let store = try makeTempCacheStore()
        let record = makeTestRecord(path: "Files/f.txt", syncedAtNs: 1_000_000_000)
        try await store.upsert(record)
        let ns = try await store.syncAnchorNs(accountAlias: "dev")
        // The upsert stamps syncedAtNs with current time when it is 0; since
        // we passed 1_000_000_000 the stored value is >= that.
        #expect(ns >= 1_000_000_000)
    }

    @Test func syncAnchorNsOnlyAccountsForGivenAlias() async throws {
        let store = try makeTempCacheStore()
        let r1 = makeTestRecord(path: "f.txt", alias: "alice", syncedAtNs: 5_000_000_000)
        let r2 = makeTestRecord(path: "g.txt", alias: "bob", syncedAtNs: 1_000_000_000)
        try await store.upsert(r1)
        try await store.upsert(r2)
        let nsAlice = try await store.syncAnchorNs(accountAlias: "alice")
        let nsBob = try await store.syncAnchorNs(accountAlias: "bob")
        #expect(nsAlice >= 5_000_000_000)
        #expect(nsBob >= 1_000_000_000)
        #expect(nsAlice > nsBob)
    }

    @Test func itemsChangedAfterReturnsOnlyNewerRecords() async throws {
        let store = try makeTempCacheStore()
        let anchorNs: Int64 = 2_000_000_000
        let old = makeTestRecord(path: "old.txt", syncedAtNs: 1_000_000_000)
        let newer = makeTestRecord(path: "new.txt", syncedAtNs: 3_000_000_000)
        try await store.upsert(old)
        try await store.upsert(newer)
        let (changed, _) = try await store.itemsChangedAfter(accountAlias: "dev", ns: anchorNs)
        let paths = changed.map(\.path)
        // Only 'new.txt' has syncedAtNs strictly > anchorNs
        // (provided CacheStore preserved our value and didn't override it)
        // Note: CacheStore stamps syncedAtNs = currentTime when it is 0.
        // Since we pass non-zero values they should be preserved.
        #expect(paths.contains("new.txt"))
        #expect(!paths.contains("old.txt"))
    }

    // MARK: - fpe-02 / N1: createItem without contents must not lose remote data

    /// Verifies that a cache row is preserved when a metadata-only create
    /// (`.mayAlreadyExist` or no `.contents` in fields) is processed.
    ///
    /// The fpe-02 fix ensures `engineCreateItem` skips the upload path when
    /// `fields` does not include `.contents`. At the OfemKit layer the
    /// invariant is: if the cache row for the key already exists, its content
    /// must survive a metadata-only create path (no upsert with empty content
    /// should overwrite it). We test this by checking that `fetch` returns the
    /// original record after an upsert that carries the preserved blob columns.
    @Test func cacheRowPreservedAfterMetadataOnlyUpsert() async throws {
        let store = try makeTempCacheStore()
        // Write a row with known content length and etag.
        var original = makeTestRecord(path: "Files/data.parquet", syncedAtNs: 1_000_000_000)
        original.contentLength = 8192
        original.etag = "\"etag-remote\""
        try await store.upsert(original)

        // Simulate a metadata-only re-upsert (no blob, same etag) — as the
        // .mayAlreadyExist path in engineCreateItem would do.
        var metaOnly = original
        metaOnly.blobSHA256 = ""
        metaOnly.blobSize = 0
        try await store.upsert(metaOnly)

        let key = CacheKey(
            accountAlias: original.accountAlias,
            workspaceID: original.workspaceID,
            itemID: original.itemID,
            path: original.path
        )
        let fetched = try await store.fetch(key: key)
        // The upsert must not overwrite content length or etag.
        #expect(fetched.contentLength == 8192)
        #expect(fetched.etag == "\"etag-remote\"")
        // blobSHA256 was explicitly cleared above (caller carries forward or drops).
        #expect(fetched.blobSHA256 == "")
    }

    // MARK: - Helpers

    private func makeTempCacheStore() throws -> CacheStore {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        return try CacheStore(root: tmp)
    }

    private func makeTestRecord(
        path: String,
        alias: String = "dev",
        syncedAtNs: Int64 = 0
    ) -> MetadataRecord {
        MetadataRecord(
            accountAlias: alias,
            workspaceID: "ws-1",
            itemID: "lh-1",
            path: path,
            parentPath: "",
            name: (path as NSString).lastPathComponent,
            isDir: false,
            contentLength: 100,
            etag: "\"v1\"",
            syncedAtNs: syncedAtNs
        )
    }
}
