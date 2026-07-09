import Foundation
@testable import OfemKit
import Testing

// MARK: - CacheStoreCaseSensitivityTests

/// Regression tests for #426.
///
/// SQLite's `LIKE` operator is ASCII-case-insensitive by default, but
/// OneLake paths are case-sensitive. Every subtree/prefix match in
/// `CacheStore` uses `LIKE` — ``CacheStore/delete(key:)``,
/// ``CacheStore/batchDelete(_:recordTombstones:)``,
/// ``CacheStore/renamePathPrefix(accountAlias:workspaceID:itemID:oldPath:newPath:newName:)``,
/// ``CacheStore/removeMaterialized(alias:identifierPrefix:)`` — so without
/// `PRAGMA case_sensitive_like = ON` (set once at connection open, see
/// `CacheStore.enableCaseSensitiveLike`) two siblings differing only in
/// ASCII case, e.g. `Reports/…` vs `reports/…`, would cross-match: an
/// operation on one would incorrectly touch the other's cached rows.
@Suite("CacheStore case-sensitive LIKE (#426)")
struct CacheStoreCaseSensitivityTests {
    private let alias = "a"
    private let ws = "w"
    private let item = "i"

    private func key(_ path: String) -> CacheKey {
        CacheKey(accountAlias: alias, workspaceID: ws, itemID: item, path: path)
    }

    private func dirRow(_ path: String) -> MetadataRecord {
        MetadataRecord(
            accountAlias: alias, workspaceID: ws, itemID: item,
            path: path, parentPath: "", name: path, isDir: true
        )
    }

    private func fileRow(_ path: String, parent: String) -> MetadataRecord {
        MetadataRecord(
            accountAlias: alias, workspaceID: ws, itemID: item,
            path: path, parentPath: parent,
            name: (path as NSString).lastPathComponent, isDir: false
        )
    }

    /// Seeds two sibling subtrees, `Reports/` and `reports/`, differing only
    /// in ASCII case, each with one child file.
    private func seedCaseSiblings(_ store: CacheStore) async throws {
        try await store.upsert(dirRow("Reports"))
        try await store.upsert(fileRow("Reports/a.txt", parent: "Reports"))
        try await store.upsert(dirRow("reports"))
        try await store.upsert(fileRow("reports/b.txt", parent: "reports"))
    }

    // MARK: - delete

    @Test("delete does not cross-match a sibling differing only in ASCII case")
    func deleteDoesNotCrossMatchCaseSibling() async throws {
        let store = try makeTempStore()
        defer { try? FileManager.default.removeItem(at: store.root) }
        try await seedCaseSiblings(store)

        try await store.delete(key: key("Reports"))

        // "Reports" subtree is gone. The thrown error's payload is redacted
        // (`CacheKey.opaqueLogPrefix` drops the path) — that alone can't
        // distinguish "Reports" from "reports" (both produce the identical
        // "a/w/i/..." string), so it is NOT the discriminator here. The real
        // proof that the delete didn't cross-match is the surviving-sibling
        // fetch below: if case-sensitivity regressed and "reports" were
        // wrongly swept up too, that fetch would throw and fail the test.
        await #expect(throws: CacheError.notFound(key("Reports").opaqueLogPrefix)) {
            try await store.fetch(key: key("Reports"))
        }
        await #expect(throws: CacheError.notFound(key("Reports/a.txt").opaqueLogPrefix)) {
            try await store.fetch(key: key("Reports/a.txt"))
        }

        // "reports" (differing only in case) must survive untouched — this is
        // the actual cross-match discriminator (see comment above).
        let reportsDir = try await store.fetch(key: key("reports"))
        #expect(reportsDir.path == "reports")
        let reportsFile = try await store.fetch(key: key("reports/b.txt"))
        #expect(reportsFile.path == "reports/b.txt")
    }

    // MARK: - batchDelete

    @Test("batchDelete does not cross-match a sibling differing only in ASCII case")
    func batchDeleteDoesNotCrossMatchCaseSibling() async throws {
        let store = try makeTempStore()
        defer { try? FileManager.default.removeItem(at: store.root) }
        try await seedCaseSiblings(store)

        try await store.batchDelete([key("Reports")], recordTombstones: false)

        // As in `deleteDoesNotCrossMatchCaseSibling`: the redacted payload
        // can't distinguish the siblings, so the surviving-sibling fetch
        // below is the real cross-match discriminator, not this assertion.
        await #expect(throws: CacheError.notFound(key("Reports/a.txt").opaqueLogPrefix)) {
            try await store.fetch(key: key("Reports/a.txt"))
        }
        let reportsFile = try await store.fetch(key: key("reports/b.txt"))
        #expect(reportsFile.path == "reports/b.txt")
    }

    // MARK: - renamePathPrefix

    @Test("renamePathPrefix does not cross-match a sibling differing only in ASCII case")
    func renamePathPrefixDoesNotCrossMatchCaseSibling() async throws {
        let store = try makeTempStore()
        defer { try? FileManager.default.removeItem(at: store.root) }
        try await seedCaseSiblings(store)

        _ = try await store.renamePathPrefix(
            accountAlias: alias, workspaceID: ws, itemID: item,
            oldPath: "Reports", newPath: "ReportsRenamed", newName: "ReportsRenamed"
        )

        // The renamed subtree lands at the new prefix.
        let renamedFile = try await store.fetch(key: key("ReportsRenamed/a.txt"))
        #expect(renamedFile.path == "ReportsRenamed/a.txt")

        // The lower-case sibling — and its child — must be untouched, not
        // swept up by the `path LIKE 'Reports/%'` descendant rewrite.
        let reportsDir = try await store.fetch(key: key("reports"))
        #expect(reportsDir.path == "reports")
        let reportsFile = try await store.fetch(key: key("reports/b.txt"))
        #expect(reportsFile.path == "reports/b.txt")
        #expect(reportsFile.parentPath == "reports")
    }

    // MARK: - removeMaterialized

    @Test("removeMaterialized does not cross-match a sibling differing only in ASCII case")
    func removeMaterializedDoesNotCrossMatchCaseSibling() async throws {
        let store = try makeTempStore()
        defer { try? FileManager.default.removeItem(at: store.root) }

        let upperRoot = "\(ws)/\(item)/Reports"
        let upperChild = "\(ws)/\(item)/Reports/child"
        let lowerRoot = "\(ws)/\(item)/reports"
        let lowerChild = "\(ws)/\(item)/reports/child"
        try await store.setMaterialized(
            alias: alias, identifiers: [upperRoot, upperChild, lowerRoot, lowerChild]
        )

        try await store.removeMaterialized(alias: alias, identifierPrefix: upperRoot)

        let remainingPaths = Set(try await store.reader().materializedContainers(alias: alias).map(\.path))
        #expect(remainingPaths == ["reports", "reports/child"])
    }
}
