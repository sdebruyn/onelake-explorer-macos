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
        let content: Data
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

    func write(
        alias: String, workspaceGUID: String, itemGUID: String,
        path: String, content: Data, size: Int64
    ) async throws {
        lock.withLock { writeCalls.append(WriteCall(alias: alias, path: path, content: content, size: size)) }
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

    func dequeue<T>(_ arr: inout [Result<T, any Error>], name: String) throws -> T {
        guard !arr.isEmpty else {
            throw MockError.stubsExhausted(name)
        }
        return try arr.removeFirst().get()
    }

    private func dequeueVoid(_ arr: inout [Result<Void, any Error>], name: String) throws {
        guard !arr.isEmpty else {
            throw MockError.stubsExhausted(name)
        }
        try arr.removeFirst().get()
    }
}

// MARK: - MockFabricClient

final class MockFabricClient: FabricClientProtocol, @unchecked Sendable {

    var listWorkspacesResults: [Result<[Workspace], any Error>] = []
    var listItemsResults: [Result<[Item], any Error>] = []

    func listAllWorkspaces(alias: String) async throws -> [Workspace] {
        guard !listWorkspacesResults.isEmpty else { throw MockError.stubsExhausted("listAllWorkspaces") }
        return try listWorkspacesResults.removeFirst().get()
    }

    func listAllItems(alias: String, workspaceID: String) async throws -> [Item] {
        guard !listItemsResults.isEmpty else { throw MockError.stubsExhausted("listAllItems") }
        return try listItemsResults.removeFirst().get()
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
