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

// MARK: - URLSessionStreamProtocol

/// Abstraction over `URLSession.bytes(for:)` for streaming download injection.
///
/// Kept separate from ``URLSessionProtocol`` so existing mock sessions don't
/// need to implement bytes-streaming (net-19).
///
/// `URLSession` conforms via the extension below; test code injects a
/// `MockURLSessionStream` that returns pre-built byte sequences without a
/// live network connection.
public protocol URLSessionStreamProtocol: Sendable {
    /// Streams the response body for `request` as an async byte sequence.
    ///
    /// - Returns: `(AsyncBytes, URLResponse)` where `AsyncBytes` vends bytes
    ///   one at a time.
    func bytes(for request: URLRequest) async throws -> (URLSession.AsyncBytes, URLResponse)
}

extension URLSession: URLSessionStreamProtocol {
    public func bytes(for request: URLRequest) async throws -> (URLSession.AsyncBytes, URLResponse) {
        try await self.bytes(for: request, delegate: nil)
    }
}

// MARK: - ResponseSizeLimit

/// Maximum number of bytes `HTTPClient` will buffer from a single response body.
///
/// When set to `Int.max` (the default), no limit is enforced — all response
/// sizes are accepted. This is the correct default because `HTTPClient` is the
/// only download path for OneLake file content, and files routinely exceed any
/// reasonable hard cap.
///
/// Callers that handle only small control-plane JSON payloads (e.g. a future
/// `FabricClient`) may pass a lower value at construction time to get OOM
/// protection for their specific use-case. The true fix for large file
/// downloads (streaming via `session.bytes(for:)` instead of buffering) is
/// tracked as net-19 and deferred to the WP-Clients work package.
public let httpClientDefaultResponseSizeLimit: Int = Int.max

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
    /// Session used for streaming downloads (``download(to:)``).
    private let streamSession: any URLSessionStreamProtocol
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
    /// - session: The underlying `URLSession` for buffered requests. Default:
    ///   a session with a 60-second connection timeout and no response-body
    ///   timeout so large downloads are not killed mid-stream.
    /// - streamSession: The session used for streaming downloads via
    ///   ``download(to:)`` (`session.bytes(for:)`). Defaults to the same
    ///   `URLSession.ofemDefault` instance as `session`.
    /// - gateRegistry: The per-host rate-limit / concurrency registry.
    ///   Default: ``HTTPGateRegistry/makeDefault()``.
    /// - retryPolicy: Retry parameters. Default: ``HTTPRetryPolicy()``.
    /// - userAgent: The `User-Agent` header appended to every request.
    /// - responseSizeLimit: Maximum response body bytes to buffer for 2xx
    ///   responses. Default: ``httpClientDefaultResponseSizeLimit`` (unlimited).
    public init(
        session: any URLSessionProtocol = URLSession.ofemDefault,
        streamSession: (any URLSessionStreamProtocol)? = nil,
        gateRegistry: HTTPGateRegistry = HTTPGateRegistry.makeDefault(),
        retryPolicy: HTTPRetryPolicy = HTTPRetryPolicy(),
        userAgent: String = "OFEM/1.0",
        responseSizeLimit: Int = httpClientDefaultResponseSizeLimit
    ) {
        self.session = session
        // When no separate stream session is provided, fall back to the
        // buffered session if it also conforms, otherwise use the default.
        if let ss = streamSession {
            self.streamSession = ss
        } else if let ss = session as? any URLSessionStreamProtocol {
            self.streamSession = ss
        } else {
            self.streamSession = URLSession.ofemDefault
        }
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
                // Gate slot already released by withGateSlot above.
                // Classify the error — transport errors go through the retry
                // path; HTTPClientError (e.g. responseTooLarge on a 2xx body)
                // surfaces immediately without wrapping.
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
                        // Gate slot already released; this sleep is outside
                        // the gate slot so cancellation here does not leak.
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
            // Gate slot already released; this sleep is outside the gate slot
            // so cancellation here does not leak a concurrency slot.
            try await Task.sleep(for: sleepDuration)
        }

        // net-16: use the live `attempt` value (loop just exited after
        // policy.maxAttempts iterations) so `attempts:` reflects the actual
        // round-trips, not a separate constant that could drift.
        let finalError = lastError ?? HTTPClientError.serverError(0)
        throw HTTPClientError.retriesExhausted(attempts: policy.maxAttempts, last: finalError)
    }

    // MARK: - Streaming download

    /// Downloads `request` by streaming the response body directly into
    /// `destination` without buffering the whole file in memory (net-19 /
    /// onelake-02 true streaming fix).
    ///
    /// Unlike ``execute(_:tokenProvider:alias:scope:idempotent:)`` which calls
    /// `session.data(for:)` and loads the entire body into a `Data`, this
    /// method uses `streamSession.bytes(for:)` and writes each chunk to
    /// `destination` as it arrives, keeping memory use constant regardless of
    /// file size.
    ///
    /// **Retry behaviour:** GET / HEAD / PUT / DELETE are always retried on
    /// transport errors; other methods respect the `idempotent` flag. On each
    /// retry the destination is truncated to zero (via `FileHandle.truncate`)
    /// and restarted from the beginning — a partial write is never left on
    /// disk. The caller is responsible for opening the `FileHandle` and closing
    /// it after this method returns.
    ///
    /// **Cancellation:** `Task.checkCancellation()` is called before every
    /// attempt, and the async `for … in bytes` loop cooperates with structured
    /// concurrency so cancellation mid-stream is prompt.
    ///
    /// - Parameters:
    /// - request: The HTTP request. GET is typical; the `Authorization` header
    ///   is overwritten by `tokenProvider` / `alias` if supplied.
    /// - destination: An open, writable `FileHandle` positioned at the offset
    ///   where writing should begin (usually 0 for a fresh download).
    /// - tokenProvider: Supplies a bearer token. Behaves identically to
    ///   ``execute(_:tokenProvider:alias:scope:idempotent:)``.
    /// - alias: Account alias forwarded to `tokenProvider`.
    /// - scope: OAuth scope forwarded to `tokenProvider`.
    /// - idempotent: When `true`, transport errors are retried even for
    ///   non-safe HTTP methods.
    /// - Returns: The `HTTPURLResponse` (headers accessible to the caller).
    /// - Throws: ``HTTPClientError`` on failure.
    public func download(
        _ request: URLRequest,
        to destination: FileHandle,
        tokenProvider: (any TokenProvider)? = nil,
        alias: String = "",
        scope: TokenScope = .oneLake,
        idempotent: Bool = false
    ) async throws -> HTTPURLResponse {
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

        if tokenProvider != nil, url.scheme?.lowercased() != "https" {
            throw HTTPClientError.tokenAcquisitionFailed(
                URLError(.secureConnectionFailed,
                         userInfo: [NSLocalizedDescriptionKey:
                             "Bearer token refused on non-https URL (scheme: \(url.scheme ?? "nil"))"])
            )
        }

        var policy = retryPolicy
        if idempotent { policy.idempotent = true }

        let gate = await gateRegistry.gate(for: host)
        // NIT-3: hoist registryDefaults outside the retry loop (immutable after
        // construction) so the actor hop is paid once per request, not per attempt.
        let defaults = await gateRegistry.registryDefaults

        var wait = policy.initialBackoff
        var lastError: (any Error)?
        var didRefreshFor401 = false
        var cachedToken: String? = try await acquireToken(
            provider: tokenProvider, alias: alias, scope: scope
        )

        for attempt in 1...policy.maxAttempts {
            try Task.checkCancellation()

            // Truncate the destination file before each attempt so a partial
            // write from a previous attempt does not corrupt the final content.
            try destination.truncate(atOffset: 0)
            try destination.seek(toOffset: 0)

            try await gate.acquire()
            let (httpResponse, attemptError): (HTTPURLResponse?, (any Error)?) =
                await withGateSlot(gate) {
                    await self.runOneStreamAttempt(
                        request: request,
                        token: cachedToken,
                        host: host,
                        destination: destination
                    )
                }

            if let err = attemptError {
                if let clientErr = err as? HTTPClientError {
                    throw clientErr
                }
                if err is CancellationError {
                    throw HTTPClientError.cancelled
                }
                let rootError = (err as NSError).userInfo[NSUnderlyingErrorKey] as? any Error ?? err
                let hardOffline = isHardOfflineURLError(err) || isHardOfflineURLError(rootError)
                if !hardOffline,
                   isRetriableURLError(err) || isRetriableURLError(rootError),
                   policy.canRetryTransportError(method: request.httpMethod ?? "GET") {
                    lastError = err
                    let urlErrCode = (err as? URLError)?.code.rawValue ?? -1
                    Self.log.warning(
                        "HTTPClient.download: transport error attempt \(attempt, privacy: .public)/\(policy.maxAttempts, privacy: .public) code=\(urlErrCode, privacy: .public)"
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

            let status = response.statusCode

            if HTTPRetryStatusPolicy.shouldPenaliseGate(status) {
                let retryAfterDelay = retryAfterDuration(from: response, defaults: defaults)
                if let delay = retryAfterDelay {
                    let cappedDelay = min(delay, httpGateMaxPenaltyDuration)
                    let deadline = ContinuousClock.now + cappedDelay
                    await gate.penalty(until: deadline)
                }
            }

            if status >= 200, status < 300 {
                return response
            }

            if status < 400 {
                let ae = APIError(statusCode: status, status: response.httpStatus,
                                  body: Data(), attempts: attempt)
                throw HTTPClientError.apiError(ae)
            }

            if status == 401, !didRefreshFor401, let tp = tokenProvider,
               attempt < policy.maxAttempts {
                didRefreshFor401 = true
                do {
                    cachedToken = try await tp.refreshedToken(alias: alias, scope: scope)
                } catch {
                    throw HTTPClientError.tokenAcquisitionFailed(error)
                }
                lastError = HTTPClientError.unauthorized
                continue
            }

            if !HTTPClientError.isRetriableStatus(status) {
                let ae = APIError(statusCode: status, status: response.httpStatus,
                                  body: Data(), attempts: attempt)
                if let sentinel = ae.sentinel {
                    throw sentinel
                }
                throw HTTPClientError.apiError(ae)
            }

            let retryDelay = parseRetryAfter(response.value(forHTTPHeaderField: "Retry-After") ?? "")
            let ae = APIError(statusCode: status, status: response.httpStatus,
                              body: Data(), retryAfter: retryDelay ?? .zero, attempts: attempt)
            lastError = HTTPClientError.apiError(ae)

            if attempt == policy.maxAttempts { break }

            let sleepDuration: Duration
            if let override = retryDelay {
                let capped = min(override, policy.maxBackoff)
                sleepDuration = jitter(capped)
            } else {
                sleepDuration = jitter(wait)
                wait = nextBackoff(wait, max: policy.maxBackoff)
            }
            Self.log.warning(
                "HTTPClient.download: retriable \(status, privacy: .public) attempt \(attempt, privacy: .public)/\(policy.maxAttempts, privacy: .public)"
            )
            try await Task.sleep(for: sleepDuration)
        }

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
    /// transport failure.
    ///
    /// The response-size limit (net-19) is applied **only to 2xx responses**
    /// where the body is the content the caller asked for. Error-response
    /// bodies (4xx/5xx) are returned as-is; the execute() loop classifies them
    /// by status code and decides whether to retry — the body is usually a
    /// small diagnostic string and discarding it would hide information from
    /// the retry-exhausted error path.
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

        #if DEBUG
        // net-21: log the absolute request URL and the raw transport outcome
        // before any status-code classification.  .public in DEBUG so the URL
        // is visible in unredacted log streams; in Release the message is not
        // emitted at all (compile-time elimination).
        Self.log.debug(
            "HTTPClient[D]: → \(authorised.httpMethod ?? "?", privacy: .public) \(authorised.url?.absoluteString ?? "(nil)", privacy: .public)"
        )
        #endif

        let data: Data
        let urlResponse: URLResponse
        do {
            (data, urlResponse) = try await session.data(for: authorised)
        } catch {
            #if DEBUG
            Self.log.debug(
                "HTTPClient[D]: ← transport error \(String(describing: error), privacy: .public)"
            )
            #endif
            return (nil, nil, error)
        }

        guard let httpResponse = urlResponse as? HTTPURLResponse else {
            return (nil, nil, URLError(.badServerResponse))
        }

        #if DEBUG
        // net-21: log the HTTP status so a fast non-network response (e.g.
        // served from URLCache) is distinguishable from a live round-trip.
        Self.log.debug(
            "HTTPClient[D]: ← HTTP \(httpResponse.statusCode, privacy: .public) \(authorised.url?.absoluteString ?? "(nil)", privacy: .public)"
        )
        #endif

        // net-19: enforce the response-size limit only for successful (2xx)
        // responses — those are the bodies the caller actually wants to keep.
        // For error responses the body is discarded by the status-code path
        // anyway; enforcing the limit here would turn a retriable 503 with a
        // large diagnostic body into a terminal responseTooLarge error, which
        // is wrong (the BLOCKER the reviewer called out).
        let status = httpResponse.statusCode
        if status >= 200, status < 300, responseSizeLimit != Int.max,
           data.count > responseSizeLimit {
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

    /// Executes a single streaming HTTP round-trip, writing the response body
    /// to `destination` as bytes arrive.
    ///
    /// Returns `(response, nil)` on a completed transfer, or `(nil, error)` on
    /// any failure. The status code is NOT examined here — the caller decides
    /// whether to retry based on it.
    ///
    /// For non-2xx responses the body is discarded rather than written to the
    /// destination; the `(response, nil)` tuple is still returned so the caller
    /// can inspect the status and apply retry / error logic.
    private func runOneStreamAttempt(
        request: URLRequest,
        token: String?,
        host: String,
        destination: FileHandle
    ) async -> (HTTPURLResponse?, (any Error)?) {
        var authorised = request
        authorised.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        if let tok = token {
            authorised.setValue("Bearer \(tok)", forHTTPHeaderField: "Authorization")
        }

        let bytes: URLSession.AsyncBytes
        let urlResponse: URLResponse
        do {
            (bytes, urlResponse) = try await streamSession.bytes(for: authorised)
        } catch {
            return (nil, error)
        }

        guard let httpResponse = urlResponse as? HTTPURLResponse else {
            return (nil, URLError(.badServerResponse))
        }

        let status = httpResponse.statusCode
        // Only stream the body to disk for 2xx responses.
        // For error responses discard the body; the status-code path handles them.
        guard status >= 200, status < 300 else {
            // Drain the stream so the connection is released cleanly.
            // Ignore drain errors — the non-2xx status is the real signal.
            do {
                for try await _ in bytes { }
            } catch { /* drain errors discarded intentionally */ }
            return (httpResponse, nil)
        }

        // Write bytes to the destination as they arrive, honouring cancellation
        // implicitly via the async for-in loop.
        var buffer = Data()
        buffer.reserveCapacity(65536)
        do {
            for try await byte in bytes {
                buffer.append(byte)
                if buffer.count >= 65536 {
                    try destination.write(contentsOf: buffer)
                    buffer.removeAll(keepingCapacity: true)
                }
            }
            if !buffer.isEmpty {
                try destination.write(contentsOf: buffer)
            }
        } catch {
            return (nil, error)
        }

        return (httpResponse, nil)
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
    ///
    /// URL caching is explicitly disabled (`urlCache = nil`,
    /// `requestCachePolicy = .reloadIgnoringLocalCacheData`) so that a
    /// stale or negative (404) entry in `URLCache.shared` can never be
    /// served to the FPE without a live network round-trip.  Without this,
    /// a previously cached 404 from `api.fabric.microsoft.com/v1/workspaces`
    /// can be returned in <3 ms — making `FabricClient` appear to fail with
    /// `HTTPClientError.notFound` before CFNetwork even opens a connection
    /// (issue-268).
    public static var ofemDefault: URLSession {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = .infinity
        // net-20: disable the shared URL cache so stale or negative entries
        // (e.g. a previously cached 404 for the Fabric workspaces endpoint)
        // are never served without a real network round-trip.
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
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
