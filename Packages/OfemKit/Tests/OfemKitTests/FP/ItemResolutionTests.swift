import Foundation
@testable import OfemKit
import Testing

// MARK: - ItemResolution tests (F8 + S4)

//
// Exercises `ItemResolution.resolveItem` / `.createItem` and
// `SyncEngine.resolveItemType(for:)` against a real `SyncEngine` + `CacheStore`
// built from the shared mocks. These paths moved out of the FPE
// (`engineFetchItem` / `engineCreateItem`) into OfemKit; the tests pin the
// behaviour parity that move must preserve.

@Suite("ItemResolution")
struct ItemResolutionTests {
    // MARK: - Fixtures

    private static let alias = "test"
    private static let wsID = "ws-1"
    private static let itID = "item-1"

    /// Builds a real `SyncEngine` + `CacheStore` from the given mocks. The
    /// scratch dir is nested under `store.root` so one `removeItem(at:root)`
    /// cleans both (tests-07).
    private func makeEngine(
        onelake: any OneLakeClientProtocol,
        fabric: MockFabricClient = MockFabricClient()
    ) throws -> (SyncEngine, CacheStore) {
        let store = try makeTempStore()
        let scratchDir = store.root.appending(path: "scratch", directoryHint: .isDirectory)
        let engine = SyncEngine(
            cache: store,
            onelake: onelake,
            fabric: fabric,
            scratchBase: scratchDir,
            blobFreshnessTTL: .zero
        )
        return (engine, store)
    }

    private func fileRow(
        path: String,
        itemType: String = "",
        isDir: Bool = false
    ) -> MetadataRecord {
        MetadataRecord(
            accountAlias: Self.alias,
            workspaceID: Self.wsID,
            itemID: Self.itID,
            path: path,
            parentPath: Enumerator.parentPath(path),
            name: Enumerator.baseName(path),
            isDir: isDir,
            contentLength: isDir ? 0 : 100,
            etag: isDir ? "" : "\"v1\"",
            itemType: itemType
        )
    }

    // MARK: - resolveItem: path cache-hit → zero network

    @Test("resolveItem .path cache hit resolves without any network call")
    func pathCacheHitZeroNetwork() async throws {
        let ol = MockOneLakeClient()
        let fabric = MockFabricClient()
        let (engine, store) = try makeEngine(onelake: ol, fabric: fabric)
        defer { try? FileManager.default.removeItem(at: store.root) }

        let path = "Files/data.csv"
        try await store.upsert(fileRow(path: path))

        let di = try await ItemResolution.resolveItem(
            identifier: .path(workspaceID: Self.wsID, itemID: Self.itID, path: path),
            alias: Self.alias, sync: engine, cache: store
        )

        #expect(di.identifier == .path(workspaceID: Self.wsID, itemID: Self.itID, path: path))
        // Zero network: no listing, no HEAD, no download, no Fabric lookup.
        #expect(ol.listPathCalls.isEmpty)
        #expect(ol.getPropertiesCalls.isEmpty)
        #expect(ol.readCalls.isEmpty)
        #expect(fabric.listAllItemsCallCount == 0)
    }

    // MARK: - resolveItem: miss → enumerate parent → retry-hit

    @Test("resolveItem .path miss enumerates parent then resolves on retry")
    func pathMissEnumeratesThenResolves() async throws {
        let ol = MockOneLakeClient()
        let (engine, store) = try makeEngine(onelake: ol)
        defer { try? FileManager.default.removeItem(at: store.root) }

        // The DFS listing returns entries whose `name` is the full path relative
        // to the item root, so the child of "Files" is "Files/data.csv".
        ol.listPathResults.append(.success(ListResult(entries: [
            PathEntry(name: "Files/data.csv", isDirectory: false, contentLength: 10,
                      eTag: "e1", lastModified: Date(timeIntervalSince1970: 0)),
        ])))

        let di = try await ItemResolution.resolveItem(
            identifier: .path(workspaceID: Self.wsID, itemID: Self.itID, path: "Files/data.csv"),
            alias: Self.alias, sync: engine, cache: store
        )

        #expect(di.identifier == .path(workspaceID: Self.wsID, itemID: Self.itID, path: "Files/data.csv"))
        // Exactly one parent enumeration (the miss → enumerate → retry cycle).
        #expect(ol.listPathCalls.count == 1)
        #expect(ol.listPathCalls.first?.directory == "Files")
    }

    // MARK: - resolveItem: miss after enumerate → noSuchItem

    @Test("resolveItem .path still absent after enumerate throws noSuchItem")
    func pathMissAfterEnumerateThrowsNoSuchItem() async throws {
        let ol = MockOneLakeClient()
        let (engine, store) = try makeEngine(onelake: ol)
        defer { try? FileManager.default.removeItem(at: store.root) }

        // Parent lists successfully but does NOT contain the requested child.
        ol.listPathResults.append(.success(ListResult(entries: [])))

        do {
            _ = try await ItemResolution.resolveItem(
                identifier: .path(workspaceID: Self.wsID, itemID: Self.itID, path: "Files/gone.csv"),
                alias: Self.alias, sync: engine, cache: store
            )
            Issue.record("expected resolveItem to throw")
        } catch let error as FPError {
            guard case .noSuchItem = error else {
                Issue.record("expected .noSuchItem, got \(error)")
                return
            }
        }
    }

    // MARK: - resolveItem: non-notFound cache error → invalidRecord (NOT noSuchItem)

    @Test("resolveItem maps a non-notFound cache error to invalidRecord, not noSuchItem")
    func pathNonNotFoundCacheErrorMapsToInvalidRecord() async throws {
        let ol = MockOneLakeClient()
        let (engine, store) = try makeEngine(onelake: ol)
        defer { try? FileManager.default.removeItem(at: store.root) }

        // An empty itemID makes `CacheStore.fetch` reject the key with
        // `CacheError.missingArgument` (a non-notFound cache error) — the same
        // shape as a transient DB blip. It must surface as `.invalidRecord`
        // (→ cannotSynchronize), never `.noSuchItem` (a deletion signal), and
        // must NOT fall through to a parent enumeration.
        do {
            _ = try await ItemResolution.resolveItem(
                identifier: .path(workspaceID: Self.wsID, itemID: "", path: "Files/x.csv"),
                alias: Self.alias, sync: engine, cache: store
            )
            Issue.record("expected resolveItem to throw")
        } catch let error as FPError {
            guard case .invalidRecord = error else {
                Issue.record("expected .invalidRecord, got \(error)")
                return
            }
        }
        #expect(ol.listPathCalls.isEmpty)
    }

    // MARK: - createItem: mayAlreadyExist + existing row → no write

    @Test("createItem mayAlreadyExist returns the existing row without uploading")
    func createItemMayAlreadyExistSkipsUpload() async throws {
        let ol = MockOneLakeClient()
        let (engine, store) = try makeEngine(onelake: ol)
        defer { try? FileManager.default.removeItem(at: store.root) }

        let path = "Files/exists.txt"
        try await store.upsert(fileRow(path: path))

        let di = try await ItemResolution.createItem(
            parent: .path(workspaceID: Self.wsID, itemID: Self.itID, path: "Files"),
            filename: "exists.txt",
            isDirectory: false,
            uploadSource: URL(fileURLWithPath: "/nonexistent/never-read"),
            mayAlreadyExist: true,
            alias: Self.alias, sync: engine, cache: store
        )

        #expect(di.identifier == .path(workspaceID: Self.wsID, itemID: Self.itID, path: path))
        // .mayAlreadyExist re-import must not upload or mkdir over the existing item.
        #expect(ol.writeCalls.isEmpty)
        #expect(ol.createDirectoryCalls.isEmpty)
    }

    // MARK: - createItem: directory → mkdir + cache row

    @Test("createItem directory issues one mkdir and persists a directory row")
    func createItemDirectoryMkdirsAndRows() async throws {
        let ol = MockOneLakeClient()
        ol.createDirectoryResults.append(.success(()))
        let (engine, store) = try makeEngine(onelake: ol)
        defer { try? FileManager.default.removeItem(at: store.root) }

        let di = try await ItemResolution.createItem(
            parent: .path(workspaceID: Self.wsID, itemID: Self.itID, path: "Files"),
            filename: "newdir",
            isDirectory: true,
            uploadSource: nil,
            mayAlreadyExist: false,
            alias: Self.alias, sync: engine, cache: store
        )

        #expect(di.identifier == .path(workspaceID: Self.wsID, itemID: Self.itID, path: "Files/newdir"))
        #expect(di.isDirectory)
        #expect(ol.createDirectoryCalls.count == 1)
        #expect(ol.createDirectoryCalls.first?.path == "Files/newdir")
        #expect(ol.writeCalls.isEmpty)
        // mkdir upserts the directory row, so the post-create fetch resolves a
        // real (non-synthetic) item.
        let row = try await store.fetch(key: CacheKey(
            accountAlias: Self.alias, workspaceID: Self.wsID, itemID: Self.itID, path: "Files/newdir"
        ))
        #expect(row.isDir)
    }

    // MARK: - createItem: synthetic fallback carries the parent's item type

    @Test("createItem synthetic fallback carries the parent directory item type")
    func createItemSyntheticFallbackCarriesParentItemType() async throws {
        let ol = MockOneLakeClient()
        let (engine, store) = try makeEngine(onelake: ol)
        defer { try? FileManager.default.removeItem(at: store.root) }

        // Seed the item-discovery row so refreshFolder resolves the folder's
        // item type as "Lakehouse" (VirtualIDs.itemID row, path == item GUID).
        try await store.upsert(MetadataRecord(
            accountAlias: Self.alias, workspaceID: Self.wsID, itemID: VirtualIDs.itemID,
            path: Self.itID, parentPath: "", name: Self.itID, isDir: true,
            itemType: "Lakehouse"
        ))
        // The parent enumeration lists no children, so the placeholder create
        // finds no row afterwards and lands on the synthetic fallback.
        ol.listPathResults.append(.success(ListResult(entries: [])))

        // Placeholder file create (no contents, not mayAlreadyExist): no upload,
        // no mkdir → post-create fetch misses → enumerate parent → retry miss →
        // synthetic fallback.
        let di = try await ItemResolution.createItem(
            parent: .path(workspaceID: Self.wsID, itemID: Self.itID, path: "Files"),
            filename: "new.txt",
            isDirectory: false,
            uploadSource: nil,
            mayAlreadyExist: false,
            alias: Self.alias, sync: engine, cache: store
        )

        #expect(di.identifier == .path(workspaceID: Self.wsID, itemID: Self.itID, path: "Files/new.txt"))
        #expect(ol.writeCalls.isEmpty)
        #expect(ol.createDirectoryCalls.isEmpty)
        // The synthetic item carries the parent's "Lakehouse" type, so a Files/
        // file is writable — not the read-only default an empty type would give.
        let expected = DomainItem.synthetic(
            identifier: .path(workspaceID: Self.wsID, itemID: Self.itID, path: "Files/new.txt"),
            parentIdentifier: .path(workspaceID: Self.wsID, itemID: Self.itID, path: "Files"),
            name: "new.txt", isDirectory: false, itemType: "Lakehouse"
        ).capabilities
        #expect(di.capabilities == expected)
        #expect(di.capabilities == DomainItem.CapabilitySet.writableFile)
    }

    // MARK: - SyncEngine.resolveItemType: own / parent / empty

    @Test("resolveItemType prefers the row's own item type")
    func resolveItemTypeOwn() async throws {
        let (engine, store) = try makeEngine(onelake: MockOneLakeClient())
        defer { try? FileManager.default.removeItem(at: store.root) }

        try await store.upsert(fileRow(path: "Files/f.csv", itemType: "Warehouse"))
        let key = CacheKey(accountAlias: Self.alias, workspaceID: Self.wsID, itemID: Self.itID, path: "Files/f.csv")
        let resolved = await engine.resolveItemType(for: key)
        #expect(resolved == "Warehouse")
    }

    @Test("resolveItemType falls back to the parent directory's item type")
    func resolveItemTypeParent() async throws {
        let (engine, store) = try makeEngine(onelake: MockOneLakeClient())
        defer { try? FileManager.default.removeItem(at: store.root) }

        // No row for the child; the parent directory carries the type.
        try await store.upsert(fileRow(path: "Files", itemType: "Lakehouse", isDir: true))
        let key = CacheKey(accountAlias: Self.alias, workspaceID: Self.wsID, itemID: Self.itID, path: "Files/child.csv")
        let resolved = await engine.resolveItemType(for: key)
        #expect(resolved == "Lakehouse")
    }

    @Test("resolveItemType returns empty when neither row nor parent is cached")
    func resolveItemTypeEmpty() async throws {
        let (engine, store) = try makeEngine(onelake: MockOneLakeClient())
        defer { try? FileManager.default.removeItem(at: store.root) }

        let key = CacheKey(accountAlias: Self.alias, workspaceID: Self.wsID, itemID: Self.itID, path: "Files/orphan.csv")
        let resolved = await engine.resolveItemType(for: key)
        #expect(resolved == "")
    }

    // MARK: - parentPath substitution equivalence (F8 pin)

    /// Pins the substitution of the removed FPE `parentPath(of:)` helper by
    /// `Enumerator.parentPath`. Identifier paths never carry a trailing slash,
    /// so the two are equivalent for every input the FPE fed the old helper —
    /// these are exactly the cases its own tests asserted.
    @Test("Enumerator.parentPath matches the removed FPE parentPath(of:) for identifier paths")
    func parentPathSubstitutionEquivalence() {
        #expect(Enumerator.parentPath("Files/raw/2024/sales.csv") == "Files/raw/2024")
        #expect(Enumerator.parentPath("Files") == "")
        #expect(Enumerator.parentPath("") == "")
        #expect(Enumerator.parentPath("a/b") == "a")
        #expect(Enumerator.parentPath("a/b/c/d") == "a/b/c")
    }
}
