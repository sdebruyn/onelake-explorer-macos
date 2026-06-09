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
    public enum Code: String, Sendable {
        case noSuchItem        = "noSuchItem"
        case notAuthenticated  = "notAuthenticated"
        case serverBusy        = "serverBusy"
        case serverUnreachable = "serverUnreachable"
        case cannotSynchronize = "cannotSynchronize"
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
        case .invalidIdentifier(let msg): return "fp: invalid identifier: \(msg)"
        case .invalidRecord(let msg):     return "fp: invalid record: \(msg)"
        case .wrongItemKind(let msg):     return "fp: wrong item kind: \(msg)"
        case .noSuchItem(let msg):        return "fp: no such item: \(msg)"
        }
    }
}

// MARK: - Private HTTP → FPError.Code helpers

private func httpCode(for error: HTTPClientError) -> FPError.Code {
    switch error {
    case .unauthorized, .forbidden:
        return .notAuthenticated
    case .notFound, .gone:
        return .noSuchItem
    case .throttled:
        return .serverBusy
    case .transport, .retriesExhausted:
        return .serverUnreachable
    default:
        return .cannotSynchronize
    }
}

private func oneLakeCode(for error: OneLakeError) -> FPError.Code {
    switch error {
    case .unauthorized, .forbidden:
        return .notAuthenticated
    case .notFound:
        return .noSuchItem
    case .retriesExhausted:
        return .serverUnreachable
    default:
        return .cannotSynchronize
    }
}

private func fabricCode(for error: FabricError) -> FPError.Code {
    switch error {
    case .unauthorized, .forbidden:
        return .notAuthenticated
    case .notFound:
        return .noSuchItem
    default:
        return .cannotSynchronize
    }
}
