import Alamofire
import Foundation
@testable import OfemKit
import Testing

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
            #expect(ms >= 59000 && ms <= 61000)
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

// MARK: - HTTPClientError sentinels

// tests-13: use pattern matching instead of == to avoid the brittle retroactive
// Equatable conformance. Case-pattern matching is exhaustive per case and does
// not require a `default: false` arm that would silently pass new cases.

@Suite("HTTPClientError sentinels")
struct HTTPClientErrorSentinelTests {
    @Test("401 maps to .unauthorized")
    func maps401() {
        guard case .unauthorized = HTTPClientError.sentinel(for: 401) else {
            Issue.record("expected .unauthorized for 401"); return
        }
    }

    @Test("403 maps to .forbidden")
    func maps403() {
        guard case .forbidden = HTTPClientError.sentinel(for: 403) else {
            Issue.record("expected .forbidden for 403"); return
        }
    }

    @Test("404 maps to .notFound")
    func maps404() {
        guard case .notFound = HTTPClientError.sentinel(for: 404) else {
            Issue.record("expected .notFound for 404"); return
        }
    }

    @Test("409 maps to .conflict")
    func maps409() {
        guard case .conflict = HTTPClientError.sentinel(for: 409) else {
            Issue.record("expected .conflict for 409"); return
        }
    }

    @Test("410 maps to .gone")
    func maps410() {
        guard case .gone = HTTPClientError.sentinel(for: 410) else {
            Issue.record("expected .gone for 410"); return
        }
    }

    @Test("412 maps to .preconditionFailed")
    func maps412() {
        guard case .preconditionFailed = HTTPClientError.sentinel(for: 412) else {
            Issue.record("expected .preconditionFailed for 412"); return
        }
    }

    @Test("429 maps to .throttled")
    func maps429() {
        guard case .throttled = HTTPClientError.sentinel(for: 429) else {
            Issue.record("expected .throttled for 429"); return
        }
    }

    @Test("500 maps to .serverError")
    func maps500() throws {
        if case .serverError(500) = try #require(HTTPClientError.sentinel(for: 500)) {
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

// MARK: - RetryAfterRetrier retry-budget cap (F3)

/// Counts every outgoing attempt (initial request + each retry), independent
/// of how many stubs remain in the mock queue — lets a test assert an exact
/// attempt count without relying on the queue running dry.
private final class AttemptCounter: RequestAdapter, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var count = 0

    func adapt(
        _ urlRequest: URLRequest,
        for _: Session,
        completion: @escaping (Result<URLRequest, any Error>) -> Void
    ) {
        lock.withLock { count += 1 }
        completion(.success(urlRequest))
    }
}

@Suite("RetryAfterRetrier retry budget")
struct RetryAfterRetrierBudgetTests {
    /// F3: a sustained 429 with a parseable `Retry-After` header must stop
    /// retrying once the shared `request.retryCount` budget (aligned with
    /// `RetryPolicy(retryLimit: 5)`) is spent, not retry forever. Registering
    /// more stubs than the budget allows proves the retrier stopped because of
    /// the cap, not because the mock queue ran dry.
    @Test("sustained 429 + Retry-After stops after the shared retry cap and surfaces the error")
    func stopsAfterMaxRetries() async {
        let queueID = "retry-budget-\(UUID().uuidString)"
        let stubs = (0 ..< 20).map { _ in
            MockURLProtocol.StubResponse(status: 429, headers: ["Retry-After": "0"])
        }
        MockURLProtocol.registerQueue(id: queueID, stubs: stubs)
        defer { MockURLProtocol.clearQueue(id: queueID) }

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        config.urlCache = nil

        let counter = AttemptCounter()
        // Mirrors SessionPool's retrier chain: RetryAfterRetrier ahead of
        // RetryPolicy so an explicit Retry-After wins, both sharing one
        // request.retryCount budget.
        let interceptor = Interceptor(
            adapters: [counter, QueueIDAdapter(queueID: queueID)],
            retriers: [RetryAfterRetrier(), RetryPolicy(retryLimit: 5, retryableHTTPStatusCodes: [429])]
        )
        let session = Session(configuration: config, interceptor: interceptor)

        let dataResponse = await session.request("https://example.invalid/throttled")
            .validate()
            .serializingData()
            .response

        #expect(dataResponse.response?.statusCode == 429)
        guard case .failure = dataResponse.result else {
            Issue.record("Expected the request to fail once the retry budget is exhausted")
            return
        }
        #expect(counter.count == RetryAfterRetrier.maxRetries + 1)
    }
}

// MARK: - JitteredRetryPolicy (C10)

@Suite("JitteredRetryPolicy")
struct JitteredRetryPolicyTests {
    /// C10: without jitter, every concurrently-throttled request computes the
    /// identical exponential-backoff delay and retries in the same
    /// synchronized wave, amplifying the throttling. `jitteredDelay` must
    /// return a value in `[0, deterministicDelay]`, and must vary across
    /// samples rather than always returning the deterministic maximum.
    @Test("jitteredDelay stays within the deterministic bound and varies across samples")
    func jitteredDelayIsBoundedAndVaries() {
        let policy = JitteredRetryPolicy(retryLimit: 5, retryableHTTPStatusCodes: [429])
        let retryCount = 3
        let deterministicDelay = pow(
            Double(policy.exponentialBackoffBase), Double(retryCount)
        ) * policy.exponentialBackoffScale

        let samples = (0 ..< 50).map { _ in policy.jitteredDelay(forRetryCount: retryCount) }

        for delay in samples {
            #expect(delay >= 0)
            #expect(delay <= deterministicDelay)
        }
        // With 50 samples drawn uniformly from [0, deterministicDelay], the
        // odds of every single one landing on the exact same value are
        // negligible — this would only fail if jitter were not applied.
        #expect(Set(samples).count > 1)
    }

    @Test("jitteredDelay never goes negative when the deterministic delay is zero")
    func jitteredDelayHandlesZeroDelay() {
        let policy = JitteredRetryPolicy(
            retryLimit: 5, exponentialBackoffScale: 0, retryableHTTPStatusCodes: [429]
        )
        #expect(policy.jitteredDelay(forRetryCount: 0) == 0)
    }
}
