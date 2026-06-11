import Foundation

// MARK: - OneLakeClientProtocol

/// The subset of ``OneLakeClient`` that ``SyncEngine`` and ``PauseManager`` use.
///
/// Defining a protocol makes both types testable without a live HTTP stack:
/// inject a mock conformance in tests and the concrete ``OneLakeClient`` in
/// production.
public protocol OneLakeClientProtocol: Sendable {
    /// Enumerates a directory inside a OneLake item.
    func listPath(
        alias: String,
        workspaceGUID: String,
        itemGUID: String,
        directory: String,
        recursive: Bool
    ) async throws -> ListResult

    /// Returns metadata for a single path (HEAD request).
    func getProperties(
        alias: String,
        workspaceGUID: String,
        itemGUID: String,
        path: String
    ) async throws -> PathProperties

    /// Downloads a file or byte range.
    func read(
        alias: String,
        workspaceGUID: String,
        itemGUID: String,
        path: String,
        range: Range<Int64>?,
        ifMatch: String
    ) async throws -> (Data, PathProperties)

    /// Uploads content using the DFS create + append + flush pattern.
    func write(
        alias: String,
        workspaceGUID: String,
        itemGUID: String,
        path: String,
        content: Data,
        size: Int64
    ) async throws

    /// Creates a directory.
    func createDirectory(
        alias: String,
        workspaceGUID: String,
        itemGUID: String,
        path: String
    ) async throws

    /// Removes a file or directory.
    func delete(
        alias: String,
        workspaceGUID: String,
        itemGUID: String,
        path: String,
        recursive: Bool
    ) async throws
}

// MARK: - OneLakeClient conformance

extension OneLakeClient: OneLakeClientProtocol {}
