import Foundation
import os.log

// MARK: - SyncEngine+Transfer

extension SyncEngine {
    // MARK: - Open (download)

    /// Result of a successful ``open(key:)``: the servable file URL plus the
    /// metadata record describing exactly what it points to.
    /// Threaded through internally so ``openReturningRecord(key:)`` gets both
    /// from the single read/write pass ``open(key:)`` already performs,
    /// instead of the caller fetching the row again afterward.
    ///
    /// M10a (#466): `internal`, not `private` — the base file's
    /// `inFlightDownloads` stores a `Task<OpenResult, any Error>` and needs
    /// to see this type across the file split.
    typealias OpenResult = (url: URL, record: MetadataRecord)

    // periphery:ignore - only test callers remain; exclude_tests: true hides them from periphery
    /// Downloads a file, serving from the local blob cache when fresh.
    ///
    /// Returns a file URL rather than in-memory `Data` so the FPE can write
    /// directly to its staging destination without buffering the entire file.
    ///
    /// Concurrent calls for the same key are coalesced: the second caller
    /// awaits the first's in-flight task rather than issuing a duplicate
    /// download. The in-flight entry is removed when the task VALUE is delivered,
    /// not when the spawning frame unwinds, so late-joining callers always
    /// find a live entry (sync-24 fix).
    ///
    /// The blob cache is checked BEFORE acquiring a download semaphore slot, so
    /// cache hits never consume a slot.
    ///
    /// The sole production caller (`FileProviderExtension.fetchContents`) now
    /// uses ``openReturningRecord(key:)`` instead, so it also needs the served
    /// record; this URL-only entry point is kept as the minimal public API for
    /// any caller that only needs the file (matching `blobURL(key:)` /
    /// `handoffBlob(key:to:)` below) and is exercised extensively by the
    /// `open()` test suite.
    public func open(key: CacheKey, onProgress: (@Sendable (Int64, Int64) -> Void)? = nil) async throws -> URL {
        try await performOpen(key: key, onProgress: onProgress).url
    }

    /// Like ``open(key:)`` but also returns the ``MetadataRecord`` describing
    /// exactly what was served.
    ///
    /// Used by the FPE's `fetchContents`, which needs a version-accurate
    /// `NSFileProviderItem` for the SAME bytes it hands back: building that
    /// item from a fetch taken before `open()` ran left its `contentVersion`
    /// stale relative to a just-completed re-download, causing a redundant
    /// re-download the next cycle. Re-fetching after `open()` instead would
    /// fix the staleness but re-read the row a second time; returning the
    /// record `open()` already has in hand needs neither.
    ///
    /// - Parameter onProgress: Optional incremental download-progress callback
    ///   (#461), forwarded to a fresh download only — a cache-hit / offline-stale
    ///   / freshness-revalidated return below never calls it, since the FPE
    ///   already reports completion for those synchronously once this returns.
    ///   When multiple callers coalesce onto the same in-flight download (see
    ///   below), only the FIRST caller's `onProgress` is wired in; late joiners
    ///   still get the correct final bytes, just no incremental ticks.
    public func openReturningRecord(
        key: CacheKey,
        onProgress: (@Sendable (Int64, Int64) -> Void)? = nil
    ) async throws -> (url: URL, record: MetadataRecord) {
        try await performOpen(key: key, onProgress: onProgress)
    }

    private func performOpen(
        key: CacheKey,
        onProgress: (@Sendable (Int64, Int64) -> Void)? = nil
    ) async throws -> OpenResult {
        let start = Date()
        try await pauseManager.guardPaused(workspaceID: key.workspaceID, alias: key.accountAlias)

        // Fetch the cached row (optional — a miss just means we download fresh).
        let cached = try? await cache.fetch(key: key)

        if let c = cached, !c.blobSHA256.isEmpty {
            // A row synced within blobFreshnessTTL is presumed fresh — it was
            // stamped either by this file's own last download/revalidate or
            // by a refreshFolder pass that observed a real change to it, so
            // re-validating with a getProperties HEAD on every single open
            // (Quick Look, a burst of re-opens) is a redundant round trip
            // that closely-spaced opens would otherwise all pay. Skip the
            // HEAD entirely inside the window; an unchanged row's syncedAtNs
            // is not refreshed by the poll (see defaultBlobFreshnessTTL), so
            // it still re-validates with a real HEAD roughly once per window.
            let rowAgeNs = currentNowNs() - c.syncedAtNs
            let ttlNs = Int64(blobFreshnessTTL.seconds * 1_000_000_000)
            if c.syncedAtNs > 0, rowAgeNs >= 0, rowAgeNs < ttlNs,
               let blobURL = await cache.blobURL(record: c)
            {
                do { try await cache.touch(key: key) } catch {
                    Self.log.warning("open: touch failed err=\(error, privacy: .public)")
                }
                await track(eventName: "file_download", alias: key.accountAlias, start: start, outcome: .success())
                return (blobURL, c)
            }

            // Outside the TTL, a known-offline engine skips the HEAD too:
            // issuing one would just block until the network timeout before
            // falling back to the same stale blob the catch-block offline
            // path below would serve anyway.
            if await offlineTracker.currentlyOffline(), let blobURL = await cache.blobURL(record: c) {
                logger.debug("offline; serving stale cached blob without a freshness HEAD", metadata: ["path": key.path])
                await track(eventName: "file_download", alias: key.accountAlias, start: start,
                            outcome: .successWithCode("served_stale_offline"))
                return (blobURL, c)
            }

            // Attempt to serve from blob cache — done BEFORE acquiring a slot
            // so cache hits do not consume download bandwidth.
            do {
                let (fresh, _) = try await isBlobFresh(key: key, cached: c)
                if fresh {
                    await offlineTracker.observe(nil)
                    if let blobURL = await cache.blobURL(record: c) {
                        do { try await cache.touch(key: key) } catch {
                            Self.log.warning("open: touch failed err=\(error, privacy: .public)")
                        }
                        await track(eventName: "file_download", alias: key.accountAlias, start: start, outcome: .success())
                        return (blobURL, c)
                    }
                }
                // Remote moved on — fall through to download.
            } catch {
                await offlineTracker.observe(error)
                // HEAD path through markPausedIfNeeded: a paused capacity signal
                // on the freshness check must mark the workspace paused.
                if await pauseManager.markPausedIfNeeded(
                    workspaceID: key.workspaceID, alias: key.accountAlias, error: error
                ) {
                    await track(eventName: "file_download", alias: key.accountAlias, start: start, outcome: .paused)
                    throw SyncError.workspacePaused
                }
                // Offline fallback: serve stale blob when the HEAD failed offline.
                if await offlineTracker.currentlyOffline(), let blobURL = await cache.blobURL(record: c) {
                    logger.debug("offline; serving stale cached blob", metadata: ["path": key.path])
                    await track(eventName: "file_download", alias: key.accountAlias, start: start,
                                outcome: .successWithCode("served_stale_offline"))
                    return (blobURL, c)
                }
                throw error
            }
        }

        // Coalesce concurrent opens for the same key.
        //
        // The coalescing entry is inserted BEFORE any await that could allow a
        // sibling call to reach this point concurrently. The entry is removed
        // after `task.value` resolves (inside the task itself, not in a defer on
        // the spawning frame) so late-arriving joiners always find a live entry
        // while the download is running (sync-04/sync-24 fix).
        //
        // Livelock guard: if the existing task was cancelled, `existing.value`
        // throws `CancellationError`. We remove the dead map entry and fall
        // through to spawn a fresh download (sync-03: the control-flow is now
        // explicit — only CancellationError continues, other errors would
        // rethrow from the `do` below and not reach the spawn path).
        let keyString = key.stableKeyString
        if let existing = inFlightDownloads[keyString] {
            do {
                return try await existing.value
            } catch is CancellationError {
                // The first task was cancelled — clear the stale entry and fall
                // through to spawn a fresh task for this caller. Propagate the
                // cancellation normally if *this* task is also cancelled.
                inFlightDownloads.removeValue(forKey: keyString)
                try Task.checkCancellation()
                // Fall through to spawn a fresh download below.
            }
            // For any other error the entry was already cleaned up by the task
            // itself; we reach here only via the CancellationError branch above.
        }

        let myGeneration: UInt64 = {
            let next = (downloadGenerations[keyString] ?? 0) + 1
            downloadGenerations[keyString] = next
            return next
        }()

        // Snapshot mutable state needed inside the unstructured task so it
        // doesn't capture `self` via actor isolation.
        let gen = myGeneration
        let task = Task<OpenResult, any Error> { [self] in
            defer {
                // Remove the map entry after the task value is delivered so
                // late-arriving joiners always find a live entry (sync-24 fix).
                // Called directly (not wrapped in a new Task) so cleanup runs
                // in the same actor turn as task completion — no ordering gap.
                self.cleanupInflight(keyString: keyString, generation: gen)
            }
            return try await self.performDownload(key: key, start: start, cached: cached, onProgress: onProgress)
        }
        inFlightDownloads[keyString] = task

        // Propagate cancellation to the unstructured download task so that if
        // the caller is cancelled while awaiting the result, the inner task
        // (which may be blocked inside onelake.read()) also gets cancelled.
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    // MARK: - Item type resolution

    /// Resolves the Fabric item type to stamp on a row for `key`.
    ///
    /// Returns the cached row's own `itemType` when non-empty, else the parent
    /// directory row's `itemType`, else `""`. An empty string is treated as
    /// "unknown" by `computeCapabilities`, which yields read-only capabilities.
    ///
    /// This is the single derivation used by the write paths (`put`, `mkdir`,
    /// `performDownload`) and by `ItemResolution.createItem`'s synthetic
    /// fallback so a freshly created/uploaded file under a Lakehouse `Files/`
    /// subtree keeps writable capabilities without waiting for the next
    /// refreshFolder (fp-05).
    public func resolveItemType(for key: CacheKey) async -> String {
        let own = (try? await cache.fetch(key: key))?.itemType ?? ""
        if !own.isEmpty { return own }
        let parentKey = CacheKey(
            accountAlias: key.accountAlias, workspaceID: key.workspaceID,
            itemID: key.itemID, path: Enumerator.parentPath(key.path)
        )
        return (try? await cache.fetch(key: parentKey))?.itemType ?? ""
    }

    // MARK: - Put (upload)

    /// Uploads the file at `sourceURL` to OneLake and mirrors it in the blob
    /// cache.
    ///
    /// macOS metadata files are silently swallowed (no telemetry, no upload).
    public func put(key: CacheKey, sourceURL: URL) async throws {
        if isMacOSMetadata(key.path) {
            logger.debug("ignoring macOS metadata upload", metadata: ["path": key.path])
            return
        }

        try await pauseManager.guardPaused(workspaceID: key.workspaceID, alias: key.accountAlias)
        try await acquireUploadSlot(alias: key.accountAlias)
        defer { releaseUploadSlot(alias: key.accountAlias) }

        let start = Date()
        // Determine size from the file on disk. Run off-actor to avoid blocking
        // the actor thread with synchronous FileManager calls (sync-14).
        let fileSize: Int64 = try await Task.detached(priority: .userInitiated) {
            let attrs = try FileManager.default.attributesOfItem(atPath: sourceURL.path)
            return (attrs[.size] as? NSNumber)?.int64Value ?? 0
        }.value

        do {
            try await onelake.write(
                alias: key.accountAlias,
                workspaceGUID: key.workspaceID,
                itemGUID: key.itemID,
                path: key.path,
                sourceURL: sourceURL,
                size: fileSize
            )
        } catch {
            try await withRemoteOperationError(
                error: error, key: key, eventName: "file_upload",
                failCode: "write_failed", start: start
            )
        }
        await offlineTracker.observe(nil)

        // Best-effort HEAD to capture the server-assigned etag/lastmod.
        // Log a warning on failure so the missing etag is visible rather than
        // silently leaving the row with etag="" (sync-12).
        let nowNs = currentNowNs()
        // Carry the item type from the existing cache row or the parent
        // directory row so that a freshly uploaded file under a Lakehouse
        // Files/ subtree keeps writable capabilities without waiting for the
        // next refreshFolder (fp-05).
        let cached = try? await cache.fetch(key: key)
        let existingItemType = await resolveItemType(for: key)
        var row = MetadataRecord(
            accountAlias: key.accountAlias,
            workspaceID: key.workspaceID,
            itemID: key.itemID,
            path: key.path,
            parentPath: Enumerator.parentPath(key.path),
            name: Enumerator.baseName(key.path),
            isDir: false,
            contentLength: fileSize,
            lastAccessedNs: nowNs,
            syncedAtNs: nowNs,
            itemType: existingItemType,
            // Carry forward a previously-captured creation time so a HEAD failure
            // after upload does not overwrite a good createdNs with 0 (symmetric
            // with the performDownload path that uses cached?.createdNs ?? 0).
            createdNs: cached?.createdNs ?? 0
        )
        do {
            let props = try await onelake.getProperties(
                alias: key.accountAlias,
                workspaceGUID: key.workspaceID,
                itemGUID: key.itemID,
                path: key.path
            )
            row.etag = props.eTag
            if props.contentLength != 0 { row.contentLength = props.contentLength }
            row.lastModifiedNs = dateToNsOrNil(props.lastModified) ?? 0
            row.contentType = props.contentType
            // Capture real creation time from the HEAD response when available.
            // The entryChanged createdNs guard will fire a metadata update so
            // Finder refreshes the displayed Date Created without a re-download.
            if let cd = props.creationDate { row.createdNs = dateToNsOrNil(cd) ?? cached?.createdNs ?? 0 }
        } catch {
            // sync-12: log HEAD failure so the empty-etag outcome is detectable.
            logger.warn("put: post-upload HEAD failed; row will have empty etag",
                        metadata: ["path": key.path, "error": "\(error)"])
        }

        // sync-29: treat the metadata upsert and blob store as a logical unit.
        // Both must succeed for the cache to be consistent. Surface any error
        // from either step rather than swallowing it independently.
        let rowCopy = row
        try await cache.upsert(rowCopy)
        // Mirror locally (best-effort after upsert: upload already succeeded).
        // storeBlobFromURL prefers an atomic moveItem (same-volume, zero-copy).
        // On FPE retry the source URL may be absent; log but don't fail.
        do {
            try await cache.storeBlobFromURL(sourceURL, key: key)
        } catch {
            logger.warn("put: storeBlobFromURL failed (blob cache inconsistent)",
                        metadata: ["path": key.path, "error": "\(error)"])
        }

        await track(TelemetryEvent(
            name: "file_upload",
            accountAliasHash: TelemetryRedaction.hashAlias(key.accountAlias),
            durationMs: elapsedMs(since: start),
            success: true,
            bytesTransferred: fileSize
        ))
    }

    // MARK: - Private: in-flight cleanup (sync-24)

    /// Removes the coalescing map entry for `keyString` if it still belongs to
    /// `generation`. Called from within the download task after it produces its
    /// value so late-arriving joiners always find a live entry.
    private func cleanupInflight(keyString: String, generation: UInt64) {
        if downloadGenerations[keyString] == generation {
            inFlightDownloads.removeValue(forKey: keyString)
            downloadGenerations.removeValue(forKey: keyString)
        }
    }

    // MARK: - Private: download implementation

    /// Executes the actual network download for `open()`.
    ///
    /// Acquires a semaphore slot, handles the 412-resume-discard-retry path
    /// (using ``ResumePlan`` for clean state representation), and returns a
    /// file URL alongside the metadata record just written for it. All
    /// blocking filesystem I/O runs off the actor via `Task.detached` (sync-14).
    ///
    /// The 412-resume-discard-retry state machine needs to stay in one place
    /// to reason about correctness; splitting would scatter the resume logic
    /// across functions.
    // swiftlint:disable:next function_body_length
    private func performDownload(
        key: CacheKey,
        start: Date,
        cached: MetadataRecord?,
        onProgress: (@Sendable (Int64, Int64) -> Void)? = nil
    ) async throws -> OpenResult {
        try await acquireDownloadSlot(alias: key.accountAlias)
        defer { releaseDownloadSlot(alias: key.accountAlias) }

        // Decide resume offset from the spill file / etag sidecar (sync-09:
        // ResumePlan captures all three correlated values atomically).
        let emptyRecord = MetadataRecord(
            accountAlias: key.accountAlias, workspaceID: key.workspaceID,
            itemID: key.itemID, path: key.path, parentPath: "",
            name: Enumerator.baseName(key.path), isDir: false
        )
        let plan = partials.rangeStart(for: key, cachedRecord: cached ?? emptyRecord)

        // Run all blocking spill-file I/O off the actor (sync-14).
        let spillURL = partials.partialURL(for: key)
        try await Task.detached(priority: .userInitiated) {
            try FileManager.default.createDirectory(
                at: spillURL.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            if !FileManager.default.fileExists(atPath: spillURL.path) {
                FileManager.default.createFile(atPath: spillURL.path, contents: nil)
            }
        }.value

        // Perform the download, handling 412 on the resume path.
        let props = try await performNetworkRead(
            key: key, spillURL: spillURL, plan: plan, start: start, onProgress: onProgress
        )
        await offlineTracker.observe(nil)

        // Cancellation checkpoint after the (potentially long) network read.
        try Task.checkCancellation()

        // Pin the partial etag when starting fresh (no existing partial).
        if !plan.hasPartial && !props.eTag.isEmpty {
            let etagToStore = props.eTag
            do { try partials.storeEtag(etagToStore, for: key) } catch {
                Self.log.warning("open: storeEtag failed err=\(error, privacy: .public)")
            }
        }

        // Compute total expected. Prefer the server-authoritative total from
        // the `Content-Range` header (`props.totalLength`, C8) when present —
        // it needs no client-side arithmetic and so cannot overflow. Fall back
        // to `plan.rangeStart` (local spill file size) + `props.contentLength`
        // (remote `Content-Length` header, which on a 206 response is only the
        // size of the returned range, not the full file) when the header was
        // absent, e.g. a full 200 response or an older/non-conformant server.
        // Both fallback inputs are untrusted; a hostile or corrupted header
        // near `Int64.max` could overflow the plain `+` and trap. Use a
        // reporting add so an absurd combination surfaces as a handled error
        // instead.
        var expectedTotal = cached?.contentLength ?? 0
        if let totalLength = props.totalLength, totalLength > 0 {
            expectedTotal = totalLength
        } else if props.contentLength > 0 {
            if plan.hasPartial {
                let (total, overflowed) = plan.rangeStart.addingReportingOverflow(props.contentLength)
                guard !overflowed else {
                    // Discard the partial + etag sidecar before rethrowing (#413).
                    // Otherwise the next open() resumes from the same offset, sees
                    // the same hostile Content-Length, and overflows again forever —
                    // discarding self-heals into a fresh full download instead.
                    partials.discard(for: key)
                    throw SyncError.resumeOffsetOverflow(
                        rangeStart: plan.rangeStart, contentLength: props.contentLength
                    )
                }
                expectedTotal = total
            } else {
                expectedTotal = props.contentLength
            }
        }

        // Determine spill file size and verify (off actor — sync-14).
        let spillSize: Int64 = try await Task.detached(priority: .userInitiated) {
            let attrs = try FileManager.default.attributesOfItem(atPath: spillURL.path)
            return (attrs[.size] as? NSNumber)?.int64Value ?? 0
        }.value

        if expectedTotal > 0, spillSize != expectedTotal {
            if spillSize > expectedTotal { partials.discard(for: key) }
            throw SyncError.shortDownload(expected: expectedTotal, got: spillSize)
        }

        // Cancellation checkpoint before the expensive SHA pass.
        try Task.checkCancellation()

        // SHA verification when an expected hash is known. Run off actor (sync-14).
        let expectedSHA = plan.hasPartial ? cached?.blobSHA256 : nil
        if let expected = expectedSHA, !expected.isEmpty {
            let got = try await Task.detached(priority: .userInitiated) {
                try self.partials.hashSpillFile(spillURL)
            }.value
            if got != expected {
                partials.discard(for: key)
                throw SyncError.blobSHAMismatch(got: got, expected: expected)
            }
        }

        // Cancellation checkpoint before cache writes.
        try Task.checkCancellation()

        // Upsert metadata row and blob store as a logical pair (sync-29).
        let nowNs = currentNowNs()
        // Carry the item type from the cached row (or the parent directory)
        // so that a downloaded file under a Lakehouse Files/ subtree keeps
        // writable capabilities without waiting for the next refreshFolder (fp-05).
        // This is an INTENTIONAL fresh cache read, not the pre-download `cached`
        // snapshot: `itemType` is immutable per item, so it can never flip to a
        // different non-empty type here; the worst case is a momentary "" if a
        // concurrent refreshFolder transiently evicted the item-discovery row,
        // which self-corrects on the next poll. Do NOT "optimize" this back to
        // `cached?.itemType` — the snapshot buys nothing and drops that recovery.
        let downloadItemType = await resolveItemType(for: key)
        var row = MetadataRecord(
            accountAlias: key.accountAlias,
            workspaceID: key.workspaceID,
            itemID: key.itemID,
            path: key.path,
            parentPath: Enumerator.parentPath(key.path),
            name: Enumerator.baseName(key.path),
            isDir: false,
            contentLength: expectedTotal > 0 ? expectedTotal : spillSize,
            etag: props.eTag,
            lastModifiedNs: dateToNsOrNil(props.lastModified) ?? 0,
            contentType: props.contentType,
            lastAccessedNs: nowNs,
            syncedAtNs: nowNs,
            itemType: downloadItemType,
            // Capture real creation time from GET/HEAD response header. The
            // entryChanged createdNs guard triggers a metadata-only update so
            // Finder refreshes Date Created without forcing a re-download.
            createdNs: props.creationDate.flatMap { dateToNsOrNil($0) } ?? cached?.createdNs ?? 0
        )
        if row.name.isEmpty { row.name = Enumerator.baseName(key.path) }

        // sync-29: surface paired-write errors. If the upsert fails, don't
        // proceed to storeBlobFromURL — a blob with no linking row is an orphan.
        let downloadRow = row
        do {
            try await cache.upsert(downloadRow)
        } catch {
            Self.log.warning("open: upsert failed err=\(error, privacy: .public)")
            // Blob store skipped — row not present to link SHA.
            // Fall back to the spill file so the caller gets content even though
            // the cache is inconsistent.
            await track(eventName: "file_download", alias: key.accountAlias, start: start,
                        outcome: .success(bytes: spillSize))
            return (spillURL, downloadRow)
        }

        // Move/copy spill file into the blob cache. storeBlobFromURL returns
        // the sha256/size it just computed, so `row` can carry them without a
        // redundant re-fetch of the record we just upserted.
        do {
            let (sha, size) = try await cache.storeBlobFromURL(spillURL, key: key)
            row.blobSHA256 = sha
            row.blobSize = size
        } catch {
            Self.log.warning("open: storeBlobFromURL failed (blob cache inconsistent) err=\(error, privacy: .public)")
        }

        // Return the blob URL when available; fall back to the spill file when
        // the cache store failed.
        if let blobURL = await cache.blobURL(record: row) {
            await track(eventName: "file_download", alias: key.accountAlias, start: start,
                        outcome: .success(bytes: spillSize))
            return (blobURL, row)
        } else {
            logger.warn("open: blob cache unavailable; returning spill file URL",
                        metadata: ["path": key.path])
            await track(eventName: "file_download", alias: key.accountAlias, start: start,
                        outcome: .success(bytes: spillSize))
            return (spillURL, row)
        }
    }

    /// Thread-safe, monotonically-non-decreasing clamp for one download's
    /// progress `completed` value (#461 review round 3).
    ///
    /// The session's interceptor chain (`RetryAfterRetrier`,
    /// `JitteredRetryPolicy`, `AuthenticationInterceptor`'s
    /// 401→refresh→retry) can silently retry the SAME `DownloadRequest`
    /// mid-transfer — which restarts from byte 0 and resets Alamofire's own
    /// per-request `completedUnitCount` to 0 — without ever re-entering
    /// `performNetworkRead`, so nothing else observes it happening. Without
    /// this clamp the absolute `completed` reported to the caller would jump
    /// backward every time that happens (and, separately, at the
    /// 412-full-restart boundary, which also restarts from byte 0). `clamp(_:)`
    /// is `@Sendable`-safe to call from Alamofire's own delivery queue.
    final class MonotonicProgressClamp: @unchecked Sendable {
        private let lock = NSLock()
        private var highWaterMark: Int64 = 0

        /// Returns the higher of `candidate` and every previously-clamped
        /// value, and remembers it for the next call.
        func clamp(_ candidate: Int64) -> Int64 {
            lock.withLock {
                if candidate > highWaterMark {
                    highWaterMark = candidate
                }
                return highWaterMark
            }
        }
    }

    /// Combines a single network attempt's own (completed, total) progress
    /// tick with the local resume offset to produce an ABSOLUTE pair for the
    /// whole file (#461, review round 2).
    ///
    /// Alamofire's `totalUnitCount` for a ranged/resumed request only covers
    /// the bytes THIS request returns (the remaining range), not the full
    /// file — adding `rangeStart` (bytes already on disk from a prior
    /// attempt) reconstructs the true total live, from data the progress
    /// tick itself carries. This deliberately does NOT use a value sourced
    /// before the download started (e.g. a cached row's stale
    /// `contentLength`): if the remote size changed since that row was
    /// written — most plausible exactly on the 412-resume-discard-retry path,
    /// which exists BECAUSE the remote object changed — a fixed pre-download
    /// total could report `completed > total` or land short of 100%.
    ///
    /// - Returns: `total == 0` when Alamofire hasn't reported a positive
    ///   total for this request yet (e.g. chunked transfer encoding) —
    ///   callers treat that as "indeterminate" rather than inventing a
    ///   number. A hostile/corrupted header that would overflow `Int64` when
    ///   added to `rangeStart` degrades the same way (this is a UI hint, not
    ///   correctness-critical, so it silently drops to indeterminate rather
    ///   than throwing).
    static func absoluteDownloadProgress(
        rangeStart: Int64,
        completedInRequest: Int64,
        totalInRequest: Int64
    ) -> (completed: Int64, total: Int64) {
        let (completed, completedOverflowed) = rangeStart.addingReportingOverflow(completedInRequest)
        guard !completedOverflowed else { return (0, 0) }
        guard totalInRequest > 0 else { return (completed, 0) }
        let (total, totalOverflowed) = rangeStart.addingReportingOverflow(totalInRequest)
        return (completed, totalOverflowed ? 0 : total)
    }

    /// Issues the network read for a single download attempt. Handles the 412
    /// precondition-failed path by resetting to a full restart and retrying
    /// once (sync-02/sync-09/sync-23).
    ///
    /// All blocking FileHandle operations run off the actor via `Task.detached`
    /// (sync-14).
    ///
    /// - Parameter onProgress: Forwarded to `onelake.read(...)`, wrapped per
    ///   attempt via ``absoluteDownloadProgress(rangeStart:completedInRequest:totalInRequest:)``
    ///   so the caller sees an ABSOLUTE (completed, total) pair rather than
    ///   values relative to this one request. The 412-retry-as-full-restart
    ///   branch below rewraps with a `rangeStart` of 0 — that attempt is a
    ///   fresh, unranged GET, so the original resume offset no longer applies.
    ///   A single ``MonotonicProgressClamp`` is shared across both the primary
    ///   attempt and that 412 retry, so `completed` can never regress across
    ///   either boundary (#461 review round 3): the session's interceptor
    ///   chain (`RetryAfterRetrier`, `JitteredRetryPolicy`,
    ///   `AuthenticationInterceptor`'s 401→refresh→retry) can silently retry
    ///   the SAME `DownloadRequest` mid-transfer — which restarts from byte 0
    ///   and resets Alamofire's own per-request progress — without ever
    ///   re-entering this function, so nothing else would catch it.
    private func performNetworkRead(
        key: CacheKey,
        spillURL: URL,
        plan: ResumePlan,
        start: Date,
        onProgress: (@Sendable (Int64, Int64) -> Void)? = nil
    ) async throws -> PathProperties {
        // Fresh per call to this function (i.e. per open()/fetchContents
        // attempt) — shared across the primary attempt and the 412-retry
        // branch below so it survives any restart-from-byte-0 within THIS
        // download without resetting; a NEW performNetworkRead call (a new
        // fetch) always gets its own instance.
        let progressClamp = MonotonicProgressClamp()

        func absoluteProgress(rangeStart: Int64) -> (@Sendable (Int64, Int64) -> Void)? {
            guard let onProgress else { return nil }
            return { @Sendable completedInRequest, totalInRequest in
                let (completed, total) = Self.absoluteDownloadProgress(
                    rangeStart: rangeStart, completedInRequest: completedInRequest, totalInRequest: totalInRequest
                )
                // `total` is intentionally passed through unclamped — only
                // `completed` is high-water-marked. A silently-retried SAME
                // request reporting a SMALLER totalInRequest than an earlier
                // tick (near-impossible; would almost always trip an
                // etag/412 mismatch first) could transiently let the clamped
                // `completed` exceed a shrunk `total` mid-download. That's a
                // theoretical visual glitch only, not a correctness issue: a
                // second high-water-mark on `total` would add its own
                // cross-clamp subtleties for a scenario this unlikely, and
                // fetchContents' completion step forces both totalUnitCount
                // and completedUnitCount to actualBytes regardless (#461
                // review round 3 addendum).
                onProgress(progressClamp.clamp(completed), total)
            }
        }

        // Open the spill file, seek to the resume offset, and hold the handle
        // open for the streaming read. Single FD open per attempt — the handle
        // is passed directly to onelake.read() and closed exactly once on all
        // paths below (success, error, cancellation). Runs off-actor to avoid
        // blocking on FileHandle (sync-14).
        let readHandleResult: Result<FileHandle, any Error> = await Task.detached(priority: .userInitiated) {
            do {
                let h = try FileHandle(forUpdating: spillURL)
                try h.seek(toOffset: UInt64(plan.rangeStart))
                return .success(h)
            } catch {
                return .failure(SyncError.spillFileError(error))
            }
        }.value
        let spillHandle: FileHandle
        switch readHandleResult {
        case let .failure(err): throw err
        case let .success(h): spillHandle = h
        }

        do {
            let props = try await onelake.read(
                alias: key.accountAlias,
                workspaceGUID: key.workspaceID,
                itemGUID: key.itemID,
                path: key.path,
                range: plan.range,
                ifMatch: plan.ifMatch,
                destination: spillHandle,
                onProgress: absoluteProgress(rangeStart: plan.rangeStart)
            )
            try? spillHandle.close()
            return props
        } catch {
            try? spillHandle.close()
            // 412 on resume: discard the stale partial and retry with a full
            // download (sync-09/23: ResumePlan.fullRestart captures the reset).
            if plan.hasPartial, case OneLakeError.preconditionFailed = error {
                logger.info("resume etag changed; discarding partial and restarting",
                            metadata: ["path": key.path])
                partials.discard(for: key)
                // Re-create the spill file from scratch (off actor).
                await Task.detached(priority: .userInitiated) {
                    try? FileManager.default.removeItem(at: spillURL)
                    FileManager.default.createFile(atPath: spillURL.path, contents: nil)
                }.value
                let freshHandleResult: Result<FileHandle, any Error> = await Task.detached(priority: .userInitiated) {
                    do {
                        return .success(try FileHandle(forUpdating: spillURL))
                    } catch {
                        return .failure(SyncError.spillFileError(error))
                    }
                }.value
                let freshHandle: FileHandle
                switch freshHandleResult {
                case let .failure(e): throw e
                case let .success(h): freshHandle = h
                }
                do {
                    let props = try await onelake.read(
                        alias: key.accountAlias,
                        workspaceGUID: key.workspaceID,
                        itemGUID: key.itemID,
                        path: key.path,
                        range: nil,
                        ifMatch: "",
                        destination: freshHandle,
                        // Full restart from byte 0 — the original rangeStart no
                        // longer applies (#461).
                        onProgress: absoluteProgress(rangeStart: 0)
                    )
                    try? freshHandle.close()
                    return props
                } catch {
                    try? freshHandle.close()
                    // Discard spill before rethrowing so the next open() starts fresh.
                    partials.discard(for: key)
                    try await withRemoteOperationError(
                        error: error, key: key, eventName: "file_download",
                        failCode: "read_failed", start: start
                    )
                }
            } else {
                // Non-412 failure: discard any spill + etag sidecar before
                // rethrowing so the next open() re-downloads from scratch.
                partials.discard(for: key)
                try await withRemoteOperationError(
                    error: error, key: key, eventName: "file_download",
                    failCode: "read_failed", start: start
                )
            }
        }
    }

    private func isBlobFresh(key: CacheKey, cached: MetadataRecord) async throws -> (Bool, PathProperties?) {
        let props = try await onelake.getProperties(
            alias: key.accountAlias,
            workspaceGUID: key.workspaceID,
            itemGUID: key.itemID,
            path: key.path
        )
        if cached.etag.isEmpty { return (false, props) }
        if !props.eTag.isEmpty, props.eTag == cached.etag { return (true, props) }
        return (false, props)
    }

    // MARK: - Semaphore helpers (download / upload, actor-isolated)

    private func acquireDownloadSlot(alias: String) async throws {
        let sem = downloadSemaphore(for: alias)
        try await sem.wait()
    }

    private func releaseDownloadSlot(alias: String) {
        downloadSemaphore(for: alias).signal()
    }

    private func acquireUploadSlot(alias: String) async throws {
        let sem = uploadSemaphore(for: alias)
        try await sem.wait()
    }

    private func releaseUploadSlot(alias: String) {
        uploadSemaphore(for: alias).signal()
    }

    private func downloadSemaphore(for alias: String) -> AsyncSemaphore {
        if let s = downloadSlots[alias] { return s }
        let s = AsyncSemaphore(value: maxDownloads)
        downloadSlots[alias] = s
        return s
    }

    private func uploadSemaphore(for alias: String) -> AsyncSemaphore {
        if let s = uploadSlots[alias] { return s }
        let s = AsyncSemaphore(value: maxUploads)
        uploadSlots[alias] = s
        return s
    }
}
