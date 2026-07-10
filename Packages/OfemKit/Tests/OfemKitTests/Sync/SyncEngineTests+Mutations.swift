import Foundation
@testable import OfemKit
import Testing

// MARK: - SyncEngine Mutations Tests

extension SyncEngineTests {
    // MARK: - Paused workspace guard: guardPaused throws before any network call

    @Test("put() throws workspacePaused immediately when workspace is paused")
    func pausedWorkspaceGuardBlocksPut() async throws {
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

        // Write a small temp file to use as source.
        let src = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".txt")
        try Data(repeating: 0xAB, count: 10).write(to: src)
        defer { try? FileManager.default.removeItem(at: src) }

        let key = Self.baseKey
        do {
            try await engine.put(key: key, sourceURL: src)
            Issue.record("Expected workspacePaused to be thrown")
        } catch SyncError.workspacePaused {
            // Correct.
        }
        #expect(ol.writeCalls.isEmpty)
    }

    @Test("delete() throws workspacePaused immediately when workspace is paused")
    func pausedWorkspaceGuardBlocksDelete() async throws {
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

        let key = Self.baseKey
        do {
            try await engine.delete(key: key)
            Issue.record("Expected workspacePaused to be thrown")
        } catch SyncError.workspacePaused {
            // Correct.
        }
        #expect(ol.deleteCalls.isEmpty)
    }

    @Test("mkdir() throws workspacePaused immediately when workspace is paused")
    func pausedWorkspaceGuardBlocksMkdir() async throws {
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

        let key = CacheKey(accountAlias: Self.alias, workspaceID: Self.wsID, itemID: Self.itID, path: "NewDir")
        do {
            try await engine.mkdir(key: key)
            Issue.record("Expected workspacePaused to be thrown")
        } catch SyncError.workspacePaused {
            // Correct.
        }
    }

    // MARK: - delete: error propagation and workspace-paused mapping

    @Test("delete() propagates network error when it is not a paused-capacity signal")
    func deletePropagatesNetworkError() async throws {
        let ol = MockOneLakeClient()
        let (engine, store) = try makeEngine(onelake: ol)
        defer { try? FileManager.default.removeItem(at: store.root) }

        let networkErr = URLError(.networkConnectionLost)
        ol.deleteResults.append(.failure(OneLakeError.httpError(networkErr)))

        let key = Self.baseKey
        // tests-11: assert the concrete error type — any throw is not enough.
        do {
            try await engine.delete(key: key)
            Issue.record("Expected OneLakeError.httpError to be rethrown")
        } catch let err as OneLakeError {
            if case .httpError = err {
                // Correct — network error propagated as-is.
            } else {
                Issue.record("Expected .httpError, got \(err)")
            }
        } catch {
            Issue.record("Expected OneLakeError, got \(type(of: error)): \(error)")
        }
    }

    @Test("delete() marks workspace paused and throws workspacePaused on capacity error")
    func deleteMarksPausedOnCapacityError() async throws {
        let ol = MockOneLakeClient()
        let (engine, store) = try makeEngine(onelake: ol)
        defer { try? FileManager.default.removeItem(at: store.root) }

        let apiBody = #"{"errorCode":"CapacityPaused","message":"paused"}"#
        let apiErr = HTTPClientError.apiError(APIError(statusCode: 503, status: "503", body: try #require(apiBody.data(using: .utf8))))
        ol.deleteResults.append(.failure(OneLakeError.httpError(apiErr)))

        let key = Self.baseKey
        do {
            try await engine.delete(key: key)
            Issue.record("Expected workspacePaused")
        } catch SyncError.workspacePaused {
            // Correct.
        }
        let status = try? await store.workspaceStatus(accountAlias: Self.alias, workspaceID: Self.wsID)
        #expect(status?.state == .paused)
    }

    // MARK: - F14: a replayed DELETE that 404s is treated as success

    @Test("delete() treats a notFound error as success (replayed DELETE already committed)")
    func deleteTreatsNotFoundAsSuccess() async throws {
        let ol = MockOneLakeClient()
        let (engine, store) = try makeEngine(onelake: ol)
        defer { try? FileManager.default.removeItem(at: store.root) }

        // Seed a cache row so we can assert it is cleared on the success path.
        let key = Self.baseKey
        try await store.upsert(MetadataRecord(
            accountAlias: Self.alias, workspaceID: Self.wsID, itemID: Self.itID,
            path: Self.path, parentPath: "Files", name: "data.csv", isDir: false
        ))

        // DELETE is retryable in SessionPool; if the delete already committed
        // server-side and the ack was lost, the replay 404s. The row is gone
        // either way, so this must not surface as delete_failed.
        ol.deleteResults.append(.failure(OneLakeError.notFound))

        try await engine.delete(key: key)

        let cached = try? await store.fetch(key: key)
        #expect(cached == nil)
    }

    // MARK: - macOS metadata: put and delete with .DS_Store / ._* paths

    @Test("put() silently ignores .DS_Store uploads (no network call)")
    func putIgnoresDSStore() async throws {
        let ol = MockOneLakeClient()
        let (engine, store) = try makeEngine(onelake: ol)
        defer { try? FileManager.default.removeItem(at: store.root) }

        let src = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".txt")
        try Data(repeating: 0xFF, count: 4).write(to: src)
        defer { try? FileManager.default.removeItem(at: src) }

        let key = CacheKey(accountAlias: Self.alias, workspaceID: Self.wsID, itemID: Self.itID, path: ".DS_Store")
        // Must not throw and must not call onelake.write.
        try await engine.put(key: key, sourceURL: src)
        #expect(ol.writeCalls.isEmpty)
    }

    @Test("put() silently ignores AppleDouble (._*) uploads")
    func putIgnoresAppleDouble() async throws {
        let ol = MockOneLakeClient()
        let (engine, store) = try makeEngine(onelake: ol)
        defer { try? FileManager.default.removeItem(at: store.root) }

        let src = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try Data(repeating: 0x01, count: 8).write(to: src)
        defer { try? FileManager.default.removeItem(at: src) }

        let key = CacheKey(accountAlias: Self.alias, workspaceID: Self.wsID, itemID: Self.itID, path: "._myfile.txt")
        try await engine.put(key: key, sourceURL: src)
        #expect(ol.writeCalls.isEmpty)
    }

    @Test("delete() on .DS_Store only deletes from cache, no remote call")
    func deleteDSStoreLocalOnly() async throws {
        let ol = MockOneLakeClient()
        let (engine, store) = try makeEngine(onelake: ol)
        defer { try? FileManager.default.removeItem(at: store.root) }

        // Seed the cache with a .DS_Store entry.
        let key = CacheKey(accountAlias: Self.alias, workspaceID: Self.wsID, itemID: Self.itID, path: ".DS_Store")
        let record = MetadataRecord(
            accountAlias: Self.alias,
            workspaceID: Self.wsID,
            itemID: Self.itID,
            path: ".DS_Store",
            parentPath: "",
            name: ".DS_Store",
            isDir: false
        )
        try await store.upsert(record)

        try await engine.delete(key: key)

        // No remote delete call.
        #expect(ol.deleteCalls.isEmpty)
        // Row removed from cache.
        let fetched = try? await store.fetch(key: key)
        #expect(fetched == nil)
    }

    // MARK: - mkdir: error propagation

    @Test("mkdir() propagates network error")
    func mkdirPropagatesNetworkError() async throws {
        let ol = MockOneLakeClient()
        let (engine, store) = try makeEngine(onelake: ol)
        defer { try? FileManager.default.removeItem(at: store.root) }

        let networkErr = URLError(.networkConnectionLost)
        ol.createDirectoryResults.append(.failure(OneLakeError.httpError(networkErr)))

        let key = CacheKey(accountAlias: Self.alias, workspaceID: Self.wsID, itemID: Self.itID, path: "NewDir")
        // tests-11: assert the concrete error type, not just that something threw.
        do {
            try await engine.mkdir(key: key)
            Issue.record("Expected OneLakeError.httpError to be rethrown")
        } catch let err as OneLakeError {
            if case .httpError = err {
                // Correct — network error propagated as-is.
            } else {
                Issue.record("Expected .httpError, got \(err)")
            }
        } catch {
            Issue.record("Expected OneLakeError, got \(type(of: error)): \(error)")
        }
    }

    @Test("mkdir() marks workspace paused and throws workspacePaused on capacity error")
    func mkdirMarksPausedOnCapacityError() async throws {
        let ol = MockOneLakeClient()
        let (engine, store) = try makeEngine(onelake: ol)
        defer { try? FileManager.default.removeItem(at: store.root) }

        let apiBody = #"{"errorCode":"CapacityPaused","message":"paused"}"#
        let apiErr = HTTPClientError.apiError(APIError(statusCode: 503, status: "503", body: try #require(apiBody.data(using: .utf8))))
        ol.createDirectoryResults.append(.failure(OneLakeError.httpError(apiErr)))

        let key = CacheKey(accountAlias: Self.alias, workspaceID: Self.wsID, itemID: Self.itID, path: "NewDir")
        do {
            try await engine.mkdir(key: key)
            Issue.record("Expected workspacePaused")
        } catch SyncError.workspacePaused {
            // Correct.
        }
        let status = try? await store.workspaceStatus(accountAlias: Self.alias, workspaceID: Self.wsID)
        #expect(status?.state == .paused)
    }

    @Test("mkdir() succeeds and upserts a directory row in the cache")
    func mkdirUpsertsCacheRow() async throws {
        let ol = MockOneLakeClient()
        let (engine, store) = try makeEngine(onelake: ol)
        defer { try? FileManager.default.removeItem(at: store.root) }

        ol.createDirectoryResults.append(.success(()))

        let key = CacheKey(accountAlias: Self.alias, workspaceID: Self.wsID, itemID: Self.itID, path: "NewDir")
        try await engine.mkdir(key: key)

        let row = try? await store.fetch(key: key)
        #expect(row != nil)
        #expect(row?.isDir == true)
        #expect(row?.name == "NewDir")
    }

    // MARK: - put: success path upserts cache and mirrors blob

    @Test("put() success upserts a file row in the cache with correct path")
    func putSuccessUpsertsCacheRow() async throws {
        let ol = MockOneLakeClient()
        let (engine, store) = try makeEngine(onelake: ol)
        defer { try? FileManager.default.removeItem(at: store.root) }

        let src = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".csv")
        let fileData = Data(repeating: 0xCC, count: 128)
        try fileData.write(to: src)
        defer { try? FileManager.default.removeItem(at: src) }

        ol.writeResults.append(.success(()))
        // Best-effort HEAD after write — engine uses try? so stub not needed;
        // but we add one so the etag is captured.
        let postWriteProps = PathProperties.make(contentLength: 128, eTag: "server-etag")
        ol.getPropertiesResults.append(.success(postWriteProps))

        let key = Self.baseKey
        try await engine.put(key: key, sourceURL: src)

        let row = try? await store.fetch(key: key)
        #expect(row != nil)
        #expect(row?.isDir == false)
        #expect(row?.etag == "server-etag")
        #expect(row?.contentLength == 128)
    }

    @Test("put() propagates write failure")
    func putPropagatesWriteError() async throws {
        let ol = MockOneLakeClient()
        let (engine, store) = try makeEngine(onelake: ol)
        defer { try? FileManager.default.removeItem(at: store.root) }

        let src = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".csv")
        try Data(repeating: 0x42, count: 10).write(to: src)
        defer { try? FileManager.default.removeItem(at: src) }

        let networkErr = URLError(.networkConnectionLost)
        ol.writeResults.append(.failure(OneLakeError.httpError(networkErr)))

        let key = Self.baseKey
        // tests-11: assert the concrete error type, not just that something threw.
        do {
            try await engine.put(key: key, sourceURL: src)
            Issue.record("Expected OneLakeError.httpError to be rethrown")
        } catch let err as OneLakeError {
            if case .httpError = err {
                // Correct — write error propagated as-is.
            } else {
                Issue.record("Expected .httpError, got \(err)")
            }
        } catch {
            Issue.record("Expected OneLakeError, got \(type(of: error)): \(error)")
        }
    }

    // MARK: - delete: uses recursive=true for directories

    @Test("delete() passes recursive=true when the cache row is a directory")
    func deleteDirectoryUsesRecursiveTrue() async throws {
        let ol = MockOneLakeClient()
        let (engine, store) = try makeEngine(onelake: ol)
        defer { try? FileManager.default.removeItem(at: store.root) }

        // Seed a directory row.
        let key = CacheKey(accountAlias: Self.alias, workspaceID: Self.wsID, itemID: Self.itID, path: "MyDir")
        let record = MetadataRecord(
            accountAlias: Self.alias, workspaceID: Self.wsID, itemID: Self.itID,
            path: "MyDir", parentPath: "", name: "MyDir", isDir: true
        )
        try await store.upsert(record)

        ol.deleteResults.append(.success(()))
        try await engine.delete(key: key)

        #expect(ol.deleteCalls.count == 1)
        #expect(ol.deleteCalls[0].recursive == true)
    }

    @Test("delete() passes recursive=false when the cache row is a file")
    func deleteFileUsesRecursiveFalse() async throws {
        let ol = MockOneLakeClient()
        let (engine, store) = try makeEngine(onelake: ol)
        defer { try? FileManager.default.removeItem(at: store.root) }

        // Seed a file row.
        let key = Self.baseKey
        let record = MetadataRecord(
            accountAlias: Self.alias, workspaceID: Self.wsID, itemID: Self.itID,
            path: Self.path, parentPath: "Files", name: "data.csv", isDir: false
        )
        try await store.upsert(record)

        ol.deleteResults.append(.success(()))
        try await engine.delete(key: key)

        #expect(ol.deleteCalls.count == 1)
        #expect(ol.deleteCalls[0].recursive == false)
    }

    @Test("delete() uses recursive=true when no cache row exists (unknown type)")
    func deleteUnknownTypeUsesRecursiveTrue() async throws {
        let ol = MockOneLakeClient()
        let (engine, store) = try makeEngine(onelake: ol)
        defer { try? FileManager.default.removeItem(at: store.root) }

        // No cache row for this key.
        ol.deleteResults.append(.success(()))
        let key = Self.baseKey
        try await engine.delete(key: key)

        #expect(ol.deleteCalls.count == 1)
        #expect(ol.deleteCalls[0].recursive == true)
    }

    // MARK: - put / mkdir: item_type propagated from parent cache row

    @Test("put() carries item_type from parent directory row into the upserted file row")
    func putCarriesItemTypeFromParent() async throws {
        let ol = MockOneLakeClient()
        let (engine, store) = try makeEngine(onelake: ol)
        defer { try? FileManager.default.removeItem(at: store.root) }

        // Pre-seed parent directory row with Lakehouse item_type.
        let parentRow = MetadataRecord(
            accountAlias: Self.alias, workspaceID: Self.wsID,
            itemID: Self.itID, path: "Files", parentPath: "",
            name: "Files", isDir: true, itemType: "Lakehouse"
        )
        try await store.upsert(parentRow)

        let src = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".csv")
        try Data(repeating: 0xAB, count: 64).write(to: src)
        defer { try? FileManager.default.removeItem(at: src) }

        ol.writeResults.append(.success(()))
        ol.getPropertiesResults.append(.success(PathProperties.make(contentLength: 64, eTag: "etag1")))

        let key = CacheKey(accountAlias: Self.alias, workspaceID: Self.wsID, itemID: Self.itID, path: "Files/data.csv")
        try await engine.put(key: key, sourceURL: src)

        let row = try await store.fetch(key: key)
        #expect(row.itemType == "Lakehouse", "put() must carry Lakehouse item_type so the file is immediately writable")
    }

    @Test("mkdir() carries item_type from parent directory row into the upserted directory row")
    func mkdirCarriesItemTypeFromParent() async throws {
        let ol = MockOneLakeClient()
        let (engine, store) = try makeEngine(onelake: ol)
        defer { try? FileManager.default.removeItem(at: store.root) }

        // Pre-seed parent directory row with Lakehouse item_type.
        let parentRow = MetadataRecord(
            accountAlias: Self.alias, workspaceID: Self.wsID,
            itemID: Self.itID, path: "Files", parentPath: "",
            name: "Files", isDir: true, itemType: "Lakehouse"
        )
        try await store.upsert(parentRow)

        ol.createDirectoryResults.append(.success(()))

        let key = CacheKey(accountAlias: Self.alias, workspaceID: Self.wsID, itemID: Self.itID, path: "Files/NewDir")
        try await engine.mkdir(key: key)

        let row = try await store.fetch(key: key)
        #expect(row.itemType == "Lakehouse", "mkdir() must carry Lakehouse item_type so the new directory is immediately writable")
    }

    // MARK: - put: created_ns preserved on HEAD failure (finding #1)

    /// When the post-upload HEAD fails, `put()` must not overwrite a
    /// previously-captured `createdNs` with 0. This mirrors the symmetric guard
    /// in `performDownload` (`cached?.createdNs ?? 0`).
    @Test("put() preserves existing createdNs when post-upload HEAD fails")
    func putPreservesCreatedNsOnHeadFailure() async throws {
        let ol = MockOneLakeClient()
        let (engine, store) = try makeEngine(onelake: ol)
        defer { try? FileManager.default.removeItem(at: store.root) }

        let knownUnixSeconds: TimeInterval = 1_715_526_400
        let knownCreatedNs = dateToNs(Date(timeIntervalSince1970: knownUnixSeconds))

        // Pre-seed cache row with a real creation time captured by a prior open().
        var existing = MetadataRecord(
            accountAlias: Self.alias, workspaceID: Self.wsID, itemID: Self.itID,
            path: Self.path, parentPath: "Files", name: "data.csv", isDir: false,
            contentLength: 10, etag: "old-etag"
        )
        existing.createdNs = knownCreatedNs
        try await store.upsert(existing)

        let src = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".csv")
        try Data(repeating: 0xAB, count: 10).write(to: src)
        defer { try? FileManager.default.removeItem(at: src) }

        ol.writeResults.append(.success(()))
        // HEAD fails — the row is written with createdNs carried forward from cache.
        ol.getPropertiesResults.append(.failure(URLError(.networkConnectionLost)))

        let key = Self.baseKey
        try await engine.put(key: key, sourceURL: src)

        let row = try await store.fetch(key: key)
        #expect(row.createdNs == knownCreatedNs,
                "put() must not overwrite a good createdNs with 0 when HEAD fails")
    }

    // MARK: - dateToNs: far-future date returns nil, not Optional(0) (finding #2)

    /// A far-future `x-ms-creation-time` (outside Int64 range) must not silently
    /// zero a good `createdNs`. `dateToNs` must return `nil` for overflow dates
    /// so `flatMap { dateToNs($0) } ?? cached?.createdNs ?? 0` falls through to
    /// the carried value rather than landing on `Optional(0)`.
    @Test("dateToNs returns nil for distantFuture, allowing cached createdNs fallback to apply")
    func dateToNsDistantFutureReturnsNilNotOptionalZero() async throws {
        let ol = MockOneLakeClient()
        let (engine, store) = try makeEngine(onelake: ol)
        defer { try? FileManager.default.removeItem(at: store.root) }

        let knownUnixSeconds: TimeInterval = 1_715_526_400
        let knownCreatedNs = dateToNs(Date(timeIntervalSince1970: knownUnixSeconds))

        // Pre-seed with a real creation time.
        var existing = MetadataRecord(
            accountAlias: Self.alias, workspaceID: Self.wsID, itemID: Self.itID,
            path: Self.path, parentPath: "Files", name: "data.csv", isDir: false,
            contentLength: 10, etag: "v1"
        )
        existing.createdNs = knownCreatedNs
        try await store.upsert(existing)

        let src = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".csv")
        try Data(repeating: 0xAB, count: 10).write(to: src)
        defer { try? FileManager.default.removeItem(at: src) }

        ol.writeResults.append(.success(()))
        // HEAD returns a far-future creation date that overflows Int64 nanoseconds.
        let farFutureProps = PathProperties(
            isDirectory: false, contentLength: 10, eTag: "v2",
            lastModified: Date(), contentType: "text/csv",
            creationDate: .distantFuture
        )
        ol.getPropertiesResults.append(.success(farFutureProps))

        let key = Self.baseKey
        try await engine.put(key: key, sourceURL: src)

        let row = try await store.fetch(key: key)
        #expect(row.createdNs == knownCreatedNs,
                "overflow creation date must not clobber a good cached createdNs")
    }
}
