import Foundation

// MARK: - OneLakeError

/// Typed errors produced by ``OneLakeClient``.
///
/// Wraps ``HTTPClientError`` for transport/API failures and adds
/// OneLake-specific semantic errors.
///
/// Mirrors `internal/httpretry/errors.go` sentinels as used by the
/// `internal/onelake` package.
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

    /// Retries were exhausted. `attempts` is the total attempt count.
    case retriesExhausted(attempts: Int)

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
    static func from(_ error: any Error) -> OneLakeError {
        switch error {
        case HTTPClientError.unauthorized:        return .unauthorized
        case HTTPClientError.forbidden:           return .forbidden
        case HTTPClientError.notFound:            return .notFound
        case HTTPClientError.conflict:            return .conflict
        case HTTPClientError.preconditionFailed:  return .preconditionFailed
        case let HTTPClientError.retriesExhausted(attempts, _):
            return .retriesExhausted(attempts: attempts)
        default:
            return .httpError(error)
        }
    }
}
