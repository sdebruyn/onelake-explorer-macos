import Foundation
import Testing

@testable import OfemKit

// MARK: - MaterializedContainersTests

/// Tests for the materialized-container cache: migration, writer, and reader.
@Suite("MaterializedContainers")
struct MaterializedContainersTests {

    // MARK: - Schema

    @Test("v4 migration creates materialized_containers table")
    func v4MigrationCreatesTable() async throws {
        let store = try makeTempStore()
        defer { try? FileManager.default.removeItem(at: store.root) }
        let exists = try await store.tableExists("materialized_containers")
        #expect(exists)
    }

    @Test("v4 migration creates idx_mc_alias index")
    func v4MigrationCreatesIndex() async throws {
        let store = try makeTempStore()
        defer { try? FileManager.default.removeItem(at: store.root) }
        let indexes = try await store.indexes(on: "materialized_containers")
        #expect(indexes.contains("idx_mc_alias"))
    }

    @Test("fresh database lists v4 in applied migrations")
    func v4ListedInAppliedMigrations() async throws {
        let store = try makeTempStore()
        defer { try? FileManager.default.removeItem(at: store.root) }
        let applied = try await store.appliedMigrations()
        #expect(applied.contains("v4"))
    }

    // MARK: - setMaterialized / materializedContainers round-trip

    @Test("empty identifiers produces empty result")
    func emptyIdentifiersProducesEmptyResult() async throws {
        let store = try makeTempStore()
        defer { try? FileManager.default.removeItem(at: store.root) }
        try await store.setMaterialized(alias: "work", identifiers: [])
        let keys = try await store.reader().materializedContainers(alias: "work")
        #expect(keys.isEmpty)
    }

    @Test("item identifier round-trips to CacheKey")
    func itemIdentifierRoundTrips() async throws {
        let store = try makeTempStore()
        defer { try? FileManager.default.removeItem(at: store.root) }
        // .item identifier string: "<wsID>/<itemID>"
        let wsID = "ws-aaa"
        let itemID = "item-bbb"
        let identStr = "\(wsID)/\(itemID)"
        try await store.setMaterialized(alias: "work", identifiers: [identStr])
        let keys = try await store.reader().materializedContainers(alias: "work")
        #expect(keys.count == 1)
        let key = try #require(keys.first)
        #expect(key.accountAlias == "work")
        #expect(key.workspaceID == wsID)
        #expect(key.itemID == itemID)
        #expect(key.path == "")
    }

    @Test("path identifier round-trips to CacheKey")
    func pathIdentifierRoundTrips() async throws {
        let store = try makeTempStore()
        defer { try? FileManager.default.removeItem(at: store.root) }
        let wsID = "ws-111"
        let itemID = "item-222"
        let path = "Files/reports"
        let identStr = "\(wsID)/\(itemID)/\(path)"
        try await store.setMaterialized(alias: "work", identifiers: [identStr])
        let keys = try await store.reader().materializedContainers(alias: "work")
        #expect(keys.count == 1)
        let key = try #require(keys.first)
        #expect(key.accountAlias == "work")
        #expect(key.workspaceID == wsID)
        #expect(key.itemID == itemID)
        #expect(key.path == path)
    }

    @Test("workspace identifier maps to VirtualIDs.itemID CacheKey")
    func workspaceIdentifierMapsToVirtualKey() async throws {
        let store = try makeTempStore()
        defer { try? FileManager.default.removeItem(at: store.root) }
        let wsID = "ws-333"
        // .workspace identifier string is just the workspace ID
        try await store.setMaterialized(alias: "work", identifiers: [wsID])
        let keys = try await store.reader().materializedContainers(alias: "work")
        #expect(keys.count == 1)
        let key = try #require(keys.first)
        #expect(key.workspaceID == wsID)
        #expect(key.itemID == VirtualIDs.itemID)
        #expect(key.path == "")
    }

    @Test("setMaterialized is a full replace for the alias")
    func setMaterializedIsFullReplace() async throws {
        let store = try makeTempStore()
        defer { try? FileManager.default.removeItem(at: store.root) }
        let first = ["ws-1/item-1", "ws-2/item-2"]
        let second = ["ws-3/item-3"]
        try await store.setMaterialized(alias: "work", identifiers: first)
        try await store.setMaterialized(alias: "work", identifiers: second)
        let keys = try await store.reader().materializedContainers(alias: "work")
        #expect(keys.count == 1)
        #expect(keys[0].workspaceID == "ws-3")
        #expect(keys[0].itemID == "item-3")
    }

    @Test("setMaterialized does not affect other aliases")
    func setMaterializedDoesNotAffectOtherAliases() async throws {
        let store = try makeTempStore()
        defer { try? FileManager.default.removeItem(at: store.root) }
        try await store.setMaterialized(alias: "work", identifiers: ["ws-1/item-1"])
        try await store.setMaterialized(alias: "home", identifiers: ["ws-2/item-2"])
        let workKeys = try await store.reader().materializedContainers(alias: "work")
        let homeKeys = try await store.reader().materializedContainers(alias: "home")
        #expect(workKeys.count == 1)
        #expect(workKeys[0].workspaceID == "ws-1")
        #expect(homeKeys.count == 1)
        #expect(homeKeys[0].workspaceID == "ws-2")
    }

    @Test("well-known sentinel identifiers are skipped")
    func sentinelIdentifiersAreSkipped() async throws {
        let store = try makeTempStore()
        defer { try? FileManager.default.removeItem(at: store.root) }
        // Root, trash, and working-set sentinels must be filtered out.
        // Store the raw strings directly to simulate unexpected values that
        // might appear from the OS.
        let rootStr = "NSFileProviderRootContainerItemIdentifier"
        let trashStr = "NSFileProviderTrashContainerItemIdentifier"
        let wsStr = "NSFileProviderWorkingSetContainerItemIdentifier"
        try await store.setMaterialized(
            alias: "work",
            identifiers: [rootStr, trashStr, wsStr]
        )
        let keys = try await store.reader().materializedContainers(alias: "work")
        // Root maps to .root → skipped. Trash and workingSet likewise.
        #expect(keys.isEmpty)
    }

    @Test("unparseable identifier strings are skipped")
    func unparseableIdentifiersAreSkipped() async throws {
        let store = try makeTempStore()
        defer { try? FileManager.default.removeItem(at: store.root) }
        let bad = "/leading-slash-is-invalid"
        let good = "ws-ok/item-ok"
        try await store.setMaterialized(alias: "work", identifiers: [bad, good])
        let keys = try await store.reader().materializedContainers(alias: "work")
        // Only the valid .item identifier survives.
        #expect(keys.count == 1)
        #expect(keys[0].workspaceID == "ws-ok")
    }

    @Test("setMaterialized clears set when called with empty array")
    func setMaterializedClearsSet() async throws {
        let store = try makeTempStore()
        defer { try? FileManager.default.removeItem(at: store.root) }
        try await store.setMaterialized(alias: "work", identifiers: ["ws-1/item-1", "ws-2/item-2"])
        try await store.setMaterialized(alias: "work", identifiers: [])
        let keys = try await store.reader().materializedContainers(alias: "work")
        #expect(keys.isEmpty)
    }

    @Test("multiple identifiers all stored and retrieved")
    func multipleIdentifiersRoundTrip() async throws {
        let store = try makeTempStore()
        defer { try? FileManager.default.removeItem(at: store.root) }
        let identifiers = [
            "ws-a/item-1",
            "ws-a/item-2/Files/subdir",
            "ws-b",
        ]
        try await store.setMaterialized(alias: "corp", identifiers: identifiers)
        let keys = try await store.reader().materializedContainers(alias: "corp")
        // ws-b → workspace → VirtualIDs.itemID; ws-a/item-1 → .item; ws-a/item-2/... → .path
        #expect(keys.count == 3)
        let sortedWorkspaceIDs = keys.map(\.workspaceID).sorted()
        #expect(sortedWorkspaceIDs.contains("ws-a"))
        #expect(sortedWorkspaceIDs.contains("ws-b"))
    }
}
