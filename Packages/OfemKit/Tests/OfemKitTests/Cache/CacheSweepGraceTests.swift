import Foundation
@testable import OfemKit
import Testing

// MARK: - Init-time orphan sweep grace-window tests (#482)

//
// Pins the fix for the race between the init-time orphan sweep and a concurrent
// first blob store: the sweep must never delete a blob (or `*.tmp` scratch file)
// that was written concurrently with — or after — it, because such a file may
// belong to an in-flight `storeBlob` whose disk write has landed but whose DB
// commit has not. The sweep spares any file modified within its grace window and
// reaps only older, genuine crash-orphans.
//
// Every case is deterministic: it drives `sweepOrphans()` (the synchronous
// entry point) against files whose modification time is pinned to "now" (fresh)
// or the Unix epoch (stale), never relying on winning the fire-and-forget init
// Task's timing.

@Suite("CacheStore orphan-sweep grace window (#482)")
struct CacheSweepGraceTests {
    // MARK: - Helpers

    /// Writes an unreferenced blob file directly into the shard for `sha`,
    /// optionally pinning its modification time. Returns the on-disk URL.
    @discardableResult
    private func writeLooseBlob(_ store: CacheStore, sha: String, mtime: Date? = nil) throws -> URL {
        // Reconstruct the shard path via a fresh BlobShardCache over the same
        // blob root (the established test pattern) — a single source of truth
        // for the `<blobRoot>/<first2>/<remaining62>` layout.
        let blobCache = try BlobShardCache(blobRoot: store.blobRoot)
        let (shardDir, fileURL) = blobCache.shardPath(for: sha)
        try FileManager.default.createDirectory(at: shardDir, withIntermediateDirectories: true)
        try Data("loose blob".utf8).write(to: fileURL)
        if let mtime {
            try FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: fileURL.path)
        }
        return fileURL
    }

    /// Writes a `blob-<uuid>.tmp` scratch file into the blob root, optionally
    /// pinning its modification time. Returns the on-disk URL.
    @discardableResult
    private func writeTmpScratch(_ store: CacheStore, mtime: Date? = nil) throws -> URL {
        let url = store.blobRoot.appendingPathComponent("blob-\(UUID().uuidString).tmp")
        try Data("scratch".utf8).write(to: url)
        if let mtime {
            try FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: url.path)
        }
        return url
    }

    /// A valid 64-char lowercase-hex SHA built from a single repeated nibble.
    private func fakeSHA(_ nibble: Character) -> String {
        String(repeating: nibble, count: BlobShardCache.shaLength)
    }

    private func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    // MARK: - Core: a fresh unreferenced blob is spared

    @Test("a freshly written, unreferenced blob is spared by the sweep's grace window")
    func freshUnreferencedBlobIsSpared() async throws {
        let store = try makeTempStore()
        defer { try? FileManager.default.removeItem(at: store.root) }

        // No DB row references this SHA, and the file's mtime is "now": exactly
        // the shape of a blob a concurrent in-flight storeBlob has written but
        // not yet committed. Pre-fix the sweep deletes it (the #482 bug);
        // post-fix the grace window spares it.
        let loose = try writeLooseBlob(store, sha: fakeSHA("b"))

        try await store.sweepOrphans()

        #expect(exists(loose), "a fresh unreferenced blob must survive the sweep (grace window)")
    }

    // MARK: - A stale unreferenced blob is still reaped

    @Test("a stale, unreferenced blob is still reaped (grace window is not a blanket disable)")
    func staleUnreferencedBlobIsReaped() async throws {
        let store = try makeTempStore()
        defer { try? FileManager.default.removeItem(at: store.root) }

        // Same unreferenced shape, but aged decades into the past — a genuine
        // crash-orphan from a prior process. It must still be reclaimed.
        let loose = try writeLooseBlob(store, sha: fakeSHA("c"), mtime: Date(timeIntervalSince1970: 0))

        try await store.sweepOrphans()

        #expect(!exists(loose), "a stale unreferenced orphan must still be reaped")
    }

    // MARK: - A referenced blob always survives (baseline)

    @Test("a referenced blob survives the sweep")
    func referencedBlobSurvives() async throws {
        let store = try makeTempStore()
        defer { try? FileManager.default.removeItem(at: store.root) }

        let key = CacheKey(accountAlias: "a", workspaceID: "ws", itemID: "item", path: "kept.bin")
        let content = Data("referenced".utf8)
        try await store.upsert(MetadataRecord(
            accountAlias: key.accountAlias, workspaceID: key.workspaceID,
            itemID: key.itemID, path: key.path, parentPath: "",
            name: key.path, isDir: false, contentLength: Int64(content.count), etag: "e"
        ))
        try await store.storeBlob(key: key, data: content)

        try await store.sweepOrphans()

        let record = try await store.fetch(key: key)
        let maybeURL = await store.blobURL(record: record)
        let url = try #require(maybeURL, "a referenced blob must not be swept")
        #expect(exists(url))
    }

    // MARK: - *.tmp scratch files honour the same grace window

    @Test("a fresh *.tmp scratch file is spared by the grace window")
    func freshTmpScratchIsSpared() async throws {
        let store = try makeTempStore()
        defer { try? FileManager.default.removeItem(at: store.root) }

        // A concurrent BlobShardCache.store writes blob-<uuid>.tmp then renames
        // it into the shard; deleting a fresh one mid-write is the same hazard.
        let tmp = try writeTmpScratch(store)

        try await store.sweepOrphans()

        #expect(exists(tmp), "a fresh *.tmp scratch file must survive the sweep")
    }

    @Test("a stale *.tmp scratch file is still reaped")
    func staleTmpScratchIsReaped() async throws {
        let store = try makeTempStore()
        defer { try? FileManager.default.removeItem(at: store.root) }

        let tmp = try writeTmpScratch(store, mtime: Date(timeIntervalSince1970: 0))

        try await store.sweepOrphans()

        #expect(!exists(tmp), "a stale *.tmp scratch file must still be reaped")
    }
}
