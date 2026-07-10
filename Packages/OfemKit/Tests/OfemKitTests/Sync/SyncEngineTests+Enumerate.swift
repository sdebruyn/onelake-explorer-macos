import Foundation
import GRDB
@testable import OfemKit
import Testing

// MARK: - SyncEngine Enumerate Tests

extension SyncEngineTests {
    // MARK: - sync-14: macOS metadata filtered at enumeration

    @Test("refreshFolder does not surface .DS_Store entries")
    func macOSMetadataFilteredInEnumeration() async throws {
        let ol = MockOneLakeClient()
        let fabric = MockFabricClient()
        let (engine, store) = try makeEngine(onelake: ol, fabric: fabric)
        defer { try? FileManager.default.removeItem(at: store.root) }

        let key = CacheKey(accountAlias: Self.alias, workspaceID: Self.wsID, itemID: Self.itID, path: "")
        let listing = ListResult(entries: [
            PathEntry(name: "real.csv", isDirectory: false, contentLength: 10, eTag: "e1", lastModified: Date(timeIntervalSince1970: 0)),
            PathEntry(name: ".DS_Store", isDirectory: false, contentLength: 4, eTag: "e2", lastModified: Date(timeIntervalSince1970: 0)),
            PathEntry(name: "._real.csv", isDirectory: false, contentLength: 4, eTag: "e3", lastModified: Date(timeIntervalSince1970: 0)),
        ])
        ol.listPathResults.append(.success(listing))

        let diff = try await engine.refreshFolder(key: key)

        // Only real.csv should be added; .DS_Store and ._real.csv must be filtered.
        #expect(diff.added == 1)
        let children = try await store.children(of: key)
        let paths = children.map(\.name)
        #expect(paths.contains("real.csv"))
        #expect(!paths.contains(".DS_Store"))
        #expect(!paths.contains("._real.csv"))
    }

    // MARK: - F11: OneLakeClient upload-staging files filtered at enumeration

    @Test("refreshFolder does not surface OneLakeClient upload-staging entries")
    func uploadStagingFilteredInEnumeration() async throws {
        // A staging file (finding F11) can be caught mid-flight by a
        // concurrent listing, or left behind entirely if the process is
        // killed between a successful flush and the terminal rename. Either
        // way it must never surface as an ordinary visible file — the same
        // guarantee refreshFolder already gives .DS_Store / ._* junk via
        // isMacOSMetadata.
        let ol = MockOneLakeClient()
        let fabric = MockFabricClient()
        let (engine, store) = try makeEngine(onelake: ol, fabric: fabric)
        defer { try? FileManager.default.removeItem(at: store.root) }

        let key = CacheKey(accountAlias: Self.alias, workspaceID: Self.wsID, itemID: Self.itID, path: "")
        let stagingName = "\(ofemUploadStagingPrefix)\(UUID().uuidString)-real.csv"
        let listing = ListResult(entries: [
            PathEntry(name: "real.csv", isDirectory: false, contentLength: 10, eTag: "e1", lastModified: Date(timeIntervalSince1970: 0)),
            PathEntry(name: stagingName, isDirectory: false, contentLength: 10, eTag: "e2", lastModified: Date(timeIntervalSince1970: 0)),
        ])
        ol.listPathResults.append(.success(listing))

        let diff = try await engine.refreshFolder(key: key)

        // Only real.csv should be added; the staging entry must be filtered.
        #expect(diff.added == 1)
        let children = try await store.children(of: key)
        let paths = children.map(\.name)
        #expect(paths.contains("real.csv"))
        #expect(!paths.contains(stagingName))
    }

    // MARK: - sync-22: enumerate throws wrongItemKind for files

    @Test("enumerate() throws wrongItemKind when key is a file")
    func enumerateThrowsWrongItemKind() async throws {
        let ol = MockOneLakeClient()
        let fabric = MockFabricClient()
        let (engine, store) = try makeEngine(onelake: ol, fabric: fabric)
        defer { try? FileManager.default.removeItem(at: store.root) }

        // Insert a file (isDir: false) into the cache.
        let key = CacheKey(accountAlias: Self.alias, workspaceID: Self.wsID, itemID: Self.itID, path: "file.txt")
        let record = MetadataRecord(
            accountAlias: Self.alias,
            workspaceID: Self.wsID,
            itemID: Self.itID,
            path: "file.txt",
            parentPath: "",
            name: "file.txt",
            isDir: false,
            childrenSyncedAtNs: Int64(Date().timeIntervalSince1970 * 1e9) // Make it "fresh"
        )
        try await store.upsert(record)

        do {
            _ = try await engine.enumerate(key: key)
            Issue.record("Expected wrongItemKind to be thrown")
        } catch let fpErr as FPError {
            if case .wrongItemKind = fpErr {
                // Correct — test passes.
            } else {
                Issue.record("Expected wrongItemKind, got \(fpErr)")
            }
        }
    }

    // MARK: - Paused workspace guard: guardPaused throws before any network call

    @Test("refreshFolder() throws workspacePaused immediately when workspace is paused")
    func pausedWorkspaceGuardBlocksRefreshFolder() async throws {
        let ol = MockOneLakeClient()
        let (engine, store) = try makeEngine(onelake: ol)
        defer { try? FileManager.default.removeItem(at: store.root) }

        let status = WorkspaceStatusRecord(
            accountAlias: Self.alias,
            workspaceID: Self.wsID,
            state: .paused,
            reason: "capacity_paused",
            detectedAtNs: Int64(Date().timeIntervalSince1970 * 1_000_000_000)
        )
        try await store.setWorkspaceStatus(status)

        let key = CacheKey(accountAlias: Self.alias, workspaceID: Self.wsID, itemID: Self.itID, path: "")
        do {
            _ = try await engine.refreshFolder(key: key)
            Issue.record("Expected workspacePaused to be thrown")
        } catch SyncError.workspacePaused {
            // Correct.
        }
        #expect(ol.listPathCalls.isEmpty)
    }

    // MARK: - refreshFolder: paused-capacity error from listPath marks workspace paused

    @Test("refreshFolder() marks workspace paused when listPath returns a paused-capacity error")
    func refreshFolderMarksPausedOnCapacityError() async throws {
        let ol = MockOneLakeClient()
        let (engine, store) = try makeEngine(onelake: ol)
        defer { try? FileManager.default.removeItem(at: store.root) }

        let apiBody = #"{"errorCode":"CapacityPaused","message":"capacity is currently paused"}"#
        let apiErr = HTTPClientError.apiError(APIError(statusCode: 503, status: "503 Service Unavailable", body: try #require(apiBody.data(using: .utf8))))
        ol.listPathResults.append(.failure(OneLakeError.httpError(apiErr)))

        let key = CacheKey(accountAlias: Self.alias, workspaceID: Self.wsID, itemID: Self.itID, path: "")
        do {
            _ = try await engine.refreshFolder(key: key)
            Issue.record("Expected workspacePaused to be thrown")
        } catch SyncError.workspacePaused {
            // Correct.
        }

        let status = try? await store.workspaceStatus(accountAlias: Self.alias, workspaceID: Self.wsID)
        #expect(status?.state == .paused)
    }

    // MARK: - refreshFolder: item-relative PathEntry.name (issue-244 regression)

    /// Regression test for the double-stripping bug fixed in issue #244.
    ///
    /// After onelake-12 (commit 6d3c25f), `OneLakeClient.listPath` returns
    /// `PathEntry.name` values that are already item-relative — the `<itemGUID>/`
    /// prefix is stripped by `convertRawEntry` inside the client. Before the fix,
    /// `SyncEngine.refreshFolder` called `Enumerator.stripItemPrefix` on those
    /// already-stripped names, which returned `nil` for every entry (the itemGUID
    /// was not present as a prefix) and left `remoteChildren` empty — causing zero
    /// children to be reconciled into the cache.
    ///
    /// This test drives `refreshFolder` with a mock returning item-relative names
    /// (matching what the real client returns) and asserts all children are cached.
    @Test("refreshFolder() reconciles item-relative PathEntry.name values into the cache (issue-244)")
    func refreshFolderItemRelativeNames() async throws {
        let ol = MockOneLakeClient()
        let (engine, store) = try makeEngine(onelake: ol)
        defer { try? FileManager.default.removeItem(at: store.root) }

        // Directory at a nested path, as used by the integration tests.
        let dir = "Files/ofem-ci/test-run"
        let key = CacheKey(
            accountAlias: Self.alias,
            workspaceID: Self.wsID,
            itemID: Self.itID,
            path: dir
        )

        // Item-relative names — no "<itemGUID>/" prefix.  This matches what
        // OneLakeClient.listPath returns after onelake-12.
        ol.listPathResults.append(.success(ListResult(entries: [
            PathEntry(name: "\(dir)/alpha.bin", isDirectory: false, contentLength: 100, eTag: "e1", lastModified: .distantPast),
            PathEntry(name: "\(dir)/beta.bin", isDirectory: false, contentLength: 200, eTag: "e2", lastModified: .distantPast),
            PathEntry(name: "\(dir)/sub", isDirectory: true, contentLength: 0, eTag: "", lastModified: .distantPast),
        ])))

        let diff = try await engine.refreshFolder(key: key)

        // Before the fix, all three entries were dropped (remoteChildren empty)
        // because stripItemPrefix returned nil for every item-relative name.
        #expect(diff.added == 3, "refreshFolder must add all 3 remote entries")

        let kids = try await store.children(of: key)
        #expect(kids.count == 3, "cache must contain 3 children after refresh")

        let alpha = kids.first { $0.name == "alpha.bin" }
        #expect(alpha != nil, "alpha.bin must be cached")
        #expect(alpha?.isDir == false)
        #expect(alpha?.contentLength == 100)

        let sub = kids.first { $0.name == "sub" }
        #expect(sub != nil, "sub directory must be cached")
        #expect(sub?.isDir == true)
    }

    // MARK: - refreshFolder: empty remote listing removes all cached children

    @Test("refreshFolder() with empty remote listing deletes all cached children")
    func refreshFolderEmptyRemovesCachedChildren() async throws {
        let ol = MockOneLakeClient()
        let (engine, store) = try makeEngine(onelake: ol)
        defer { try? FileManager.default.removeItem(at: store.root) }

        let key = CacheKey(accountAlias: Self.alias, workspaceID: Self.wsID, itemID: Self.itID, path: "")

        // Seed two children in the cache.
        let parent = MetadataRecord(accountAlias: Self.alias, workspaceID: Self.wsID, itemID: Self.itID,
                                    path: "", parentPath: "", name: "root", isDir: true)
        let child1 = MetadataRecord(accountAlias: Self.alias, workspaceID: Self.wsID, itemID: Self.itID,
                                    path: "a.csv", parentPath: "", name: "a.csv", isDir: false)
        let child2 = MetadataRecord(accountAlias: Self.alias, workspaceID: Self.wsID, itemID: Self.itID,
                                    path: "b.csv", parentPath: "", name: "b.csv", isDir: false)
        try await store.upsert(parent)
        try await store.upsert(child1)
        try await store.upsert(child2)

        // Remote listing returns nothing.
        ol.listPathResults.append(.success(ListResult(entries: [])))

        let diff = try await engine.refreshFolder(key: key)
        #expect(diff.removed == 2)
        #expect(diff.added == 0)

        let children = try await store.children(of: key)
        #expect(children.isEmpty)
    }

    // MARK: - refreshFolder: remote item vanished (stale cached child removed)

    @Test("refreshFolder() removes a cached entry when its remote counterpart disappears")
    func refreshFolderRemovesVanishedRemoteItem() async throws {
        let ol = MockOneLakeClient()
        let (engine, store) = try makeEngine(onelake: ol)
        defer { try? FileManager.default.removeItem(at: store.root) }

        let key = CacheKey(accountAlias: Self.alias, workspaceID: Self.wsID, itemID: Self.itID, path: "")

        // Seed three children.
        let parent = MetadataRecord(accountAlias: Self.alias, workspaceID: Self.wsID, itemID: Self.itID,
                                    path: "", parentPath: "", name: "root", isDir: true)
        try await store.upsert(parent)
        for name in ["keep.csv", "gone.csv", "also-keep.csv"] {
            let r = MetadataRecord(accountAlias: Self.alias, workspaceID: Self.wsID, itemID: Self.itID,
                                   path: name, parentPath: "", name: name, isDir: false)
            try await store.upsert(r)
        }

        // Remote only returns keep.csv and also-keep.csv.
        let listing = ListResult(entries: [
            PathEntry(name: "keep.csv", isDirectory: false, contentLength: 10, eTag: "e1", lastModified: .distantPast),
            PathEntry(name: "also-keep.csv", isDirectory: false, contentLength: 10, eTag: "e2", lastModified: .distantPast),
        ])
        ol.listPathResults.append(.success(listing))

        let diff = try await engine.refreshFolder(key: key)
        #expect(diff.removed == 1)

        let remaining = try await store.children(of: key)
        let names = remaining.map(\.name)
        #expect(names.contains("keep.csv"))
        #expect(names.contains("also-keep.csv"))
        #expect(!names.contains("gone.csv"))
    }

    // MARK: - refreshFolder: delete-phase DB error rolls back atomically (#427)

    /// Issue #427 / review finding M2: refreshFolder's upsert and delete phases
    /// used to be separate transactions, and both swallowed DB errors (log-only).
    /// A delete-phase failure after the upserts had already committed left
    /// vanished rows in the cache with no tombstone while the sync anchor (the
    /// max synced_at_ns, already advanced by the committed upserts) moved past
    /// them regardless. This test installs a `BEFORE DELETE` trigger that fails
    /// exactly the deletion of one vanished child — a stand-in for a transient
    /// SQLITE_BUSY/SQLITE_FULL — and asserts the failure propagates AND the
    /// whole reconcile (including the co-occurring upsert of a brand-new child)
    /// rolled back, rather than leaving a partially-applied cache.
    @Test("refreshFolder() propagates a delete-phase DB error and rolls back the co-committed upserts")
    func refreshFolderDeletePhaseFailureRollsBackUpserts() async throws {
        let ol = MockOneLakeClient()
        let (engine, store) = try makeEngine(onelake: ol)
        defer { try? FileManager.default.removeItem(at: store.root) }

        let key = CacheKey(accountAlias: Self.alias, workspaceID: Self.wsID, itemID: Self.itID, path: "")

        // Seed a parent row plus two children.
        let parent = MetadataRecord(accountAlias: Self.alias, workspaceID: Self.wsID, itemID: Self.itID,
                                    path: "", parentPath: "", name: "root", isDir: true)
        try await store.upsert(parent)
        for name in ["keep.csv", "gone.csv"] {
            let r = MetadataRecord(accountAlias: Self.alias, workspaceID: Self.wsID, itemID: Self.itID,
                                   path: name, parentPath: "", name: name, isDir: false)
            try await store.upsert(r)
        }

        // A trigger that fails ONLY the "gone.csv" delete, so it fires deep
        // inside the delete phase — after the upsert phase (below) has already
        // run its INSERT/UPDATE statements in the SAME transaction.
        try await store.dbPool.write { db in
            try db.execute(sql: """
            CREATE TEMP TRIGGER fail_gone_delete BEFORE DELETE ON path_metadata
            WHEN OLD.path = 'gone.csv'
            BEGIN SELECT RAISE(ABORT, 'issue-427 simulated delete-phase failure'); END;
            """)
        }

        // Remote listing: keep.csv survives, gone.csv vanished, new.csv is a
        // brand-new child — so this pass has both an upsert and a delete.
        let listing = ListResult(entries: [
            PathEntry(name: "keep.csv", isDirectory: false, contentLength: 10, eTag: "e1", lastModified: .distantPast),
            PathEntry(name: "new.csv", isDirectory: false, contentLength: 20, eTag: "e2", lastModified: .distantPast),
        ])
        ol.listPathResults.append(.success(listing))

        await #expect(throws: (any Error).self) {
            try await engine.refreshFolder(key: key)
        }

        // The delete-phase failure must roll back the WHOLE reconcile
        // transaction, not just the failing delete: new.csv must not have been
        // committed, and gone.csv must still be present and un-tombstoned — no
        // partial state where upserts landed but the vanished row silently
        // dropped out of the incremental delta.
        let children = try await store.children(of: key)
        let names = Set(children.map(\.name))
        #expect(names == ["keep.csv", "gone.csv"])
    }

    // MARK: - refreshFolder: etag carry-over when unchanged

    @Test("refreshFolder() carries blob linkage when remote etag is unchanged")
    func refreshFolderCarriesBlobLinkageOnUnchangedEtag() async throws {
        let ol = MockOneLakeClient()
        let (engine, store) = try makeEngine(onelake: ol)
        defer { try? FileManager.default.removeItem(at: store.root) }

        let key = CacheKey(accountAlias: Self.alias, workspaceID: Self.wsID, itemID: Self.itID, path: "")

        // Seed a parent and one child with a known etag + blobSHA256.
        let parent = MetadataRecord(accountAlias: Self.alias, workspaceID: Self.wsID, itemID: Self.itID,
                                    path: "", parentPath: "", name: "root", isDir: true)
        var child = MetadataRecord(accountAlias: Self.alias, workspaceID: Self.wsID, itemID: Self.itID,
                                   path: "data.csv", parentPath: "", name: "data.csv", isDir: false,
                                   contentLength: 50, etag: "stable-etag")
        child.blobSHA256 = "sha-abc"
        try await store.upsert(parent)
        try await store.upsert(child)

        // Remote returns same etag → blob linkage should be preserved.
        let listing = ListResult(entries: [
            PathEntry(name: "data.csv", isDirectory: false, contentLength: 50, eTag: "stable-etag", lastModified: .distantPast),
        ])
        ol.listPathResults.append(.success(listing))

        _ = try await engine.refreshFolder(key: key)

        let updated = try? await store.fetch(key: CacheKey(
            accountAlias: Self.alias, workspaceID: Self.wsID, itemID: Self.itID, path: "data.csv"
        ))
        #expect(updated?.blobSHA256 == "sha-abc")
    }

    @Test("refreshFolder() clears blob linkage when remote etag changes")
    func refreshFolderClearsBlobLinkageOnEtagChange() async throws {
        let ol = MockOneLakeClient()
        let (engine, store) = try makeEngine(onelake: ol)
        defer { try? FileManager.default.removeItem(at: store.root) }

        let key = CacheKey(accountAlias: Self.alias, workspaceID: Self.wsID, itemID: Self.itID, path: "")

        let parent = MetadataRecord(accountAlias: Self.alias, workspaceID: Self.wsID, itemID: Self.itID,
                                    path: "", parentPath: "", name: "root", isDir: true)
        var child = MetadataRecord(accountAlias: Self.alias, workspaceID: Self.wsID, itemID: Self.itID,
                                   path: "data.csv", parentPath: "", name: "data.csv", isDir: false,
                                   contentLength: 50, etag: "old-etag")
        child.blobSHA256 = "sha-old"
        try await store.upsert(parent)
        try await store.upsert(child)

        // Remote returns a new etag.
        let listing = ListResult(entries: [
            PathEntry(name: "data.csv", isDirectory: false, contentLength: 60, eTag: "new-etag", lastModified: Date()),
        ])
        ol.listPathResults.append(.success(listing))

        _ = try await engine.refreshFolder(key: key)

        let updated = try? await store.fetch(key: CacheKey(
            accountAlias: Self.alias, workspaceID: Self.wsID, itemID: Self.itID, path: "data.csv"
        ))
        // tests-18: assert the exact canonical cleared representation ("") rather than
        // a disjunction — MetadataRecord.blobSHA256 defaults to "" when blob linkage
        // is not carried (etag changed path in SyncEngine.refreshFolder).
        #expect(updated?.blobSHA256 == "", "blobSHA256 must be cleared (empty string) when etag changes")
        #expect(updated?.etag == "new-etag")
    }

    // MARK: - enumerate: stale cache triggers refresh

    @Test("enumerate() issues a remote refresh when the cached listing is stale")
    func enumerateStaleRefreshesFromRemote() async throws {
        let ol = MockOneLakeClient()
        let fabric = MockFabricClient()
        // Use a very short TTL (1 s) so the cached row is fresh, then check
        // that an empty cache routes through refreshFolder.
        let (engine, store) = try makeEngine(onelake: ol, fabric: fabric)
        defer { try? FileManager.default.removeItem(at: store.root) }

        let key = CacheKey(accountAlias: Self.alias, workspaceID: Self.wsID, itemID: Self.itID, path: "")

        // No parent row in cache → enumerate must call refreshFolder.
        let listing = ListResult(entries: [
            PathEntry(name: "hello.txt", isDirectory: false, contentLength: 5, eTag: "e1", lastModified: .distantPast),
        ])
        ol.listPathResults.append(.success(listing))

        let children = try await engine.enumerate(key: key)
        #expect(children.count == 1)
        #expect(children[0].name == "hello.txt")
        #expect(ol.listPathCalls.count == 1)
    }

    @Test("enumerate() serves from cache when listing is fresh")
    func enumerateServesFromFreshCache() async throws {
        let ol = MockOneLakeClient()
        let (engine, store) = try makeEngine(onelake: ol)
        defer { try? FileManager.default.removeItem(at: store.root) }

        let key = CacheKey(accountAlias: Self.alias, workspaceID: Self.wsID, itemID: Self.itID, path: "")
        let nowNs = Int64(Date().timeIntervalSince1970 * 1_000_000_000)

        // Insert a fresh parent row (childrenSyncedAtNs = now).
        let parent = MetadataRecord(
            accountAlias: Self.alias, workspaceID: Self.wsID, itemID: Self.itID,
            path: "", parentPath: "", name: "root", isDir: true,
            childrenSyncedAtNs: nowNs
        )
        let child = MetadataRecord(
            accountAlias: Self.alias, workspaceID: Self.wsID, itemID: Self.itID,
            path: "cached.csv", parentPath: "", name: "cached.csv", isDir: false
        )
        try await store.upsert(parent)
        try await store.upsert(child)

        let children = try await engine.enumerate(key: key)
        #expect(children.count == 1)
        #expect(children[0].name == "cached.csv")
        // No remote call.
        #expect(ol.listPathCalls.isEmpty)
    }

    /// After a `refreshFolder` failure with the wrapped offline shape, `currentlyOffline`
    /// must flip to true because `offlineTracker.observe(_:)` was fed the error.
    @Test("currentlyOffline becomes true after refreshFolder fails with wrapped offline error via listPath")
    func isOffline_trueAfterRefreshFolderFailsOffline() async throws {
        let ol = MockOneLakeClient()
        let (engine, store) = try makeEngine(onelake: ol)
        defer { try? FileManager.default.removeItem(at: store.root) }

        // Guard: starts online.
        #expect(await engine.currentlyOffline == false)

        // Inject the realistic offline error that SyncEngine sees from OneLakeClient
        // after the short-circuit path: transport-wrapped, then OneLake-wrapped.
        let offlineTransport = HTTPClientError.transport(URLError(.notConnectedToInternet))
        let wrappedOffline = OneLakeError.httpError(offlineTransport)
        ol.listPathResults.append(.failure(wrappedOffline))

        let key = CacheKey(accountAlias: Self.alias, workspaceID: Self.wsID, itemID: Self.itID, path: "")
        do {
            _ = try await engine.refreshFolder(key: key)
            Issue.record("Expected refreshFolder to throw")
        } catch {
            // The error is not a workspacePaused (503) so it should propagate as-is.
            if case SyncError.workspacePaused = error {
                Issue.record("Should not remap offline transport error to workspacePaused")
            }
        }

        // OfflineTracker must now be in the offline state.
        #expect(await engine.currentlyOffline == true)
    }

    // MARK: - refreshFolder: item_type propagated to child rows

    @Test("refreshFolder() stamps item_type from discovery row onto child path rows")
    func refreshFolderStampsItemType() async throws {
        let ol = MockOneLakeClient()
        let fabric = MockFabricClient()
        let (engine, store) = try makeEngine(onelake: ol, fabric: fabric)
        defer { try? FileManager.default.removeItem(at: store.root) }

        // Write the discovery row that listItems would produce (Lakehouse).
        let discoveryRow = MetadataRecord(
            accountAlias: Self.alias, workspaceID: Self.wsID,
            itemID: VirtualIDs.itemID, path: Self.itID,
            parentPath: "", name: "Sales LH", isDir: true,
            itemType: "Lakehouse"
        )
        try await store.upsert(discoveryRow)

        // Stub listPath to return one file under Files/.
        ol.listPathResults.append(.success(ListResult(entries: [
            PathEntry.file(name: "Files/data.csv"),
        ])))

        let key = CacheKey(accountAlias: Self.alias, workspaceID: Self.wsID, itemID: Self.itID, path: "Files")
        _ = try await engine.refreshFolder(key: key)

        let childKey = CacheKey(accountAlias: Self.alias, workspaceID: Self.wsID, itemID: Self.itID, path: "Files/data.csv")
        let childRow = try await store.fetch(key: childKey)
        #expect(childRow.itemType == "Lakehouse", "child rows must carry the Lakehouse item_type from the discovery row")
    }

    @Test("refreshFolder() before listItems: child rows get empty item_type and are read-only")
    func refreshFolderBeforeListItemsYieldsReadOnlyRows() async throws {
        let ol = MockOneLakeClient()
        let fabric = MockFabricClient()
        let (engine, store) = try makeEngine(onelake: ol, fabric: fabric)
        defer { try? FileManager.default.removeItem(at: store.root) }

        // No discovery row written — simulates refreshFolder racing ahead of listItems.
        ol.listPathResults.append(.success(ListResult(entries: [
            PathEntry.file(name: "Files/data.csv"),
        ])))

        let key = CacheKey(accountAlias: Self.alias, workspaceID: Self.wsID, itemID: Self.itID, path: "Files")
        _ = try await engine.refreshFolder(key: key)

        let childKey = CacheKey(accountAlias: Self.alias, workspaceID: Self.wsID, itemID: Self.itID, path: "Files/data.csv")
        let childRow = try await store.fetch(key: childKey)
        // item_type is "" — the row is read-only until the next listItems + refreshFolder cycle.
        #expect(childRow.itemType == "", "missing discovery row must produce empty item_type (transient read-only)")
    }

    // MARK: - refreshFolder: created_ns preservation (issue-370)

    /// `convertRawEntry` (the only production path into `refreshFolder`) never
    /// populates `PathEntry.creationDate` — the DFS list schema has no
    /// creationTime field. `refreshFolder` therefore always sees
    /// `entry.creationDate == nil`, and the expression
    ///     `dateToNs(entry.creationDate) ?? cur?.createdNs ?? 0`
    /// collapses to `cur?.createdNs ?? 0`.
    ///
    /// This test routes through `convertRawEntry` (matching production) and
    /// verifies that a previously-captured `createdNs` value is preserved
    /// across a sync poll — i.e. refreshFolder does not overwrite a good
    /// `createdNs` with 0 on a no-content-change re-poll.
    @Test("refreshFolder() preserves existing created_ns when DFS list has no creationDate (production path via convertRawEntry)")
    func refreshFolderPreservesCreatedNsViaConvertRawEntry() async throws {
        let ol = MockOneLakeClient()
        let (engine, store) = try makeEngine(onelake: ol)
        defer { try? FileManager.default.removeItem(at: store.root) }

        let knownUnixSeconds: TimeInterval = 1_715_526_400 // 2024-05-12T20:53:20Z
        let knownCreatedNs = dateToNs(Date(timeIntervalSince1970: knownUnixSeconds))

        let parentKey = CacheKey(accountAlias: Self.alias, workspaceID: Self.wsID, itemID: Self.itID, path: "Files")
        let childPath = "Files/data.csv"
        let parent = MetadataRecord(
            accountAlias: Self.alias, workspaceID: Self.wsID, itemID: Self.itID,
            path: "Files", parentPath: "", name: "Files", isDir: true
        )
        var child = MetadataRecord(
            accountAlias: Self.alias, workspaceID: Self.wsID, itemID: Self.itID,
            path: childPath, parentPath: "Files", name: "data.csv", isDir: false,
            contentLength: 42, etag: "v1"
        )
        // A previously-captured real creation time (e.g. from a prior HEAD/GET).
        child.createdNs = knownCreatedNs
        // The cached row must also carry the matching lastModifiedNs so that
        // entryChanged does not fire due to a 0-vs-real lastModifiedNs mismatch —
        // the test is about createdNs stability, not lastModified.
        child.lastModifiedNs = dateToNs(Date(timeIntervalSince1970: knownUnixSeconds))
        try await store.upsert(parent)
        try await store.upsert(child)

        // Wire-level JSON with no creationTime field — matches the DFS Path-List
        // schema exactly; convertRawEntry will produce creationDate: nil.
        // The etag value is kept free of extra quotes so it round-trips to "v1",
        // matching the value seeded into the cache above.
        let json = """
        {"paths":[{"name":"item-1/Files/data.csv","contentLength":"42","etag":"v1","lastModified":"Sun, 12 May 2024 15:06:40 GMT"}]}
        """
        let rawList = try JSONDecoder().decode(RawListBody.self, from: Data(json.utf8))
        let entries = (rawList.paths ?? []).map { convertRawEntry($0, itemGUID: Self.itID) }
        // Verify this is the real production path: creationDate must be nil.
        #expect(entries.first?.creationDate == nil, "convertRawEntry must never produce a creationDate from list JSON")

        ol.listPathResults.append(.success(ListResult(entries: entries)))

        // No content change (same etag, same lastModifiedNs), so refreshFolder
        // carries cur?.createdNs forward. entryChanged only fires for the
        // 0→non-zero backfill trigger; here current.createdNs is already non-zero
        // and next.createdNs == 0 (convertRawEntry returns creationDate: nil), so
        // the poll is stable (diff.updated == 0).
        let diff = try await engine.refreshFolder(key: parentKey)
        #expect(diff.updated == 0, "unchanged row must not produce a spurious update")

        let stored = try await store.fetch(key: CacheKey(
            accountAlias: Self.alias, workspaceID: Self.wsID, itemID: Self.itID, path: childPath
        ))
        #expect(stored.createdNs == knownCreatedNs,
                "refreshFolder must not overwrite a good createdNs when DFS list has no creationDate")
    }

    /// After the one-time backfill (via open/put HEAD), subsequent DFS-list polls
    /// must not produce spurious updated counts.
    ///
    /// Note: `convertRawEntry` always yields `creationDate: nil`; the backfill
    /// itself is done by `open()` / `put()` via the x-ms-creation-time HEAD header.
    @Test("refreshFolder() does not re-update a row whose created_ns is already set (stable after HEAD backfill)")
    func refreshFolderNoSpuriousUpdateAfterBackfill() async throws {
        let ol = MockOneLakeClient()
        let (engine, store) = try makeEngine(onelake: ol)
        defer { try? FileManager.default.removeItem(at: store.root) }

        let knownUnixSeconds: TimeInterval = 1_715_526_400
        let knownCreatedNs = dateToNs(Date(timeIntervalSince1970: knownUnixSeconds))

        let parentKey = CacheKey(accountAlias: Self.alias, workspaceID: Self.wsID, itemID: Self.itID, path: "Files")
        let childPath = "Files/data.csv"
        let parent = MetadataRecord(
            accountAlias: Self.alias, workspaceID: Self.wsID, itemID: Self.itID,
            path: "Files", parentPath: "", name: "Files", isDir: true
        )
        var child = MetadataRecord(
            accountAlias: Self.alias, workspaceID: Self.wsID, itemID: Self.itID,
            path: childPath, parentPath: "Files", name: "data.csv", isDir: false,
            contentLength: 42, etag: "v1"
        )
        child.createdNs = knownCreatedNs // already-backfilled via HEAD
        try await store.upsert(parent)
        try await store.upsert(child)

        // Production-path list entry (no creationDate from convertRawEntry).
        ol.listPathResults.append(.success(ListResult(entries: [
            PathEntry(name: childPath, isDirectory: false, contentLength: 42,
                      eTag: "v1", lastModified: .distantPast),
        ])))

        let diff = try await engine.refreshFolder(key: parentKey)

        #expect(diff.updated == 0, "no spurious update once created_ns is already set")
        #expect(diff.added == 0)
        #expect(diff.removed == 0)
    }

    // MARK: - dateToNs (private duplicate): exact Int64.max boundary no longer traps

    /// `Double(Int64.max)` rounds *up* to exactly `2^63`, one past the actual
    /// `Int64.max`. A remote `lastModified` whose nanosecond value lands on that
    /// rounded boundary must not trap `Int64(ns)` inside `SyncEngine`'s private
    /// `dateToNs` duplicate — it must clamp to the "unknown" sentinel (`0`),
    /// same as the canonical helper.
    @Test("refreshFolder() does not trap on a remote lastModified at the Int64.max rounding boundary")
    func refreshFolderBoundaryLastModifiedDoesNotTrap() async throws {
        let ol = MockOneLakeClient()
        let (engine, store) = try makeEngine(onelake: ol)
        defer { try? FileManager.default.removeItem(at: store.root) }

        let dir = "Files"
        let key = CacheKey(accountAlias: Self.alias, workspaceID: Self.wsID, itemID: Self.itID, path: dir)

        let boundaryDate = Date(timeIntervalSince1970: Double(Int64.max) / 1_000_000_000)
        ol.listPathResults.append(.success(ListResult(entries: [
            PathEntry(name: "\(dir)/boundary.bin", isDirectory: false, contentLength: 10, eTag: "e1", lastModified: boundaryDate),
        ])))

        // Must not trap — that's the whole point of the test.
        let diff = try await engine.refreshFolder(key: key)
        #expect(diff.added == 1)

        let kids = try await store.children(of: key)
        let row = kids.first { $0.name == "boundary.bin" }
        #expect(row != nil)
        #expect(row?.lastModifiedNs == 0, "out-of-range lastModified must clamp to 0, not trap")
    }
}
