import Foundation
@testable import OfemKit
import Testing

// MARK: - PauseManager Tests

/// Tests for ``PauseManager`` — pause classification, probe state machine, and
/// the ``isPausedCapacityError`` mapping table.
@Suite("PauseManager")
struct PauseManagerTests {
    // MARK: - Helpers

    private func makeManager(
        onelake: MockOneLakeClient = MockOneLakeClient(),
        store: CacheStore? = nil
    ) throws -> (PauseManager, CacheStore) {
        let s = try store ?? makeTempStore()
        let mgr = PauseManager(
            cache: s,
            onelake: onelake,
            probeInterval: .seconds(0) // zero interval → probe always fires in tests
        )
        return (mgr, s)
    }

    // MARK: - Classification: regex patterns

    @Test("isPausedCapacityError recognises 'capacity not active'")
    func capacityNotActive() throws {
        let (mgr, store) = try makeManager()
        defer { try? FileManager.default.removeItem(at: store.root) }
        let err = makeAPIError(body: #"{"message":"capacity not active"}"#)
        #expect(mgr.isPausedCapacityError(err))
    }

    @Test("isPausedCapacityError recognises 'Fabric capacity is paused'")
    func fabricCapacityIsPaused() throws {
        let (mgr, store) = try makeManager()
        defer { try? FileManager.default.removeItem(at: store.root) }
        let err = makeAPIError(body: #"{"message":"Fabric capacity is paused"}"#)
        #expect(mgr.isPausedCapacityError(err))
    }

    @Test("isPausedCapacityError recognises 'capacity suspended'")
    func capacitySuspended() throws {
        let (mgr, store) = try makeManager()
        defer { try? FileManager.default.removeItem(at: store.root) }
        let err = makeAPIError(body: #"{"message":"capacity suspended"}"#)
        #expect(mgr.isPausedCapacityError(err))
    }

    @Test("isPausedCapacityError recognises 'capacity has been paused'")
    func capacityHasBeenPaused() throws {
        let (mgr, store) = try makeManager()
        defer { try? FileManager.default.removeItem(at: store.root) }
        let err = makeAPIError(body: #"{"message":"Capacity has been paused"}"#)
        #expect(mgr.isPausedCapacityError(err))
    }

    // MARK: - Classification: errorCode field

    @Test("isPausedCapacityError recognises errorCode 'capacitypaused' (case-insensitive)")
    func errorCodeCapacityPaused() throws {
        let (mgr, store) = try makeManager()
        defer { try? FileManager.default.removeItem(at: store.root) }
        let err = makeAPIError(body: #"{"errorCode":"CapacityPaused","message":"other"}"#)
        #expect(mgr.isPausedCapacityError(err))
    }

    @Test("isPausedCapacityError recognises errorCode 'workspacecapacitypaused'")
    func errorCodeWorkspaceCapacityPaused() throws {
        let (mgr, store) = try makeManager()
        defer { try? FileManager.default.removeItem(at: store.root) }
        let err = makeAPIError(body: #"{"errorCode":"WorkspaceCapacityPaused"}"#)
        #expect(mgr.isPausedCapacityError(err))
    }

    @Test("isPausedCapacityError returns false for unrelated errors")
    func nonPausedError() throws {
        let (mgr, store) = try makeManager()
        defer { try? FileManager.default.removeItem(at: store.root) }
        let err = URLError(.notConnectedToInternet)
        #expect(!mgr.isPausedCapacityError(err))
    }

    @Test("isPausedCapacityError unwraps OneLakeError.httpError")
    func unwrapsOneLakeError() throws {
        let (mgr, store) = try makeManager()
        defer { try? FileManager.default.removeItem(at: store.root) }
        let inner = makeAPIError(body: #"{"message":"capacity is currently paused"}"#)
        let wrapped = OneLakeError.httpError(inner)
        #expect(mgr.isPausedCapacityError(wrapped))
    }

    @Test("isPausedCapacityError unwraps FabricError.httpError")
    func unwrapsFabricError() throws {
        let (mgr, store) = try makeManager()
        defer { try? FileManager.default.removeItem(at: store.root) }
        let inner = makeAPIError(body: #"{"errorCode":"capacitysuspended"}"#)
        let wrapped = FabricError.httpError(inner)
        #expect(mgr.isPausedCapacityError(wrapped))
    }

    // MARK: - Probe state machine

    @Test("markPausedIfNeeded marks workspace paused in store")
    func markPausedPersists() async throws {
        let (mgr, store) = try makeManager()
        defer { try? FileManager.default.removeItem(at: store.root) }
        let err = makeAPIError(body: #"{"message":"capacity not active"}"#)
        let paused = await mgr.markPausedIfNeeded(workspaceID: "ws-1", alias: "a", error: err)
        #expect(paused)
        let status = try await store.workspaceStatus(accountAlias: "a", workspaceID: "ws-1")
        #expect(status.state == .paused)
    }

    @Test("guardPaused recovers when probe succeeds")
    func guardPausedRecovery() async throws {
        let ol = MockOneLakeClient()
        let (mgr, store) = try makeManager(onelake: ol)
        defer { try? FileManager.default.removeItem(at: store.root) }

        // Mark workspace paused.
        let paused = await mgr.markPausedIfNeeded(
            workspaceID: "ws-1", alias: "a",
            error: makeAPIError(body: #"{"message":"capacity not active"}"#)
        )
        #expect(paused)

        // Probe HEAD → success (recovery).
        ol.getPropertiesResults.append(.success(PathProperties.make()))

        // guardPaused should now return without throwing.
        try await mgr.guardPaused(workspaceID: "ws-1", alias: "a")
        // After recovery the workspace should be active.
        let status = try await store.workspaceStatus(accountAlias: "a", workspaceID: "ws-1")
        #expect(status.state == .active)
    }

    @Test("guardPaused throws workspacePaused when probe fails")
    func guardPausedStillPaused() async throws {
        let ol = MockOneLakeClient()
        let (mgr, store) = try makeManager(onelake: ol)
        defer { try? FileManager.default.removeItem(at: store.root) }

        _ = await mgr.markPausedIfNeeded(
            workspaceID: "ws-1", alias: "a",
            error: makeAPIError(body: #"{"message":"capacity not active"}"#)
        )

        // Probe HEAD → still failing.
        ol.getPropertiesResults.append(.failure(MockError.intentional("still paused")))

        do {
            try await mgr.guardPaused(workspaceID: "ws-1", alias: "a")
            Issue.record("Expected workspacePaused to be thrown")
        } catch SyncError.workspacePaused {
            // Correct.
        }
    }

    // MARK: - Helpers

    private func makeAPIError(body: String) -> HTTPClientError {
        .apiError(APIError(
            statusCode: 503,
            status: "503 Service Unavailable",
            body: body.data(using: .utf8)!
        ))
    }
}
