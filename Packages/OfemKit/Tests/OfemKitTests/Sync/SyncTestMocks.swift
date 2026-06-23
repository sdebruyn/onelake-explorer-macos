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
    // tests-10: record getProperties and createDirectory calls so tests can
    // assert "exactly one HEAD was issued" or "mkdir was called with this path".
    private(set) var getPropertiesCalls: [GetPropertiesCall] = []
    private(set) var createDirectoryCalls: [CreateDirectoryCall] = []
    private(set) var readCalls: [ReadCall] = []
    private(set) var writeCalls: [WriteCall] = []
    private(set) var deleteCalls: [DeleteCall] = []
    private(set) var renameCalls: [RenameCall] = []

    struct ListPathCall {
        let alias: String
        let workspaceGUID: String
        let itemGUID: String
        let directory: String
        let recursive: Bool
    }

    struct GetPropertiesCall {
        let alias: String
        let workspaceGUID: String
        let itemGUID: String
        let path: String
    }

    struct CreateDirectoryCall {
        let alias: String
        let workspaceGUID: String
        let itemGUID: String
        let path: String
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

    struct RenameCall {
        let alias: String
        let workspaceGUID: String
        let itemGUID: String
        let sourcePath: String
        let destinationPath: String
    }

    private let lock = NSLock()

    // MARK: - Scripted responses (rename)

    var renameResults: [Result<Void, any Error>] = []

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
        // tests-10: record the call so tests can assert HEAD count and args.
        lock.withLock { getPropertiesCalls.append(GetPropertiesCall(alias: alias, workspaceGUID: workspaceGUID, itemGUID: itemGUID, path: path)) }
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
        alias: String, workspaceGUID _: String, itemGUID _: String,
        path: String, content: Data, size: Int64
    ) async throws {
        lock.withLock { writeCalls.append(WriteCall(alias: alias, path: path, content: content, sourceURL: nil, size: size)) }
        try dequeueVoid(&writeResults, name: "write")
    }

    func write(
        alias: String, workspaceGUID _: String, itemGUID _: String,
        path: String, sourceURL: URL, size: Int64
    ) async throws {
        lock.withLock { writeCalls.append(WriteCall(alias: alias, path: path, content: nil, sourceURL: sourceURL, size: size)) }
        try dequeueVoid(&writeResults, name: "write")
    }

    func createDirectory(
        alias: String, workspaceGUID: String, itemGUID: String, path: String
    ) async throws {
        // tests-10: record the call so tests can assert mkdir count and path.
        lock.withLock { createDirectoryCalls.append(CreateDirectoryCall(alias: alias, workspaceGUID: workspaceGUID, itemGUID: itemGUID, path: path)) }
        try dequeueVoid(&createDirectoryResults, name: "createDirectory")
    }

    func rename(
        alias: String, workspaceGUID: String, itemGUID: String,
        sourcePath: String, destinationPath: String
    ) async throws {
        lock.withLock { renameCalls.append(RenameCall(alias: alias, workspaceGUID: workspaceGUID, itemGUID: itemGUID, sourcePath: sourcePath, destinationPath: destinationPath)) }
        try dequeueVoid(&renameResults, name: "rename")
    }

    func delete(
        alias: String, workspaceGUID _: String, itemGUID _: String,
        path: String, recursive: Bool
    ) async throws {
        lock.withLock { deleteCalls.append(DeleteCall(alias: alias, path: path, recursive: recursive)) }
        try dequeueVoid(&deleteResults, name: "delete")
    }

    // MARK: - Private helper

    /// Dequeue under lock to avoid races in concurrent tests (e.g. testConcurrentOpensCoalesce).
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
    var readEntered: AsyncStream<Void> {
        readEnteredContinuation.stream
    }

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
        alias _: String, workspaceGUID _: String, itemGUID _: String,
        path _: String, range _: Range<Int64>?, ifMatch _: String
    ) async throws -> (Data, PathProperties) {
        try await withTaskCancellationHandler(
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

    func listPath(alias _: String, workspaceGUID _: String, itemGUID _: String, directory _: String, recursive _: Bool) async throws -> ListResult {
        ListResult(entries: [])
    }

    func getProperties(alias _: String, workspaceGUID _: String, itemGUID _: String, path _: String) async throws -> PathProperties {
        PathProperties.make()
    }

    func write(alias _: String, workspaceGUID _: String, itemGUID _: String, path _: String, content _: Data, size _: Int64) async throws {}
    func write(alias _: String, workspaceGUID _: String, itemGUID _: String, path _: String, sourceURL _: URL, size _: Int64) async throws {}
    func createDirectory(alias _: String, workspaceGUID _: String, itemGUID _: String, path _: String) async throws {}
    func rename(alias _: String, workspaceGUID _: String, itemGUID _: String, sourcePath _: String, destinationPath _: String) async throws {}
    func delete(alias _: String, workspaceGUID _: String, itemGUID _: String, path _: String, recursive _: Bool) async throws {}
}

// MARK: - MockFabricClient

// tests-09: protect all mutable arrays with an NSLock, matching the pattern
// used by MockOneLakeClient, so that any future concurrent-Fabric test does
// not race the array mutation.
final class MockFabricClient: FabricClientProtocol, @unchecked Sendable {
    var listWorkspacesResults: [Result<[Workspace], any Error>] = []
    var listItemsResults: [Result<[Item], any Error>] = []
    var listFoldersResults: [Result<[Folder], any Error>] = []

    private let lock = NSLock()

    func listAllWorkspaces(alias _: String) async throws -> [Workspace] {
        let result: Result<[Workspace], any Error> = lock.withLock {
            guard !listWorkspacesResults.isEmpty else {
                return .failure(MockError.stubsExhausted("listAllWorkspaces"))
            }
            return listWorkspacesResults.removeFirst()
        }
        return try result.get()
    }

    func listAllItems(alias _: String, workspaceID _: String) async throws -> [Item] {
        let result: Result<[Item], any Error> = lock.withLock {
            guard !listItemsResults.isEmpty else {
                return .failure(MockError.stubsExhausted("listAllItems"))
            }
            return listItemsResults.removeFirst()
        }
        return try result.get()
    }

    func listAllFolders(alias _: String, workspaceID _: String) async throws -> [Folder] {
        let result: Result<[Folder], any Error> = lock.withLock {
            guard !listFoldersResults.isEmpty else {
                return .failure(MockError.stubsExhausted("listAllFolders"))
            }
            return listFoldersResults.removeFirst()
        }
        return try result.get()
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

    static func directory(
        name: String,
        lastModified: Date = Date(timeIntervalSince1970: 0)
    ) -> PathEntry {
        PathEntry(name: name, isDirectory: true, contentLength: 0, eTag: "", lastModified: lastModified)
    }
}

// MARK: - BlockingListMockOneLakeClient

/// An ``OneLakeClientProtocol`` mock whose `listPath` suspends until explicitly
/// unblocked. Used to test concurrency-cap enforcement in
/// ``SyncEngine/refreshMaterialized(alias:keys:concurrencyCap:)``.
final class BlockingListMockOneLakeClient: OneLakeClientProtocol, @unchecked Sendable {
    private var pending: [CheckedContinuation<ListResult, any Error>] = []
    private let lock = NSLock()
    private var _listPathCallCount = 0

    private let listEnteredStream = AsyncStream<Void>.makeStream()
    var listEntered: AsyncStream<Void> {
        listEnteredStream.stream
    }

    var listPathCallCount: Int {
        lock.withLock { _listPathCallCount }
    }

    /// Resolves the oldest blocked `listPath` with `result`.
    func unblock(with result: ListResult) {
        let cont = lock.withLock { pending.isEmpty ? nil : pending.removeFirst() }
        cont?.resume(returning: result)
    }

    /// Resolves the oldest blocked `listPath` by throwing `error`.
    func fail(with error: any Error) {
        let cont = lock.withLock { pending.isEmpty ? nil : pending.removeFirst() }
        cont?.resume(throwing: error)
    }

    func listPath(
        alias _: String, workspaceGUID _: String, itemGUID _: String,
        directory _: String, recursive _: Bool
    ) async throws -> ListResult {
        lock.withLock { _listPathCallCount += 1 }
        return try await withTaskCancellationHandler(
            operation: {
                try await withCheckedThrowingContinuation { cont in
                    lock.withLock { pending.append(cont) }
                    listEnteredStream.continuation.yield(())
                }
            },
            onCancel: {
                let cont = lock.withLock { pending.isEmpty ? nil : pending.removeFirst() }
                cont?.resume(throwing: CancellationError())
            }
        )
    }

    /// Remaining protocol surface is unused by these tests.
    func getProperties(alias _: String, workspaceGUID _: String, itemGUID _: String, path _: String) async throws -> PathProperties {
        PathProperties.make()
    }

    func read(alias _: String, workspaceGUID _: String, itemGUID _: String, path _: String, range _: Range<Int64>?, ifMatch _: String) async throws -> (Data, PathProperties) {
        (Data(), PathProperties.make())
    }

    func read(alias _: String, workspaceGUID _: String, itemGUID _: String, path _: String, range _: Range<Int64>?, ifMatch _: String, destination _: FileHandle) async throws -> PathProperties {
        PathProperties.make()
    }

    func write(alias _: String, workspaceGUID _: String, itemGUID _: String, path _: String, content _: Data, size _: Int64) async throws {}
    func write(alias _: String, workspaceGUID _: String, itemGUID _: String, path _: String, sourceURL _: URL, size _: Int64) async throws {}
    func createDirectory(alias _: String, workspaceGUID _: String, itemGUID _: String, path _: String) async throws {}
    func rename(alias _: String, workspaceGUID _: String, itemGUID _: String, sourcePath _: String, destinationPath _: String) async throws {}
    func delete(alias _: String, workspaceGUID _: String, itemGUID _: String, path _: String, recursive _: Bool) async throws {}
}
