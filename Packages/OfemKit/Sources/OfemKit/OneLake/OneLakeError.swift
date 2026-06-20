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
    /// - First unwraps one level of ``HTTPClientError/apiError(_:)`` to reach
    ///   the inner sentinel, mirroring `FabricError.from`.
    /// - Maps bare ``CancellationError`` (Swift Concurrency cancellation) to
    ///   `.cancelled`.
    /// - Maps ``HTTPClientError/tokenAcquisitionFailed(_:)`` to `.unauthorized`
    ///   (onelake-01-fix-276): ANY token-acquisition failure means the process
    ///   cannot authenticate for the OneLake/storage audience and must surface as
    ///   an auth error, not as a generic sync failure. Mirrors the
    ///   `fabric-03-fix-272` arm in `FabricError.from`; see that comment for the
    ///   transient-outage tradeoff.
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
        case HTTPClientError.gone:                return .gone
        case HTTPClientError.preconditionFailed:  return .preconditionFailed
        case HTTPClientError.payloadTooLarge:     return .payloadTooLarge
        case HTTPClientError.rangeNotSatisfiable: return .rangeNotSatisfiable
        case HTTPClientError.throttled:           return .rateLimited
        case HTTPClientError.cancelled:           return .cancelled
        case is CancellationError:                return .cancelled
        case HTTPClientError.tokenAcquisitionFailed:
            // onelake-01-fix-276: map ALL token-acquisition failures to
            // .unauthorized. Any failure here means the process could not
            // obtain a storage access token — whether because the refresh token
            // has expired (.interactionRequired), Conditional Access fired, or
            // a local MSAL configuration error prevented even the silent call
            // from starting (e.g. FPE bundle-ID mismatch, MSAL -42011).
            // In every case the correct surface is .unauthorized →
            // FPError.notAuthenticated so Finder shows an auth-required
            // indicator rather than a silent empty folder.
            return .unauthorized
        case let HTTPClientError.serverError(code):
            return .serverError(code)
        case let HTTPClientError.retriesExhausted(attempts, last):
            // onelake-02-fix-276: unwrap the last error so that a retry loop
            // that exits because token acquisition failed surfaces as
            // .unauthorized rather than .retriesExhausted. Without this unwrap
            // FPError.oneLakeCode maps .retriesExhausted to .serverUnreachable,
            // hiding the auth failure behind an offline indicator.
            if let lastHTTP = last as? HTTPClientError,
               case HTTPClientError.tokenAcquisitionFailed = lastHTTP {
                return .unauthorized
            }
            return .retriesExhausted(attempts: attempts)
        default:
            return .httpError(resolved)
        }
    }
}
