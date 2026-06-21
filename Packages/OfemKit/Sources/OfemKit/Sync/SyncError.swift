import Foundation

// MARK: - SyncError

/// Typed errors produced by the ``SyncEngine``.
public enum SyncError: Error, Sendable, CustomStringConvertible {
    // MARK: - Cases

    /// The workspace's Fabric capacity is paused; all reads and writes fail.
    case workspacePaused

    /// The download stream was shorter than the declared `Content-Length`.
    case shortDownload(expected: Int64, got: Int64)

    /// The SHA-256 of the assembled download bytes did not match the expected
    /// hash stored in the cache (resume stitching integrity violation).
    case blobSHAMismatch(got: String, expected: String)

    /// A spill file operation (create / seek / read / write) failed.
    case spillFileError(any Error)

    // MARK: - FPError.Code mapping

    /// The ``FPError/Code`` this `SyncError` maps to.
    var fpCode: FPError.Code {
        switch self {
        case .workspacePaused:
            .serverBusy
        case .shortDownload, .blobSHAMismatch, .spillFileError:
            .cannotSynchronize
        }
    }

    // MARK: - CustomStringConvertible

    public var description: String {
        switch self {
        case .workspacePaused:
            "sync: workspace capacity is paused"
        case let .shortDownload(expected, got):
            "sync: short download: expected \(expected) bytes, got \(got)"
        case let .blobSHAMismatch(got, expected):
            "sync: blob SHA mismatch: got \(got), expected \(expected)"
        case let .spillFileError(err):
            "sync: spill file error: \(err)"
        }
    }
}
