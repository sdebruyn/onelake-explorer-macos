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
        case let (.notFound(a), .notFound(b)): return a == b
        case let (.invalidSHA(a), .invalidSHA(b)): return a == b
        case let (.missingArgument(a), .missingArgument(b)): return a == b
        case let (.blobIOError(a), .blobIOError(b)):
            // Compare by NSError domain + code so distinct underlying failures are
            // distinguishable in tests (e.g. "disk full" vs "permission denied").
            let na = a as NSError, nb = b as NSError
            return na.domain == nb.domain && na.code == nb.code
        default: return false
        }
    }
}

extension CacheError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .notFound(desc):
            "Cache entry not found: \(desc)"
        case let .invalidSHA(sha):
            "Invalid SHA-256 digest: '\(sha)'"
        case let .missingArgument(name):
            "Missing required argument: \(name)"
        case let .blobIOError(err):
            "Blob I/O error: \(err.localizedDescription)"
        }
    }
}
