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

/// Builds a bare Alamofire `Session` (no `SessionPool`) wired to
/// `MockURLProtocol` with `retriers` in its interceptor chain, registering
/// `stubs` under a fresh queue ID. Shared by every RetryAfterRetrier-focused
/// suite below so each test isn't re-deriving the same
/// config/interceptor/session boilerplate (review nit on PR #451).
private func makeRetrierSession(
    stubs: [MockURLProtocol.StubResponse],
    retriers: [RequestRetrier],
    adapters: [RequestAdapter] = []
) -> (session: Session, queueID: String) {
    let queueID = "retrier-\(UUID().uuidString)"
    MockURLProtocol.registerQueue(id: queueID, stubs: stubs)
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [MockURLProtocol.self]
    config.urlCache = nil
    let interceptor = Interceptor(
        adapters: adapters + [QueueIDAdapter(queueID: queueID)],
        retriers: retriers
    )
    return (Session(configuration: config, interceptor: interceptor), queueID)
}

@Suite("RetryAfterRetrier retry budget")
struct RetryAfterRetrierBudgetTests {
    /// F3: a sustained 429 with a parseable `Retry-After` header must stop
    /// retrying once the shared `request.retryCount` budget (aligned with
    /// `JitteredRetryPolicy(retryLimit:)`) is spent, not retry forever.
    /// Registering more stubs than the budget allows proves the retrier
    /// stopped because of the cap, not because the mock queue ran dry.
    @Test("sustained 429 + Retry-After stops after the shared retry cap and surfaces the error")
    func stopsAfterMaxRetries() async {
        let stubs = (0 ..< 20).map { _ in
            MockURLProtocol.StubResponse(status: 429, headers: ["Retry-After": "0"])
        }
        let counter = AttemptCounter()
        // Mirrors SessionPool's actual retrier chain (not a stand-in): the
        // production RetryAfterRetrier ahead of the production
        // JitteredRetryPolicy, both sharing one request.retryCount budget.
        let (session, queueID) = makeRetrierSession(
            stubs: stubs,
            retriers: [
                RetryAfterRetrier(),
                JitteredRetryPolicy(
                    retryLimit: UInt(RetryAfterRetrier.maxRetries), retryableHTTPStatusCodes: [429]
                ),
            ],
            adapters: [counter]
        )
        defer { MockURLProtocol.clearQueue(id: queueID) }

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

// MARK: - RetryAfterRetrier idempotency gate (#450)

@Suite("RetryAfterRetrier idempotency gate")
struct RetryAfterRetrierIdempotencyTests {
    /// #450: a `Retry-After` on a non-idempotent request (POST) must not be
    /// replayed. `RetryAfterRetrier` gates on the same
    /// `idempotentHTTPMethods` set `SessionPool` configures
    /// `JitteredRetryPolicy` from, so the two retriers can never disagree.
    /// Registering only one stub proves the point: if the retrier incorrectly
    /// retried the POST, the second attempt would exhaust the queue and fail
    /// with `.resourceUnavailable` instead of surfacing the 429.
    @Test("POST is not retried on Retry-After even within the retry budget")
    func postIsNotRetriedOnRetryAfter() async {
        let counter = AttemptCounter()
        let (session, queueID) = makeRetrierSession(
            stubs: [MockURLProtocol.StubResponse(status: 429, headers: ["Retry-After": "0"])],
            retriers: [RetryAfterRetrier()],
            adapters: [counter]
        )
        defer { MockURLProtocol.clearQueue(id: queueID) }

        let dataResponse = await session.request(
            "https://example.invalid/throttled", method: .post
        )
        .validate()
        .serializingData()
        .response

        #expect(dataResponse.response?.statusCode == 429)
        guard case .failure = dataResponse.result else {
            Issue.record("Expected the POST to fail without a Retry-After replay")
            return
        }
        #expect(counter.count == 1)
    }

    /// Companion to the POST test above: confirms the idempotency gate did
    /// not accidentally stop GET (an idempotent method) from retrying.
    @Test("GET is still retried on Retry-After")
    func getIsStillRetriedOnRetryAfter() async {
        let counter = AttemptCounter()
        let (session, queueID) = makeRetrierSession(
            stubs: [
                MockURLProtocol.StubResponse(status: 429, headers: ["Retry-After": "0"]),
                MockURLProtocol.StubResponse(status: 200),
            ],
            retriers: [RetryAfterRetrier()],
            adapters: [counter]
        )
        defer { MockURLProtocol.clearQueue(id: queueID) }

        let dataResponse = await session.request("https://example.invalid/throttled")
            .validate()
            .serializingData()
            .response

        #expect(dataResponse.response?.statusCode == 200)
        #expect(counter.count == 2)
    }

    /// Should-fix on PR #451 review: a per-request `markIdempotent(false:)`
    /// override takes precedence over the method-based default — a PATCH
    /// (normally in `idempotentHTTPMethods`) explicitly opted out must not be
    /// replayed on Retry-After.
    @Test("an explicit markIdempotent(false:) override is not retried even for a normally-idempotent method")
    func explicitOptOutOverridesMethodDefault() async {
        let counter = AttemptCounter()
        let (session, queueID) = makeRetrierSession(
            stubs: [MockURLProtocol.StubResponse(status: 429, headers: ["Retry-After": "0"])],
            retriers: [RetryAfterRetrier()],
            adapters: [counter]
        )
        defer { MockURLProtocol.clearQueue(id: queueID) }

        let dataResponse = await session.request(
            "https://example.invalid/throttled", method: .patch
        ) { urlRequest in
            RetryAfterRetrier.markIdempotent(false, on: &urlRequest)
        }
        .validate()
        .serializingData()
        .response

        #expect(dataResponse.response?.statusCode == 429)
        guard case .failure = dataResponse.result else {
            Issue.record("Expected the opted-out PATCH to fail without a Retry-After replay")
            return
        }
        #expect(counter.count == 1)
    }

    /// Companion: an explicit `markIdempotent(true:)` override retries a
    /// method that would otherwise be excluded from `idempotentHTTPMethods`
    /// (POST) — the override works in both directions, not just as an
    /// opt-out.
    @Test("an explicit markIdempotent(true:) override retries even a normally-excluded method")
    func explicitOptInOverridesMethodDefault() async {
        let counter = AttemptCounter()
        let (session, queueID) = makeRetrierSession(
            stubs: [
                MockURLProtocol.StubResponse(status: 429, headers: ["Retry-After": "0"]),
                MockURLProtocol.StubResponse(status: 200),
            ],
            retriers: [RetryAfterRetrier()],
            adapters: [counter]
        )
        defer { MockURLProtocol.clearQueue(id: queueID) }

        let dataResponse = await session.request(
            "https://example.invalid/throttled", method: .post
        ) { urlRequest in
            RetryAfterRetrier.markIdempotent(true, on: &urlRequest)
        }
        .validate()
        .serializingData()
        .response

        #expect(dataResponse.response?.statusCode == 200)
        #expect(counter.count == 2)
    }

    /// #451 review round 3 (high should-fix): `markIdempotent(false:)` must
    /// be honored by the FULL production retrier chain, not just
    /// `RetryAfterRetrier` in isolation. `SessionPool` wires
    /// `[RetryAfterRetrier(), JitteredRetryPolicy(...)]`, and Alamofire falls
    /// through to the next retrier on `.doNotRetry` — without
    /// `JitteredRetryPolicy` also consulting the override,
    /// `RetryAfterRetrier` would correctly decline, only for
    /// `JitteredRetryPolicy`'s own (override-blind) method check to replay
    /// the same request anyway on the same 429, a silent no-op opt-out. This
    /// wires both retriers, exactly mirroring `SessionPool`'s real chain
    /// (only the concrete stubs/status codes differ), to pin the opt-out
    /// holding end-to-end.
    @Test("an explicit markIdempotent(false:) override is honored end-to-end through the full production retrier chain")
    func explicitOptOutHoldsThroughFullRetrierChain() async {
        let counter = AttemptCounter()
        let (session, queueID) = makeRetrierSession(
            stubs: [MockURLProtocol.StubResponse(status: 429, headers: ["Retry-After": "0"])],
            retriers: [
                RetryAfterRetrier(),
                JitteredRetryPolicy(
                    retryLimit: UInt(RetryAfterRetrier.maxRetries), retryableHTTPStatusCodes: [429]
                ),
            ],
            adapters: [counter]
        )
        defer { MockURLProtocol.clearQueue(id: queueID) }

        let dataResponse = await session.request(
            "https://example.invalid/throttled", method: .patch
        ) { urlRequest in
            RetryAfterRetrier.markIdempotent(false, on: &urlRequest)
        }
        .validate()
        .serializingData()
        .response

        #expect(dataResponse.response?.statusCode == 429)
        guard case .failure = dataResponse.result else {
            Issue.record("Expected the opted-out PATCH to fail without either retrier replaying it")
            return
        }
        #expect(counter.count == 1)
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

// MARK: - Buffered response size cap (#450)

@Suite("executeDataRequest buffered response cap")
struct BufferedResponseCapTests {
    private static let capURL = URL(string: "https://example.invalid/buffered")!

    /// Builds a `SessionPool` backed by a mock session serving `stubs`, mirroring
    /// the pool `FabricClient`/`OneLakeClient` construction uses in production.
    private func makePool(stubs: [MockURLProtocol.StubResponse]) async -> (SessionPool, String) {
        let queueID = "buffered-cap-\(UUID().uuidString)"
        MockURLProtocol.registerQueue(id: queueID, stubs: stubs)
        let session = makeMockSession(queueID: queueID)
        let pool = SessionPool(tokenProvider: NoopTokenProvider())
        await pool._setSessionForTesting(session, alias: "test", scope: .fabric)
        return (pool, queueID)
    }

    /// #450: a buffered response body over ``HTTPClientError/maxBufferedResponseBytes``
    /// must throw `.responseTooLarge` rather than being handed back uncapped —
    /// `mapError: FabricError.from` mirrors the real call site
    /// (`FabricClient.doRequest`) so this exercises the exact same mapping
    /// path production code uses.
    @Test("an over-cap buffered response throws responseTooLarge")
    func overCapResponseThrows() async {
        let overCap = Data(count: HTTPClientError.maxBufferedResponseBytes + 1)
        let (pool, queueID) = await makePool(stubs: [
            MockURLProtocol.StubResponse(status: 200, body: overCap),
        ])
        defer { MockURLProtocol.clearQueue(id: queueID) }

        do {
            _ = try await executeDataRequest(
                sessionPool: pool,
                alias: "test",
                scope: .fabric,
                method: "GET",
                url: Self.capURL,
                headers: [:],
                body: nil,
                mapError: FabricError.from
            )
            Issue.record("Expected responseTooLarge to be thrown for an over-cap buffered response")
        } catch let FabricError.httpError(underlying) {
            guard case let HTTPClientError.responseTooLarge(bytesReceived, limit)? = underlying as? HTTPClientError else {
                Issue.record("Expected HTTPClientError.responseTooLarge, got \(underlying)")
                return
            }
            #expect(bytesReceived == overCap.count)
            #expect(limit == HTTPClientError.maxBufferedResponseBytes)
        } catch {
            Issue.record("Expected FabricError.httpError(.responseTooLarge), got \(error)")
        }
    }

    /// A response at exactly the cap is not rejected — the guard is `<=`, not `<`.
    @Test("a buffered response at the cap is returned normally")
    func atCapResponseSucceeds() async throws {
        let atCap = Data(count: HTTPClientError.maxBufferedResponseBytes)
        let (pool, queueID) = await makePool(stubs: [
            MockURLProtocol.StubResponse(status: 200, body: atCap),
        ])
        defer { MockURLProtocol.clearQueue(id: queueID) }

        let (data, response) = try await executeDataRequest(
            sessionPool: pool,
            alias: "test",
            scope: .fabric,
            method: "GET",
            url: Self.capURL,
            headers: [:],
            body: nil,
            mapError: FabricError.from
        )
        #expect(data.count == HTTPClientError.maxBufferedResponseBytes)
        #expect(response.statusCode == 200)
    }

    /// #451 review round 3: distinct from `overCapResponseThrows` above,
    /// which relies on the post-buffer `data.count` backstop, this pins the
    /// `downloadProgress`-driven PREFLIGHT specifically. The stub declares a
    /// `Content-Length` far over the cap but sends only a tiny actual body,
    /// so the post-buffer check (which only ever sees those 10 bytes) can
    /// never trip on its own — the only way this can observe
    /// `responseTooLarge` is the preflight guard reading the declared
    /// `Content-Length` (via `Progress.totalUnitCount`) and recording it as
    /// over-cap, independent of whether `req.cancel()` wins its race against
    /// the mock's synchronous delivery.
    @Test("a response declaring Content-Length over the cap is preflight-rejected despite a tiny actual body")
    func declaredContentLengthOverCapIsPreflightRejected() async {
        let declaredLength = HTTPClientError.maxBufferedResponseBytes + 1
        let (pool, queueID) = await makePool(stubs: [
            MockURLProtocol.StubResponse(
                status: 200,
                body: Data(count: 10),
                headers: ["Content-Length": "\(declaredLength)"]
            ),
        ])
        defer { MockURLProtocol.clearQueue(id: queueID) }

        do {
            _ = try await executeDataRequest(
                sessionPool: pool,
                alias: "test",
                scope: .fabric,
                method: "GET",
                url: Self.capURL,
                headers: [:],
                body: nil,
                mapError: FabricError.from
            )
            Issue.record("Expected responseTooLarge from the Content-Length preflight despite a tiny actual body")
        } catch let FabricError.httpError(underlying) {
            guard case let HTTPClientError.responseTooLarge(bytesReceived, limit)? = underlying as? HTTPClientError else {
                Issue.record("Expected HTTPClientError.responseTooLarge, got \(underlying)")
                return
            }
            #expect(bytesReceived == declaredLength)
            #expect(limit == HTTPClientError.maxBufferedResponseBytes)
        } catch {
            Issue.record("Expected FabricError.httpError(.responseTooLarge), got \(error)")
        }
    }
}
