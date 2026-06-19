import Foundation
import Testing

@testable import OfemKit

/// Extended OneLake DFS data-plane integration tests covering multi-chunk I/O,
/// sourceURL uploads, overwrites, recursive listing, directory properties,
/// conditional reads, and recursive deletes.
///
/// Every test provisions a unique `Files/ofem-ci/<UUID>` directory and cleans
/// it up — even on failure — so the live lakehouse stays tidy.
@Suite("OneLake data plane integration", .integration, .serialized)
struct OneLakeDataPlaneIntegrationTests {

    // MARK: - Helper

    /// Binds the live workspace + lakehouse so test bodies stay readable.
    /// Mirrors the `LiveLakehouse` pattern from `OneLakeIntegrationTests`.
    private struct LiveLakehouse {
        let client: OneLakeClient
        let workspace: String
        let item: String
        let alias = "ci"

        func mkdir(_ path: String) async throws {
            try await client.createDirectory(
                alias: alias, workspaceGUID: workspace, itemGUID: item, path: path
            )
        }

        func write(_ path: String, _ data: Data) async throws {
            try await client.write(
                alias: alias, workspaceGUID: workspace, itemGUID: item,
                path: path, content: data, size: Int64(data.count)
            )
        }

        func write(_ path: String, sourceURL: URL, size: Int64) async throws {
            try await client.write(
                alias: alias, workspaceGUID: workspace, itemGUID: item,
                path: path, sourceURL: sourceURL, size: size
            )
        }

        func list(_ dir: String, recursive: Bool = false) async throws -> ListResult {
            try await client.listPath(
                alias: alias, workspaceGUID: workspace, itemGUID: item,
                directory: dir, recursive: recursive
            )
        }

        func properties(_ path: String) async throws -> PathProperties {
            try await client.getProperties(
                alias: alias, workspaceGUID: workspace, itemGUID: item, path: path
            )
        }

        func read(_ path: String, range: Range<Int64>? = nil, ifMatch: String = "") async throws -> (Data, PathProperties) {
            try await client.read(
                alias: alias, workspaceGUID: workspace, itemGUID: item,
                path: path, range: range, ifMatch: ifMatch
            )
        }

        @discardableResult
        func read(_ path: String, destination: FileHandle) async throws -> PathProperties {
            try await client.read(
                alias: alias, workspaceGUID: workspace, itemGUID: item,
                path: path, destination: destination
            )
        }

        func rm(_ path: String, recursive: Bool = true) async throws {
            try await client.delete(
                alias: alias, workspaceGUID: workspace, itemGUID: item,
                path: path, recursive: recursive
            )
        }
    }

    private func liveLakehouse() throws -> LiveLakehouse {
        let config = try IntegrationConfig.fromEnvironment()
        let pool = SessionPool(tokenProvider: EnvVarTokenProvider())
        let client = OneLakeClient(sessionPool: pool)
        return LiveLakehouse(client: client, workspace: config.workspaceID, item: config.lakehouseID)
    }

    // MARK: - Tests

    /// Writes a payload that crosses the 4 MiB chunk boundary twice (>9 MiB),
    /// reads it back in full, and verifies byte equality and reported size.
    @Test("large multi-chunk file round-trips byte-for-byte")
    func largeMultiChunkRoundTrip() async throws {
        let lake = try liveLakehouse()
        let dir = "Files/ofem-ci/\(UUID().uuidString)"
        let filePath = "\(dir)/large.bin"

        // 9.5 MiB — crosses the 4 MiB boundary at 4 MiB and 8 MiB.
        // Pattern: position mod 251 XOR (position >> 8) mod 199, so bytes vary
        // across the chunk seam and a stitching bug shows up immediately.
        let byteCount = 9 * 1024 * 1024 + 512 * 1024
        var bytes = [UInt8](repeating: 0, count: byteCount)
        for i in 0..<byteCount {
            bytes[i] = UInt8((i % 251) ^ ((i >> 8) % 199))
        }
        let payload = Data(bytes)

        do {
            try await lake.mkdir(dir)
            try await lake.write(filePath, payload)

            let (readBack, readProps) = try await lake.read(filePath)
            #expect(readBack == payload, "read-back bytes must match uploaded payload exactly")
            #expect(readProps.contentLength == Int64(byteCount), "contentLength must equal payload size")
            #expect(!readProps.isDirectory, "a file must not report isDirectory")

            let headProps = try await lake.properties(filePath)
            #expect(headProps.contentLength == Int64(byteCount), "getProperties contentLength must match")
            #expect(!headProps.isDirectory, "getProperties must report isDirectory == false for a file")
        } catch {
            try? await lake.rm(dir)
            throw error
        }
        try await lake.rm(dir)
    }

    /// Uploads via the `sourceURL` overload (streams from a local temp file)
    /// and verifies the server stores the exact bytes.
    @Test("write(sourceURL:) streams a file from disk")
    func writeFromSourceURL() async throws {
        let lake = try liveLakehouse()
        let dir = "Files/ofem-ci/\(UUID().uuidString)"
        let filePath = "\(dir)/streamed.bin"

        // 1 MiB of deterministic content written to a temp file first.
        let localContent = Data((0..<(1024 * 1024)).map { UInt8($0 % 233) })
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".bin")
        try localContent.write(to: tempURL)
        // Defer ensures the local temp file is removed on every exit path —
        // success, thrown error from the do block, or a thrown error from the
        // final lake.rm call below.
        defer { try? FileManager.default.removeItem(at: tempURL) }

        do {
            try await lake.mkdir(dir)
            try await lake.write(filePath, sourceURL: tempURL, size: Int64(localContent.count))

            let (readBack, props) = try await lake.read(filePath)
            #expect(readBack == localContent, "streamed upload must produce identical bytes on read-back")
            #expect(props.contentLength == Int64(localContent.count))
        } catch {
            try? await lake.rm(dir)
            throw error
        }
        try await lake.rm(dir)
    }

    /// Writes content A, overwrites the same path with shorter content B, then
    /// reads back and confirms no leftover bytes from A remain.
    @Test("overwriting a file replaces its content")
    func overwriteReplacesContent() async throws {
        let lake = try liveLakehouse()
        let dir = "Files/ofem-ci/\(UUID().uuidString)"
        let filePath = "\(dir)/overwrite.bin"

        let contentA = Data(repeating: 0xAA, count: 512 * 1024)   // 512 KiB
        let contentB = Data(repeating: 0xBB, count: 128 * 1024)   // 128 KiB — shorter

        do {
            try await lake.mkdir(dir)
            try await lake.write(filePath, contentA)
            try await lake.write(filePath, contentB)

            let (readBack, props) = try await lake.read(filePath)
            #expect(readBack == contentB, "read-back must equal the second write exactly")
            #expect(
                props.contentLength == Int64(contentB.count),
                "contentLength must reflect the new shorter size, not the original"
            )
            #expect(readBack.count == contentB.count, "no leftover bytes from the first write")
        } catch {
            try? await lake.rm(dir)
            throw error
        }
        try await lake.rm(dir)
    }

    /// Creates a two-level directory tree and verifies recursive vs.
    /// non-recursive listing returns the correct sets of entries.
    @Test("recursive listing returns the nested tree")
    func recursiveListing() async throws {
        let lake = try liveLakehouse()
        let dir = "Files/ofem-ci/\(UUID().uuidString)"
        let subDir = "\(dir)/sub"
        let fileA = "\(dir)/a.bin"
        let fileB = "\(subDir)/b.bin"

        let stubData = Data([0x01, 0x02, 0x03])

        do {
            try await lake.mkdir(dir)
            try await lake.mkdir(subDir)
            try await lake.write(fileA, stubData)
            try await lake.write(fileB, stubData)

            // Recursive listing from the parent must contain both files and the
            // `sub` directory entry.
            let recursive = try await lake.list(dir, recursive: true)
            #expect(
                recursive.entries.contains { $0.name.hasSuffix("a.bin") && !$0.isDirectory },
                "recursive listing must include a.bin"
            )
            #expect(
                recursive.entries.contains { $0.name.hasSuffix("b.bin") && !$0.isDirectory },
                "recursive listing must include b.bin"
            )
            #expect(
                recursive.entries.contains { $0.name.hasSuffix("/sub") && $0.isDirectory },
                "recursive listing must include the sub directory"
            )

            // Non-recursive listing from the parent must include `sub` and
            // `a.bin` but must NOT directly include `b.bin` (it is nested).
            let shallow = try await lake.list(dir, recursive: false)
            #expect(
                shallow.entries.contains { $0.name.hasSuffix("a.bin") },
                "shallow listing must include the direct child a.bin"
            )
            #expect(
                shallow.entries.contains { $0.name.hasSuffix("/sub") && $0.isDirectory },
                "shallow listing must include the sub directory entry"
            )
            #expect(
                !shallow.entries.contains { $0.name.hasSuffix("b.bin") },
                "shallow listing must not include b.bin which lives one level deeper"
            )
        } catch {
            try? await lake.rm(dir)
            throw error
        }
        try await lake.rm(dir)
    }

    /// Verifies that `getProperties` on a directory path reports `isDirectory == true`.
    @Test("getProperties on a directory reports isDirectory == true")
    func directoryProperties() async throws {
        let lake = try liveLakehouse()
        let dir = "Files/ofem-ci/\(UUID().uuidString)"

        do {
            try await lake.mkdir(dir)

            let props = try await lake.properties(dir)
            #expect(props.isDirectory, "a created directory must report isDirectory == true")
        } catch {
            try? await lake.rm(dir)
            throw error
        }
        try await lake.rm(dir)
    }

    /// A read with a stale/wrong If-Match etag must throw; a read with the
    /// correct etag must succeed.
    @Test("conditional read with a stale If-Match fails; correct etag succeeds")
    func conditionalRead() async throws {
        let lake = try liveLakehouse()
        let dir = "Files/ofem-ci/\(UUID().uuidString)"
        let filePath = "\(dir)/conditional.bin"

        let payload = Data((0..<(64 * 1024)).map { UInt8($0 % 211) })

        do {
            try await lake.mkdir(dir)
            try await lake.write(filePath, payload)

            // Capture the real etag via a HEAD request.
            let props = try await lake.properties(filePath)

            // A wrong etag must cause the server to reject the request.
            await #expect(throws: (any Error).self) {
                _ = try await lake.read(filePath, ifMatch: "\"0xDEADBEEF\"")
            }

            // The correct etag must succeed and return the full payload.
            let (readBack, _) = try await lake.read(filePath, ifMatch: props.eTag)
            #expect(readBack == payload, "read with correct etag must return the full payload")
        } catch {
            try? await lake.rm(dir)
            throw error
        }
        try await lake.rm(dir)
    }

    /// Non-recursive delete on a non-empty directory must fail; recursive
    /// delete must succeed and leave the path gone.
    @Test("delete non-recursive on a non-empty directory fails; recursive succeeds")
    func deleteRecursive() async throws {
        let lake = try liveLakehouse()
        let dir = "Files/ofem-ci/\(UUID().uuidString)"
        let filePath = "\(dir)/child.bin"

        let payload = Data([0xDE, 0xAD, 0xBE, 0xEF])

        do {
            try await lake.mkdir(dir)
            try await lake.write(filePath, payload)

            // Non-recursive delete on a directory that has a child must fail.
            await #expect(throws: (any Error).self) {
                try await lake.rm(dir, recursive: false)
            }

            // Recursive delete must succeed.
            try await lake.rm(dir, recursive: true)
        } catch {
            try? await lake.rm(dir)
            throw error
        }

        // After recursive delete the path is gone — listing must throw.
        await #expect(throws: (any Error).self) {
            _ = try await lake.list(dir)
        }
    }

    /// Calls `createDirectory` twice on the same path and verifies that the
    /// second call succeeds rather than throwing — OneLake returns 201 on the
    /// repeat (idempotent PUT semantics; there is no 409 Conflict for directories).
    @Test("createDirectory is idempotent on an existing directory")
    func createDirectoryIsIdempotent() async throws {
        let lake = try liveLakehouse()
        let dir = "Files/ofem-ci/\(UUID().uuidString)"

        do {
            // First creation — must succeed.
            try await lake.mkdir(dir)

            // Second creation of the same path — must also succeed (no throw).
            // OneLake treats the repeat PUT as a no-op and returns 201 again.
            try await lake.mkdir(dir)

            // Path must still be reported as a directory.
            let props = try await lake.properties(dir)
            #expect(props.isDirectory, "the path must report isDirectory == true after a repeated createDirectory")
        } catch {
            try? await lake.rm(dir)
            throw error
        }
        try await lake.rm(dir)
    }

    /// Calls `getProperties` on the lakehouse's top-level `Files` directory and
    /// asserts the HEAD succeeds and reports `isDirectory == true`.
    ///
    /// `Files` is the always-present managed data root of a lakehouse, so this
    /// exercises a HEAD on a pre-existing top-level directory (distinct from the
    /// freshly-created sub-directory covered above) against the real DFS endpoint.
    /// Note: DFS rejects a HEAD on an empty relative path with HTTP 400, so the
    /// engine always probes a concrete path — `Files` is the cheapest such root.
    @Test("getProperties on the Files root reports isDirectory == true")
    func getPropertiesOnFilesRoot() async throws {
        let lake = try liveLakehouse()

        // The LiveLakehouse.properties helper delegates directly to
        // OneLakeClient.getProperties, so this exercises the real HEAD request.
        let props = try await lake.properties("Files")
        #expect(props.isDirectory, "the Files root must report isDirectory == true")
    }

    /// Non-recursive delete on an EMPTY directory must succeed, and the path
    /// must be absent afterward. (Contrast: `deleteRecursive` already proves that
    /// non-recursive delete on a NON-EMPTY directory fails — this test is the
    /// complementary happy path.)
    @Test("delete non-recursive succeeds on an empty directory")
    func deleteNonRecursiveEmptyDirectory() async throws {
        let lake = try liveLakehouse()
        let dir = "Files/ofem-ci/\(UUID().uuidString)"

        // Create the directory, but do NOT write any children into it.
        try await lake.mkdir(dir)

        // Non-recursive delete on an empty directory must not throw.
        try await lake.rm(dir, recursive: false)

        // The path is gone — a HEAD request must throw (404 / server error).
        await #expect(throws: (any Error).self) {
            _ = try await lake.properties(dir)
        }
    }

    /// Writes a file larger than 8 MiB, then requests a byte range whose bounds
    /// straddle the 4 MiB upload-chunk seam. Verifies that the returned bytes
    /// equal the exact corresponding slice of the source buffer, detecting any
    /// stitching or off-by-one bug at the chunk boundary.
    @Test("ranged read across the 4 MiB chunk seam returns exact bytes")
    func rangedReadAcrossChunkSeam() async throws {
        let lake = try liveLakehouse()
        let dir = "Files/ofem-ci/\(UUID().uuidString)"
        let filePath = "\(dir)/seam.bin"

        // 9 MiB — guarantees two full 4 MiB chunks and a residual third chunk,
        // so the seam at 4 MiB lies well inside the uploaded content.
        let byteCount = 9 * 1024 * 1024
        var bytes = [UInt8](repeating: 0, count: byteCount)
        for i in 0..<byteCount {
            bytes[i] = UInt8(i % 251)
        }
        let payload = Data(bytes)

        // The range straddles the 4 MiB boundary: 1000 bytes before and after.
        let seamOffset: Int64 = 4 * 1024 * 1024
        let rangeStart: Int64 = seamOffset - 1000
        let rangeEnd: Int64   = seamOffset + 1000   // inclusive last byte
        // `read(range:)` takes a half-open `Range<Int64>`; the server receives
        // `Range: bytes=<rangeStart>-<rangeEnd>` (inclusive), so the returned
        // slice covers `rangeEnd - rangeStart + 1` bytes.
        let expectedSlice = payload[Int(rangeStart)...Int(rangeEnd)]
        let expectedLength = rangeEnd - rangeStart + 1

        do {
            try await lake.mkdir(dir)
            try await lake.write(filePath, payload)

            // Half-open range: [rangeStart, rangeEnd + 1).
            let (sliceData, _) = try await lake.read(filePath, range: rangeStart..<(rangeEnd + 1))
            #expect(
                Int64(sliceData.count) == expectedLength,
                "returned byte count must equal the requested range length (\(expectedLength))"
            )
            #expect(
                sliceData == Data(expectedSlice),
                "returned bytes must equal the corresponding slice of the source buffer"
            )
        } catch {
            try? await lake.rm(dir)
            throw error
        }
        try await lake.rm(dir)
    }

    /// Writes a file, then streams the full content into a temp `FileHandle`
    /// using the `read(destination:)` overload. Asserts that the written temp
    /// file is byte-for-byte identical to the uploaded content.
    @Test("streaming read into a FileHandle produces byte-identical output")
    func streamingReadIntoFileHandle() async throws {
        let lake = try liveLakehouse()
        let dir = "Files/ofem-ci/\(UUID().uuidString)"
        let filePath = "\(dir)/stream.bin"

        // 2 MiB of deterministic content — large enough to verify streaming but
        // small enough to keep the live test reasonably fast.
        let byteCount = 2 * 1024 * 1024
        let payload = Data((0..<byteCount).map { UInt8($0 % 199) })

        // Prepare a temp file that the streaming overload will write into.
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".bin")
        FileManager.default.createFile(atPath: tempURL.path, contents: nil)
        // Defer ensures the temp file is removed on every exit path.
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let destHandle = try FileHandle(forWritingTo: tempURL)
        defer { try? destHandle.close() }

        do {
            try await lake.mkdir(dir)
            try await lake.write(filePath, payload)

            // Stream the full file into the destination handle.
            let props = try await lake.read(filePath, destination: destHandle)
            try destHandle.synchronize()

            #expect(!props.isDirectory, "a file must not report isDirectory")
            #expect(
                props.contentLength == Int64(byteCount),
                "response properties must report the correct content length"
            )

            // Read the temp file back and compare byte-for-byte.
            let written = try Data(contentsOf: tempURL)
            #expect(written == payload, "streamed bytes must be byte-identical to the uploaded payload")
        } catch {
            try? await lake.rm(dir)
            throw error
        }
        try await lake.rm(dir)
    }
}
