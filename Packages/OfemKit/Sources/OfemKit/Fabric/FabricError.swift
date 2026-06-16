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
    /// - First unwraps one level of ``HTTPClientError/apiError(_:)`` to reach
    ///   the inner sentinel, mirroring `OneLakeError.from` (fabric-01).
    /// - Maps bare ``CancellationError`` (Swift Concurrency cancellation) to
    ///   `.cancelled` (fabric-02).
    /// - Maps ``HTTPClientError/tokenAcquisitionFailed(_:)`` to `.unauthorized`
    ///   (fabric-03-fix-272): ANY token-acquisition failure means the process
    ///   cannot authenticate for the Fabric audience and must surface as an auth
    ///   error, not as a generic sync failure. This covers both MSAL
    ///   interaction-required responses and local MSAL configuration errors
    ///   (e.g. FPE bundle-ID mismatch, -42011) that would otherwise produce a
    ///   silent empty Finder mount with no auth prompt.
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
        case HTTPClientError.gone:           // NIT-2: symmetry with OneLakeError
            return .gone
        case HTTPClientError.payloadTooLarge:
            return .payloadTooLarge
        case HTTPClientError.rangeNotSatisfiable:
            return .rangeNotSatisfiable
        case HTTPClientError.throttled:
            return .rateLimited
        case HTTPClientError.cancelled:
            return .cancelled
        case is CancellationError:           // fabric-02: bare Swift cancellation
            return .cancelled
        case HTTPClientError.tokenAcquisitionFailed:
            // fabric-03-fix-272: map ALL token-acquisition failures to
            // .unauthorized. Any failure here means the process could not
            // obtain a Fabric access token — whether because the refresh token
            // has expired (.interactionRequired), Conditional Access fired, or
            // a local MSAL configuration error prevented even the silent call
            // from starting (e.g. FPE bundle-ID mismatch, MSAL -42011).
            // In every case the correct surface is .unauthorized →
            // FPError.notAuthenticated so Finder shows an auth-required
            // indicator rather than a silent empty folder.
            return .unauthorized
        case let HTTPClientError.retriesExhausted(attempts, last):
            // fabric-04: unwrap the last error so that a retry loop that exits
            // because token acquisition failed surfaces as .unauthorized rather
            // than .retriesExhausted. Without this unwrap FPError.fabricCode
            // maps .retriesExhausted to .serverUnreachable, hiding the auth
            // failure behind an offline indicator.
            if let lastHTTP = last as? HTTPClientError,
               case HTTPClientError.tokenAcquisitionFailed = lastHTTP {
                return .unauthorized
            }
            return .retriesExhausted(attempts: attempts)
        case let HTTPClientError.serverError(code):
            return .serverError(code)
        default:
            return .httpError(resolved)
        }
    }
}
