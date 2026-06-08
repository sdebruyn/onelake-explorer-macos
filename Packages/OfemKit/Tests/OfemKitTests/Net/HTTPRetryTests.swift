import Foundation
import Testing
@testable import OfemKit

// MARK: - HTTPRetryPolicyTests

@Suite("HTTPRetryPolicy")
struct HTTPRetryPolicyTests {
    // MARK: - Defaults

    @Test("defaults: maxAttempts is 6")
    func defaultMaxAttempts() {
        let p = HTTPRetryPolicy()
        #expect(p.maxAttempts == 6)
    }

    @Test("defaults: initialBackoff is 250 ms")
    func defaultInitialBackoff() {
        let p = HTTPRetryPolicy()
        #expect(p.initialBackoff == .milliseconds(250))
    }

    @Test("defaults: maxBackoff is 30 s")
    func defaultMaxBackoff() {
        let p = HTTPRetryPolicy()
        #expect(p.maxBackoff == .seconds(30))
    }

    // MARK: - Clamping

    @Test("maxAttempts < 1 is treated as 1")
    func clampMaxAttempts() {
        let p = HTTPRetryPolicy(maxAttempts: 0)
        #expect(p.maxAttempts == 1)
    }

    // MARK: - canRetryTransportError

    @Test("GET transport error is always retried")
    func getAlwaysRetried() {
        let p = HTTPRetryPolicy(idempotent: false)
        #expect(p.canRetryTransportError(method: "GET"))
    }

    @Test("HEAD transport error is always retried")
    func headAlwaysRetried() {
        let p = HTTPRetryPolicy(idempotent: false)
        #expect(p.canRetryTransportError(method: "HEAD"))
    }

    @Test("PUT transport error is always retried")
    func putAlwaysRetried() {
        let p = HTTPRetryPolicy(idempotent: false)
        #expect(p.canRetryTransportError(method: "PUT"))
    }

    @Test("DELETE transport error is always retried")
    func deleteAlwaysRetried() {
        let p = HTTPRetryPolicy(idempotent: false)
        #expect(p.canRetryTransportError(method: "DELETE"))
    }

    @Test("POST transport error is NOT retried by default")
    func postNotRetriedByDefault() {
        let p = HTTPRetryPolicy(idempotent: false)
        #expect(!p.canRetryTransportError(method: "POST"))
    }

    @Test("PATCH transport error is NOT retried by default")
    func patchNotRetriedByDefault() {
        let p = HTTPRetryPolicy(idempotent: false)
        #expect(!p.canRetryTransportError(method: "PATCH"))
    }

    @Test("POST transport error IS retried when idempotent=true")
    func postRetriedWhenIdempotent() {
        let p = HTTPRetryPolicy(idempotent: true)
        #expect(p.canRetryTransportError(method: "POST"))
    }
}

// MARK: - ParseRetryAfterTests

@Suite("parseRetryAfter")
struct ParseRetryAfterTests {
    private static let now = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: - Delta-seconds

    @Test("parses zero seconds")
    func zeroSeconds() {
        #expect(parseRetryAfter("0", now: Self.now) == .seconds(0))
    }

    @Test("parses positive integer seconds")
    func positiveSeconds() {
        #expect(parseRetryAfter("30", now: Self.now) == .seconds(30))
    }

    @Test("parses large integer seconds")
    func largeSeconds() {
        #expect(parseRetryAfter("3600", now: Self.now) == .seconds(3600))
    }

    @Test("negative seconds returns nil")
    func negativeSeconds() {
        #expect(parseRetryAfter("-1", now: Self.now) == nil)
    }

    // MARK: - HTTP-date

    @Test("parses RFC 1123 date in the future")
    func rfc1123Date() {
        // A date 60 seconds in the future.
        let future = Date(timeIntervalSince1970: Self.now.timeIntervalSince1970 + 60)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(abbreviation: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        let dateString = formatter.string(from: future)
        let result = parseRetryAfter(dateString, now: Self.now)
        // Should be approximately 60 seconds (allow ±1 s for formatting).
        if let r = result {
            let ms = r.components.seconds * 1000 + r.components.attoseconds / 1_000_000_000_000_000
            #expect(ms >= 59_000 && ms <= 61_000)
        } else {
            Issue.record("parseRetryAfter returned nil for future RFC 1123 date '\(dateString)'")
        }
    }

    @Test("HTTP-date in the past returns nil")
    func pastHTTPDate() {
        let past = Date(timeIntervalSince1970: Self.now.timeIntervalSince1970 - 60)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(abbreviation: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        let dateString = formatter.string(from: past)
        #expect(parseRetryAfter(dateString, now: Self.now) == nil)
    }

    // MARK: - Edge cases

    @Test("empty string returns nil")
    func emptyString() {
        #expect(parseRetryAfter("", now: Self.now) == nil)
    }

    @Test("whitespace-only string returns nil")
    func whitespaceOnly() {
        #expect(parseRetryAfter("   ", now: Self.now) == nil)
    }

    @Test("garbage value returns nil")
    func garbageValue() {
        #expect(parseRetryAfter("not-a-date-or-number", now: Self.now) == nil)
    }
}

// MARK: - BackoffTests

@Suite("backoff helpers")
struct BackoffTests {
    @Test("nextBackoff doubles the window")
    func doublesWindow() {
        #expect(nextBackoff(.milliseconds(250), max: .seconds(30)) == .milliseconds(500))
    }

    @Test("nextBackoff clamps to maxBackoff")
    func clampedToMax() {
        #expect(nextBackoff(.seconds(20), max: .seconds(30)) == .seconds(30))
    }

    @Test("jitter returns value within [0, window)")
    func jitterInRange() {
        let window = Duration.seconds(10)
        for _ in 0..<50 {
            let j = jitter(window)
            #expect(j >= .zero)
            #expect(j < window)
        }
    }

    @Test("jitter on zero window returns zero")
    func jitterZeroWindow() {
        #expect(jitter(.zero) == .zero)
    }
}

// MARK: - HTTPClientError sentinels

@Suite("HTTPClientError sentinels")
struct HTTPClientErrorSentinelTests {
    @Test("401 maps to .unauthorized")
    func maps401() {
        #expect(HTTPClientError.sentinel(for: 401) == .unauthorized)
    }

    @Test("403 maps to .forbidden")
    func maps403() {
        #expect(HTTPClientError.sentinel(for: 403) == .forbidden)
    }

    @Test("404 maps to .notFound")
    func maps404() {
        #expect(HTTPClientError.sentinel(for: 404) == .notFound)
    }

    @Test("409 maps to .conflict")
    func maps409() {
        #expect(HTTPClientError.sentinel(for: 409) == .conflict)
    }

    @Test("410 maps to .gone")
    func maps410() {
        #expect(HTTPClientError.sentinel(for: 410) == .gone)
    }

    @Test("412 maps to .preconditionFailed")
    func maps412() {
        #expect(HTTPClientError.sentinel(for: 412) == .preconditionFailed)
    }

    @Test("429 maps to .throttled")
    func maps429() {
        #expect(HTTPClientError.sentinel(for: 429) == .throttled)
    }

    @Test("500 maps to .serverError")
    func maps500() {
        if case .serverError(500) = HTTPClientError.sentinel(for: 500)! {
            // pass
        } else {
            Issue.record("expected .serverError(500)")
        }
    }

    @Test("200 has no sentinel")
    func maps200() {
        #expect(HTTPClientError.sentinel(for: 200) == nil)
    }

    @Test("400 has no sentinel")
    func maps400() {
        #expect(HTTPClientError.sentinel(for: 400) == nil)
    }
}

// MARK: - HTTPClientError equatable conformance helper

extension HTTPClientError: Equatable {
    public static func == (lhs: HTTPClientError, rhs: HTTPClientError) -> Bool {
        switch (lhs, rhs) {
        case (.unauthorized, .unauthorized): return true
        case (.forbidden, .forbidden): return true
        case (.notFound, .notFound): return true
        case (.conflict, .conflict): return true
        case (.gone, .gone): return true
        case (.preconditionFailed, .preconditionFailed): return true
        case (.payloadTooLarge, .payloadTooLarge): return true
        case (.unsupportedMediaType, .unsupportedMediaType): return true
        case (.rangeNotSatisfiable, .rangeNotSatisfiable): return true
        case (.unprocessableEntity, .unprocessableEntity): return true
        case (.throttled, .throttled): return true
        case (.serverError(let a), .serverError(let b)): return a == b
        case (.cancelled, .cancelled): return true
        default: return false
        }
    }
}
