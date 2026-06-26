import Foundation

// MARK: - FPError

/// Errors produced by the FP domain model layer.
///
/// The FPE maps these to `NSFileProviderError` values.
public enum FPError: Error, Sendable, CustomStringConvertible {
    // MARK: - Domain errors

    /// The identifier string is malformed.
    case invalidIdentifier(String)

    /// A cache or discovery record is missing required fields.
    case invalidRecord(String)

    /// The operation requires a file identifier, but a container was provided
    /// (or vice versa). Maps to `noSuchItem`.
    case wrongItemKind(String)

    /// The item does not exist. Maps to `noSuchItem`.
    case noSuchItem(String)

    // MARK: - Error code

    /// The stable error code the FPE switches on.
    ///
    /// Raw values are synthesized automatically by Swift (case name == raw
    /// value for `String` enums), so they are not spelled out explicitly
    /// (fp-08).
    public enum Code: String, Sendable {
        case noSuchItem
        case notAuthenticated
        case serverBusy
        case serverUnreachable
        case cannotSynchronize
    }

    // MARK: - Classification

    /// Maps any error to the stable ``Code`` the FPE switches on.
    ///
    /// Classification is based exclusively on typed errors — no substring
    /// matching on error messages.
    public static func classify(_ error: any Error) -> Code {
        // Check domain errors first.
        if let fpError = error as? FPError {
            switch fpError {
            case .noSuchItem, .wrongItemKind, .invalidIdentifier:
                return .noSuchItem
            case .invalidRecord:
                return .cannotSynchronize
            }
        }

        // SyncError classification.
        if let syncError = error as? SyncError {
            return syncError.fpCode
        }

        // HTTP / transport errors.
        if let httpError = error as? HTTPClientError {
            return httpCode(for: httpError)
        }
        if let olError = error as? OneLakeError {
            return oneLakeCode(for: olError)
        }
        if let fabError = error as? FabricError {
            return fabricCode(for: fabError)
        }

        // Offline: URLError is a transport error.
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .networkConnectionLost,
                 .cannotConnectToHost, .cannotFindHost,
                 .dnsLookupFailed, .timedOut:
                return .serverUnreachable
            default:
                break
            }
        }

        return .cannotSynchronize
    }

    // MARK: - CustomStringConvertible

    public var description: String {
        switch self {
        case let .invalidIdentifier(msg): "fp: invalid identifier: \(msg)"
        case let .invalidRecord(msg): "fp: invalid record: \(msg)"
        case let .wrongItemKind(msg): "fp: wrong item kind: \(msg)"
        case let .noSuchItem(msg): "fp: no such item: \(msg)"
        }
    }
}

// MARK: - Private HTTP → FPError.Code helpers

//
// fp-07: exhaustive switches so adding a new error case forces a deliberate
// classification decision rather than silently falling into `cannotSynchronize`.

private func httpCode(for error: HTTPClientError) -> FPError.Code {
    switch error {
    case .unauthorized, .tokenAcquisitionFailed:
        .notAuthenticated
    case .forbidden:
        // HTTP 403 means authenticated-but-not-authorised — the token is valid.
        // Must NOT map to .notAuthenticated (which triggers markNeedsSignIn).
        // A paused-capacity 403 arrives as .sentinelWithBody and is intercepted
        // by PauseManager upstream before FPError.classify is called; only a
        // genuine permission denial or an unrecognised body reaches this arm.
        .cannotSynchronize
    case .notFound, .gone:
        .noSuchItem
    case .throttled:
        .serverBusy
    case .transport, .retriesExhausted, .cancelled:
        .serverUnreachable
    case let .sentinelWithBody(s, _):
        // Delegate to the typed sentinel. The body was already offered to
        // PauseManager upstream; strip it here to reach the correct code.
        httpCode(for: s)
    case .conflict, .preconditionFailed, .payloadTooLarge, .unsupportedMediaType,
         .rangeNotSatisfiable, .unprocessableEntity, .serverError, .apiError,
         .responseTooLarge:
        .cannotSynchronize
    }
}

private func oneLakeCode(for error: OneLakeError) -> FPError.Code {
    switch error {
    case .unauthorized:
        return .notAuthenticated
    case .forbidden:
        // HTTP 403: authenticated-but-not-authorised. A paused-capacity 403
        // arrives as .httpError(.sentinelWithBody) and is intercepted by
        // PauseManager before reaching here. A direct .forbidden (bare sentinel
        // from a non-Alamofire path) must also not trigger markNeedsSignIn.
        return .cannotSynchronize
    case .notFound, .gone:
        return .noSuchItem
    case .retriesExhausted, .cancelled:
        return .serverUnreachable
    case .rateLimited:
        return .serverBusy
    case let .httpError(inner):
        // Unwrap the wrapped HTTPClientError so that throttling (429) is
        // correctly classified as serverBusy (sync-12).
        if let httpErr = inner as? HTTPClientError {
            return httpCode(for: httpErr)
        }
        return .cannotSynchronize
    case .missingArgument, .shortRead, .paginationExceeded, .conflict,
         .preconditionFailed, .payloadTooLarge, .rangeNotSatisfiable,
         .serverError, .decodeFailed:
        return .cannotSynchronize
    }
}

private func fabricCode(for error: FabricError) -> FPError.Code {
    switch error {
    case .unauthorized:
        return .notAuthenticated
    case .forbidden:
        // HTTP 403: authenticated-but-not-authorised. Same reasoning as
        // oneLakeCode: must not trigger markNeedsSignIn.
        return .cannotSynchronize
    case .notFound, .gone:
        return .noSuchItem
    case .rateLimited:
        return .serverBusy
    case .retriesExhausted, .cancelled:
        return .serverUnreachable
    case let .httpError(inner):
        // Unwrap the wrapped HTTPClientError so that auth failures (401) and
        // throttling (429) carried as .sentinelWithBody classify correctly —
        // mirroring oneLakeCode (sync-12 equivalent for the Fabric path).
        if let httpErr = inner as? HTTPClientError {
            return httpCode(for: httpErr)
        }
        return .cannotSynchronize
    case .missingArgument, .paginationExceeded, .payloadTooLarge,
         .rangeNotSatisfiable, .serverError, .decodeFailed,
         .loopingPagination, .continuationURIHostMismatch:
        return .cannotSynchronize
    }
}
