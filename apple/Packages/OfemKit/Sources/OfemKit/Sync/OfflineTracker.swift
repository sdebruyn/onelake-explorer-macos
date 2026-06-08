import Foundation

// MARK: - OfflineTracker

/// Tracks whether the engine has recently observed an offline-class network
/// failure.
///
/// A successful outbound call clears the offline flag. An offline-class error
/// (DNS failure, connection refused, network loss) sets it. The flag auto-
/// expires after `cooldown` with no traffic flowing.
///
/// Mirrors `internal/sync/offline.go` — `offlineState`.
///
/// `OfflineTracker` is a Swift `actor` for safe concurrent mutation.
public actor OfflineTracker {

    // MARK: - Constants

    /// Maximum time the engine keeps reporting offline without a successful
    /// round-trip.
    ///
    /// Mirrors `internal/sync/offline.go` — `offlineCooldown`.
    public static let defaultCooldown: Duration = .seconds(60)

    // MARK: - State

    private let cooldown: Duration
    private var since: Date?

    // MARK: - Init

    public init(cooldown: Duration = OfflineTracker.defaultCooldown) {
        self.cooldown = cooldown
    }

    // MARK: - Public API

    /// Records a successful outbound call (clears the offline flag).
    public func markOnline() {
        since = nil
    }

    /// Records an offline-class failure (sets the offline flag).
    public func markOffline() {
        if since == nil { since = Date() }
    }

    /// Returns `true` when the engine is currently considered offline.
    public var isOffline: Bool {
        guard let start = since else { return false }
        let age = Date().timeIntervalSince(start)
        if age > cooldown.seconds {
            since = nil
            return false
        }
        return true
    }

    /// Feeds the outcome of a single outbound call.
    ///
    /// Mirrors `internal/sync/offline.go` — `Engine.observeNetworkResult`.
    public func observe(_ error: (any Error)?) {
        if error == nil {
            markOnline()
        } else if OfflineTracker.isOfflineError(error!) {
            markOffline()
        }
        // Other errors (404, 403, etc.) don't change offline state.
    }

    // MARK: - Offline error classification

    /// Returns `true` when `error` matches the kernel- and DNS-class failures
    /// OFEM treats as "host is offline".
    ///
    /// Deliberately restrictive: a 503 does NOT promote the engine to offline
    /// (paused capacity must not appear as an offline condition).
    ///
    /// Mirrors `internal/sync/offline.go` — `IsOfflineError`.
    public static func isOfflineError(_ error: any Error) -> Bool {
        guard let urlError = error as? URLError else { return false }
        switch urlError.code {
        case .notConnectedToInternet,
             .networkConnectionLost,
             .cannotConnectToHost,
             .cannotFindHost,
             .dnsLookupFailed:
            return true
        case .timedOut:
            // Timeout is NOT treated as offline — it is a server-side issue.
            // Mirrors the Go check: `!opErr.Timeout()` in `IsOfflineError`.
            return false
        default:
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
