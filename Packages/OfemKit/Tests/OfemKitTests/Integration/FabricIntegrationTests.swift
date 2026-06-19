import Foundation
import Testing

@testable import OfemKit

/// Live Fabric REST discovery against the real test workspace.
@Suite("Fabric integration", .integration)
struct FabricIntegrationTests {

    private func fabricClient() -> FabricClient {
        let pool = SessionPool(tokenProvider: EnvVarTokenProvider())
        return FabricClient(sessionPool: pool)
    }

    @Test("lists the test workspace among all workspaces")
    func listsWorkspace() async throws {
        let config = try IntegrationConfig.fromEnvironment()
        let workspaces = try await fabricClient().listAllWorkspaces(alias: "ci")
        #expect(workspaces.contains { $0.id == config.workspaceID })
    }

    @Test("lists the lakehouse item inside the test workspace")
    func listsLakehouseItem() async throws {
        let config = try IntegrationConfig.fromEnvironment()
        let items = try await fabricClient().listAllItems(alias: "ci", workspaceID: config.workspaceID)
        let lakehouse = items.first { $0.id == config.lakehouseID }
        #expect(lakehouse != nil)
        #expect(lakehouse?.type == "Lakehouse")
    }
}
