import Foundation

// MARK: - OfflineTracker

/// Tracks whether the engine has recently observed an offline-class network
/// failure.
///
/// A successful outbound call clears the offline flag. An offline-class error
/// (DNS failure, connection refused, network loss) sets it. The flag auto-
/// expires after `cooldown` with no traffic flowing.
///
/// `OfflineTracker` is a Swift `actor` for safe concurrent mutation.
actor OfflineTracker {
    // MARK: - Constants

    /// Maximum time the engine keeps reporting offline without a successful
    /// round-trip.
    static let defaultCooldown: Duration = .seconds(60)

    // MARK: - State

    private let cooldown: Duration
    private var since: Date?

    // MARK: - Init

    init(cooldown: Duration = OfflineTracker.defaultCooldown) {
        self.cooldown = cooldown
    }

    // MARK: - Internal API (sync-26: reduced from public to internal)

    /// Records a successful outbound call (clears the offline flag).
    func markOnline() {
        since = nil
    }

    /// Records an offline-class failure (sets the offline flag).
    func markOffline() {
        if since == nil { since = Date() }
    }

    /// Returns `true` when the engine is currently considered offline and
    /// resets the cooldown clock when it has elapsed (sync-20).
    ///
    /// This is an explicit method rather than a computed property so it is
    /// clear that a call can mutate state (expiring the cooldown resets
    /// `since`). Two consecutive calls to `currentlyOffline()` can return
    /// different values with no intervening `observe()` call; using a method
    /// name makes this self-documenting.
    func currentlyOffline() -> Bool {
        guard let start = since else { return false }
        let age = Date().timeIntervalSince(start)
        if age > cooldown.seconds {
            since = nil
            return false
        }
        return true
    }

    /// Feeds the outcome of a single outbound call.
    func observe(_ error: (any Error)?) {
        guard let error else {
            markOnline()
            return
        }
        if OfflineTracker.isOfflineError(error) {
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
    static func isOfflineError(_ error: any Error) -> Bool {
        guard let urlError = underlyingURLError(error) else { return false }
        switch urlError.code {
        case .notConnectedToInternet,
             .networkConnectionLost,
             .cannotConnectToHost,
             .cannotFindHost,
             .dnsLookupFailed:
            return true
        case .timedOut:
            // Timeout is NOT treated as offline — it is a server-side issue.
            return false
        default:
            return false
        }
    }

    /// Unwraps the layers the engine wraps a transport failure in to reach an
    /// underlying `URLError`, if any. Bounded to 5 unwrap levels (sync-07:
    /// the depth limit of 5 is a deliberate policy cap documented here).
    private static let maxUnwrapDepth = 5

    static func underlyingURLError(_ error: any Error) -> URLError? {
        var current: (any Error)? = error
        var depth = 0
        while let err = current, depth < maxUnwrapDepth {
            if let urlError = err as? URLError { return urlError }
            if let oneLake = err as? OneLakeError, case let .httpError(inner) = oneLake {
                current = inner
            } else if let fabric = err as? FabricError, case let .httpError(inner) = fabric {
                current = inner
            } else if let http = err as? HTTPClientError {
                switch http {
                case let .transport(inner): current = inner
                case let .retriesExhausted(_, last): current = last
                default: return nil
                }
            } else {
                return nil
            }
            depth += 1
        }
        return nil
    }
}
