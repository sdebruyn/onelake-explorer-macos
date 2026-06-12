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

    /// HTTP 429 — the server is throttling this client.
    ///
    /// ``HTTPClient`` retries with backoff; this is only surfaced after all
    /// retry attempts are exhausted.
    case rateLimited

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
    /// Handles wrapped errors by unwrapping one level of `apiError` to match
    /// the inner sentinel where possible.
    static func from(_ error: any Error) -> OneLakeError {
        // Unwrap apiError wrapper to reach the sentinel first.
        let resolved: any Error
        if let httpErr = error as? HTTPClientError,
           case let HTTPClientError.apiError(ae) = httpErr,
           let sentinel = ae.sentinel {
            resolved = sentinel
        } else {
            resolved = error
        }

        switch resolved {
        case HTTPClientError.unauthorized:        return .unauthorized
        case HTTPClientError.forbidden:           return .forbidden
        case HTTPClientError.notFound:            return .notFound
        case HTTPClientError.conflict:            return .conflict
        case HTTPClientError.preconditionFailed:  return .preconditionFailed
        case HTTPClientError.throttled:           return .rateLimited
        case HTTPClientError.cancelled:           return .cancelled
        case is CancellationError:                return .cancelled
        case let HTTPClientError.retriesExhausted(attempts, _):
            return .retriesExhausted(attempts: attempts)
        default:
            return .httpError(resolved)
        }
    }
}
