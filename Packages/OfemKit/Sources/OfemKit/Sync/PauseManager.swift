import Foundation
import os.log

// MARK: - PauseManager

/// Tracks workspace pause state and serialises recovery probes.
///
/// State machine:
///
/// - When a network call returns a paused-capacity response, the manager
/// records the workspace as `.paused` in the ``CacheStore``.
/// - Every subsequent call through ``guardPaused(workspaceID:alias:)`` returns
/// ``SyncError/workspacePaused`` immediately (no network call).
/// - A recovery probe (HEAD against the workspace root) is sent at most once
/// per ``probeInterval``. Multiple concurrent callers that trigger a probe
/// are serialised: only one probe runs; others either see the recovered
/// state or return early.
///
/// `PauseManager` is a Swift `actor` so all mutable state (the in-flight probe
/// set) is automatically serialised.
actor PauseManager {
    // MARK: - Constants

    /// Default minimum gap between two recovery probes for the same workspace.
    static let defaultProbeInterval: Duration = .seconds(120)

    // MARK: - State

    private let cache: CacheStore
    private let onelake: any OneLakeClientProtocol
    private let probeInterval: Duration
    private var inFlightProbes: Set<String> = []

    private static let log = Logger(subsystem: "dev.debruyn.ofem", category: "PauseManager")

    // MARK: - Paused-capacity detection

    /// Stable Fabric REST `errorCode` values that signal a paused capacity.
    ///
    /// These are the primary signal — reliable, locale-independent, versioned
    /// in the Fabric API contract. The regex below is a secondary fallback for
    /// older API versions that do not populate `errorCode` (sync-17).
    ///
    /// Note: the exact `errorCode` values a paused F-SKU returns on the DFS and
    /// Fabric REST paths have not been confirmed against a live paused capacity.
    /// Verifying and extending this table with a real paused F-SKU capture is a
    /// follow-up (see open questions in issue #385).
    private static let pausedErrorCodes: Set<String> = [
        "capacitypaused",
        "capacitysuspended",
        "capacitynotactive",
        "workspacecapacitypaused",
        "capacityassignmentpaused",
    ]

    /// Regex matching the phrases Fabric may return when a workspace's capacity
    /// is paused. Used only when no `errorCode` field is present in the body
    /// (sync-17: prose matching is locale- and wording-fragile; the stable
    /// `errorCode` above is always checked first).
    // swiftlint:disable:next force_try
    private static let pausedCapacityPattern = try! NSRegularExpression( // safe: literal pattern, never fails
        // Regex literal cannot be broken across lines without altering the pattern.
        // swiftlint:disable:next line_length
        pattern: #"(?i)(capacity\s+not\s+active|capacity\s+is\s+not\s+active|fabric\s+capacity\s+is\s+(currently\s+)?paused|capacity\s+is\s+(currently\s+)?paused|capacity\s+suspended|capacity\s+has\s+been\s+paused|capacity\s+\S+\s+is\s+currently\s+not\s+available|capacity\s+is\s+(currently\s+)?not\s+available)"#,
        options: []
    )

    // MARK: - Init

    /// Creates a `PauseManager`.
    ///
    /// - Parameters:
    /// - cache: The cache store used to persist workspace status.
    /// - onelake: The DFS client used to probe workspace reachability.
    /// - probeInterval: Minimum gap between recovery probes for the same
    /// workspace. Default: ``defaultProbeInterval``.
    init(
        cache: CacheStore,
        onelake: any OneLakeClientProtocol,
        probeInterval: Duration = PauseManager.defaultProbeInterval
    ) {
        self.cache = cache
        self.onelake = onelake
        self.probeInterval = probeInterval
    }

    // MARK: - Internal API (sync-26: reduced from public to internal)

    /// Checks whether `workspaceID` is paused, issuing a recovery probe when
    /// the minimum interval has elapsed. Returns without throwing when the
    /// workspace is reachable; throws ``SyncError/workspacePaused`` when it is
    /// still paused.
    func guardPaused(workspaceID: String, alias: String) async throws {
        guard let status = try? await cache.workspaceStatus(
            accountAlias: alias, workspaceID: workspaceID
        ) else {
            // No cached status row → assume active.
            return
        }
        guard status.state == .paused else { return }

        // Try a probe; if it succeeds (or if another probe already recovered
        // the workspace) return without throwing.
        let recovered = await probe(workspaceID: workspaceID, alias: alias, current: status)
        if !recovered {
            throw SyncError.workspacePaused
        }
    }

    /// Records `workspaceID` as paused when `error` is a paused-capacity
    /// signal.
    ///
    /// Returns `true` when the error was a paused-capacity signal (caller
    /// should re-map to ``SyncError/workspacePaused``).
    func markPausedIfNeeded(workspaceID: String, alias: String, error: any Error) async -> Bool {
        guard isPausedCapacityError(error) else { return false }

        let now = Date()
        let status = WorkspaceStatusRecord(
            accountAlias: alias,
            workspaceID: workspaceID,
            state: .paused,
            reason: "capacity_paused",
            detectedAtNs: dateToNs(now)
        )
        do {
            try await cache.setWorkspaceStatus(status)
            Self.log.info("PauseManager: workspace marked paused alias=\(alias, privacy: .public) ws=\(workspaceID, privacy: .public)")
        } catch {
            Self.log.warning("PauseManager: failed to persist paused status alias=\(alias, privacy: .public) ws=\(workspaceID, privacy: .public) err=\(error, privacy: .public)")
        }
        return true
    }

    // MARK: - Paused-capacity detection (internal, nonisolated for reuse)

    /// Returns `true` when `error` signals a paused / suspended Fabric capacity.
    ///
    /// Detection order (sync-17, extended):
    /// 0. Check `x-ms-error-code` response header — fastest path, catches
    ///    paused-capacity 404s whose bodies are empty.
    /// 1. Parse `errorCode` from the JSON body — stable and locale-independent.
    /// 2. Fall back to regex over the prose body — catches older API versions.
    nonisolated func isPausedCapacityError(_ error: any Error) -> Bool {
        // Fast path: header-based check (catches 404 CapacityNotActive with empty body).
        if let code = extractMsErrorCode(error),
           Self.pausedErrorCodes.contains(code.lowercased())
        {
            return true
        }

        let body = extractAPIErrorBody(error)
        guard let body, !body.isEmpty else { return false }

        // Primary: stable errorCode check.
        if let code = extractErrorCode(from: body),
           Self.pausedErrorCodes.contains(code.lowercased())
        {
            return true
        }
        // Secondary: prose regex fallback for older API responses.
        let range = NSRange(body.startIndex..., in: body)
        return Self.pausedCapacityPattern.firstMatch(in: body, range: range) != nil
    }

    // MARK: - Private probe logic

    /// Runs one recovery probe if the interval has elapsed and no other probe
    /// is in flight for the same workspace. Returns `true` on recovery.
    private func probe(workspaceID: String, alias: String, current: WorkspaceStatusRecord) async -> Bool {
        // Respect the minimum probe interval.
        if let probedAt = current.probedAt {
            let age = Date().timeIntervalSince(probedAt)
            if age < probeInterval.seconds { return false }
        }

        let key = "\(alias)/\(workspaceID)"
        guard !inFlightProbes.contains(key) else { return false }
        inFlightProbes.insert(key)
        defer { inFlightProbes.remove(key) }

        // Re-read after acquiring the "lock" to catch a concurrent recovery.
        if let fresh = try? await cache.workspaceStatus(accountAlias: alias, workspaceID: workspaceID) {
            if fresh.state == .active { return true }
            if let probedAt = fresh.probedAt {
                let age = Date().timeIntervalSince(probedAt)
                if age < probeInterval.seconds { return false }
            }
        }

        // Issue a cheap HEAD against the workspace root.
        let now = Date()
        do {
            _ = try await onelake.getProperties(
                alias: alias,
                workspaceGUID: workspaceID,
                itemGUID: workspaceID,
                path: ""
            )
            // 2xx → recovered.
            let recovered = WorkspaceStatusRecord(
                accountAlias: alias,
                workspaceID: workspaceID,
                state: .active,
                detectedAtNs: dateToNs(now),
                probedAtNs: dateToNs(now)
            )
            try? await cache.setWorkspaceStatus(recovered)
            Self.log.info("PauseManager: workspace recovered alias=\(alias, privacy: .public) ws=\(workspaceID, privacy: .public)")
            return true
        } catch {
            // Non-2xx or transport failure → stay paused; update probedAt.
            let stillPaused = WorkspaceStatusRecord(
                accountAlias: alias,
                workspaceID: workspaceID,
                state: .paused,
                reason: current.reason,
                detectedAtNs: current.detectedAtNs,
                probedAtNs: dateToNs(now)
            )
            try? await cache.setWorkspaceStatus(stillPaused)
            return false
        }
    }
}

// MARK: - APIError header extraction

private func extractMsErrorCode(_ error: any Error) -> String? {
    switch error {
    case let onelakeErr as OneLakeError:
        if case let .httpError(inner) = onelakeErr {
            return extractMsErrorCode(inner)
        }
    case let fabricErr as FabricError:
        if case let .httpError(inner) = fabricErr {
            return extractMsErrorCode(inner)
        }
    case let httpErr as HTTPClientError:
        if case let .apiError(api) = httpErr {
            return api.msErrorCode
        } else if case let .sentinelWithBody(_, api) = httpErr {
            return api.msErrorCode
        }
    default:
        break
    }
    return nil
}

// MARK: - APIError body extraction

private func extractAPIErrorBody(_ error: any Error) -> String? {
    switch error {
    case let onelakeErr as OneLakeError:
        if case let .httpError(inner) = onelakeErr {
            return extractAPIErrorBody(inner)
        }
    case let fabricErr as FabricError:
        if case let .httpError(inner) = fabricErr {
            return extractAPIErrorBody(inner)
        }
    case let httpErr as HTTPClientError:
        if case let .apiError(api) = httpErr {
            return String(data: api.body, encoding: .utf8)
        } else if case let .sentinelWithBody(_, api) = httpErr {
            // Body-carrying sentinel: the body was preserved at the transport
            // layer so PauseManager can inspect it for paused-capacity signals.
            return String(data: api.body, encoding: .utf8)
        }
    default:
        break
    }
    return nil
}

/// Parses a paused-capacity error code from a JSON error body.
///
/// Checks two shapes:
/// 1. Top-level `errorCode` — Fabric REST contract (primary).
/// 2. Nested `{"error":{"code":"…"}}` — ADLS Gen2 / DFS contract (fallback).
///
/// Both values are lowercased before returning so callers can match against
/// ``pausedErrorCodes`` case-insensitively.
///
/// Note: the exact key and nesting for a *paused-capacity* 403 on the DFS path
/// is unconfirmed — the nested shape is based on the documented ADLS Gen2
/// error contract. Verify against a real paused F-SKU body and extend
/// ``pausedErrorCodes`` accordingly (see open questions in issue #385).
private func extractErrorCode(from body: String) -> String? {
    guard let data = body.data(using: .utf8),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return nil }

    // 1. Top-level errorCode — Fabric REST error contract.
    for (key, value) in json {
        if key.lowercased() == "errorcode", let code = value as? String {
            return code.lowercased()
        }
    }

    // 2. Nested {"error":{"code":"…"}} — ADLS Gen2 / DFS error contract.
    if let errorObj = json["error"] as? [String: Any] {
        for (key, value) in errorObj {
            if key.lowercased() == "code", let code = value as? String {
                return code.lowercased()
            }
        }
    }

    return nil
}
