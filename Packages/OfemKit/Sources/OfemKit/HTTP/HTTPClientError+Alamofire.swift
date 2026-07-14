import Alamofire
import Foundation

// MARK: - Paused-capacity x-ms-error-code values

private let pausedCapacityMsErrorCodes: Set<String> = [
    "capacitypaused",
    "capacitysuspended",
    "capacitynotactive",
    "workspacecapacitypaused",
    "capacityassignmentpaused",
]

// MARK: - HTTPClientError initialiser from Alamofire errors

extension HTTPClientError {
    /// Maps an `AFError` and the associated HTTP response into the typed
    /// `HTTPClientError` vocabulary used by `OneLakeError.from` / `FabricError.from`
    /// / `FPError` / `PauseManager`.
    ///
    /// - Parameters:
    ///   - afError: The Alamofire error produced by the failed request.
    ///   - response: The HTTP response accompanying the error, if any.
    ///   - body: The raw HTTP response body, forwarded into `APIError` so callers
    ///     such as `PauseManager.isPausedCapacityError()` can inspect the payload.
    ///   - retryCount: The number of retry attempts Alamofire made before surfacing
    ///     this error, sourced from `Request.retryCount`; used to populate
    ///     `retriesExhausted(attempts:last:)`.
    init(afError: AFError, response: HTTPURLResponse?, body: Data? = nil, retryCount: Int = 0) {
        // Cancellation — check first so it short-circuits all other classification.
        if afError.isExplicitlyCancelledError {
            self = .cancelled
            return
        }

        // Retry exhaustion (requestRetryFailed wraps the final underlying error).
        if case let .requestRetryFailed(retryError, originalError) = afError {
            // retryError describes *why* retrying stopped; originalError is the
            // last per-attempt failure.  Map the original error recursively so
            // the final `last:` carries a meaningful HTTPClientError.
            let lastHTTP: any Error = if let af = originalError as? AFError {
                HTTPClientError(afError: af, response: response)
            } else {
                HTTPClientError.transport(originalError)
            }
            // retryError.underlyingError is the true stop reason (e.g. exceeded
            // retry limit); attempts = retryCount + 1 (the initial attempt plus
            // all retries that fired).
            _ = retryError
            self = .retriesExhausted(attempts: retryCount + 1, last: lastHTTP)
            return
        }

        // Authentication interceptor failure (refresh threw).
        if case let .requestAdaptationFailed(underlying) = afError {
            self = .tokenAcquisitionFailed(underlying)
            return
        }

        // Validation failure (non-2xx after .validate()): map by HTTP status.
        if case .responseValidationFailed = afError, let resp = response {
            let status = resp.statusCode
            let phrase = HTTPURLResponse.localizedString(forStatusCode: status)
            let statusStr = "\(status) \(phrase)"
            let msErrorCode = resp.value(forHTTPHeaderField: "x-ms-error-code")
            let ae = APIError(
                statusCode: status,
                status: statusStr,
                body: body ?? Data(),
                attempts: retryCount + 1,
                msErrorCode: msErrorCode
            )
            if let sentinel = ae.sentinel {
                // For body-relevant sentinels (401/403/429/5xx) carry the APIError
                // alongside the sentinel so downstream callers such as PauseManager
                // can inspect the response body. Non-body-relevant sentinels keep the
                // bare typed case so their consumers (e.g. SyncEngine.notFound) are
                // unaffected and the body is not needlessly retained.
                //
                // 404 is conditionally body-relevant: only when x-ms-error-code
                // signals a paused capacity. An unconditional 404 body would map it
                // to apiError(…) instead of .notFound, breaking the catch in
                // SyncEngine+Mutations that treats delete-404 as idempotent success.
                //
                // Match on the sentinel case (not raw status codes) so the
                // body-relevant set stays in sync with sentinel(for:) — a drift
                // would silently strip a body PauseManager needs.
                let bodyRelevant = switch sentinel {
                case .unauthorized, .forbidden, .throttled, .serverError:
                    true
                case .notFound where msErrorCode.map { pausedCapacityMsErrorCodes.contains($0.lowercased()) } == true:
                    true
                default:
                    false
                }
                self = bodyRelevant ? .sentinelWithBody(sentinel, ae) : sentinel
            } else {
                self = .apiError(ae)
            }
            return
        }

        // Underlying URLError (transport failures, cancellation via URLSession).
        if let urlError = afError.underlyingError as? URLError {
            if urlError.code == .cancelled {
                self = .cancelled
                return
            }
            self = .transport(urlError)
            return
        }

        // Session task failure (wraps a URLError or other transport error).
        if case let .sessionTaskFailed(underlying) = afError {
            if let urlError = underlying as? URLError {
                if urlError.code == .cancelled {
                    self = .cancelled
                    return
                }
                self = .transport(urlError)
            } else {
                self = .transport(underlying)
            }
            return
        }

        // Fallback: treat as a generic transport error carrying the AFError.
        self = .transport(afError)
    }
}
