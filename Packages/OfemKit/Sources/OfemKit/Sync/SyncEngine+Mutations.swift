import Foundation
import os.log

// MARK: - SyncEngine+Mutations

extension SyncEngine {
    // MARK: - Delete

    /// Removes a file or directory from OneLake and the local cache.
    ///
    /// macOS metadata files are dropped from the local cache only (no remote
    /// call, no telemetry).
    public func delete(key: CacheKey) async throws {
        let start = Date()

        // sync-05: surface cache read error — treating a DB failure as
        // `isDir = false` risks choosing non-recursive delete on a populated
        // directory, causing a 409. Log but continue with the safe assumption.
        let cached: MetadataRecord?
        do {
            cached = try await cache.fetch(key: key)
        } catch {
            Self.log.warning("delete: cache read failed, assuming isDir=false err=\(error, privacy: .public)")
            cached = nil
        }
        let isDir = cached?.isDir ?? false
        let eventName = isDir ? "folder_delete" : "file_delete"

        if isMacOSMetadata(key.path) {
            do { try await cache.delete(key: key) } catch {
                Self.log.warning("delete: macOS metadata cache delete failed err=\(error, privacy: .public)")
            }
            return
        }

        try await pauseManager.guardPaused(workspaceID: key.workspaceID, alias: key.accountAlias)

        // When cache has no row we cannot tell file from directory; ask DFS to
        // recurse to avoid 409 on a populated directory.
        let recursive = isDir || cached == nil

        do {
            try await onelake.delete(
                alias: key.accountAlias,
                workspaceGUID: key.workspaceID,
                itemGUID: key.itemID,
                path: key.path,
                recursive: recursive
            )
        } catch OneLakeError.notFound {
            // DELETE is in SessionPool's retryable HTTP methods, and the
            // `idempotent` flag Alamofire exposes is a documented no-op. If the
            // delete already committed server-side but its ack was lost, the
            // replayed DELETE 404s. The row is gone either way — that is the
            // goal of this call — so treat it as success rather than surfacing
            // `delete_failed`, mirroring the `destinationExists` guard for a
            // replayed rename PUT below.
            Self.log.info("delete: remote 404 — already gone, treating as success")
        } catch {
            try await withRemoteOperationError(
                error: error, key: key, eventName: eventName,
                failCode: "delete_failed", start: start
            )
        }
        await offlineTracker.observe(nil)

        do { try await cache.delete(key: key) } catch {
            Self.log.warning("delete: cache delete failed err=\(error, privacy: .public)")
        }

        await track(eventName: eventName, alias: key.accountAlias, start: start, outcome: .success())
    }

    // MARK: - Mkdir

    /// Creates a directory on OneLake and upserts the matching cache row.
    public func mkdir(key: CacheKey) async throws {
        let start = Date()
        try await pauseManager.guardPaused(workspaceID: key.workspaceID, alias: key.accountAlias)

        do {
            try await onelake.createDirectory(
                alias: key.accountAlias,
                workspaceGUID: key.workspaceID,
                itemGUID: key.itemID,
                path: key.path
            )
        } catch {
            try await withRemoteOperationError(
                error: error, key: key, eventName: "folder_create",
                failCode: "mkdir_failed", start: start
            )
        }
        await offlineTracker.observe(nil)

        let nowNs = currentNowNs()
        // Carry the item type from the parent directory row so that a newly
        // created folder under a Lakehouse Files/ subtree keeps writable
        // capabilities without waiting for the next refreshFolder (fp-05).
        let mkdirItemType = await resolveItemType(for: key)
        let row = MetadataRecord(
            accountAlias: key.accountAlias,
            workspaceID: key.workspaceID,
            itemID: key.itemID,
            path: key.path,
            parentPath: Enumerator.parentPath(key.path),
            name: Enumerator.baseName(key.path),
            isDir: true,
            lastAccessedNs: nowNs,
            syncedAtNs: nowNs,
            itemType: mkdirItemType
        )
        do { try await cache.upsert(row) } catch {
            Self.log.warning("mkdir: upsert failed err=\(error, privacy: .public)")
        }

        await track(eventName: "folder_create", alias: key.accountAlias, start: start, outcome: .success())
    }

    // MARK: - Rename

    /// Renames a file or directory within the same parent directory on OneLake
    /// and re-keys the matching cache row (and any cached descendants).
    ///
    /// Move/reparent (changing `.parentItemIdentifier`) is out of scope: only
    /// same-directory renames where the parent directory is unchanged are handled
    /// here. The caller is responsible for ensuring `newName` does not contain
    /// a path separator.
    ///
    /// - Parameters:
    ///   - key: The current ``CacheKey`` of the item to rename.
    ///   - newName: The new leaf name (final path segment, no `"/"`).
    /// - Returns: The updated ``MetadataRecord`` under the new path so the FPE
    ///   can build a fresh ``OfemFPEItem`` without an additional cache lookup.
    public func rename(key: CacheKey, newName: String) async throws -> MetadataRecord {
        let start = Date()
        try await pauseManager.guardPaused(workspaceID: key.workspaceID, alias: key.accountAlias)

        // Compute the destination path: same parent directory, new leaf name.
        let parentDir = Enumerator.parentPath(key.path)
        let destinationPath = parentDir.isEmpty ? newName : "\(parentDir)/\(newName)"

        do {
            try await onelake.rename(
                alias: key.accountAlias,
                workspaceGUID: key.workspaceID,
                itemGUID: key.itemID,
                sourcePath: key.path,
                destinationPath: destinationPath
            )
        } catch let error as OneLakeError {
            // Rename is non-idempotent, but the session retrier retries the PUT
            // on transient failures. If a retry runs after the rename already
            // committed server-side, the source path is gone → `notFound`,
            // surfaced as a spurious failure on an operation that succeeded.
            // Conservatively swallow `notFound` (and only `notFound`) when the
            // destination is now present, confirming the rename did commit, and
            // proceed to the cache re-key. Any other error propagates as before.
            if case .notFound = error,
               await destinationExists(
                   alias: key.accountAlias,
                   workspaceID: key.workspaceID,
                   itemID: key.itemID,
                   destinationPath: destinationPath
               )
            {
                Self.log.info("rename: source gone but destination present — treating retried rename as already committed")
            } else {
                try await withRemoteOperationError(
                    error: error, key: key, eventName: "item_rename",
                    failCode: "rename_failed", start: start
                )
            }
        } catch {
            try await withRemoteOperationError(
                error: error, key: key, eventName: "item_rename",
                failCode: "rename_failed", start: start
            )
        }
        await offlineTracker.observe(nil)

        // Read the existing row up front so we can both (a) carry forward fields
        // (created/modified dates, size, type) into the synthesised fallback and
        // (b) write a tombstone for the OLD identifier after the re-key succeeds.
        let existing = try? await cache.fetch(key: key)

        // Re-key the cache: update the exact row and all descendants atomically.
        // A cache failure must NOT be swallowed — reporting rename success while
        // the cache still holds the old key would make the old name reappear on
        // the next enumeration (cache/server divergence with no retry). Let it
        // propagate so the FPE leaves `.filename` pending and the framework
        // retries.
        let renamed = try await cache.renamePathPrefix(
            accountAlias: key.accountAlias,
            workspaceID: key.workspaceID,
            itemID: key.itemID,
            oldPath: key.path,
            newPath: destinationPath,
            newName: newName
        )

        // Tombstone the OLD identifier so other enumerators (working-set poll,
        // a re-opened materialized container) retire the row under the old name
        // via itemsChangedAfter → enumerateChanges → didDeleteItems, mirroring
        // `delete`. Written only after the new-path row is committed above.
        try? await cache.recordDeletion(
            accountAlias: key.accountAlias,
            identifierString: ItemIdentifier
                .path(workspaceID: key.workspaceID, itemID: key.itemID, path: key.path)
                .identifierString
        )

        // Prefer the row read back inside the rename transaction; fall back to a
        // synthesised record only when no row existed at the old path to rename.
        let updatedRecord: MetadataRecord
        if let renamed {
            updatedRecord = renamed
        } else {
            // Best-effort: build from the old key's cached data, carrying
            // created/modified dates forward so Finder does not regress to the
            // 1970 epoch (ab283ce).
            let nowNs = currentNowNs()
            updatedRecord = MetadataRecord(
                accountAlias: key.accountAlias,
                workspaceID: key.workspaceID,
                itemID: key.itemID,
                path: destinationPath,
                parentPath: parentDir,
                name: newName,
                isDir: existing?.isDir ?? false,
                contentLength: existing?.contentLength ?? 0,
                etag: existing?.etag ?? "",
                lastModifiedNs: existing?.lastModifiedNs ?? 0,
                contentType: existing?.contentType ?? "",
                lastAccessedNs: nowNs,
                syncedAtNs: nowNs,
                itemType: existing?.itemType ?? "",
                createdNs: existing?.createdNs ?? 0
            )
        }

        await track(eventName: "item_rename", alias: key.accountAlias, start: start, outcome: .success())
        return updatedRecord
    }

    /// Returns `true` when the rename destination is confirmed to exist, used to
    /// recognise an already-committed (retried) rename whose source has vanished.
    ///
    /// Checks the cache first (cheap, no network); only when the row is absent
    /// does it issue a single HEAD (`getProperties`). Any probe error is treated
    /// as "not present" so a transient network blip cannot make a genuinely
    /// failed rename look successful.
    private func destinationExists(
        alias: String,
        workspaceID: String,
        itemID: String,
        destinationPath: String
    ) async -> Bool {
        let newKey = CacheKey(
            accountAlias: alias,
            workspaceID: workspaceID,
            itemID: itemID,
            path: destinationPath
        )
        if (try? await cache.fetch(key: newKey)) != nil {
            return true
        }
        do {
            _ = try await onelake.getProperties(
                alias: alias,
                workspaceGUID: workspaceID,
                itemGUID: itemID,
                path: destinationPath
            )
            return true
        } catch {
            return false
        }
    }
}
