import Foundation
@testable import OfemKit

// MARK: - MockOneLakeClient

/// Scriptable mock for ``OneLakeClientProtocol``.
///
/// Each call dequeues from the corresponding `*Results` array. Throws
/// `MockError.stubsExhausted` when the array is empty.
final class MockOneLakeClient: OneLakeClientProtocol, @unchecked Sendable {

    // MARK: - Scripted responses

    var listPathResults: [Result<ListResult, any Error>] = []
    var getPropertiesResults: [Result<PathProperties, any Error>] = []
    var readResults: [Result<(Data, PathProperties), any Error>] = []
    var writeResults: [Result<Void, any Error>] = []
    var createDirectoryResults: [Result<Void, any Error>] = []
    var deleteResults: [Result<Void, any Error>] = []

    // MARK: - Recorded calls (for assertions)

    private(set) var listPathCalls: [ListPathCall] = []
    private(set) var readCalls: [ReadCall] = []
    private(set) var writeCalls: [WriteCall] = []
    private(set) var deleteCalls: [DeleteCall] = []

    struct ListPathCall {
        let alias: String
        let workspaceGUID: String
        let itemGUID: String
        let directory: String
        let recursive: Bool
    }

    struct ReadCall {
        let alias: String
        let workspaceGUID: String
        let itemGUID: String
        let path: String
        let range: Range<Int64>?
        let ifMatch: String
    }

    struct WriteCall {
        let alias: String
        let path: String
        let content: Data?
        let sourceURL: URL?
        let size: Int64
    }

    struct DeleteCall {
        let alias: String
        let path: String
        let recursive: Bool
    }

    private let lock = NSLock()

    // MARK: - OneLakeClientProtocol

    func listPath(
        alias: String, workspaceGUID: String, itemGUID: String,
        directory: String, recursive: Bool
    ) async throws -> ListResult {
        lock.withLock { listPathCalls.append(ListPathCall(alias: alias, workspaceGUID: workspaceGUID, itemGUID: itemGUID, directory: directory, recursive: recursive)) }
        return try dequeue(&listPathResults, name: "listPath")
    }

    func getProperties(
        alias: String, workspaceGUID: String, itemGUID: String, path: String
    ) async throws -> PathProperties {
        return try dequeue(&getPropertiesResults, name: "getProperties")
    }

    func read(
        alias: String, workspaceGUID: String, itemGUID: String,
        path: String, range: Range<Int64>?, ifMatch: String
    ) async throws -> (Data, PathProperties) {
        lock.withLock { readCalls.append(ReadCall(alias: alias, workspaceGUID: workspaceGUID, itemGUID: itemGUID, path: path, range: range, ifMatch: ifMatch)) }
        return try dequeue(&readResults, name: "read")
    }

    func read(
        alias: String, workspaceGUID: String, itemGUID: String,
        path: String, range: Range<Int64>?, ifMatch: String,
        destination: FileHandle
    ) async throws -> PathProperties {
        lock.withLock { readCalls.append(ReadCall(alias: alias, workspaceGUID: workspaceGUID, itemGUID: itemGUID, path: path, range: range, ifMatch: ifMatch)) }
        let (data, props) = try dequeue(&readResults, name: "read")
        try destination.write(contentsOf: data)
        return props
    }

    func write(
        alias: String, workspaceGUID: String, itemGUID: String,
        path: String, content: Data, size: Int64
    ) async throws {
        lock.withLock { writeCalls.append(WriteCall(alias: alias, path: path, content: content, sourceURL: nil, size: size)) }
        try dequeueVoid(&writeResults, name: "write")
    }

    func write(
        alias: String, workspaceGUID: String, itemGUID: String,
        path: String, sourceURL: URL, size: Int64
    ) async throws {
        lock.withLock { writeCalls.append(WriteCall(alias: alias, path: path, content: nil, sourceURL: sourceURL, size: size)) }
        try dequeueVoid(&writeResults, name: "write")
    }

    func createDirectory(
        alias: String, workspaceGUID: String, itemGUID: String, path: String
    ) async throws {
        try dequeueVoid(&createDirectoryResults, name: "createDirectory")
    }

    func delete(
        alias: String, workspaceGUID: String, itemGUID: String,
        path: String, recursive: Bool
    ) async throws {
        lock.withLock { deleteCalls.append(DeleteCall(alias: alias, path: path, recursive: recursive)) }
        try dequeueVoid(&deleteResults, name: "delete")
    }

    // MARK: - Private helper

    // Dequeue under lock to avoid races in concurrent tests (e.g. testConcurrentOpensCoalesce).
    func dequeue<T>(_ arr: inout [Result<T, any Error>], name: String) throws -> T {
        let result: Result<T, any Error> = lock.withLock {
            guard !arr.isEmpty else {
                return .failure(MockError.stubsExhausted(name))
            }
            return arr.removeFirst()
        }
        return try result.get()
    }

    private func dequeueVoid(_ arr: inout [Result<Void, any Error>], name: String) throws {
        let result: Result<Void, any Error> = lock.withLock {
            guard !arr.isEmpty else {
                return .failure(MockError.stubsExhausted(name))
            }
            return arr.removeFirst()
        }
        try result.get()
    }
}

// MARK: - BlockingMockOneLakeClient

/// A ``OneLakeClientProtocol`` mock whose `read()` blocks until `unblock()` or
/// `failWith(_:)` is called. Used by T1 (livelock test) to control exactly when
/// the first download task completes so the test can reliably cancel it while
/// a second `open()` is coalescing on it.
final class BlockingMockOneLakeClient: OneLakeClientProtocol, @unchecked Sendable {

    // MARK: - State

    /// Continuation for the blocked `read()` call.
    private var pendingContinuation: CheckedContinuation<(Data, PathProperties), any Error>?
    private let lock = NSLock()

    /// Signals when the mock has entered `read()` and is suspending.
    private let readEnteredContinuation = AsyncStream<Void>.makeStream()
    var readEntered: AsyncStream<Void> { readEnteredContinuation.stream }

    // MARK: - Control

    /// Resolves the blocked `read()` with a successful result.
    func unblock(data: Data, props: PathProperties) {
        let cont = lock.withLock { () -> CheckedContinuation<(Data, PathProperties), any Error>? in
            let c = pendingContinuation; pendingContinuation = nil; return c
        }
        cont?.resume(returning: (data, props))
    }

    /// Resolves the blocked `read()` with an error.
    func failWith(_ error: any Error) {
        let cont = lock.withLock { () -> CheckedContinuation<(Data, PathProperties), any Error>? in
            let c = pendingContinuation; pendingContinuation = nil; return c
        }
        cont?.resume(throwing: error)
    }

    // MARK: - OneLakeClientProtocol

    func read(
        alias: String, workspaceGUID: String, itemGUID: String,
        path: String, range: Range<Int64>?, ifMatch: String
    ) async throws -> (Data, PathProperties) {
        return try await withTaskCancellationHandler(
            operation: {
                try await withCheckedThrowingContinuation { cont in
                    lock.withLock { pendingContinuation = cont }
                    readEnteredContinuation.continuation.yield(())
                }
            },
            onCancel: {
                // Unblock the continuation with a CancellationError so the
                // Task that awaits this mock can exit cleanly on cancellation.
                let cont = lock.withLock { () -> CheckedContinuation<(Data, PathProperties), any Error>? in
                    let c = pendingContinuation; pendingContinuation = nil; return c
                }
                cont?.resume(throwing: CancellationError())
            }
        )
    }

    func read(alias: String, workspaceGUID: String, itemGUID: String, path: String, range: Range<Int64>?, ifMatch: String, destination: FileHandle) async throws -> PathProperties {
        let (data, props) = try await read(alias: alias, workspaceGUID: workspaceGUID, itemGUID: itemGUID, path: path, range: range, ifMatch: ifMatch)
        try destination.write(contentsOf: data)
        return props
    }
    func listPath(alias: String, workspaceGUID: String, itemGUID: String, directory: String, recursive: Bool) async throws -> ListResult { ListResult(entries: []) }
    func getProperties(alias: String, workspaceGUID: String, itemGUID: String, path: String) async throws -> PathProperties { PathProperties.make() }
    func write(alias: String, workspaceGUID: String, itemGUID: String, path: String, content: Data, size: Int64) async throws {}
    func write(alias: String, workspaceGUID: String, itemGUID: String, path: String, sourceURL: URL, size: Int64) async throws {}
    func createDirectory(alias: String, workspaceGUID: String, itemGUID: String, path: String) async throws {}
    func delete(alias: String, workspaceGUID: String, itemGUID: String, path: String, recursive: Bool) async throws {}
}

// MARK: - MockFabricClient

final class MockFabricClient: FabricClientProtocol, @unchecked Sendable {

    var listWorkspacesResults: [Result<[Workspace], any Error>] = []
    var listItemsResults: [Result<[Item], any Error>] = []
    var listFoldersResults: [Result<[Folder], any Error>] = []

    func listAllWorkspaces(alias: String) async throws -> [Workspace] {
        guard !listWorkspacesResults.isEmpty else { throw MockError.stubsExhausted("listAllWorkspaces") }
        return try listWorkspacesResults.removeFirst().get()
    }

    func listAllItems(alias: String, workspaceID: String) async throws -> [Item] {
        guard !listItemsResults.isEmpty else { throw MockError.stubsExhausted("listAllItems") }
        return try listItemsResults.removeFirst().get()
    }

    func listAllFolders(alias: String, workspaceID: String) async throws -> [Folder] {
        guard !listFoldersResults.isEmpty else { throw MockError.stubsExhausted("listAllFolders") }
        return try listFoldersResults.removeFirst().get()
    }
}

// MARK: - MockError

enum MockError: Error, Equatable {
    case stubsExhausted(String)
    case intentional(String)
}

// MARK: - Convenience builders

extension PathProperties {
    static func make(
        isDirectory: Bool = false,
        contentLength: Int64 = 0,
        eTag: String = "",
        lastModified: Date = Date(timeIntervalSince1970: 0),
        contentType: String = ""
    ) -> PathProperties {
        PathProperties(
            isDirectory: isDirectory,
            contentLength: contentLength,
            eTag: eTag,
            lastModified: lastModified,
            contentType: contentType
        )
    }
}

extension ListResult {
    static func make(entries: [PathEntry] = []) -> ListResult {
        ListResult(entries: entries)
    }
}

extension PathEntry {
    static func file(
        name: String,
        size: Int64 = 100,
        eTag: String = "abc",
        lastModified: Date = Date(timeIntervalSince1970: 0)
    ) -> PathEntry {
        PathEntry(name: name, isDirectory: false, contentLength: size, eTag: eTag, lastModified: lastModified)
    }

    static func directory(name: String) -> PathEntry {
        PathEntry(name: name, isDirectory: true, contentLength: 0, eTag: "", lastModified: Date(timeIntervalSince1970: 0))
    }
}
