import Foundation
import Testing

@testable import OfemKit

/// Deeper Fabric REST discovery tests against the real test workspace.
///
/// The sibling `FabricIntegrationTests` already verifies that the workspace and
/// lakehouse item appear in their respective list calls. This suite goes further:
/// field-level correctness, cross-endpoint consistency, folder enumeration, and
/// pagination-vs-full-list coherence.
@Suite("Fabric discovery integration", .integration)
struct FabricDiscoveryIntegrationTests {

    private func fabricClient() -> FabricClient {
        let pool = SessionPool(tokenProvider: EnvVarTokenProvider())
        return FabricClient(sessionPool: pool)
    }

    // MARK: - 1. getItem returns the lakehouse with correct fields

    @Test("getItem returns the lakehouse with correct fields")
    func getItemReturnsLakehouseWithCorrectFields() async throws {
        let c = try IntegrationConfig.fromEnvironment()
        let item = try await fabricClient().getItem(
            alias: "ci",
            workspaceID: c.workspaceID,
            itemID: c.lakehouseID
        )
        #expect(item.id == c.lakehouseID)
        #expect(item.type == "Lakehouse")
        #expect(item.workspaceID == c.workspaceID)
        #expect(!item.displayName.isEmpty)
    }

    // MARK: - 2. getItem and listAllItems agree on stable fields

    @Test("getItem and listAllItems agree on id, type, and displayName")
    func getItemAndListAllItemsAgree() async throws {
        let c = try IntegrationConfig.fromEnvironment()
        let client = fabricClient()

        async let fetched = client.getItem(
            alias: "ci",
            workspaceID: c.workspaceID,
            itemID: c.lakehouseID
        )
        async let allItems = client.listAllItems(
            alias: "ci",
            workspaceID: c.workspaceID
        )

        let (single, items) = try await (fetched, allItems)
        let match = items.first { $0.id == c.lakehouseID }

        #expect(match != nil)
        if let match {
            #expect(single.id == match.id)
            #expect(single.type == match.type)
            #expect(single.displayName == match.displayName)
        }
    }

    // MARK: - 3. The test workspace's metadata is coherent

    @Test("test workspace has non-empty displayName and capacityID")
    func testWorkspaceMetadataIsCoherent() async throws {
        let c = try IntegrationConfig.fromEnvironment()
        let workspaces = try await fabricClient().listAllWorkspaces(alias: "ci")
        let workspace = workspaces.first { $0.id == c.workspaceID }

        #expect(workspace != nil)
        if let workspace {
            #expect(!workspace.displayName.isEmpty)
            #expect(!workspace.capacityID.isEmpty)
        }
    }

    // MARK: - 4. listAllItems contains a Lakehouse-typed item

    @Test("listAllItems contains at least one Lakehouse-typed item")
    func listAllItemsContainsLakehouseTypedItem() async throws {
        let c = try IntegrationConfig.fromEnvironment()
        let items = try await fabricClient().listAllItems(
            alias: "ci",
            workspaceID: c.workspaceID
        )

        // Verify the workspace holds at least one Lakehouse; the sibling suite
        // already asserts that the specific CI lakehouse ID is present.
        #expect(items.contains { $0.type == "Lakehouse" })
    }

    // MARK: - 5. listAllFolders does not throw and every folder belongs to the workspace

    @Test("listAllFolders returns a valid [Folder] with consistent workspaceID")
    func listAllFoldersReturnsValidArray() async throws {
        let c = try IntegrationConfig.fromEnvironment()
        let folders = try await fabricClient().listAllFolders(
            alias: "ci",
            workspaceID: c.workspaceID
        )

        // Result may legitimately be empty; every returned folder must belong to the workspace.
        for folder in folders {
            #expect(folder.workspaceID == c.workspaceID)
        }
    }

    // MARK: - 6. getItem throws notFound for a non-existent item ID

    @Test("getItem throws notFound for a non-existent item ID")
    func getItemThrowsNotFoundForBogusItemID() async throws {
        let c = try IntegrationConfig.fromEnvironment()
        // The nil-UUID is guaranteed never to exist; the live Fabric API returns
        // HTTP 404 with body {"errorCode":"ItemNotFound",...}.
        // doRequest maps HTTPClientError.notFound → FabricError.notFound (see FabricError.from(_:)).
        // FabricError isn't Equatable, so match the specific case in the `throws:` closure
        // rather than the value form of #expect(throws:).
        await #expect {
            try await fabricClient().getItem(
                alias: "ci",
                workspaceID: c.workspaceID,
                itemID: "00000000-0000-0000-0000-000000000000"
            )
        } throws: { error in
            guard case FabricError.notFound = error else { return false }
            return true
        }
    }

    // MARK: - 7. Single-page listItems is a prefix of listAllItems

    @Test("first page of listItems is consistent with listAllItems")
    func singlePageListItemsIsSubsetOfListAllItems() async throws {
        let c = try IntegrationConfig.fromEnvironment()
        let client = fabricClient()

        async let firstPage = client.listItems(
            alias: "ci",
            workspaceID: c.workspaceID
        )
        async let allItems = client.listAllItems(
            alias: "ci",
            workspaceID: c.workspaceID
        )

        let (page, all) = try await (firstPage, allItems)
        let allIDs = Set(all.map(\.id))

        // Every item in the first page must appear in the full list.
        for item in page.items {
            #expect(allIDs.contains(item.id))
        }

        // When the first page already exhausts the result set, counts must match.
        if page.continuationToken == nil {
            #expect(page.items.count == all.count)
        }
    }
}
