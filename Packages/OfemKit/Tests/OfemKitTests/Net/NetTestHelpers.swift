import Foundation
@testable import OfemKit

// MARK: - Shared helpers for Net / OneLake / Fabric test files

// Consolidates boilerplate that was copy-pasted across HTTPClientTests,
// OneLakeClientTests, FabricClientTests, FabricClientCorrectnessTests,
// HTTPClientDownloadTests, and OneLakeStreamingTests (tests-15).

/// Creates an `HTTPGateRegistry` with a single pre-seeded gate for `host`.
///
/// Using the seeded initialiser registers the gate synchronously, avoiding
/// the race where `execute()` fires before an asynchronous Task-registered
/// gate lands (tests-04).
func makeGate(
    host: String,
    maxConcurrent: Int = 8,
    tokensPerSecond: Double = 100,
    burst: Int = 100
) -> HTTPGateRegistry {
    let gate = HTTPGate(
        host: host,
        maxConcurrent: maxConcurrent,
        tokensPerSecond: tokensPerSecond,
        burst: burst
    )
    return HTTPGateRegistry(
        defaults: HTTPGateDefaults(
            maxConcurrent: maxConcurrent,
            tokensPerSecond: tokensPerSecond,
            burst: burst
        ),
        seeded: [gate]
    )
}

/// Creates a temporary file and opens it for reading and writing.
///
/// The caller is responsible for closing the handle and removing the file,
/// typically via `defer`:
/// ```swift
/// let (tmpURL, handle) = try makeTempFileHandle(prefix: "my-test")
/// defer {
///     try? handle.close()
///     try? FileManager.default.removeItem(at: tmpURL)
/// }
/// ```
func makeTempFileHandle(prefix: String = "ofem-test") throws -> (URL, FileHandle) {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("\(prefix)-\(UUID().uuidString).bin")
    FileManager.default.createFile(atPath: url.path, contents: nil)
    let handle = try FileHandle(forUpdating: url)
    return (url, handle)
}
