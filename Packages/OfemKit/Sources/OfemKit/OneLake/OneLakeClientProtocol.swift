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

    /// Downloads a file or byte range, returning the body as `Data`.
    ///
    /// Used for small files and metadata payloads. Large files should use
    /// ``read(alias:workspaceGUID:itemGUID:path:range:ifMatch:destination:)``
    /// to avoid whole-file buffering.
    // periphery:ignore
    func read(
        alias: String,
        workspaceGUID: String,
        itemGUID: String,
        path: String,
        range: Range<Int64>?,
        ifMatch: String
    ) async throws -> (Data, PathProperties)

    /// Downloads a file or byte range, writing body bytes into `destination`.
    ///
    /// Streaming overload: avoids holding the full response body in memory.
    func read(
        alias: String,
        workspaceGUID: String,
        itemGUID: String,
        path: String,
        range: Range<Int64>?,
        ifMatch: String,
        destination: FileHandle
    ) async throws -> PathProperties

    /// Uploads content from an in-memory buffer using the DFS create + append
    /// + flush pattern.
    // periphery:ignore
    func write(
        alias: String,
        workspaceGUID: String,
        itemGUID: String,
        path: String,
        content: Data,
        size: Int64
    ) async throws

    /// Uploads content from a local file URL using the DFS create + append +
    /// flush pattern. Reads in bounded chunks to avoid buffering the entire
    /// file in memory (arch-07/net-10).
    func write(
        alias: String,
        workspaceGUID: String,
        itemGUID: String,
        path: String,
        sourceURL: URL,
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
