import Foundation

// MARK: - FabricError

/// Typed errors produced by ``FabricClient``.
///
/// Wraps ``HTTPClientError`` for transport/API failures and adds
/// Fabric-specific semantic errors, including `.cancelled` for Swift
/// Concurrency task cancellation.
public enum FabricError: Error, Sendable {
    // MARK: - Validation errors (client-side, no network call made)

    /// A required argument (workspace ID, item ID) was empty.
    case missingArgument(String)

    /// Pagination exceeded the configured safety limit.
    case paginationExceeded(Int)

    // MARK: - HTTP / transport errors (forwarded from HTTPClient)

    /// HTTP 401 — the access token is invalid or expired.
    case unauthorized

    /// HTTP 403 — the account lacks permission.
    case forbidden

    /// HTTP 404 — the resource does not exist.
    case notFound

    /// HTTP 429 — the server is throttling this client.
    ///
    /// ``HTTPClient`` retries with backoff; this is only surfaced after all
    /// retry attempts are exhausted.
    case rateLimited

    /// Any 5xx response after retries are exhausted.
    case serverError(Int)

    /// Retries were exhausted. `attempts` is the total attempt count.
    case retriesExhausted(attempts: Int)

    /// The task was cancelled by the caller. ``FabricClient`` maps
    /// ``HTTPClientError/cancelled`` here.
    case cancelled

    /// An unexpected HTTP or transport error.
    case httpError(any Error)

    // MARK: - Response-decoding errors

    /// The server returned a body that could not be decoded.
    case decodeFailed(any Error)

    // MARK: - Pagination safety errors

    /// The server returned an identical continuation token or URI twice in
    /// a row — indicates a misbehaving or looping API.
    case loopingPagination(String)

    /// The continuation URI points to a host different from the configured
    /// Fabric base URL — rejected to prevent open-redirect attacks.
    case continuationURIHostMismatch(String)
}

// MARK: - HTTPClientError → FabricError mapping

extension FabricError {
    /// Converts an ``HTTPClientError`` (or any error from the Net layer) to
    /// a ``FabricError``.
    ///
    /// - First unwraps one level of ``HTTPClientError/apiError(_:)`` to reach
    ///   the inner sentinel, mirroring `OneLakeError.from` (fabric-01).
    /// - Maps bare ``CancellationError`` (Swift Concurrency cancellation) to
    ///   `.cancelled` (fabric-02).
    static func from(_ error: any Error) -> FabricError {
        // fabric-01: unwrap apiError wrapper to reach the sentinel first,
        // mirroring OneLakeError.from — without this, a retriesExhausted(last:
        // apiError(…)) never matches any typed sentinel case and degrades to
        // httpError.
        let resolved: any Error
        if let httpErr = error as? HTTPClientError,
           case let HTTPClientError.apiError(ae) = httpErr,
           let sentinel = ae.sentinel {
            resolved = sentinel
        } else {
            resolved = error
        }

        switch resolved {
        case HTTPClientError.unauthorized:
            return .unauthorized
        case HTTPClientError.forbidden:
            return .forbidden
        case HTTPClientError.notFound:
            return .notFound
        case HTTPClientError.throttled:
            return .rateLimited
        case HTTPClientError.cancelled:
            return .cancelled
        case is CancellationError:           // fabric-02: bare Swift cancellation
            return .cancelled
        case let HTTPClientError.serverError(code):
            return .serverError(code)
        case let HTTPClientError.retriesExhausted(attempts, _):
            return .retriesExhausted(attempts: attempts)
        default:
            return .httpError(resolved)
        }
    }
}
