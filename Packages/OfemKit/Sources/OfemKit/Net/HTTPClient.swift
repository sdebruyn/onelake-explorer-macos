import Foundation
import os.log

// MARK: - TokenProvider

/// Supplies access tokens for a named account alias.
///
/// `OneLakeClient` and future Fabric clients receive a `TokenProvider` at
/// construction time. The concrete implementation (``OfemAuth``) is wired
/// in the host app or daemon. Test code uses stub closures.
public protocol TokenProvider: Sendable {
    /// Returns a valid bearer token for the given account alias and scope.
    ///
    /// - Parameters:
    /// - alias: The account alias (e.g. `"work"`).
    /// - scope: The OAuth audience to target.
    /// - Returns: A bearer token string.
    /// - Throws: Any error from the underlying auth implementation.
    func token(alias: String, scope: TokenScope) async throws -> String

    /// Forces a token refresh (discards any cached token) and returns a fresh one.
    ///
    /// Called on 401 to recover from mid-flight token expiry without surfacing
    /// the error immediately (net-03). The default implementation delegates to
    /// ``token(alias:scope:)``; concrete types override this if the underlying
    /// library exposes a forced-refresh API.
    func refreshedToken(alias: String, scope: TokenScope) async throws -> String
}

public extension TokenProvider {
    /// Default: delegates to ``token(alias:scope:)`` (no forced refresh).
    func refreshedToken(alias: String, scope: TokenScope) async throws -> String {
        try await token(alias: alias, scope: scope)
    }
}

// MARK: - URLSessionProtocol

/// Abstraction over `URLSession` for test injection.
///
/// In production code pass a `URLSession`; in tests pass a
/// `MockURLSession` that returns canned responses via `URLProtocol`.
public protocol URLSessionProtocol: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

extension URLSession: URLSessionProtocol {}

// MARK: - ResponseSizeLimit

/// Maximum number of bytes `HTTPClient` will buffer from a single response body.
///
/// Responses larger than this limit are rejected with
/// ``HTTPClientError/responseTooLarge(bytesReceived:limit:)`` so a misbehaving
/// server cannot cause an OOM crash in the memory-constrained FPE (net-19).
///
/// The default (32 MiB) covers all Fabric REST/metadata payloads; callers that
/// need larger transfers must use a dedicated streaming path.
public let httpClientDefaultResponseSizeLimit: Int = 32 * 1_024 * 1_024

// MARK: - HTTPClient

/// Executes HTTP requests with per-host gate throttling, retry-with-backoff,
/// and bearer-token injection.
///
/// `HTTPClient` composes:
/// - ``HTTPGateRegistry`` — per-host concurrency + rate-limiting
/// - ``HTTPRetryPolicy`` — exponential backoff with jitter + Retry-After
/// - ``TokenProvider`` — acquires bearer tokens for each request
///
/// The client itself is `Sendable`-safe; all mutable state lives in the
/// actor-isolated ``HTTPGateRegistry``.
public final class HTTPClient: Sendable {
    // MARK: - Properties

    private let session: any URLSessionProtocol
    private let gateRegistry: HTTPGateRegistry
    private let retryPolicy: HTTPRetryPolicy
    private let userAgent: String
    /// Maximum response body size in bytes. Responses exceeding this limit are
    /// rejected to prevent OOM in the FPE (net-19).
    private let responseSizeLimit: Int

    private static let log = Logger(subsystem: "dev.debruyn.ofem", category: "HTTPClient")

    // MARK: - Initialisers

    /// Creates an `HTTPClient`.
    ///
    /// - Parameters:
    /// - session: The underlying `URLSession`. Default: a session with a
    ///   60-second request timeout and no response-body timeout (so large
    ///   downloads are not killed mid-stream).
    /// - gateRegistry: The per-host rate-limit / concurrency registry.
    ///   Default: ``HTTPGateRegistry/makeDefault()``.
    /// - retryPolicy: Retry parameters. Default: ``HTTPRetryPolicy()``.
    /// - userAgent: The `User-Agent` header appended to every request.
    /// - responseSizeLimit: Maximum response body bytes to buffer. Default:
    ///   ``httpClientDefaultResponseSizeLimit`` (32 MiB).
    public init(
        session: any URLSessionProtocol = URLSession.ofemDefault,
        gateRegistry: HTTPGateRegistry = HTTPGateRegistry.makeDefault(),
        retryPolicy: HTTPRetryPolicy = HTTPRetryPolicy(),
        userAgent: String = "OFEM/1.0",
        responseSizeLimit: Int = httpClientDefaultResponseSizeLimit
    ) {
        self.session = session
        self.gateRegistry = gateRegistry
        self.retryPolicy = retryPolicy
        self.userAgent = userAgent
        self.responseSizeLimit = responseSizeLimit
    }

    // MARK: - Execute

    /// Executes `request` with gate throttling, retry and token injection.
    ///
    /// - Parameters:
    /// - request: A fully formed `URLRequest`. The `Authorization` header
    ///   is overwritten by `tokenProvider` / `alias` if supplied.
    /// - tokenProvider: Supplies an access token. When non-nil and `alias` is
    ///   non-empty, an `Authorization: Bearer …` header is injected. Supplying
    ///   a `tokenProvider` with an empty `alias` is a contract violation and
    ///   throws ``HTTPClientError/tokenAcquisitionFailed(_:)`` immediately
    ///   (fail fast rather than silently sending an unauthenticated request).
    /// - alias: Account alias forwarded to `tokenProvider`.
    /// - scope: OAuth scope forwarded to `tokenProvider`.
    /// - idempotent: When `true`, transport errors are retried even for
    ///   non-safe HTTP methods (POST/PATCH). GET/HEAD/PUT/DELETE are always
    ///   retried on transport errors regardless of this flag.
    /// - Returns: `(Data, HTTPURLResponse)` on success.
    /// - Throws: ``HTTPClientError`` on failure.
    public func execute(
        _ request: URLRequest,
        tokenProvider: (any TokenProvider)? = nil,
        alias: String = "",
        scope: TokenScope = .oneLake,
        idempotent: Bool = false
    ) async throws -> (Data, HTTPURLResponse) {
        // Fail fast when a TokenProvider is given but alias is empty —
        // sending the request unauthenticated would produce a confusing remote 401.
        if tokenProvider != nil, alias.isEmpty {
            throw HTTPClientError.tokenAcquisitionFailed(
                URLError(.userAuthenticationRequired,
                         userInfo: [NSLocalizedDescriptionKey: "TokenProvider supplied but alias is empty"])
            )
        }

        guard let url = request.url, let host = url.host else {
            throw HTTPClientError.transport(
                URLError(.badURL, userInfo: [NSURLErrorFailingURLStringErrorKey: request.url?.absoluteString ?? "nil"])
            )
        }

        // net-04: reject non-https requests before attaching credentials.
        // Bearer tokens must never travel over an unencrypted channel.
        if tokenProvider != nil, url.scheme?.lowercased() != "https" {
            throw HTTPClientError.tokenAcquisitionFailed(
                URLError(.secureConnectionFailed,
                         userInfo: [NSLocalizedDescriptionKey:
                             "Bearer token refused on non-https URL (scheme: \(url.scheme ?? "nil"))"])
            )
        }

        // Build the per-call policy with the caller's idempotency assertion
        // merged in. We copy the value-type policy so the shared instance is
        // never mutated (net-06).
        var policy = retryPolicy
        if idempotent { policy.idempotent = true }

        let gate = await gateRegistry.gate(for: host)
        let defaults = await gateRegistry.registryDefaults

        var wait = policy.initialBackoff
        var lastError: (any Error)?
        // Tracks whether we've already performed a forced token refresh for a
        // 401 response so we only do it once (net-03).
        var didRefreshFor401 = false
        // Hoist token acquisition out of the loop — re-fetch inside the loop
        // only on 401 (net-03: fetching every attempt pays Keychain/MSAL cost
        // on every transport/5xx retry even though the token cannot help there).
        var cachedToken: String? = try await acquireToken(
            provider: tokenProvider, alias: alias, scope: scope
        )

        for attempt in 1...policy.maxAttempts {
            // Check for task cancellation before each attempt.
            try Task.checkCancellation()

            // Structured gate slot guarantee (net-01 / net-12):
            // acquire() is immediately followed by a defer that calls release(),
            // so the slot is freed on every exit path — success, throw, or
            // cancellation — without manual bookkeeping across 10 branches.
            try await gate.acquire()
            let (data, httpResponse, slotError): (Data?, HTTPURLResponse?, (any Error)?) =
                await withGateSlot(gate) {
                    await self.runOneAttempt(
                        request: request,
                        token: cachedToken,
                        host: host
                    )
                }

            if let err = slotError {
                // If `runOneAttempt` returned an HTTPClientError (e.g.
                // responseTooLarge), rethrow it directly without wrapping in
                // .transport so callers can pattern-match on it precisely.
                if let clientErr = err as? HTTPClientError {
                    throw clientErr
                }
                // Transport / URLSession error.
                if err is CancellationError {
                    throw HTTPClientError.cancelled
                }
                let rootError = (err as NSError).userInfo[NSUnderlyingErrorKey] as? any Error ?? err
                let hardOffline = isHardOfflineURLError(err) || isHardOfflineURLError(rootError)
                if !hardOffline,
                   isRetriableURLError(err) || isRetriableURLError(rootError),
                   policy.canRetryTransportError(method: request.httpMethod ?? "GET") {
                    lastError = err
                    // net-05: log the URLError code (an integer) rather than
                    // localizedDescription, which may carry the full URL path.
                    let urlErrCode = (err as? URLError)?.code.rawValue ?? -1
                    Self.log.warning(
                        "HTTPClient: transport error attempt \(attempt, privacy: .public)/\(policy.maxAttempts, privacy: .public) code=\(urlErrCode, privacy: .public)"
                    )
                    if attempt < policy.maxAttempts {
                        let j = jitter(wait)
                        try await Task.sleep(for: j)
                        wait = nextBackoff(wait, max: policy.maxBackoff)
                    }
                    continue
                }
                throw HTTPClientError.transport(err)
            }

            guard let response = httpResponse else {
                throw HTTPClientError.transport(URLError(.badServerResponse))
            }
            guard let responseData = data else {
                throw HTTPClientError.transport(URLError(.badServerResponse))
            }

            let status = response.statusCode

            // Apply Retry-After penalty to the gate on overload statuses.
            // Cap the penalty so a buggy/hostile server cannot close the gate
            // for an excessive duration (net-17).
            if HTTPRetryStatusPolicy.shouldPenaliseGate(status) {
                let retryAfterDelay = retryAfterDuration(from: response, defaults: defaults)
                if let delay = retryAfterDelay {
                    let cappedDelay = min(delay, httpGateMaxPenaltyDuration)
                    let deadline = ContinuousClock.now + cappedDelay
                    await gate.penalty(until: deadline)
                }
            }

            // 2xx — success.
            if status >= 200, status < 300 {
                return (responseData, response)
            }

            // 3xx — URLSession follows redirects transparently by default, so
            // a 3xx status code here means auto-redirect is disabled. Surface
            // as an API error rather than silently treating it as a success
            // (net-18: the old "stray redirect" comment was misleading; if we
            // ever want to block redirects we must do so via a session delegate,
            // not by inspecting the final status).
            if status < 400 {
                let ae = APIError(statusCode: status, status: response.httpStatus,
                                  body: responseData, attempts: attempt)
                throw HTTPClientError.apiError(ae)
            }

            // 401 — single refresh-and-retry (net-03).
            // 401 is not in the general retriable set, but a mid-flight token
            // expiry can cause a genuine 401. We perform one forced refresh and
            // retry; if the refreshed request still gets 401 we surface it.
            // Only attempt the refresh if there is at least one more iteration
            // left in the loop — if this is the last allowed attempt, fall
            // through to the non-retriable 4xx branch and surface immediately.
            if status == 401, !didRefreshFor401, let tp = tokenProvider,
               attempt < policy.maxAttempts {
                didRefreshFor401 = true
                do {
                    cachedToken = try await tp.refreshedToken(alias: alias, scope: scope)
                } catch {
                    throw HTTPClientError.tokenAcquisitionFailed(error)
                }
                // Retry immediately (no backoff — this is a token issue, not load).
                lastError = HTTPClientError.unauthorized
                continue
            }

            // Non-retriable 4xx — surface immediately.
            if !HTTPClientError.isRetriableStatus(status) {
                let retryDelay = parseRetryAfter(response.value(forHTTPHeaderField: "Retry-After") ?? "")
                let ae = APIError(statusCode: status, status: response.httpStatus, body: responseData,
                                  retryAfter: retryDelay ?? .zero, attempts: attempt)
                if let sentinel = ae.sentinel {
                    throw sentinel
                }
                throw HTTPClientError.apiError(ae)
            }

            // Retriable status (408, 425, 429, 5xx).
            let retryDelay = parseRetryAfter(response.value(forHTTPHeaderField: "Retry-After") ?? "")
            let ae = APIError(statusCode: status, status: response.httpStatus, body: responseData,
                              retryAfter: retryDelay ?? .zero, attempts: attempt)
            lastError = HTTPClientError.apiError(ae)

            if attempt == policy.maxAttempts { break }

            // net-02: jitter the Retry-After-derived sleep too so all
            // concurrent clients don't wake at the same instant.
            let sleepDuration: Duration
            if let override = retryDelay {
                let capped = min(override, policy.maxBackoff)
                sleepDuration = jitter(capped)
            } else {
                sleepDuration = jitter(wait)
                wait = nextBackoff(wait, max: policy.maxBackoff)
            }
            Self.log.warning(
                "HTTPClient: retriable \(status, privacy: .public) attempt \(attempt, privacy: .public)/\(policy.maxAttempts, privacy: .public) waiting \(sleepDuration, privacy: .public)"
            )
            try await Task.sleep(for: sleepDuration)
        }

        // net-16: use the live `attempt` value (loop just exited after
        // policy.maxAttempts iterations) so `attempts:` reflects the actual
        // round-trips, not a separate constant that could drift.
        let finalError = lastError ?? HTTPClientError.serverError(0)
        throw HTTPClientError.retriesExhausted(attempts: policy.maxAttempts, last: finalError)
    }

    // MARK: - Private helpers

    /// Acquires a token from `provider` if supplied. Returns `nil` when no
    /// provider is configured (unauthenticated request).
    private func acquireToken(
        provider: (any TokenProvider)?,
        alias: String,
        scope: TokenScope
    ) async throws -> String? {
        guard let tp = provider else { return nil }
        do {
            return try await tp.token(alias: alias, scope: scope)
        } catch {
            throw HTTPClientError.tokenAcquisitionFailed(error)
        }
    }

    /// Executes a single HTTP round-trip and returns the raw result.
    ///
    /// Returns `(data, response, nil)` on success or `(nil, nil, error)` on
    /// transport failure. Enforces the response-size limit (net-19).
    private func runOneAttempt(
        request: URLRequest,
        token: String?,
        host: String
    ) async -> (Data?, HTTPURLResponse?, (any Error)?) {
        var authorised = request
        authorised.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        if let tok = token {
            // net-04: scheme check is enforced in execute() before we reach here.
            authorised.setValue("Bearer \(tok)", forHTTPHeaderField: "Authorization")
        }

        let data: Data
        let urlResponse: URLResponse
        do {
            (data, urlResponse) = try await session.data(for: authorised)
        } catch {
            return (nil, nil, error)
        }

        guard let httpResponse = urlResponse as? HTTPURLResponse else {
            return (nil, nil, URLError(.badServerResponse))
        }

        // net-19: enforce response size limit — session.data(for:) buffers the
        // full body in memory, so a large response risks OOM in the FPE.
        if data.count > responseSizeLimit {
            let limit = self.responseSizeLimit
            Self.log.error(
                "HTTPClient[\(host, privacy: .public)]: response body \(data.count, privacy: .public) bytes exceeds limit \(limit, privacy: .public)"
            )
            return (nil, nil, HTTPClientError.responseTooLarge(
                bytesReceived: data.count,
                limit: responseSizeLimit
            ))
        }

        return (data, httpResponse, nil)
    }

    /// Extracts a Retry-After delay from the response, falling back to the
    /// registry default when the header is absent.
    private func retryAfterDuration(
        from response: HTTPURLResponse,
        defaults: HTTPGateDefaults
    ) -> Duration? {
        let header = response.value(forHTTPHeaderField: "Retry-After") ?? ""
        if let d = parseRetryAfter(header) { return d }
        if defaults.missingRetryAfter > .zero { return defaults.missingRetryAfter }
        return nil
    }
}

// MARK: - Structured gate-slot helper

/// Runs `body` then releases `gate` — structured acquire/release guarantee
/// that eliminates manual release bookkeeping across every exit path
/// (net-01 / net-12).
///
/// The gate must already have been acquired before calling this helper; it
/// owns the release on all exit paths including cancellation.
///
/// `body` is non-throwing: transport errors and response-validation failures
/// are returned as a typed tuple so all classification happens *after* the
/// slot is released, keeping the slot duration minimal.
///
/// - Returns: The value produced by `body`.
private func withGateSlot<T: Sendable>(
    _ gate: HTTPGate,
    body: () async -> T
) async -> T {
    let result = await body()
    await gate.release()
    return result
}

// MARK: - URLSession default

extension URLSession {
    /// Default session for production use: 60-second connection timeout,
    /// no overall `timeoutIntervalForResource` limit so large downloads are
    /// not killed mid-body. Callers control the overall deadline via
    /// Swift Concurrency task cancellation / `withTimeout`.
    public static var ofemDefault: URLSession {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = .infinity
        return URLSession(configuration: config)
    }
}

// MARK: - HTTPURLResponse convenience

private extension HTTPURLResponse {
    var httpStatus: String {
        let phrase = HTTPURLResponse.localizedString(forStatusCode: statusCode)
        return "\(statusCode) \(phrase)"
    }
}
