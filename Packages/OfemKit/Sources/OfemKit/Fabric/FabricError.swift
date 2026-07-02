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

    /// HTTP 410 — the resource was permanently removed.
    case gone

    /// HTTP 413 — the request payload exceeded the server's limit.
    case payloadTooLarge

    /// HTTP 416 — the `Range` header names a range the server cannot satisfy.
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
    /// The apiError-unwrap, bare-`CancellationError` mapping,
    /// `tokenAcquisitionFailed` arm (fabric-03-fix-272), and the
    /// `retriesExhausted`-unwrap fix (fabric-04, broadened by #272) are shared
    /// with ``OneLakeError/from(_:)`` via ``HTTPErrorClassification``; see that
    /// type's doc comment for the full rationale, including the
    /// transient-outage tradeoff of mapping every `tokenAcquisitionFailed` to
    /// `.unauthorized`.
    ///
    /// Unlike `OneLakeError`, `FabricError` has no dedicated `.conflict` /
    /// `.preconditionFailed` case — `.gone` / `.payloadTooLarge` /
    /// `.rangeNotSatisfiable` were added for symmetry with `OneLakeError`
    /// (NIT-2), but conflict and precondition-failed were not. Those two
    /// categories, and anything else `HTTPErrorClassification` does not
    /// recognise, box the resolved error as `.httpError`, exactly as they did
    /// before this mapping was shared.
    static func from(_ error: any Error) -> FabricError {
        let classified = HTTPErrorClassification.classify(error)
        switch classified.category {
        case .unauthorized: return .unauthorized
        case .forbidden: return .forbidden
        case .notFound: return .notFound
        case .gone: return .gone
        case .payloadTooLarge: return .payloadTooLarge
        case .rangeNotSatisfiable: return .rangeNotSatisfiable
        case .rateLimited: return .rateLimited
        case let .serverError(code): return .serverError(code)
        case let .retriesExhausted(attempts): return .retriesExhausted(attempts: attempts)
        case .cancelled: return .cancelled
        case .conflict, .preconditionFailed, .unmapped:
            return .httpError(classified.resolvedError)
        }
    }
}
