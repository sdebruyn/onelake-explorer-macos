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
    /// - Adds an explicit ``HTTPClientError/tokenAcquisitionFailed(_:)`` arm
    ///   (onelake-01-fix-276): a direct `tokenAcquisitionFailed` previously fell
    ///   through to `default` → `.httpError(resolved)`, which `FPError.oneLakeCode`
    ///   then delegated to `FPError.httpCode` — which already mapped
    ///   `tokenAcquisitionFailed` to `.notAuthenticated`. So the direct path was
    ///   not a silent sync-failure regression; the explicit arm is a structural
    ///   clarity improvement that makes the intent unambiguous and prevents any
    ///   future `oneLakeCode` refactor from accidentally breaking the path.
    ///   The real behavioral fix is onelake-02 (the `retriesExhausted` unwrap).
    ///   Mirrors the `fabric-03-fix-272` arm in `FabricError.from`; see that
    ///   comment for the transient-outage tradeoff.
    static func from(_ error: any Error) -> OneLakeError {
        // Unwrap apiError wrapper to reach the sentinel first.
        let resolved: any Error = if let httpErr = error as? HTTPClientError,
                                     case let HTTPClientError.apiError(ae) = httpErr,
                                     let sentinel = ae.sentinel
        {
            sentinel
        } else {
            error
        }

        switch resolved {
        case HTTPClientError.unauthorized: return .unauthorized
        case HTTPClientError.forbidden: return .forbidden
        case HTTPClientError.notFound: return .notFound
        case HTTPClientError.conflict: return .conflict
        case HTTPClientError.gone: return .gone
        case HTTPClientError.preconditionFailed: return .preconditionFailed
        case HTTPClientError.payloadTooLarge: return .payloadTooLarge
        case HTTPClientError.rangeNotSatisfiable: return .rangeNotSatisfiable
        case HTTPClientError.throttled: return .rateLimited
        case HTTPClientError.cancelled: return .cancelled
        case is CancellationError: return .cancelled
        case HTTPClientError.tokenAcquisitionFailed:
            // onelake-01-fix-276: explicit arm for clarity. The old default path
            // already reached FPError.notAuthenticated via
            //   .httpError(resolved) → oneLakeCode → httpCode → .notAuthenticated
            // but spelling it out removes the dependency on that indirection and
            // prevents future refactors from silently regressing it.
            return .unauthorized
        case let HTTPClientError.sentinelWithBody(sentinel, ae):
            // Body-carrying sentinel: route through .httpError so the APIError body
            // remains reachable by PauseManager.extractAPIErrorBody. The typed
            // sentinel inside is exposed via FPError.httpCode(for: .sentinelWithBody)
            // for code paths that do not need the body.
            return .httpError(HTTPClientError.sentinelWithBody(sentinel, ae))
        case let HTTPClientError.serverError(code):
            return .serverError(code)
        case let HTTPClientError.retriesExhausted(attempts, last):
            // onelake-02-fix-276: unwrap the last error so that a retry loop
            // that exits because token acquisition failed surfaces as
            // .unauthorized rather than .retriesExhausted. Without this unwrap
            // FPError.oneLakeCode maps .retriesExhausted to .serverUnreachable,
            // hiding the auth failure behind an offline indicator.
            if case HTTPClientError.tokenAcquisitionFailed = last {
                return .unauthorized
            }
            return .retriesExhausted(attempts: attempts)
        default:
            return .httpError(resolved)
        }
    }
}
