import Foundation
import GRDB

// MARK: - CacheStore+WorkspaceStatus

public extension CacheStore {
    // MARK: - Workspace purge

    /// Returns the distinct workspace IDs the cache holds `path_metadata` rows
    /// for, under `accountAlias`. Delegates to ``CacheReader/workspaceIDs(accountAlias:)``.
    func workspaceIDs(accountAlias: String) async throws -> [String] {
        try await reader().workspaceIDs(accountAlias: accountAlias)
    }

    /// Deletes every `path_metadata` row for one removed workspace, plus its
    /// `workspace_status` row, in ONE write transaction. No tombstones are
    /// written.
    ///
    /// A single `workspace_id` predicate covers the whole subtree in one
    /// statement: real item rows (every `item_id`), item-discovery rows
    /// `(workspaceID, __items__, <itemGUID>)`, and the item-listing root marker
    /// `(workspaceID, __items__, "")`. Enumerating item GUIDs and batch-deleting
    /// per item is deliberately avoided — `batchDelete` cannot express "whole
    /// workspace" the way this single predicate does.
    ///
    /// `workspace_status` has no other cleanup path today: a workspace that was
    /// capacity-paused and then removed/unshared would otherwise keep feeding a
    /// stale "paused" badge forever, so it is cleared here too.
    ///
    /// Called only when a workspace vanishes from a successful Fabric listing
    /// (see ``SyncEngine/purgeRemovedWorkspaces(alias:seen:)``). No tombstones
    /// are written — the workspace's removal from Finder is remount-driven (its
    /// discovery-row expiry changes the alias's domain signature, which
    /// `ChangeWatcher` turns into a `removeDomain` + `addDomain` cycle), so the
    /// whole subtree drops out of the fresh root enumeration rather than
    /// through any per-row delta.
    ///
    /// Blob files are left for the existing orphan sweep to reclaim — this only
    /// unlinks metadata rows, matching ``removeMaterialized(alias:identifierPrefix:)``'s
    /// posture.
    ///
    /// Returns the number of deleted `path_metadata` rows.
    @discardableResult
    func purgeWorkspaceRows(accountAlias: String, workspaceID: String) async throws -> Int {
        guard !accountAlias.isEmpty else { throw CacheError.missingArgument("accountAlias") }
        guard !workspaceID.isEmpty else { throw CacheError.missingArgument("workspaceID") }
        return try await dbPool.write { db -> Int in
            try db.execute(sql: """
            DELETE FROM path_metadata WHERE account_alias = ? AND workspace_id = ?
            """, arguments: [accountAlias, workspaceID])
            let deleted = db.changesCount

            try db.execute(sql: """
            DELETE FROM workspace_status WHERE account_alias = ? AND workspace_id = ?
            """, arguments: [accountAlias, workspaceID])

            return deleted
        }
    }

    // MARK: - Workspace status

    /// Upserts the workspace status row.
    ///
    /// When the new state matches the persisted state, `detected_at_ns` is
    /// preserved (continuous pause). On a state change the new `detectedAtNs`
    /// is recorded.
    func setWorkspaceStatus(_ status: WorkspaceStatusRecord) async throws {
        guard !status.accountAlias.isEmpty, !status.workspaceID.isEmpty else {
            throw CacheError.missingArgument("accountAlias and workspaceID")
        }

        try await dbPool.write { db in
            // Read existing row to preserve detectedAtNs on same-state updates.
            let existing = try WorkspaceStatusRecord
                .filter(WorkspaceStatusRecord.Columns.accountAlias == status.accountAlias)
                .filter(WorkspaceStatusRecord.Columns.workspaceID == status.workspaceID)
                .fetchOne(db)

            var detectedNs = status.detectedAtNs
            if let ex = existing, ex.state == status.state, ex.detectedAtNs > 0 {
                detectedNs = ex.detectedAtNs
            }

            var probedNs = status.probedAtNs
            if probedNs == 0, let ex = existing {
                probedNs = ex.probedAtNs
            }

            var row = status
            row.detectedAtNs = detectedNs
            row.probedAtNs = probedNs
            try row.upsert(db)
        }
    }

    /// Reads the persisted status for the given workspace.
    ///
    /// Throws ``CacheError/notFound(_:)`` when no row exists.
    func workspaceStatus(accountAlias: String, workspaceID: String) async throws -> WorkspaceStatusRecord {
        try await reader().workspaceStatus(accountAlias: accountAlias, workspaceID: workspaceID)
    }

    // periphery:ignore
    /// Returns all persisted workspace status rows ordered by
    /// `(account_alias, workspace_id)`.
    func allWorkspaceStatuses() async throws -> [WorkspaceStatusRecord] {
        try await reader().allWorkspaceStatuses()
    }

    /// Returns only the workspace status rows whose state is `.paused`,
    /// ordered by `(account_alias, workspace_id)`.
    ///
    /// Used by the menu-bar host to build the paused-workspaces badge.
    func listPausedWorkspaces() async throws -> [WorkspaceStatusRecord] {
        try await dbPool.read { db in
            try WorkspaceStatusRecord
                .filter(WorkspaceStatusRecord.Columns.state == WorkspaceStatusRecord.State.paused.rawValue)
                .order(
                    WorkspaceStatusRecord.Columns.accountAlias,
                    WorkspaceStatusRecord.Columns.workspaceID
                )
                .fetchAll(db)
        }
    }
}
