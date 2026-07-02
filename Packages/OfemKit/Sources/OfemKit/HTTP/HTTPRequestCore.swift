import Alamofire
import Foundation

// MARK: - HTTPErrorClassification (http-01)

/// Shared classification of an `HTTPClientError` (or any transport error),
/// used by ``OneLakeError/from(_:)`` and ``FabricError/from(_:)``.
///
/// Both domain error types wrap the same HTTP transport layer and previously
/// duplicated the same three pieces of unwrap logic: reaching the sentinel
/// inside ``HTTPClientError/apiError(_:)``, treating a bare `CancellationError`
/// as cancellation, and unwrapping ``HTTPClientError/retriesExhausted(attempts:last:)``
/// so a retry loop that stopped because token acquisition failed surfaces as
/// an auth failure rather than a generic "retries exhausted" / offline signal.
/// Centralising it here (http-01) means a new status arm, or a fix to the
/// retriesExhausted unwrap, only needs to be made once.
///
/// `resolvedError` carries the error that produced `category`, so a caller
/// whose domain type has no dedicated case for it (e.g. `FabricError` has no
/// `.conflict`) can still box it as its own `httpError` case — exactly as it
/// did before this mapping was shared.
struct HTTPErrorClassification {
    /// The normalized outcome. `.unmapped` means the caller has no dedicated
    /// case for this error and should box `resolvedError` as `httpError`.
    enum Category {
        case unauthorized
        case forbidden
        case notFound
        case conflict
        case gone
        case preconditionFailed
        case payloadTooLarge
        case rangeNotSatisfiable
        case rateLimited
        case serverError(Int)
        case retriesExhausted(attempts: Int)
        case cancelled
        case unmapped
    }

    let category: Category
    let resolvedError: any Error

    /// Classifies `error`, mirroring the unwrap logic previously duplicated
    /// in `OneLakeError.from` and `FabricError.from`.
    static func classify(_ error: any Error) -> HTTPErrorClassification {
        // Unwrap apiError wrapper to reach the sentinel first — without this a
        // retriesExhausted(last: apiError(…)) never matches any typed sentinel
        // case and degrades to .unmapped.
        let resolved: any Error = if let httpErr = error as? HTTPClientError,
                                     case let HTTPClientError.apiError(ae) = httpErr,
                                     let sentinel = ae.sentinel
        {
            sentinel
        } else {
            error
        }

        switch resolved {
        case HTTPClientError.unauthorized:
            return HTTPErrorClassification(category: .unauthorized, resolvedError: resolved)
        case HTTPClientError.forbidden:
            return HTTPErrorClassification(category: .forbidden, resolvedError: resolved)
        case HTTPClientError.notFound:
            return HTTPErrorClassification(category: .notFound, resolvedError: resolved)
        case HTTPClientError.conflict:
            return HTTPErrorClassification(category: .conflict, resolvedError: resolved)
        case HTTPClientError.gone:
            return HTTPErrorClassification(category: .gone, resolvedError: resolved)
        case HTTPClientError.preconditionFailed:
            return HTTPErrorClassification(category: .preconditionFailed, resolvedError: resolved)
        case HTTPClientError.payloadTooLarge:
            return HTTPErrorClassification(category: .payloadTooLarge, resolvedError: resolved)
        case HTTPClientError.rangeNotSatisfiable:
            return HTTPErrorClassification(category: .rangeNotSatisfiable, resolvedError: resolved)
        case HTTPClientError.throttled:
            return HTTPErrorClassification(category: .rateLimited, resolvedError: resolved)
        case HTTPClientError.cancelled:
            return HTTPErrorClassification(category: .cancelled, resolvedError: resolved)
        case is CancellationError:
            return HTTPErrorClassification(category: .cancelled, resolvedError: resolved)
        case HTTPClientError.tokenAcquisitionFailed:
            // A direct tokenAcquisitionFailed always maps to .unauthorized: it
            // means the process could not obtain an access token for this
            // audience, whether the refresh token expired (interactionRequired),
            // Conditional Access fired, or a local MSAL configuration error
            // prevented even the silent call from starting (e.g. FPE bundle-ID
            // mismatch, MSAL -42011).
            //
            // Transient-outage tradeoff (originally fabric-03-fix-272, now
            // shared with OneLakeError): by the time an error reaches this
            // classifier as tokenAcquisitionFailed, OfemAuth has already
            // stripped the underlying MSAL error down to
            // OfemAuthError.silentTokenFailed(_:), which makes transient
            // network failures (Entra DNS timeout, TLS reset during silent
            // refresh) indistinguishable from local config errors. Mapping
            // both to .unauthorized means a transient outage surfaces a
            // "Sign-in required" indicator in Finder instead of a recoverable
            // "cannot synchronise" state — contradicting the project
            // preference for silent retry. This is a known tradeoff:
            // .unauthorized is still strictly better than the previous
            // silent-empty-mount .httpError path. The correct long-term fix is
            // to distinguish interactionRequired from transient failures
            // inside OfemAuth before the error is stripped (tracked as a
            // follow-up).
            //
            // For OneLakeError this arm is a structural-clarity fix rather
            // than a behavioural one (onelake-01-fix-276): the previous
            // default path already reached .notAuthenticated indirectly via
            // FPError.oneLakeCode → FPError.httpCode, which already mapped
            // tokenAcquisitionFailed to .notAuthenticated. Spelling it out
            // here removes that indirection.
            return HTTPErrorClassification(category: .unauthorized, resolvedError: resolved)
        case let HTTPClientError.serverError(code):
            return HTTPErrorClassification(category: .serverError(code), resolvedError: resolved)
        case let HTTPClientError.retriesExhausted(attempts, last):
            // Unwrap the last error so a retry loop that exits because token
            // acquisition failed surfaces as .unauthorized rather than
            // .retriesExhausted — otherwise it hides an auth failure behind an
            // offline indicator (onelake-02-fix-276, fabric-04 broadened by #272).
            if let lastHTTP = last as? HTTPClientError,
               case HTTPClientError.tokenAcquisitionFailed = lastHTTP
            {
                return HTTPErrorClassification(category: .unauthorized, resolvedError: resolved)
            }
            return HTTPErrorClassification(category: .retriesExhausted(attempts: attempts), resolvedError: resolved)
        default:
            return HTTPErrorClassification(category: .unmapped, resolvedError: resolved)
        }
    }
}

// MARK: - executeDataRequest (http-02)

/// Shared request-execution core for ``OneLakeClient`` and ``FabricClient``.
///
/// Both clients build an Alamofire `DataRequest` against a pooled `Session`,
/// validate the response, serialize the body, and map failures through
/// ``HTTPClientError`` into their own domain error type — only the headers,
/// the session scope, and the target error type differ (http-02). This
/// function captures the shared plumbing so a change to it — e.g. the
/// `emptyRequestMethods` allowlist, or the defensive nil-response guard — only
/// needs to be made once.
///
/// - Parameters:
///   - onFailure: Invoked with the raw `AFError` before it is mapped, so a
///     caller can log the pre-classification error (fabric-05). Not invoked
///     on the nil-response guard path, mirroring the pre-extraction behaviour.
///   - mapError: Converts a mapped ``HTTPClientError`` into the caller's
///     domain error — pass ``OneLakeError/from(_:)`` or ``FabricError/from(_:)``.
func executeDataRequest<DomainError: Error>(
    sessionPool: SessionPool,
    alias: String,
    scope: TokenScope,
    method: String,
    url: URL,
    headers: HTTPHeaders,
    body: Data?,
    onFailure: ((AFError) -> Void)? = nil,
    mapError: (any Error) -> DomainError
) async throws -> (Data, HTTPURLResponse) {
    let session = await sessionPool.session(alias: alias, scope: scope)
    let httpMethod = HTTPMethod(rawValue: method)
    let req = session.request(url, method: httpMethod, headers: headers) { urlRequest in
        urlRequest.httpBody = body
    }
    .validate()
    // OneLake/ADLS Gen2 and Fabric REST both return empty bodies on successful
    // mutating calls and on 0-byte reads. Allow empty bodies for all methods
    // used by either client so Alamofire yields Data() rather than an error.
    // .validate() above already rejects non-2xx.
    let dataResponse = await req.serializingData(
        emptyRequestMethods: [.get, .put, .patch, .delete, .post, .head]
    ).response
    switch dataResponse.result {
    case let .success(data):
        guard let httpResponse = dataResponse.response else {
            throw mapError(HTTPClientError.transport(URLError(.badServerResponse)))
        }
        return (data, httpResponse)
    case let .failure(afError):
        onFailure?(afError)
        let mapped = HTTPClientError(
            afError: afError,
            response: dataResponse.response,
            body: dataResponse.data,
            retryCount: req.retryCount
        )
        throw mapError(mapped)
    }
}
