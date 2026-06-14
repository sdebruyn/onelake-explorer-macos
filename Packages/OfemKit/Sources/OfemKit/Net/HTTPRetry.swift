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
    ///
    /// This field lives on the policy because it participates in the retry
    /// decision. Callers should pass `idempotent: true` on ``HTTPClient/execute``
    /// rather than mutating a shared policy instance (net-06).
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

// MARK: - Retriable status policy

/// The set of HTTP status codes that the retry loop will retry.
///
/// Consolidating the policy here (net-13) ensures the retry loop and the
/// gate-penalty logic share a single source of truth.
public enum HTTPRetryStatusPolicy {
    /// Returns `true` when `status` warrants another attempt.
    public static func isRetriable(_ status: Int) -> Bool {
        switch status {
        case 408, 425, 429, 500, 502, 503, 504:
            return true
        default:
            return false
        }
    }

    /// Returns `true` when the gate should apply a shared pause window on
    /// this status (i.e. the server signalled host-wide overload, not just
    /// per-request back-pressure).
    public static func shouldPenaliseGate(_ status: Int) -> Bool {
        switch status {
        case 429, 500, 502, 503, 504:
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
///
/// Thread-safe: uses value-type `Date.ISO8601FormatStyle` / local
/// `DateFormatter` copies rather than shared mutable singletons (net-15).
public func parseRetryAfter(_ value: String, now: Date = Date()) -> Duration? {
    let trimmed = value.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty else { return nil }

    // Delta-seconds branch.
    if let secs = Int(trimmed) {
        guard secs >= 0 else { return nil }
        return .seconds(secs)
    }

    // HTTP-date branch — create per-call formatter instances so concurrent
    // callers never share mutable state (net-15: DateFormatter is not Sendable).
    for fmt in makeRetryAfterFormatters() {
        if let date = fmt.date(from: trimmed) {
            let delta = date.timeIntervalSince(now)
            guard delta > 0 else { return nil }
            let ms = Int64(delta * 1_000)
            return .milliseconds(ms)
        }
    }
    return nil
}

/// Constructs fresh `DateFormatter` instances for each `parseRetryAfter` call.
///
/// Slightly more allocation than the old static singletons, but correct under
/// concurrent access. `DateFormatter` is not `Sendable`; sharing one instance
/// across threads is unsafe (net-15).
private func makeRetryAfterFormatters() -> [DateFormatter] {
    makeHTTPDateFormatters()
}

/// Creates a fresh set of HTTP-date formatters.
///
/// Callers that parse HTTP-date strings should call this and use the returned
/// instances locally rather than sharing static singletons across threads.
/// `DateFormatter` is not `Sendable` and concurrent `date(from:)` calls on a
/// shared instance are unsafe (net-15).
func makeHTTPDateFormatters() -> [DateFormatter] {
    [
        HTTPRetryDateFormatters.makeFresh(.rfc1123),
        HTTPRetryDateFormatters.makeFresh(.rfc850),
        HTTPRetryDateFormatters.makeFresh(.asctime),
    ]
}

// MARK: - Date formatter factory (internal so tests and OneLakeResponse can share)

/// HTTP-date format identifiers.
enum HTTPDateFormat {
    case rfc1123, rfc850, asctime

    var formatString: String {
        switch self {
        case .rfc1123: return "EEE, dd MMM yyyy HH:mm:ss zzz"
        case .rfc850:  return "EEEE, dd-MMM-yy HH:mm:ss zzz"
        case .asctime: return "EEE MMM d HH:mm:ss yyyy"
        }
    }
}

/// Provides per-instance HTTP-date `DateFormatter` construction.
///
/// Previous design used static `let` singletons shared across threads, which
/// is unsafe because `DateFormatter` is not `Sendable` (net-15). All callers
/// should use `makeFresh(_:)` (or `makeHTTPDateFormatters()`) to create
/// local instances rather than reading the deprecated static properties.
///
/// The `rfc850` and `asctime` static properties are **retained for test use
/// only** (tests that format a date for fixture construction need a stable
/// instance; they run single-threaded per test). Do not use them in
/// production code paths that may run concurrently.
enum HTTPRetryDateFormatters {
    /// Creates a fresh, per-caller `DateFormatter` for the given HTTP-date format.
    static func makeFresh(_ format: HTTPDateFormat) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(abbreviation: "GMT")
        f.dateFormat = format.formatString
        return f
    }

    // MARK: Test-use-only static instances (single-threaded test contexts only)

    /// RFC 1123 formatter for test fixture construction. Not safe for concurrent use.
    static let rfc1123: DateFormatter = makeFresh(.rfc1123)
    /// RFC 850 formatter for test fixture construction. Not safe for concurrent use.
    static let rfc850: DateFormatter = makeFresh(.rfc850)
    /// asctime formatter for test fixture construction. Not safe for concurrent use.
    static let asctime: DateFormatter = makeFresh(.asctime)
}

// MARK: - Backoff helpers

/// Returns the next exponential backoff window, clamped to `maxBackoff`.
func nextBackoff(_ current: Duration, max maxBackoff: Duration) -> Duration {
    let doubled = current * 2
    return doubled > maxBackoff ? maxBackoff : doubled
}

/// Returns a uniformly distributed random value in `[0, window)`.
///
/// Uses `Duration` arithmetic to avoid Int64 overflow and attosecond
/// precision loss from manual unit conversion (net-07).
func jitter(_ window: Duration) -> Duration {
    guard window > .zero else { return .zero }
    // Work entirely in nanoseconds, clamped to a safe range.
    // `window.components.seconds` is Int64; multiplying by 1e9 overflows for
    // values above ~9.2e9 s (centuries), but clamp to maxBackoff (30 s) makes
    // it safe in practice. We still clamp explicitly for robustness.
    let seconds = window.components.seconds
    let attoseconds = window.components.attoseconds
    // Cap at Int64.max / 1_000_000_000 to prevent overflow.
    let maxSafeSeconds: Int64 = Int64.max / 1_000_000_000
    guard seconds >= 0, seconds <= maxSafeSeconds else {
        // Window is out of range — fall back to half the duration.
        return window / 2
    }
    let ns = seconds * 1_000_000_000 &+ attoseconds / 1_000_000_000
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
