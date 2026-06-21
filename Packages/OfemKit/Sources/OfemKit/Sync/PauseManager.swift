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
    private static let pausedCapacityPattern = try! NSRegularExpression(
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
            detectedAtNs: Int64(now.timeIntervalSince1970 * 1_000_000_000)
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
    /// Detection order (sync-17):
    /// 1. Parse `errorCode` from the JSON body — stable and locale-independent.
    /// 2. Fall back to regex over the prose body — catches older API versions.
    nonisolated func isPausedCapacityError(_ error: any Error) -> Bool {
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
                detectedAtNs: Int64(now.timeIntervalSince1970 * 1_000_000_000),
                probedAtNs: Int64(now.timeIntervalSince1970 * 1_000_000_000)
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
                probedAtNs: Int64(now.timeIntervalSince1970 * 1_000_000_000)
            )
            try? await cache.setWorkspaceStatus(stillPaused)
            return false
        }
    }
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
        }
    default:
        break
    }
    return nil
}

/// Parses the `errorCode` field from a Fabric JSON error body.
private func extractErrorCode(from body: String) -> String? {
    guard let data = body.data(using: .utf8),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return nil }

    for (key, value) in json {
        if key.lowercased() == "errorcode", let code = value as? String {
            return code.lowercased()
        }
    }
    return nil
}
