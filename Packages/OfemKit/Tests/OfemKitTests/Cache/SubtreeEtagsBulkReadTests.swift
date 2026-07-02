import Foundation
import GRDB
@testable import OfemKit
import Testing

// MARK: - subtreeEtags(for:) bulk-read tests

/// Tests for the E2 bulk keyed read
/// ``CacheReader/subtreeEtags(for:)`` (and its ``CacheStore`` delegate), which
/// collapses the #380 skip-gate's per-key `subtree_etag` reads into one
/// transaction. The result must match what N individual `fetch` calls would
/// have produced: present rows keyed by ``CacheKey/stableKeyString``, missing
/// rows omitted (the caller treats an absent key as an empty token).
@Suite("subtreeEtags bulk read")
struct SubtreeEtagsBulkReadTests {
    private func seedDir(_ store: CacheStore, _ key: CacheKey, subtreeEtag: String) async throws {
        try await store.upsert(MetadataRecord(
            accountAlias: key.accountAlias,
            workspaceID: key.workspaceID,
            itemID: key.itemID,
            path: key.path,
            parentPath: Enumerator.parentPath(key.path),
            name: key.path.isEmpty ? key.itemID : Enumerator.baseName(key.path),
            isDir: true,
            subtreeEtag: subtreeEtag
        ))
    }

    @Test("Returns present rows keyed by stableKeyString, omits missing rows")
    func returnsPresentOmitsMissing() async throws {
        let store = try makeTempStore()
        defer { try? FileManager.default.removeItem(at: store.root) }

        let withToken = CacheKey(accountAlias: "a", workspaceID: "w", itemID: "i", path: "dir1")
        let emptyToken = CacheKey(accountAlias: "a", workspaceID: "w", itemID: "i", path: "dir2")
        let missing = CacheKey(accountAlias: "a", workspaceID: "w", itemID: "i", path: "dir3")

        try await seedDir(store, withToken, subtreeEtag: "st-1")
        try await seedDir(store, emptyToken, subtreeEtag: "")

        let result = try await store.subtreeEtags(for: [withToken, emptyToken, missing])

        #expect(result[withToken.stableKeyString] == "st-1")
        // A present row with an empty token is still returned (present-with-"" and
        // absent both normalise to "" at the call site).
        #expect(result[emptyToken.stableKeyString] == "")
        // A missing row is omitted entirely.
        #expect(result[missing.stableKeyString] == nil)
        #expect(result.count == 2)
    }

    @Test("Matches per-key fetch for every present key")
    func matchesPerKeyFetch() async throws {
        let store = try makeTempStore()
        defer { try? FileManager.default.removeItem(at: store.root) }

        let keys = [
            CacheKey(accountAlias: "a", workspaceID: "w", itemID: "i", path: ""),
            CacheKey(accountAlias: "a", workspaceID: "w", itemID: "i", path: "Files"),
            CacheKey(accountAlias: "a", workspaceID: "w", itemID: "i", path: "Files/sub"),
        ]
        try await seedDir(store, keys[0], subtreeEtag: "root-etag")
        try await seedDir(store, keys[1], subtreeEtag: "files-etag")
        try await seedDir(store, keys[2], subtreeEtag: "sub-etag")

        let bulk = try await store.subtreeEtags(for: keys)
        for key in keys {
            let single = try await store.fetch(key: key).subtreeEtag
            #expect(bulk[key.stableKeyString] == single)
        }
    }

    @Test("Empty key list returns an empty map")
    func emptyKeysReturnsEmpty() async throws {
        let store = try makeTempStore()
        defer { try? FileManager.default.removeItem(at: store.root) }
        let result = try await store.subtreeEtags(for: [])
        #expect(result.isEmpty)
    }

    @Test("A row whose subtree_etag is SQL NULL is omitted (distinct from empty string)")
    func nullSubtreeEtagRowIsOmitted() async throws {
        // The store API always writes a non-optional subtree_etag, so a genuine
        // SQL NULL (which `MetadataRecord.init(row:)` tolerates via `?? ""`) can
        // only be produced with raw SQL. Build a minimal path_metadata directly.
        // A NULL value makes `String.fetchOne` return nil, so the key is omitted —
        // distinct from an empty-string token, which is returned as "" (covered by
        // `returnsPresentOmitsMissing`).
        let dbQueue = try DatabaseQueue()
        try await dbQueue.write { db in
            try db.execute(sql: """
            CREATE TABLE path_metadata (
                account_alias TEXT NOT NULL,
                workspace_id TEXT NOT NULL,
                item_id TEXT NOT NULL,
                path TEXT NOT NULL,
                subtree_etag TEXT,
                PRIMARY KEY (account_alias, workspace_id, item_id, path)
            )
            """)
            try db.execute(
                sql: "INSERT INTO path_metadata VALUES (?, ?, ?, ?, ?)",
                arguments: ["a", "w", "i", "hasEtag", "st-1"]
            )
            // Explicit SQL NULL subtree_etag on a row that otherwise exists.
            try db.execute(
                sql: "INSERT INTO path_metadata VALUES (?, ?, ?, ?, NULL)",
                arguments: ["a", "w", "i", "nullEtag"]
            )
        }

        let reader = CacheReader(db: dbQueue)
        let hasEtag = CacheKey(accountAlias: "a", workspaceID: "w", itemID: "i", path: "hasEtag")
        let nullEtag = CacheKey(accountAlias: "a", workspaceID: "w", itemID: "i", path: "nullEtag")

        let result = try await reader.subtreeEtags(for: [hasEtag, nullEtag])

        // The present token is returned unchanged; the NULL-token row is omitted
        // (the caller reads an absent key as ""). The call does not throw.
        #expect(result[hasEtag.stableKeyString] == "st-1")
        #expect(result[nullEtag.stableKeyString] == nil)
        #expect(result.count == 1)
    }
}
