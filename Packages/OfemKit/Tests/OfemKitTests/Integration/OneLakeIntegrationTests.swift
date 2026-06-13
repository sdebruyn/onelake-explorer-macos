import Foundation
import Testing

@testable import OfemKit

/// Live OneLake DFS data-plane round-trips against a real Fabric lakehouse.
///
/// Serialized: every test writes under its own per-run directory, but they
/// share one workspace and we keep concurrency off the live endpoint modest.
@Suite("OneLake integration", .integration, .serialized)
struct OneLakeIntegrationTests {

    /// Binds the live workspace + lakehouse so test bodies stay readable.
    private struct LiveLakehouse {
        let client: OneLakeClient
        let workspace: String
        let item: String
        let alias = "ci"

        func mkdir(_ path: String) async throws {
            try await client.createDirectory(alias: alias, workspaceGUID: workspace, itemGUID: item, path: path)
        }
        func write(_ path: String, _ data: Data) async throws {
            try await client.write(
                alias: alias, workspaceGUID: workspace, itemGUID: item,
                path: path, content: data, size: Int64(data.count)
            )
        }
        func list(_ dir: String) async throws -> ListResult {
            try await client.listPath(alias: alias, workspaceGUID: workspace, itemGUID: item, directory: dir, recursive: false)
        }
        func read(_ path: String) async throws -> (Data, PathProperties) {
            try await client.read(alias: alias, workspaceGUID: workspace, itemGUID: item, path: path)
        }
        func rm(_ path: String) async throws {
            try await client.delete(alias: alias, workspaceGUID: workspace, itemGUID: item, path: path, recursive: true)
        }
    }

    private func liveLakehouse() throws -> LiveLakehouse {
        let config = try IntegrationConfig.fromEnvironment()
        let client = OneLakeClient(http: HTTPClient(), tokenProvider: EnvVarTokenProvider())
        return LiveLakehouse(client: client, workspace: config.workspaceID, item: config.lakehouseID)
    }

    @Test("creates, lists, reads back and deletes a file")
    func fileRoundTrip() async throws {
        let lake = try liveLakehouse()
        let dir = "Files/ofem-ci/\(UUID().uuidString)"
        let filePath = "\(dir)/payload.bin"
        // 256 KiB of non-trivial bytes — crosses no chunk boundary but is large
        // enough that a truncated read would be obvious.
        let payload = Data((0..<(256 * 1024)).map { UInt8($0 % 251) })

        do {
            try await lake.mkdir(dir)
            try await lake.write(filePath, payload)

            let listing = try await lake.list(dir)
            #expect(listing.entries.contains { $0.name.hasSuffix("payload.bin") && !$0.isDirectory })
            #expect(listing.entries.contains { $0.name.hasSuffix("payload.bin") && $0.contentLength == Int64(payload.count) })

            let (readBack, props) = try await lake.read(filePath)
            #expect(readBack == payload)
            #expect(props.contentLength == Int64(payload.count))
            #expect(!props.isDirectory)
        } catch {
            try? await lake.rm(dir)
            throw error
        }
        try await lake.rm(dir)

        // After deletion the directory listing must fail (path gone).
        await #expect(throws: (any Error).self) {
            _ = try await lake.list(dir)
        }
    }

    @Test("reads a byte range")
    func rangedRead() async throws {
        let lake = try liveLakehouse()
        let dir = "Files/ofem-ci/\(UUID().uuidString)"
        let filePath = "\(dir)/ranged.bin"
        let payload = Data((0..<1024).map { UInt8($0 % 251) })

        do {
            try await lake.mkdir(dir)
            try await lake.write(filePath, payload)

            let (slice, _) = try await lake.client.read(
                alias: lake.alias, workspaceGUID: lake.workspace, itemGUID: lake.item,
                path: filePath, range: 100..<200
            )
            #expect(slice == payload[100..<200])
        } catch {
            try? await lake.rm(dir)
            throw error
        }
        try await lake.rm(dir)
    }
}
