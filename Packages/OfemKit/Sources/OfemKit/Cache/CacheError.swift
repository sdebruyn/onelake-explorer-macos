import Foundation

// MARK: - CacheError

/// Errors surfaced by the ``CacheStore``.
public enum CacheError: Error, Sendable {
    /// The requested metadata row or blob does not exist in the cache.
    case notFound(String)

    /// A SHA-256 digest is malformed (must be 64 lowercase hex characters).
    case invalidSHA(String)

    /// A required argument was empty.
    case missingArgument(String)

    /// A filesystem error during blob I/O.
    case blobIOError(any Error)
}

extension CacheError: Equatable {
    public static func == (lhs: CacheError, rhs: CacheError) -> Bool {
        switch (lhs, rhs) {
        case (.notFound(let a), .notFound(let b)): return a == b
        case (.invalidSHA(let a), .invalidSHA(let b)): return a == b
        case (.missingArgument(let a), .missingArgument(let b)): return a == b
        case (.blobIOError, .blobIOError): return true  // compare case only; wrapped errors are not Equatable
        default: return false
        }
    }
}

extension CacheError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .notFound(let desc):
            return "Cache entry not found: \(desc)"
        case .invalidSHA(let sha):
            return "Invalid SHA-256 digest: '\(sha)'"
        case .missingArgument(let name):
            return "Missing required argument: \(name)"
        case .blobIOError(let err):
            return "Blob I/O error: \(err.localizedDescription)"
        }
    }
}
