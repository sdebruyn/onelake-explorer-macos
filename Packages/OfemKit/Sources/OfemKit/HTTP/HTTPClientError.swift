import Foundation

// MARK: - HTTPClientError

/// Typed errors produced by the HTTP transport layer.
public indirect enum HTTPClientError: Error, Sendable {
    // MARK: HTTP-status sentinels

    /// HTTP 401 — token is missing, expired or invalid.
    case unauthorized

    /// HTTP 403 — the authenticated identity lacks permission.
    case forbidden

    /// HTTP 404 — the resource does not exist.
    case notFound

    /// HTTP 409 — conflicting state on the server.
    case conflict

    /// HTTP 410 — the resource was permanently removed.
    case gone

    /// HTTP 412 — an `If-Match` / `If-None-Match` ETag precondition failed.
    case preconditionFailed

    /// HTTP 413 — the request payload exceeded the server's limit.
    case payloadTooLarge

    /// HTTP 415 — the `Content-Type` is unsupported.
    case unsupportedMediaType

    /// HTTP 416 — the `Range` header names a range the server cannot satisfy.
    case rangeNotSatisfiable

    /// HTTP 422 — the request was well-formed but semantically invalid.
    case unprocessableEntity

    /// HTTP 429 — the server is throttling this client.
    case throttled

    /// Any 5xx response not specifically named above.
    case serverError(Int)

    // MARK: API-level errors

    /// An HTTP response outside the 2xx range, carrying the raw details.
    case apiError(APIError)

    /// A body-relevant HTTP sentinel (401/403/429/5xx) whose response body is
    /// preserved for downstream callers such as ``PauseManager/isPausedCapacityError``.
    ///
    /// The first associated value is the typed sentinel for callers that only need
    /// the error category. The second carries the full ``APIError`` (including the
    /// response body) for callers that must inspect the body — e.g. to distinguish
    /// a paused-capacity 403 from a permission-denied 403.
    ///
    /// Produced by ``HTTPClientError/init(afError:response:body:retryCount:)`` for
    /// sentinel statuses where the body may carry a diagnostic payload (401, 403,
    /// 429, 5xx). Non-body-relevant sentinels (404, 409, 410, 412, 413, 415, 416,
    /// 422) keep the bare typed case so their consumers (e.g. `SyncEngine.notFound`)
    /// remain unchanged.
    case sentinelWithBody(HTTPClientError, APIError)

    // MARK: Transport / infrastructure errors

    /// The request was cancelled by the caller's `Task` or the session.
    case cancelled

    /// A transport-level error (e.g. DNS failure, connection refused).
    case transport(any Error)

    /// Retries were exhausted without a successful response.
    ///
    /// `attempts` is the total number of attempts made. `last` is the final
    /// error that caused the retry loop to stop.
    case retriesExhausted(attempts: Int, last: any Error)

    // MARK: Token-provider errors

    /// The `TokenProvider` threw when asked for an access token.
    case tokenAcquisitionFailed(any Error)

    // MARK: Response errors

    /// The response body exceeded the configured size limit.
    case responseTooLarge(bytesReceived: Int, limit: Int)
}

// MARK: - APIError

/// The parsed failure from a single non-2xx HTTP response.
public struct APIError: Sendable, CustomStringConvertible {
    /// The HTTP status code (e.g. `404`).
    public let statusCode: Int

    /// The full status string (e.g. `"404 Not Found"`).
    public let status: String

    /// Raw response body (stored in full; truncated to 256 bytes only in `description`).
    public let body: Data

    /// Parsed `Retry-After` delay; zero if the header was absent or unparseable.
    // periphery:ignore
    public let retryAfter: Duration

    /// Number of attempts made before this error was surfaced.
    public let attempts: Int

    /// The value of the `x-ms-error-code` response header, if present.
    ///
    /// Carried alongside the body so ``PauseManager/isPausedCapacityError(_:)``
    /// can detect a paused-capacity 404 even when the body is empty.
    public let msErrorCode: String?

    public init(
        statusCode: Int,
        status: String,
        body: Data,
        retryAfter: Duration = .zero,
        attempts: Int = 1,
        msErrorCode: String? = nil
    ) {
        self.statusCode = statusCode
        self.status = status
        self.body = body
        self.retryAfter = retryAfter
        self.attempts = attempts
        self.msErrorCode = msErrorCode
    }

    /// The typed sentinel that `statusCode` maps to.
    public var sentinel: HTTPClientError? {
        HTTPClientError.sentinel(for: statusCode)
    }

    public var description: String {
        let bodyStr = String(data: body.prefix(256), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "<non-UTF-8 body>"
        let attemptsSuffix = attempts > 1 ? " after \(attempts) attempts" : ""
        let codeSuffix = msErrorCode.map { " [\($0)]" } ?? ""
        if bodyStr.isEmpty {
            return "HTTP \(status)\(attemptsSuffix)\(codeSuffix)"
        }
        return "HTTP \(status)\(attemptsSuffix)\(codeSuffix): \(bodyStr)"
    }
}

// MARK: - HTTPClientError + sentinel mapping

extension HTTPClientError {
    /// Returns the sentinel error for a given HTTP status code, or `nil` if
    /// the status does not have a specific sentinel.
    static func sentinel(for status: Int) -> HTTPClientError? {
        switch status {
        case 401: .unauthorized
        case 403: .forbidden
        case 404: .notFound
        case 409: .conflict
        case 410: .gone
        case 412: .preconditionFailed
        case 413: .payloadTooLarge
        case 415: .unsupportedMediaType
        case 416: .rangeNotSatisfiable
        case 422: .unprocessableEntity
        case 429: .throttled
        case 500...: .serverError(status)
        default: nil
        }
    }
}

// MARK: - HTTPClientError + buffered response cap

extension HTTPClientError {
    /// Maximum size accepted for a response body buffered fully in memory by
    /// `executeDataRequest` — the small buffered API-response path used by
    /// `FabricClient`/`OneLakeClient` for Fabric REST discovery calls and
    /// OneLake DFS metadata PUT/PATCH/DELETE/GET. Never applies to the
    /// large-file download path (`OneLakeClient.doStreamRequest`), which
    /// streams straight to a temp file and never holds the whole body in
    /// memory.
    ///
    /// 10 MiB mirrors `RotatingFileWriter.defaultMaxFileSizeBytes`, the
    /// project's existing precedent for a generous but bounded buffer;
    /// Fabric REST and DFS metadata payloads are JSON, normally well under
    /// this size.
    static let maxBufferedResponseBytes = 10 * 1024 * 1024
}
