import Foundation

// MARK: - OneLakeError

/// Typed errors produced by ``OneLakeClient``.
///
/// Wraps ``HTTPClientError`` for transport/API failures and adds
/// OneLake-specific semantic errors.
public enum OneLakeError: Error, Sendable {
    // MARK: - Validation errors (client-side, no network call made)

    /// A required argument (workspace GUID, item GUID, or path) was empty.
    case missingArgument(String)

    /// The upload body was shorter than the declared `size`.
    case shortRead(offset: Int64)

    /// Pagination exceeded the configured safety limit.
    case paginationExceeded(Int)

    // MARK: - HTTP / transport errors (forwarded from HTTPClient)

    /// HTTP 401 — the access token is invalid or expired.
    case unauthorized

    /// HTTP 403 — the account lacks permission.
    case forbidden

    /// HTTP 404 — the path does not exist.
    case notFound

    /// HTTP 409 — conflicting state (e.g. non-empty directory delete without
    /// `recursive: true`).
    case conflict

    /// HTTP 412 — an ETag `If-Match` precondition failed.
    case preconditionFailed

    /// HTTP 410 — the resource was permanently removed.
    case gone

    /// HTTP 413 — the request payload exceeded the server's limit.
    case payloadTooLarge

    /// HTTP 416 — the `Range` header names a range the server cannot satisfy.
    ///
    /// Returned from ``OneLakeClient/read(alias:workspaceGUID:itemGUID:path:range:ifMatch:destination:)``
    /// when the requested byte range lies beyond the end of the file.
    case rangeNotSatisfiable

    /// HTTP 429 — the server is throttling this client.
    ///
    /// ``HTTPClient`` retries with backoff; this is only surfaced after all
    /// retry attempts are exhausted.
    case rateLimited

    /// Any 5xx response after retries are exhausted.
    case serverError(Int)

    /// Retries were exhausted. `attempts` is the total attempt count.
    case retriesExhausted(attempts: Int)

    /// The task was cancelled by the caller. ``OneLakeClient`` maps
    /// ``HTTPClientError/cancelled`` here.
    case cancelled

    /// An unexpected HTTP or transport error.
    case httpError(any Error)

    // MARK: - Response-decoding errors

    /// The server returned a body that could not be decoded.
    case decodeFailed(any Error)
}

// MARK: - HTTPClientError → OneLakeError mapping

extension OneLakeError {
    /// Converts an ``HTTPClientError`` (or any error from the Net layer) to
    /// an ``OneLakeError``.
    ///
    /// The apiError-unwrap, bare-`CancellationError` mapping,
    /// `tokenAcquisitionFailed` arm, and the `retriesExhausted`-unwrap fix
    /// (onelake-02-fix-276) are shared with ``FabricError/from(_:)`` via
    /// ``HTTPErrorClassification``; see that type's doc comment for the full
    /// rationale, including the transient-outage tradeoff. This switch only
    /// maps the resulting category onto `OneLakeError`'s own case set, which
    /// — unlike `FabricError` — has dedicated `.conflict` / `.preconditionFailed`
    /// cases.
    static func from(_ error: any Error) -> OneLakeError {
        let classified = HTTPErrorClassification.classify(error)
        switch classified.category {
        case .unauthorized: return .unauthorized
        case .forbidden: return .forbidden
        case .notFound: return .notFound
        case .conflict: return .conflict
        case .gone: return .gone
        case .preconditionFailed: return .preconditionFailed
        case .payloadTooLarge: return .payloadTooLarge
        case .rangeNotSatisfiable: return .rangeNotSatisfiable
        case .rateLimited: return .rateLimited
        case let .serverError(code): return .serverError(code)
        case let .retriesExhausted(attempts): return .retriesExhausted(attempts: attempts)
        case .cancelled: return .cancelled
        case .unmapped: return .httpError(classified.resolvedError)
        }
    }
}
