import Foundation

// MARK: - SyncError

/// Typed errors produced by the ``SyncEngine``.
public enum SyncError: Error, Sendable, CustomStringConvertible {

    // MARK: - Cases

    /// The workspace's Fabric capacity is paused; all reads and writes fail.
    case workspacePaused

    /// A required dependency was nil or not provided to `SyncEngine.init`.
    case missingDependency(String)

    /// A file upload was skipped because it is a macOS metadata artefact
    /// (`.DS_Store`, `._*`, etc.).
    case macOSMetadataSkipped(String)

    /// The download stream was shorter than the declared `Content-Length`.
    case shortDownload(expected: Int64, got: Int64)

    /// The SHA-256 of the assembled download bytes did not match the expected
    /// hash stored in the cache (resume stitching integrity violation).
    case blobSHAMismatch(got: String, expected: String)

    /// A scratch directory could not be created or used.
    case scratchDirectoryError(any Error)

    /// A spill file operation (create / seek / read / write) failed.
    case spillFileError(any Error)

    // MARK: - FPError.Code mapping

    /// The ``FPError/Code`` this `SyncError` maps to.
    var fpCode: FPError.Code {
        switch self {
        case .workspacePaused:
            return .serverBusy
        case .missingDependency:
            return .cannotSynchronize
        case .macOSMetadataSkipped:
            return .noSuchItem
        case .shortDownload, .blobSHAMismatch:
            return .cannotSynchronize
        case .scratchDirectoryError, .spillFileError:
            return .cannotSynchronize
        }
    }

    // MARK: - CustomStringConvertible

    public var description: String {
        switch self {
        case .workspacePaused:
            return "sync: workspace capacity is paused"
        case .missingDependency(let dep):
            return "sync: missing dependency: \(dep)"
        case .macOSMetadataSkipped(let path):
            return "sync: skipped macOS metadata: \(path)"
        case .shortDownload(let expected, let got):
            return "sync: short download: expected \(expected) bytes, got \(got)"
        case .blobSHAMismatch(let got, let expected):
            return "sync: blob SHA mismatch: got \(got), expected \(expected)"
        case .scratchDirectoryError(let err):
            return "sync: scratch directory error: \(err)"
        case .spillFileError(let err):
            return "sync: spill file error: \(err)"
        }
    }
}
