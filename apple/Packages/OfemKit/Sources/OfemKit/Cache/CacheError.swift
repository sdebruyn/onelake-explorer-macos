import Foundation

// MARK: - CacheError

/// Errors surfaced by the ``CacheStore``.
///
/// Mirrors the error patterns in `internal/cache/` — the Go implementation
/// wraps `os.ErrNotExist` for missing rows; Swift surfaces a typed enum
/// instead.
public enum CacheError: Error, Sendable {
    /// The requested metadata row or blob does not exist in the cache.
    case notFound(String)

    /// The on-disk schema version is newer than the version this binary
    /// supports. The database was written by a newer OFEM release.
    case schemaTooNew(onDisk: Int, supported: Int)

    /// A SHA-256 digest is malformed (must be 64 lowercase hex characters).
    case invalidSHA(String)

    /// A required argument was empty.
    case missingArgument(String)

    /// An underlying GRDB / SQLite error.
    case databaseError(any Error)

    /// A filesystem error during blob I/O.
    case blobIOError(any Error)
}

extension CacheError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .notFound(let desc):
            return "Cache entry not found: \(desc)"
        case .schemaTooNew(let onDisk, let supported):
            return "On-disk schema v\(onDisk) is newer than supported v\(supported)"
        case .invalidSHA(let sha):
            return "Invalid SHA-256 digest: '\(sha)'"
        case .missingArgument(let name):
            return "Missing required argument: \(name)"
        case .databaseError(let err):
            return "Database error: \(err.localizedDescription)"
        case .blobIOError(let err):
            return "Blob I/O error: \(err.localizedDescription)"
        }
    }
}
