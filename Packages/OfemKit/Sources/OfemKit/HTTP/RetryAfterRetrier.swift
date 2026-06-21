import Alamofire
import Foundation

// MARK: - RetryAfterRetrier

/// Reads a `Retry-After` header on 429/503 responses and asks Alamofire to
/// retry after the specified delay, capped at ``maxDelay``.
///
/// This retrier is placed ahead of `RetryPolicy` in the interceptor chain so
/// that an explicit `Retry-After` value wins over exponential backoff.  When
/// no parseable `Retry-After` header is present the retrier returns `.doNotRetry`
/// so `RetryPolicy` handles the response instead.
struct RetryAfterRetrier: RequestRetrier {
    /// Maximum delay accepted from a `Retry-After` header (seconds).
    static let maxDelay: TimeInterval = 30

    func retry(
        _ request: Request,
        for _: Session,
        dueTo _: Error,
        completion: @escaping @Sendable (RetryResult) -> Void
    ) {
        guard let response = request.response,
              [429, 503].contains(response.statusCode),
              let header = response.value(forHTTPHeaderField: "Retry-After"),
              let delay = parseRetryAfter(header)
        else {
            // No header, unparseable, or wrong status — let RetryPolicy decide.
            completion(.doNotRetry)
            return
        }
        let cappedDelay = min(TimeInterval(delay.components.seconds) +
            TimeInterval(delay.components.attoseconds) * 1e-18,
            Self.maxDelay)
        completion(.retryWithDelay(cappedDelay))
    }
}

// MARK: - Retry-After parsing

/// Parses an HTTP `Retry-After` header into a `Duration`.
///
/// Accepts:
/// - Non-negative integer (delta-seconds)
/// - HTTP-date (RFC 7231 / RFC 1123 / RFC 850 / asctime)
///
/// Returns `nil` for an empty, negative, or unparseable value, or for an
/// HTTP-date that is already in the past.
///
/// Thread-safe: creates per-call `DateFormatter` instances rather than sharing
/// mutable singletons.
func parseRetryAfter(_ value: String, now: Date = Date()) -> Duration? {
    let trimmed = value.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty else { return nil }

    // Delta-seconds branch.
    if let secs = Int(trimmed) {
        guard secs >= 0 else { return nil }
        return .seconds(secs)
    }

    // HTTP-date branch — create per-call formatter instances so concurrent
    // callers never share mutable state.
    for fmt in makeHTTPDateFormatters() {
        if let date = fmt.date(from: trimmed) {
            let delta = date.timeIntervalSince(now)
            guard delta > 0 else { return nil }
            let ms = Int64(delta * 1000)
            return .milliseconds(ms)
        }
    }
    return nil
}

/// Creates a fresh set of HTTP-date formatters for each call.
///
/// `DateFormatter` is not `Sendable`; sharing one instance across threads is
/// unsafe. Callers must use the returned instances locally.
func makeHTTPDateFormatters() -> [DateFormatter] {
    [
        HTTPRetryDateFormatters.makeFresh(.rfc1123),
        HTTPRetryDateFormatters.makeFresh(.rfc850),
        HTTPRetryDateFormatters.makeFresh(.asctime),
    ]
}

// MARK: - Date formatter factory

/// HTTP-date format identifiers.
enum HTTPDateFormat {
    case rfc1123, rfc850, asctime

    var formatString: String {
        switch self {
        case .rfc1123: "EEE, dd MMM yyyy HH:mm:ss zzz"
        case .rfc850: "EEEE, dd-MMM-yy HH:mm:ss zzz"
        case .asctime: "EEE MMM d HH:mm:ss yyyy"
        }
    }
}

/// Provides per-instance HTTP-date `DateFormatter` construction.
///
/// All callers should use `makeFresh(_:)` (or `makeHTTPDateFormatters()`)
/// to create local instances rather than sharing static properties.
///
/// The static `rfc1123`, `rfc850`, and `asctime` properties are
/// **test-use only** (single-threaded construction of date fixtures).
/// Do not use them in production code paths that may run concurrently.
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

    // periphery:ignore
    /// RFC 1123 formatter for test fixture construction. Not safe for concurrent use.
    static let rfc1123: DateFormatter = makeFresh(.rfc1123)
    // periphery:ignore
    /// RFC 850 formatter for test fixture construction. Not safe for concurrent use.
    static let rfc850: DateFormatter = makeFresh(.rfc850)
    // periphery:ignore
    /// asctime formatter for test fixture construction. Not safe for concurrent use.
    static let asctime: DateFormatter = makeFresh(.asctime)
}
