// End-to-end IPC integration test: spawn a real ofem daemon and drive
// it from the same Swift `IPCClient` the menu bar and File Provider
// Extension use in production. This is the regression guard for #71
// and #85, where a silent Swift-side IPC breakage shipped because CI
// only ran compile-only Swift checks.
//
// The test requires the daemon binary at <repo>/bin/ofem. If the
// binary is missing the test calls XCTSkip rather than failing — that
// keeps a fresh checkout from breaking before `make build` has run.

import Foundation
import XCTest

final class IPCIntegrationTests: XCTestCase {
    /// Spawn the daemon against a temp socket and round-trip a
    /// `status` call from the production `IPCClient`. The call must
    /// return a well-formed envelope within the 5s `callTimeout`
    /// baked into IPCClient; a hung connection (the #71 / #85 class
    /// of bug) surfaces as a thrown timeout, which fails the test.
    func testStatusRoundTrip() throws {
        let binary = try locateDaemonBinary()
        let workdir = try TempWorkdir()
        defer { workdir.cleanup() }

        let process = try spawnDaemon(binary: binary, workdir: workdir)
        defer { terminate(process) }

        try waitForSocket(workdir.socketPath, timeout: 10, logPath: workdir.logPath)

        let client = IPCClient(socketPath: workdir.socketPath)
        let responseData = try runAsyncTest {
            try await client.call(method: "status", params: [:])
        }

        let obj = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: responseData) as? [String: Any],
            "status response is not a JSON object"
        )
        // handleStatus always includes `daemonVersion` and `accounts`
        // (possibly empty). Their presence proves the daemon decoded
        // the call, dispatched it, and the Swift client decoded the
        // envelope — i.e. the whole IPC seam is live.
        XCTAssertNotNil(obj["daemonVersion"], "status response missing daemonVersion field")
        XCTAssertNotNil(obj["accounts"], "status response missing accounts field")
    }

    // MARK: - Helpers

    /// Walk up from this source file to the repo root and return the
    /// expected daemon binary path. We use `#filePath` rather than the
    /// test bundle's resource path because the daemon is built by
    /// `make build` into the source tree, not copied into the bundle.
    private func locateDaemonBinary() throws -> String {
        let here = URL(fileURLWithPath: #filePath)
        // .../apple/OneLakeTests/IPCIntegrationTests.swift → repo root
        let repoRoot = here
            .deletingLastPathComponent() // OneLakeTests
            .deletingLastPathComponent() // apple
            .deletingLastPathComponent() // repo root
        let binary = repoRoot.appendingPathComponent("bin/ofem").path
        if !FileManager.default.isExecutableFile(atPath: binary) {
            throw XCTSkip("daemon binary missing at \(binary); run `make build` first")
        }
        return binary
    }

    private func spawnDaemon(binary: String, workdir: TempWorkdir) throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = ["daemon", "run"]
        // HOME redirects config.ResolvePaths so the daemon never touches
        // the runner's real ~/Library. OFEM_SOCKET_PATH overrides the
        // bind path so we don't collide with any other ofem on the host.
        // OFEM_TELEMETRY=0 keeps the daemon from reaching out for an
        // App Insights connection string in CI.
        var env = ProcessInfo.processInfo.environment
        env["HOME"] = workdir.homePath
        env["OFEM_SOCKET_PATH"] = workdir.socketPath
        env["OFEM_TELEMETRY"] = "0"
        process.environment = env
        // Capture stdout/stderr so a failure surfaces what the daemon
        // logged instead of a bare "socket never appeared" timeout.
        FileManager.default.createFile(atPath: workdir.logPath, contents: nil)
        let logHandle = try FileHandle(forWritingTo: URL(fileURLWithPath: workdir.logPath))
        process.standardOutput = logHandle
        process.standardError = logHandle
        try process.run()
        return process
    }

    private func waitForSocket(_ path: String, timeout: TimeInterval, logPath: String) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: path) {
                return
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        let log = (try? String(contentsOfFile: logPath, encoding: .utf8)) ?? "<no log>"
        throw NSError(
            domain: "IPCIntegrationTests",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "daemon never bound socket at \(path) within \(timeout)s. daemon log:\n\(log)"]
        )
    }

    private func terminate(_ process: Process) {
        if !process.isRunning { return }
        process.terminate()
        // Bounded wait so a hung daemon never wedges the test runner.
        let deadline = Date().addingTimeInterval(5)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }
    }

    /// Bridge `async throws` to a synchronous XCTest body. XCTestCase's
    /// own async support requires the test method itself to be async,
    /// which would force every helper into an actor; this keeps the
    /// integration test top-to-bottom imperative.
    private func runAsyncTest<T>(_ op: @escaping () async throws -> T) throws -> T {
        var result: Result<T, Error>!
        let semaphore = DispatchSemaphore(value: 0)
        Task {
            do {
                result = .success(try await op())
            } catch {
                result = .failure(error)
            }
            semaphore.signal()
        }
        // The 15s ceiling is the test-level escape hatch. The
        // IPCClient.callTimeout (5s) should fire first on a hung
        // daemon and surface as a thrown error.
        if semaphore.wait(timeout: .now() + 15) == .timedOut {
            XCTFail("async test exceeded 15s ceiling")
            throw NSError(domain: "IPCIntegrationTests", code: 2)
        }
        return try result.get()
    }
}

/// Owns a temporary directory used as `HOME` and as the socket parent
/// for one test. `cleanup()` is idempotent and safe in `defer`.
private final class TempWorkdir {
    let root: URL
    let homePath: String
    let socketPath: String
    let logPath: String

    init() throws {
        // HOME goes under NSTemporaryDirectory so the daemon's config
        // resolve can write logs/cache without touching the runner's
        // real ~/Library.
        self.root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ofem-ipc-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        self.homePath = root.path
        self.logPath = root.appendingPathComponent("daemon.log").path
        // Socket path lives directly under /tmp with a short suffix.
        // macOS caps sockaddr_un.sun_path at 104 bytes; nesting the
        // socket under HOME would push past that limit and bind would
        // fail with EINVAL. Use a separate short prefix instead.
        let shortID = String(UUID().uuidString.prefix(8))
        self.socketPath = "/tmp/ofem-\(shortID).sock"
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
        // Socket lives outside `root` because of the 104-byte sun_path
        // cap. The daemon also removes it on graceful shutdown; this is
        // belt-and-braces for the kill path.
        try? FileManager.default.removeItem(atPath: socketPath)
    }
}
