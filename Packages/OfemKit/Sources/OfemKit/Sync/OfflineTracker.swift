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
public actor OfflineTracker {

    // MARK: - Constants

    /// Maximum time the engine keeps reporting offline without a successful
    /// round-trip.
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
    /// The engine never hands a raw `URLError` here — the clients wrap transport
    /// failures (`OneLakeError.httpError` / `FabricError.httpError` →
    /// `HTTPClientError.transport`). So unwrap those to reach the underlying
    /// `URLError` before classifying.
    public static func isOfflineError(_ error: any Error) -> Bool {
        guard let urlError = Self.underlyingURLError(error) else { return false }
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

    /// Unwraps the layers the engine wraps a transport failure in
    /// (`OneLakeError.httpError` / `FabricError.httpError` /
    /// `HTTPClientError.transport` / `HTTPClientError.retriesExhausted(last:)`)
    /// to reach an underlying `URLError`, if any. HTTP/status errors (a wrapped
    /// `HTTPClientError.apiError` / `.serverError`) are not transport failures
    /// and resolve to `nil`, so a paused-capacity 503 is never seen as offline.
    static func underlyingURLError(_ error: any Error) -> URLError? {
        var current: (any Error)? = error
        var depth = 0
        while let err = current, depth < 5 {
            if let urlError = err as? URLError { return urlError }
            if let oneLake = err as? OneLakeError, case let .httpError(inner) = oneLake {
                current = inner
            } else if let fabric = err as? FabricError, case let .httpError(inner) = fabric {
                current = inner
            } else if let http = err as? HTTPClientError {
                switch http {
                case .transport(let inner): current = inner
                case .retriesExhausted(_, let last): current = last
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

// MARK: - Duration.seconds helper

private extension Duration {
    var seconds: TimeInterval {
        let (sec, attosec) = self.components
        return TimeInterval(sec) + TimeInterval(attosec) / 1e18
    }
}
