import Foundation
import os.log

// MARK: - TokenProvider

/// Supplies access tokens for a named account alias.
///
/// `OneLakeClient` and future Fabric clients receive a `TokenProvider` at
/// construction time. The concrete implementation (``OfemAuth``) is wired
/// in the host app or daemon. Test code uses stub closures.
///
/// Mirrors `internal/auth/provider.go` — `TokenProvider` interface.
public protocol TokenProvider: Sendable {
    /// Returns a valid bearer token for the given account alias and scope.
    ///
    /// - Parameters:
    ///   - alias: The account alias (e.g. `"work"`).
    ///   - scope: The OAuth audience to target.
    /// - Returns: A bearer token string.
    /// - Throws: Any error from the underlying auth implementation.
    func token(alias: String, scope: TokenScope) async throws -> String
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
///
/// Mirrors `internal/onelake/client.go` — `Client.doRequest` + the
/// transport-wrapping in `internal/httpgate/roundtripper.go`.
public final class HTTPClient: Sendable {
    // MARK: - Properties

    private let session: any URLSessionProtocol
    private let gateRegistry: HTTPGateRegistry
    private let retryPolicy: HTTPRetryPolicy
    private let userAgent: String

    private static let log = Logger(subsystem: "dev.debruyn.ofem", category: "HTTPClient")

    // MARK: - Initialisers

    /// Creates an `HTTPClient`.
    ///
    /// - Parameters:
    ///   - session: The underlying `URLSession`. Default: a session with a
    ///     60-second request timeout and no response-body timeout (so large
    ///     downloads are not killed mid-stream).
    ///   - gateRegistry: The per-host rate-limit / concurrency registry.
    ///     Default: ``HTTPGateRegistry/makeDefault()``.
    ///   - retryPolicy: Retry parameters. Default: ``HTTPRetryPolicy()``.
    ///   - userAgent: The `User-Agent` header appended to every request.
    public init(
        session: any URLSessionProtocol = URLSession.ofemDefault,
        gateRegistry: HTTPGateRegistry = HTTPGateRegistry.makeDefault(),
        retryPolicy: HTTPRetryPolicy = HTTPRetryPolicy(),
        userAgent: String = "OFEM/1.0"
    ) {
        self.session = session
        self.gateRegistry = gateRegistry
        self.retryPolicy = retryPolicy
        self.userAgent = userAgent
    }

    // MARK: - Execute

    /// Executes `request` with gate throttling, retry and token injection.
    ///
    /// - Parameters:
    ///   - request: A fully formed `URLRequest`. The `Authorization` header
    ///     is overwritten by `tokenProvider` / `alias` if supplied.
    ///   - tokenProvider: Supplies an access token. When non-nil, a
    ///     `Authorization: Bearer …` header is injected (or refreshed on
    ///     401 retry).
    ///   - alias: Account alias forwarded to `tokenProvider`.
    ///   - scope: OAuth scope forwarded to `tokenProvider`.
    ///   - idempotent: Passed to ``HTTPRetryPolicy/canRetryTransportError(method:)``
    ///     to decide whether a mid-flight transport error is retried.
    /// - Returns: `(Data, HTTPURLResponse)` on success.
    /// - Throws: ``HTTPClientError`` on failure.
    public func execute(
        _ request: URLRequest,
        tokenProvider: (any TokenProvider)? = nil,
        alias: String = "",
        scope: TokenScope = .oneLake,
        idempotent: Bool = false
    ) async throws -> (Data, HTTPURLResponse) {
        guard let url = request.url, let host = url.host else {
            throw HTTPClientError.transport(
                URLError(.badURL, userInfo: [NSURLErrorFailingURLStringErrorKey: request.url?.absoluteString ?? "nil"])
            )
        }

        var policy = retryPolicy
        if idempotent { policy.idempotent = true }

        let gate = await gateRegistry.gate(for: host)
        let defaults = await gateRegistry.registryDefaults

        var wait = policy.initialBackoff
        var lastError: (any Error)?

        for attempt in 1...policy.maxAttempts {
            // Check for task cancellation before each attempt.
            try Task.checkCancellation()

            // Acquire gate slot (blocks on pause window + concurrency + QPS).
            await gate.acquire()

            // Build an authorised copy of the request.
            var authorised = request
            authorised.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            if let tp = tokenProvider, !alias.isEmpty {
                do {
                    let tok = try await tp.token(alias: alias, scope: scope)
                    authorised.setValue("Bearer \(tok)", forHTTPHeaderField: "Authorization")
                } catch {
                    await gate.release()
                    throw HTTPClientError.tokenAcquisitionFailed(error)
                }
            }

            // Execute the request.
            let data: Data
            let urlResponse: URLResponse
            do {
                (data, urlResponse) = try await session.data(for: authorised)
            } catch {
                await gate.release()
                if error is CancellationError {
                    throw HTTPClientError.cancelled
                }
                if isRetriableURLError(error), policy.canRetryTransportError(method: request.httpMethod ?? "GET") {
                    lastError = error
                    Self.log.warning("HTTPClient: transport error attempt \(attempt)/\(policy.maxAttempts, privacy: .public): \(error.localizedDescription, privacy: .public)")
                    if attempt < policy.maxAttempts {
                        let j = jitter(wait)
                        try await Task.sleep(for: j)
                        wait = nextBackoff(wait, max: policy.maxBackoff)
                    }
                    continue
                }
                throw HTTPClientError.transport(error)
            }

            guard let httpResponse = urlResponse as? HTTPURLResponse else {
                await gate.release()
                throw HTTPClientError.transport(URLError(.badServerResponse))
            }

            let status = httpResponse.statusCode

            // Apply Retry-After penalty to the gate on 429/503 (mirrors
            // httpgate/roundtripper.go: penalty is applied before the body
            // is released so peer goroutines observe it immediately).
            if status == 429 || status == 503 {
                let retryAfterHeader = httpResponse.value(forHTTPHeaderField: "Retry-After") ?? ""
                if let delay = parseRetryAfter(retryAfterHeader) {
                    let deadline = ContinuousClock.now + delay
                    await gate.penalty(until: deadline)
                } else if defaults.missingRetryAfter > .zero {
                    let deadline = ContinuousClock.now + defaults.missingRetryAfter
                    await gate.penalty(until: deadline)
                }
            }

            await gate.release()

            // 2xx — success.
            if status >= 200, status < 300 {
                return (data, httpResponse)
            }

            // 3xx — treat as error (stray redirect on PATCH/PUT/DELETE).
            if status < 400 {
                let ae = APIError(statusCode: status, status: httpResponse.httpStatus, body: data, attempts: attempt)
                throw HTTPClientError.apiError(ae)
            }

            // Non-retriable 4xx — surface immediately.
            if !HTTPClientError.isRetriableStatus(status) {
                let retryAfterDuration: Duration
                let retryHeader = httpResponse.value(forHTTPHeaderField: "Retry-After") ?? ""
                retryAfterDuration = parseRetryAfter(retryHeader) ?? .zero
                let ae = APIError(statusCode: status, status: httpResponse.httpStatus, body: data, retryAfter: retryAfterDuration, attempts: attempt)
                if let sentinel = ae.sentinel {
                    throw sentinel
                }
                throw HTTPClientError.apiError(ae)
            }

            // Retriable status (408, 425, 429, 5xx).
            let retryHeader = httpResponse.value(forHTTPHeaderField: "Retry-After") ?? ""
            let retryAfterOverride = parseRetryAfter(retryHeader)
            let ae = APIError(statusCode: status, status: httpResponse.httpStatus, body: data, retryAfter: retryAfterOverride ?? .zero, attempts: attempt)
            lastError = HTTPClientError.apiError(ae)

            if attempt == policy.maxAttempts { break }

            let sleepDuration: Duration
            if let override = retryAfterOverride {
                sleepDuration = min(override, policy.maxBackoff)
            } else {
                sleepDuration = jitter(wait)
                wait = nextBackoff(wait, max: policy.maxBackoff)
            }
            Self.log.warning("HTTPClient: retriable \(status) attempt \(attempt)/\(policy.maxAttempts, privacy: .public), waiting \(sleepDuration, privacy: .public)")
            try await Task.sleep(for: sleepDuration)
        }

        let finalError = lastError ?? HTTPClientError.serverError(0)
        throw HTTPClientError.retriesExhausted(attempts: policy.maxAttempts, last: finalError)
    }
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
