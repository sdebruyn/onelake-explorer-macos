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
public actor PauseManager {

    // MARK: - Constants

    /// Default minimum gap between two recovery probes for the same workspace.
    public static let defaultProbeInterval: Duration = .seconds(120)

    // MARK: - State

    private let cache: CacheStore
    private let onelake: OneLakeClient
    private let probeInterval: Duration
    private var inFlightProbes: Set<String> = []

    private static let log = Logger(subsystem: "dev.debruyn.ofem", category: "PauseManager")

    // MARK: - Paused-capacity detection

    /// Regex matching the phrases Fabric returns when a workspace's capacity is
    /// paused.
    private static let pausedCapacityPattern = try! NSRegularExpression(
        pattern: #"(?i)(capacity\s+not\s+active|capacity\s+is\s+not\s+active|fabric\s+capacity\s+is\s+(currently\s+)?paused|capacity\s+is\s+(currently\s+)?paused|capacity\s+suspended|capacity\s+has\s+been\s+paused|capacity\s+\S+\s+is\s+currently\s+not\s+available|capacity\s+is\s+(currently\s+)?not\s+available)"#,
        options: []
    )

    /// Stable Fabric REST `errorCode` values that signal a paused capacity.
    private static let pausedErrorCodes: Set<String> = [
        "capacitypaused",
        "capacitysuspended",
        "capacitynotactive",
        "workspacecapacitypaused",
        "capacityassignmentpaused",
    ]

    // MARK: - Init

    /// Creates a `PauseManager`.
    ///
    /// - Parameters:
    /// - cache: The cache store used to persist workspace status.
    /// - onelake: The DFS client used to probe workspace reachability.
    /// - probeInterval: Minimum gap between recovery probes for the same
    /// workspace. Default: ``defaultProbeInterval``.
    public init(
        cache: CacheStore,
        onelake: OneLakeClient,
        probeInterval: Duration = PauseManager.defaultProbeInterval
    ) {
        self.cache = cache
        self.onelake = onelake
        self.probeInterval = probeInterval
    }

    // MARK: - Public API

    /// Checks whether `workspaceID` is paused, issuing a recovery probe when
    /// the minimum interval has elapsed. Returns without throwing when the
    /// workspace is reachable; throws ``SyncError/workspacePaused`` when it is
    /// still paused.
    public func guardPaused(workspaceID: String, alias: String) async throws {
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
    public func markPausedIfNeeded(workspaceID: String, alias: String, error: any Error) async -> Bool {
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

    /// Sweeps all workspaces currently flagged as paused and runs one recovery
    /// probe per workspace.
    public func sweepPausedWorkspaces() async {
        guard let rows = try? await cache.allWorkspaceStatuses() else { return }
        for row in rows where row.state == .paused {
            _ = await probe(workspaceID: row.workspaceID, alias: row.accountAlias, current: row)
        }
    }

    // MARK: - Paused-capacity detection (internal, nonisolated for reuse)

    /// Returns `true` when `error` signals a paused / suspended Fabric capacity.
    nonisolated func isPausedCapacityError(_ error: any Error) -> Bool {
        // Attempt to extract the raw body from an APIError (via OneLake or
        // Fabric error wrapping).
        let body = extractAPIErrorBody(error)
        if let body, !body.isEmpty {
            let range = NSRange(body.startIndex..., in: body)
            if Self.pausedCapacityPattern.firstMatch(in: body, range: range) != nil {
                return true
            }
            // Parse `errorCode` from JSON body.
            if let code = extractErrorCode(from: body) {
                return Self.pausedErrorCodes.contains(code.lowercased())
            }
        }
        return false
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

// MARK: - Duration.seconds helper

private extension Duration {
    var seconds: TimeInterval {
        let (sec, attosec) = self.components
        return TimeInterval(sec) + TimeInterval(attosec) / 1e18
    }
}

// MARK: - APIError body extraction

private func extractAPIErrorBody(_ error: any Error) -> String? {
    switch error {
    case let onelakeErr as OneLakeError:
        if case .httpError(let inner) = onelakeErr {
            return extractAPIErrorBody(inner)
        }
    case let fabricErr as FabricError:
        if case .httpError(let inner) = fabricErr {
            return extractAPIErrorBody(inner)
        }
    case let httpErr as HTTPClientError:
        if case .apiError(let api) = httpErr {
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
