import Foundation
@testable import OfemKit
import Testing

// MARK: - SyncEngine Rename Tests

@Suite("SyncEngine.rename")
struct SyncEngineRenameTests {
    // MARK: - Helpers

    private func makeEngine(
        onelake: any OneLakeClientProtocol = MockOneLakeClient(),
        fabric: MockFabricClient = MockFabricClient()
    ) throws -> (SyncEngine, CacheStore) {
        let store = try makeTempStore()
        let scratchDir = store.root.appending(path: "scratch", directoryHint: .isDirectory)
        let engine = SyncEngine(
            cache: store,
            onelake: onelake,
            fabric: fabric,
            scratchBase: scratchDir
        )
        return (engine, store)
    }

    private static let alias = "test"
    private static let wsID = "ws-rename"
    private static let itID = "item-rename"

    // MARK: - Happy path: rename calls client and re-keys cache row

    @Test("rename() calls onelake.rename with correct paths and re-keys the cache row")
    func renameRekeysRow() async throws {
        let ol = MockOneLakeClient()
        ol.renameResults.append(.success(()))

        let (engine, store) = try makeEngine(onelake: ol)
        defer { try? FileManager.default.removeItem(at: store.root) }

        // Seed a cache row for the old path.
        let oldPath = "Files/untitled folder"
        let newName = "my folder"
        let key = CacheKey(accountAlias: Self.alias, workspaceID: Self.wsID, itemID: Self.itID, path: oldPath)
        let record = MetadataRecord(
            accountAlias: Self.alias,
            workspaceID: Self.wsID,
            itemID: Self.itID,
            path: oldPath,
            parentPath: "Files",
            name: "untitled folder",
            isDir: true,
            itemType: "Lakehouse"
        )
        try await store.upsert(record)

        let updated = try await engine.rename(key: key, newName: newName)

        // The client was called once with the correct paths.
        #expect(ol.renameCalls.count == 1)
        let call = try #require(ol.renameCalls.first)
        #expect(call.alias == Self.alias)
        #expect(call.workspaceGUID == Self.wsID)
        #expect(call.itemGUID == Self.itID)
        #expect(call.sourcePath == "Files/untitled folder")
        #expect(call.destinationPath == "Files/my folder")

        // The returned record has the new name and path.
        #expect(updated.name == "my folder")
        #expect(updated.path == "Files/my folder")
        #expect(updated.parentPath == "Files")

        // The old key is gone; the new key is present.
        await #expect(throws: (any Error).self) {
            _ = try await store.fetch(key: key)
        }
        let newKey = CacheKey(accountAlias: Self.alias, workspaceID: Self.wsID, itemID: Self.itID, path: "Files/my folder")
        let fetched = try await store.fetch(key: newKey)
        #expect(fetched.name == "my folder")
        #expect(fetched.path == "Files/my folder")
    }

    // MARK: - Descendants re-keyed after non-empty-folder rename

    @Test("rename() re-keys cached descendants when a non-empty folder is renamed")
    func renameRekeysDescendants() async throws {
        let ol = MockOneLakeClient()
        ol.renameResults.append(.success(()))

        let (engine, store) = try makeEngine(onelake: ol)
        defer { try? FileManager.default.removeItem(at: store.root) }

        let oldDir = "Files/alpha"
        let dirKey = CacheKey(accountAlias: Self.alias, workspaceID: Self.wsID, itemID: Self.itID, path: oldDir)

        // Seed parent + two descendants.
        let rows: [MetadataRecord] = [
            MetadataRecord(
                accountAlias: Self.alias, workspaceID: Self.wsID, itemID: Self.itID,
                path: oldDir, parentPath: "Files", name: "alpha", isDir: true
            ),
            MetadataRecord(
                accountAlias: Self.alias, workspaceID: Self.wsID, itemID: Self.itID,
                path: "Files/alpha/child.txt", parentPath: "Files/alpha",
                name: "child.txt", isDir: false
            ),
            MetadataRecord(
                accountAlias: Self.alias, workspaceID: Self.wsID, itemID: Self.itID,
                path: "Files/alpha/sub/deep.txt", parentPath: "Files/alpha/sub",
                name: "deep.txt", isDir: false
            ),
        ]
        for r in rows {
            try await store.upsert(r)
        }

        _ = try await engine.rename(key: dirKey, newName: "beta")

        // Old paths gone, new paths present.
        for old in ["Files/alpha", "Files/alpha/child.txt", "Files/alpha/sub/deep.txt"] {
            let k = CacheKey(accountAlias: Self.alias, workspaceID: Self.wsID, itemID: Self.itID, path: old)
            await #expect(throws: (any Error).self) {
                _ = try await store.fetch(key: k)
            }
        }
        let newDir = CacheKey(accountAlias: Self.alias, workspaceID: Self.wsID, itemID: Self.itID, path: "Files/beta")
        let newChild = CacheKey(accountAlias: Self.alias, workspaceID: Self.wsID, itemID: Self.itID, path: "Files/beta/child.txt")
        let newDeep = CacheKey(accountAlias: Self.alias, workspaceID: Self.wsID, itemID: Self.itID, path: "Files/beta/sub/deep.txt")
        let fetched = try await store.fetch(key: newDir)
        #expect(fetched.name == "beta")
        let fetchedChild = try await store.fetch(key: newChild)
        #expect(fetchedChild.name == "child.txt")
        #expect(fetchedChild.parentPath == "Files/beta")
        let fetchedDeep = try await store.fetch(key: newDeep)
        #expect(fetchedDeep.name == "deep.txt")
        #expect(fetchedDeep.parentPath == "Files/beta/sub")
    }

    // MARK: - Destination collision: pre-existing dest row must not PK-abort

    @Test("rename() overwrites a pre-existing destination cache row")
    func renameOverwritesExistingDestination() async throws {
        let ol = MockOneLakeClient()
        ol.renameResults.append(.success(()))

        let (engine, store) = try makeEngine(onelake: ol)
        defer { try? FileManager.default.removeItem(at: store.root) }

        // Source and a stale destination row both already exist (DFS overwrites
        // the destination server-side, so the cache can collide).
        try await store.upsert(MetadataRecord(
            accountAlias: Self.alias, workspaceID: Self.wsID, itemID: Self.itID,
            path: "Files/source.txt", parentPath: "Files", name: "source.txt", isDir: false,
            contentLength: 10, itemType: "Lakehouse"
        ))
        try await store.upsert(MetadataRecord(
            accountAlias: Self.alias, workspaceID: Self.wsID, itemID: Self.itID,
            path: "Files/dest.txt", parentPath: "Files", name: "dest.txt", isDir: false,
            contentLength: 999, itemType: "Lakehouse"
        ))

        let key = CacheKey(accountAlias: Self.alias, workspaceID: Self.wsID, itemID: Self.itID, path: "Files/source.txt")
        // Must not throw a PK violation.
        let updated = try await engine.rename(key: key, newName: "dest.txt")
        #expect(updated.path == "Files/dest.txt")
        // The surviving row is the renamed source (size 10), not the stale dest (999).
        let newKey = CacheKey(accountAlias: Self.alias, workspaceID: Self.wsID, itemID: Self.itID, path: "Files/dest.txt")
        let fetched = try await store.fetch(key: newKey)
        #expect(fetched.contentLength == 10)
    }

    // MARK: - Sibling band: alpha -> alpha2 must not re-key unrelated siblings

    @Test("rename() with a destination inside the old sort band leaves siblings untouched")
    func renameDoesNotTouchSortBandSiblings() async throws {
        let ol = MockOneLakeClient()
        ol.renameResults.append(.success(()))

        let (engine, store) = try makeEngine(onelake: ol)
        defer { try? FileManager.default.removeItem(at: store.root) }

        // alpha is renamed to alpha2 — alpha2 sorts inside the old `> alpha AND
        // < alpha\u{FFFF}` band, as do the unrelated siblings below. Only alpha
        // and its true descendants must move.
        let rows: [MetadataRecord] = [
            MetadataRecord(accountAlias: Self.alias, workspaceID: Self.wsID, itemID: Self.itID,
                           path: "Files/alpha", parentPath: "Files", name: "alpha", isDir: true),
            MetadataRecord(accountAlias: Self.alias, workspaceID: Self.wsID, itemID: Self.itID,
                           path: "Files/alpha/child.txt", parentPath: "Files/alpha", name: "child.txt", isDir: false),
            // Unrelated siblings whose paths fall in the same lexicographic band.
            MetadataRecord(accountAlias: Self.alias, workspaceID: Self.wsID, itemID: Self.itID,
                           path: "Files/alpha.txt", parentPath: "Files", name: "alpha.txt", isDir: false),
            MetadataRecord(accountAlias: Self.alias, workspaceID: Self.wsID, itemID: Self.itID,
                           path: "Files/alpha-backup", parentPath: "Files", name: "alpha-backup", isDir: true),
        ]
        for r in rows {
            try await store.upsert(r)
        }

        let key = CacheKey(accountAlias: Self.alias, workspaceID: Self.wsID, itemID: Self.itID, path: "Files/alpha")
        _ = try await engine.rename(key: key, newName: "alpha2")

        // alpha and its child moved.
        let movedDir = CacheKey(accountAlias: Self.alias, workspaceID: Self.wsID, itemID: Self.itID, path: "Files/alpha2")
        let movedChild = CacheKey(accountAlias: Self.alias, workspaceID: Self.wsID, itemID: Self.itID, path: "Files/alpha2/child.txt")
        #expect(try await store.fetch(key: movedDir).name == "alpha2")
        #expect(try await store.fetch(key: movedChild).parentPath == "Files/alpha2")

        // Siblings are untouched.
        let sibFile = CacheKey(accountAlias: Self.alias, workspaceID: Self.wsID, itemID: Self.itID, path: "Files/alpha.txt")
        let sibDir = CacheKey(accountAlias: Self.alias, workspaceID: Self.wsID, itemID: Self.itID, path: "Files/alpha-backup")
        #expect(try await store.fetch(key: sibFile).name == "alpha.txt")
        #expect(try await store.fetch(key: sibDir).name == "alpha-backup")
    }

    // MARK: - createdNs / dates preserved on the happy path

    @Test("rename() preserves created/modified timestamps in the returned record")
    func renamePreservesTimestamps() async throws {
        let ol = MockOneLakeClient()
        ol.renameResults.append(.success(()))

        let (engine, store) = try makeEngine(onelake: ol)
        defer { try? FileManager.default.removeItem(at: store.root) }

        let createdNs: Int64 = 1_600_000_000_000_000_000
        let modifiedNs: Int64 = 1_700_000_000_000_000_000
        let key = CacheKey(accountAlias: Self.alias, workspaceID: Self.wsID, itemID: Self.itID, path: "Files/old.txt")
        try await store.upsert(MetadataRecord(
            accountAlias: Self.alias, workspaceID: Self.wsID, itemID: Self.itID,
            path: "Files/old.txt", parentPath: "Files", name: "old.txt", isDir: false,
            contentLength: 42, lastModifiedNs: modifiedNs, itemType: "Lakehouse",
            createdNs: createdNs
        ))

        let updated = try await engine.rename(key: key, newName: "new.txt")
        // created_ns is not in the UPDATE SET clause, so the re-keyed row keeps it.
        #expect(updated.createdNs == createdNs)
        #expect(updated.lastModifiedNs == modifiedNs)
        #expect(updated.contentLength == 42)
    }

    // MARK: - Old identifier is tombstoned after a successful rename

    @Test("rename() writes a deletion tombstone for the old identifier")
    func renameTombstonesOldIdentifier() async throws {
        let ol = MockOneLakeClient()
        ol.renameResults.append(.success(()))

        let (engine, store) = try makeEngine(onelake: ol)
        defer { try? FileManager.default.removeItem(at: store.root) }

        let key = CacheKey(accountAlias: Self.alias, workspaceID: Self.wsID, itemID: Self.itID, path: "Files/old.txt")
        try await store.upsert(MetadataRecord(
            accountAlias: Self.alias, workspaceID: Self.wsID, itemID: Self.itID,
            path: "Files/old.txt", parentPath: "Files", name: "old.txt", isDir: false,
            itemType: "Lakehouse"
        ))

        _ = try await engine.rename(key: key, newName: "new.txt")

        let (_, deleted) = try await store.itemsChangedAfter(accountAlias: Self.alias, ns: 0)
        let oldIdentifier = "\(Self.wsID)/\(Self.itID)/Files/old.txt"
        #expect(deleted.contains(oldIdentifier),
                "the old identifier must be tombstoned so other enumerators retire it")
    }

    // MARK: - Idempotent retry: source gone but destination present → success

    @Test("rename() treats notFound source as success when the destination exists")
    func renameNotFoundButDestinationPresentSucceeds() async throws {
        let ol = MockOneLakeClient()
        // The rename PUT was already committed by an earlier (retried) attempt;
        // this attempt sees the source gone → notFound.
        ol.renameResults.append(.failure(OneLakeError.notFound))
        // The destinationExists probe issues a HEAD that confirms the dest.
        ol.getPropertiesResults.append(.success(.make(isDirectory: false)))

        let (engine, store) = try makeEngine(onelake: ol)
        defer { try? FileManager.default.removeItem(at: store.root) }

        let key = CacheKey(accountAlias: Self.alias, workspaceID: Self.wsID, itemID: Self.itID, path: "Files/old.txt")
        try await store.upsert(MetadataRecord(
            accountAlias: Self.alias, workspaceID: Self.wsID, itemID: Self.itID,
            path: "Files/old.txt", parentPath: "Files", name: "old.txt", isDir: false,
            itemType: "Lakehouse"
        ))

        // Must NOT throw — the rename already committed server-side.
        let updated = try await engine.rename(key: key, newName: "new.txt")
        #expect(updated.path == "Files/new.txt")
        #expect(ol.getPropertiesCalls.count == 1, "exactly one HEAD confirms the destination")
    }

    // MARK: - Network failure leaves item pending and cache intact

    @Test("rename() rethrows when the OneLake client call fails and leaves the old row intact")
    func renameClientFailurePropagates() async throws {
        let ol = MockOneLakeClient()
        ol.renameResults.append(.failure(OneLakeError.conflict))

        let (engine, store) = try makeEngine(onelake: ol)
        defer { try? FileManager.default.removeItem(at: store.root) }

        let key = CacheKey(accountAlias: Self.alias, workspaceID: Self.wsID, itemID: Self.itID, path: "Files/old")
        try await store.upsert(MetadataRecord(
            accountAlias: Self.alias, workspaceID: Self.wsID, itemID: Self.itID,
            path: "Files/old", parentPath: "Files", name: "old", isDir: true
        ))

        await #expect(throws: (any Error).self) {
            _ = try await engine.rename(key: key, newName: "new")
        }

        // The old-key cache row must still be present (no partial re-key).
        let fetched = try await store.fetch(key: key)
        #expect(fetched.name == "old")
        #expect(fetched.path == "Files/old")
        // And no row leaked under the new key.
        let newKey = CacheKey(accountAlias: Self.alias, workspaceID: Self.wsID, itemID: Self.itID, path: "Files/new")
        await #expect(throws: (any Error).self) {
            _ = try await store.fetch(key: newKey)
        }
    }
}
