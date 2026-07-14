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

// MARK: - Buffered response size guard

/// Tracks whether `executeDataRequest`'s size guard cancelled a request
/// because it crossed ``HTTPClientError/maxBufferedResponseBytes``, and if
/// so, the byte count observed at the moment it tripped.
///
/// `downloadProgress` fires on Alamofire's own delivery queue while
/// `executeDataRequest`'s single `await` is still suspended, so this needs
/// its own lock rather than relying on Swift concurrency isolation — reading
/// `result` after that `await` resolves is safe because `req.cancel()`
/// (called synchronously from inside the progress closure, see below)
/// always happens-before the completion handler that resolves the `await`.
private final class ResponseSizeGuard: @unchecked Sendable {
    private let lock = NSLock()
    private var tripped: (bytesReceived: Int, limit: Int)?

    /// Records `bytesReceived` as the trip point the first time it exceeds
    /// `limit`, and returns whether *this* call was the one that tripped it
    /// (so the caller cancels exactly once).
    @discardableResult
    func recordIfExceeded(bytesReceived: Int, limit: Int) -> Bool {
        lock.withLock {
            guard tripped == nil, bytesReceived > limit else { return false }
            tripped = (bytesReceived, limit)
            return true
        }
    }

    var result: (bytesReceived: Int, limit: Int)? {
        lock.withLock { tripped }
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
/// Response body size is bounded to ``HTTPClientError/maxBufferedResponseBytes``
/// via two mechanisms, layered because neither alone is both early and
/// reliable:
/// - A `downloadProgress`-driven guard cancels the request as soon as either
///   the declared `Content-Length` or the running received-byte total
///   crosses the cap — a declared-over-cap response is rejected without
///   downloading the rest of it, and a chunked/undeclared-length response is
///   cut off mid-transfer rather than only after it fully lands. This is
///   best-effort, not a guarantee: a transfer that completes before Alamofire
///   schedules the progress callback (plausible for a merely-over-cap, not
///   pathologically large, response on a fast connection) will have already
///   finished buffering by the time it fires.
/// - The post-buffer `data.count` check below is the deterministic backstop
///   for exactly that case: it always catches an over-cap body, just without
///   bounding peak memory for it, since the whole body is already in memory
///   by the time it runs.
///
/// - Parameters:
///   - idempotent: Whether this specific request is safe to replay on a
///     `Retry-After` response, independent of its HTTP method. Defaults to
///     `true` (today's behaviour for every existing caller). Threaded into
///     `RetryAfterRetrier.markIdempotent(_:on:)` so a caller can opt a
///     request out even though `RetryAfterRetrier.idempotentHTTPMethods`
///     would otherwise treat its method as replay-safe.
///   - logger: Used to emit a structured WARN or ERROR for every non-2xx
///     response. Cancelled requests are silently skipped. Transient failures
///     (`.throttled`, `.serverError`, `.transport`, `.retriesExhausted`) are
///     logged at WARN; all others at ERROR.
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
    idempotent: Bool = true,
    logger: OfemLogger = OfemLogger(),
    mapError: (any Error) -> DomainError
) async throws -> (Data, HTTPURLResponse) {
    let session = await sessionPool.session(alias: alias, scope: scope)
    let httpMethod = HTTPMethod(rawValue: method)
    let req = session.request(url, method: httpMethod, headers: headers) { urlRequest in
        urlRequest.httpBody = body
        RetryAfterRetrier.markIdempotent(idempotent, on: &urlRequest)
    }
    .validate()

    let sizeGuard = ResponseSizeGuard()
    _ = req.downloadProgress { progress in
        let declared = Int(progress.totalUnitCount)
        let received = Int(progress.completedUnitCount)
        let observed = max(declared, received)
        if sizeGuard.recordIfExceeded(bytesReceived: observed, limit: HTTPClientError.maxBufferedResponseBytes) {
            _ = req.cancel()
        }
    }

    // OneLake/ADLS Gen2 and Fabric REST both return empty bodies on successful
    // mutating calls and on 0-byte reads. Allow empty bodies for all methods
    // used by either client so Alamofire yields Data() rather than an error.
    // .validate() above already rejects non-2xx.
    let dataResponse = await req.serializingData(
        emptyRequestMethods: [.get, .put, .patch, .delete, .post, .head]
    ).response

    // The size guard may have cancelled the request above; that always takes
    // precedence over however Alamofire's own Result resolved, since a
    // cancellation this function triggered itself can race either branch
    // (.success, if the whole body had already landed when it fired, or
    // .failure(.explicitlyCancelled) otherwise) depending on timing.
    if let capped = sizeGuard.result {
        throw mapError(HTTPClientError.responseTooLarge(bytesReceived: capped.bytesReceived, limit: capped.limit))
    }

    switch dataResponse.result {
    case let .success(data):
        guard let httpResponse = dataResponse.response else {
            throw mapError(HTTPClientError.transport(URLError(.badServerResponse)))
        }
        // Deterministic backstop — see the doc comment above. Checked against
        // the actual buffered byte count rather than the declared
        // Content-Length header: a response can omit or under-report
        // Content-Length (e.g. chunked transfer-encoding), so data.count is
        // the only authoritative measure of what actually landed in memory.
        guard data.count <= HTTPClientError.maxBufferedResponseBytes else {
            throw mapError(
                HTTPClientError.responseTooLarge(
                    bytesReceived: data.count, limit: HTTPClientError.maxBufferedResponseBytes
                )
            )
        }
        return (data, httpResponse)
    case let .failure(afError):
        let mapped = HTTPClientError(
            afError: afError,
            response: dataResponse.response,
            body: dataResponse.data,
            retryCount: req.retryCount
        )
        if case .cancelled = mapped { /* skip logging for cancellations */ } else {
            let resp = dataResponse.response
            var meta: [String: String] = [
                "method": method,
                "path": url.path,
                "retries": "\(req.retryCount)",
            ]
            if let status = resp?.statusCode { meta["status"] = "\(status)" }
            if let code = resp?.value(forHTTPHeaderField: "x-ms-error-code") { meta["msErrorCode"] = code }
            if let rid = resp?.value(forHTTPHeaderField: "x-ms-request-id") { meta["requestId"] = rid }
            if let aid = resp?.value(forHTTPHeaderField: "x-ms-activity-id") { meta["activityId"] = aid }
            switch mapped {
            case .throttled, .serverError, .transport, .retriesExhausted:
                logger.warn("http non-2xx", error: mapped, metadata: meta)
            default:
                logger.error("http non-2xx", error: mapped, metadata: meta)
            }
        }
        throw mapError(mapped)
    }
}
