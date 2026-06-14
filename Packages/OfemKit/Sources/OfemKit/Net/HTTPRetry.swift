import Foundation
import os.log

// MARK: - HTTPRetryPolicy

/// Parameters for the retry loop inside ``HTTPClient``.
///
/// The zero value is valid and uses the same constants as the Go
/// implementation.
public struct HTTPRetryPolicy: Sendable {
    // MARK: - Defaults

    /// Total number of attempts including the first. Default: 6.
    public static let defaultMaxAttempts = 6

    /// First wait window before the second attempt (full jitter). Default: 250 ms.
    public static let defaultInitialBackoff: Duration = .milliseconds(250)

    /// Maximum wait for a single backoff window. Default: 30 s.
    public static let defaultMaxBackoff: Duration = .seconds(30)

    // MARK: - Fields

    /// Total number of attempts (including the first).
    /// Values < 1 are treated as 1 (no retry).
    public var maxAttempts: Int

    /// First backoff window. Zero uses ``defaultInitialBackoff``.
    public var initialBackoff: Duration

    /// Cap on a single backoff window. Zero uses ``defaultMaxBackoff``.
    public var maxBackoff: Duration

    /// Declares that the request body can be replayed after a mid-flight
    /// transport error — i.e. the operation is idempotent. GET, HEAD, PUT
    /// and DELETE are always safe regardless. POST and PATCH require the
    /// caller to assert this.
    public var idempotent: Bool

    // MARK: - Initialisers

    public init(
        maxAttempts: Int = defaultMaxAttempts,
        initialBackoff: Duration = defaultInitialBackoff,
        maxBackoff: Duration = defaultMaxBackoff,
        idempotent: Bool = false
    ) {
        self.maxAttempts = max(1, maxAttempts)
        self.initialBackoff = initialBackoff == .zero ? Self.defaultInitialBackoff : initialBackoff
        self.maxBackoff = maxBackoff == .zero ? Self.defaultMaxBackoff : maxBackoff
        self.idempotent = idempotent
    }

    // MARK: - Retry decision

    /// Returns `true` when a transport error may be retried.
    func canRetryTransportError(method: String) -> Bool {
        if idempotent { return true }
        switch method.uppercased() {
        case "GET", "HEAD", "PUT", "DELETE":
            return true
        default:
            return false
        }
    }
}

// MARK: - RetryAfter parsing

/// Parses an HTTP `Retry-After` header into a `Duration`.
///
/// Accepts:
/// - Non-negative integer (delta-seconds)
/// - HTTP-date (RFC 7231 / RFC 1123 / RFC 850 / asctime)
///
/// Returns `nil` for an empty, negative, or unparseable value, or for an
/// HTTP-date that is already in the past.
public func parseRetryAfter(_ value: String, now: Date = Date()) -> Duration? {
    let trimmed = value.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty else { return nil }

    // Delta-seconds branch.
    if let secs = Int(trimmed) {
        guard secs >= 0 else { return nil }
        return .seconds(secs)
    }

    // HTTP-date branch. Foundation's `DateFormatter` with RFC 1123 format and
    // fallbacks covers the three date formats allowed by RFC 7231.
    for formatter in HTTPRetryDateFormatters.all {
        if let date = formatter.date(from: trimmed) {
            let delta = date.timeIntervalSince(now)
            guard delta > 0 else { return nil }
            let ms = Int64(delta * 1_000)
            return .milliseconds(ms)
        }
    }
    return nil
}

// MARK: - Date formatters (internal so OneLakeResponse can reuse)

enum HTTPRetryDateFormatters {
    static let rfc1123: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(abbreviation: "GMT")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return f
    }()

    static let rfc850: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(abbreviation: "GMT")
        f.dateFormat = "EEEE, dd-MMM-yy HH:mm:ss zzz"
        return f
    }()

    static let asctime: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(abbreviation: "GMT")
        f.dateFormat = "EEE MMM d HH:mm:ss yyyy"
        return f
    }()

    static let all: [DateFormatter] = [rfc1123, rfc850, asctime]
}

// MARK: - Backoff helpers

/// Returns the next exponential backoff window, clamped to `maxBackoff`.
func nextBackoff(_ current: Duration, max maxBackoff: Duration) -> Duration {
    let doubled = current * 2
    return doubled > maxBackoff ? maxBackoff : doubled
}

/// Returns a uniformly distributed random value in `[0, window)`.
///
/// Falls back to `window / 2` if entropy is unavailable.
func jitter(_ window: Duration) -> Duration {
    guard window > .zero else { return .zero }
    let ns = window.components.seconds * 1_000_000_000 + window.components.attoseconds / 1_000_000_000
    guard ns > 0 else { return .zero }
    let randomNS = Int64.random(in: 0..<ns)
    return Duration.nanoseconds(randomNS)
}

// MARK: - Retriable transport-error detection

/// Returns `true` when a `URLError` (or underlying error) is worth retrying.
func isRetriableURLError(_ error: any Error) -> Bool {
    // Context cancellation is never retried — it's a caller-driven stop.
    if error is CancellationError { return false }

    if let urlError = error as? URLError {
        switch urlError.code {
        // Permanent / misconfiguration errors — do not retry.
        case .secureConnectionFailed,
             .serverCertificateHasBadDate,
             .serverCertificateUntrusted,
             .serverCertificateHasUnknownRoot,
             .serverCertificateNotYetValid,
             .clientCertificateRejected,
             .clientCertificateRequired:
            return false

        // Transient network conditions — retry.
        // net-16: .cannotFindHost and .cannotConnectToHost are transient on
        // Apple platforms (VPN flaps, captive portals, sleep/wake races, LB
        // restarts) — the same class of failure as .dnsLookupFailed, which
        // one you get is resolver-implementation dependent.
        case .timedOut,
             .networkConnectionLost,
             .notConnectedToInternet,
             .dnsLookupFailed,
             .cannotFindHost,
             .cannotConnectToHost,
             .resourceUnavailable,
             .requestBodyStreamExhausted:
            return true

        default:
            // Conservative: don't retry unknown codes.
            return false
        }
    }
    return false
}

/// Returns `true` for the "hard offline" transport codes — the host is
/// definitively unreachable (no internet, or an established connection dropped),
/// so retrying is pointless. The engine surfaces these immediately and falls
/// back to cached content. Distinct from the flaky-host codes
/// (`.cannotFindHost` / `.cannotConnectToHost` / `.dnsLookupFailed`), which can
/// be transient on Apple platforms and stay retriable (net-16).
func isHardOfflineURLError(_ error: any Error) -> Bool {
    guard let urlError = error as? URLError else { return false }
    switch urlError.code {
    case .notConnectedToInternet, .networkConnectionLost:
        return true
    default:
        return false
    }
}
