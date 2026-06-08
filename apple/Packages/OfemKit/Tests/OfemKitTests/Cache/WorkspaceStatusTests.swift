import Foundation
import Testing

@testable import OfemKit

// MARK: - WorkspaceStatusTests

/// Tests for workspace pause/resume state transitions.
///
/// Mirrors `internal/cache/workspace_status_test.go`.
@Suite("WorkspaceStatus")
struct WorkspaceStatusTests {

    // MARK: - Basic CRUD

    @Test("SetWorkspaceStatus inserts a new row")
    func setInsertsRow() async throws {
        let store = try makeInMemoryStore()
        let status = WorkspaceStatusRecord(
            accountAlias: "work",
            workspaceID: "ws1",
            state: .paused,
            reason: "capacity_paused",
            detectedAtNs: 1_000_000_000,
            probedAtNs: 0
        )
        try await store.setWorkspaceStatus(status)

        let fetched = try await store.workspaceStatus(accountAlias: "work", workspaceID: "ws1")
        #expect(fetched.state == .paused)
        #expect(fetched.reason == "capacity_paused")
        #expect(fetched.detectedAtNs == 1_000_000_000)
    }

    @Test("GetWorkspaceStatus throws notFound for unknown workspace")
    func getMissingThrowsNotFound() async throws {
        let store = try makeInMemoryStore()
        await #expect(throws: CacheError.self) {
            try await store.workspaceStatus(accountAlias: "work", workspaceID: "unknown")
        }
    }

    // MARK: - State transitions

    @Test("Same-state update preserves detected_at_ns")
    func sameStatePreservesDetectedAt() async throws {
        let store = try makeInMemoryStore()
        let initial = WorkspaceStatusRecord(
            accountAlias: "a", workspaceID: "w",
            state: .paused, reason: "cap_pause",
            detectedAtNs: 100, probedAtNs: 0
        )
        try await store.setWorkspaceStatus(initial)

        let update = WorkspaceStatusRecord(
            accountAlias: "a", workspaceID: "w",
            state: .paused, reason: "cap_pause",
            detectedAtNs: 999, probedAtNs: 200
        )
        try await store.setWorkspaceStatus(update)

        let fetched = try await store.workspaceStatus(accountAlias: "a", workspaceID: "w")
        #expect(fetched.detectedAtNs == 100)
        #expect(fetched.probedAtNs == 200)
    }

    @Test("State change resets detected_at_ns")
    func stateChangeResetsDetectedAt() async throws {
        let store = try makeInMemoryStore()
        try await store.setWorkspaceStatus(WorkspaceStatusRecord(
            accountAlias: "a", workspaceID: "w",
            state: .paused, reason: "cap_pause",
            detectedAtNs: 100
        ))

        try await store.setWorkspaceStatus(WorkspaceStatusRecord(
            accountAlias: "a", workspaceID: "w",
            state: .active, reason: "",
            detectedAtNs: 500
        ))

        let fetched = try await store.workspaceStatus(accountAlias: "a", workspaceID: "w")
        #expect(fetched.state == .active)
        #expect(fetched.detectedAtNs == 500)
    }

    @Test("ProbedAt preserved when new value is zero")
    func probedAtPreservedWhenZero() async throws {
        let store = try makeInMemoryStore()
        try await store.setWorkspaceStatus(WorkspaceStatusRecord(
            accountAlias: "a", workspaceID: "w",
            state: .paused, reason: "r",
            detectedAtNs: 1, probedAtNs: 777
        ))

        try await store.setWorkspaceStatus(WorkspaceStatusRecord(
            accountAlias: "a", workspaceID: "w",
            state: .paused, reason: "r",
            detectedAtNs: 1, probedAtNs: 0
        ))

        let fetched = try await store.workspaceStatus(accountAlias: "a", workspaceID: "w")
        #expect(fetched.probedAtNs == 777)
    }

    // MARK: - AllWorkspaceStatuses

    @Test("AllWorkspaceStatuses returns ordered rows")
    func allStatusesOrdered() async throws {
        let store = try makeInMemoryStore()
        try await store.setWorkspaceStatus(WorkspaceStatusRecord(
            accountAlias: "z", workspaceID: "z-ws", state: .active
        ))
        try await store.setWorkspaceStatus(WorkspaceStatusRecord(
            accountAlias: "a", workspaceID: "a-ws", state: .paused
        ))

        let statuses = try await store.allWorkspaceStatuses()
        #expect(statuses.count == 2)
        #expect(statuses[0].accountAlias == "a")
        #expect(statuses[1].accountAlias == "z")
    }

    @Test("AllWorkspaceStatuses returns empty list when no rows")
    func allStatusesEmpty() async throws {
        let store = try makeInMemoryStore()
        let statuses = try await store.allWorkspaceStatuses()
        #expect(statuses.isEmpty)
    }

    // MARK: - Validation

    @Test("Empty accountAlias throws missingArgument")
    func emptyAliasThrows() async throws {
        let store = try makeInMemoryStore()
        await #expect(throws: CacheError.self) {
            try await store.setWorkspaceStatus(WorkspaceStatusRecord(
                accountAlias: "", workspaceID: "ws", state: .active
            ))
        }
    }

    @Test("Empty workspaceID throws missingArgument")
    func emptyWorkspaceIDThrows() async throws {
        let store = try makeInMemoryStore()
        await #expect(throws: CacheError.self) {
            try await store.setWorkspaceStatus(WorkspaceStatusRecord(
                accountAlias: "a", workspaceID: "", state: .active
            ))
        }
    }

    // MARK: - WorkspaceStatusRecord model

    @Test("State raw value matches Go constants")
    func stateRawValues() {
        #expect(WorkspaceStatusRecord.State.active.rawValue == "active")
        #expect(WorkspaceStatusRecord.State.paused.rawValue == "paused")
    }

    @Test("Unknown state string falls back to active")
    func unknownStateFallsBack() async throws {
        let store = try makeInMemoryStore()
        try await store.dbPool.write { db in
            try db.execute(sql: """
                INSERT INTO workspace_status
                    (account_alias, workspace_id, state, reason, detected_at_ns, probed_at_ns)
                VALUES ('a', 'w', 'future_state', '', 0, 0)
                """)
        }
        let fetched = try await store.workspaceStatus(accountAlias: "a", workspaceID: "w")
        #expect(fetched.state == .active)
    }

    // MARK: - nsToDate / dateToNs helpers

    @Test("nsToDate returns nil for zero")
    func nsToDateZeroIsNil() {
        #expect(nsToDate(0) == nil)
    }

    @Test("nsToDate round-trips through dateToNs")
    func nsToDateRoundTrip() {
        let now = Date()
        let ns = dateToNs(now)
        let back = nsToDate(ns)
        let diff = abs((back?.timeIntervalSince1970 ?? 0) - now.timeIntervalSince1970)
        #expect(diff < 0.000_001)
    }
}
