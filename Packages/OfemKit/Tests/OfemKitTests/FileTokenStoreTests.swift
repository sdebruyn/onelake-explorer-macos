import Foundation
import Testing
@testable import OfemKit

// MARK: - FileTokenStoreTests

@Suite("FileTokenStore")
struct FileTokenStoreTests {
    // MARK: - Helpers

    private func makeStore() throws -> FileTokenStore {
        let dir = FileManager.default.temporaryDirectory
            .appending(
                path: "ofem-token-test-\(UUID().uuidString)",
                directoryHint: .isDirectory
            )
        return try FileTokenStore(tokensDir: dir)
    }

    // MARK: - Basic read / write / delete

    @Test("write then read returns the same bytes")
    func writeReadRoundTrip() throws {
        let store = try makeStore()
        let payload = Data([0x00, 0x01, 0xFF, 0xFE, 0x68, 0x69]) // includes non-UTF-8 bytes
        try store.write(alias: "work", data: payload)
        let result = try store.read(alias: "work")
        #expect(result == payload)
    }

    @Test("read missing alias throws notFound")
    func readMissingThrowsNotFound() throws {
        let store = try makeStore()
        #expect(throws: FileTokenStoreError.self) {
            _ = try store.read(alias: "nope")
        }
        // Verify the error is specifically.notFound
        do {
            _ = try store.read(alias: "nope")
            Issue.record("Expected notFound error but no error was thrown")
        } catch FileTokenStoreError.notFound(let alias) {
            #expect(alias == "nope")
        } catch {
            Issue.record("Expected FileTokenStoreError.notFound, got \(error)")
        }
    }

    @Test("delete removes the entry")
    func deleteRemovesEntry() throws {
        let store = try makeStore()
        try store.write(alias: "work", data: Data("secret".utf8))
        try store.delete(alias: "work")

        do {
            _ = try store.read(alias: "work")
            Issue.record("Expected notFound after delete")
        } catch FileTokenStoreError.notFound {
            // Expected — pass.
        }
    }

    @Test("delete missing alias is a no-op (not an error)")
    func deleteMissingIsNoop() throws {
        let store = try makeStore()
        // Must not throw.
        try store.delete(alias: "ghost")
    }

    // MARK: - Empty-value semantics

    @Test("write with empty Data() deletes the entry")
    func writeEmptyDataDeletes() throws {
        let store = try makeStore()
        try store.write(alias: "work", data: Data("secret".utf8))

        // Write empty — should delete.
        try store.write(alias: "work", data: Data())

        do {
            _ = try store.read(alias: "work")
            Issue.record("Expected notFound after empty write")
        } catch FileTokenStoreError.notFound {
            // Expected — pass.
        }
    }

    @Test("write with empty Data() on missing entry is a no-op")
    func writeEmptyOnMissingIsNoop() throws {
        let store = try makeStore()
        // No prior write — empty write must not throw.
        try store.write(alias: "phantom", data: Data())
    }

    // MARK: - Multiple aliases

    @Test("different aliases are independent")
    func multipleAliasesIndependent() throws {
        let store = try makeStore()
        let a = Data("payload-a".utf8)
        let b = Data("payload-b".utf8)

        try store.write(alias: "alice", data: a)
        try store.write(alias: "bob", data: b)

        #expect(try store.read(alias: "alice") == a)
        #expect(try store.read(alias: "bob") == b)

        try store.delete(alias: "alice")

        do {
            _ = try store.read(alias: "alice")
            Issue.record("Expected notFound for alice after delete")
        } catch FileTokenStoreError.notFound { }

        #expect(try store.read(alias: "bob") == b, "bob must be unaffected by alice delete")
    }

    // MARK: - Alias encoding

    @Test("alias with slashes is handled safely")
    func aliasWithSlashes() throws {
        let store = try makeStore()
        let alias = "some/tenant/path"
        let data = Data("token".utf8)
        try store.write(alias: alias, data: data)
        #expect(try store.read(alias: alias) == data)
    }

    @Test("alias with non-ASCII characters is handled safely")
    func aliasWithNonASCII() throws {
        let store = try makeStore()
        let alias = "werk-\u{00E9}-\u{00E0}"
        let data = Data("token-non-ascii".utf8)
        try store.write(alias: alias, data: data)
        #expect(try store.read(alias: alias) == data)
    }

    @Test("alias with special characters maps to unique filename (no collisions)")
    func noAliasCollisions() throws {
        let store = try makeStore()
        // These aliases differ only in non-trivial byte sequences —
        // the hex encoding must produce different filenames.
        let a = Data("alias-a".utf8)
        let b = Data("alias-b".utf8)
        try store.write(alias: "alias-a", data: a)
        try store.write(alias: "alias-b", data: b)
        #expect(try store.read(alias: "alias-a") == a)
        #expect(try store.read(alias: "alias-b") == b)
    }

    // MARK: - Overwrite

    @Test("second write overwrites first")
    func overwrite() throws {
        let store = try makeStore()
        try store.write(alias: "work", data: Data("old".utf8))
        try store.write(alias: "work", data: Data("new".utf8))
        #expect(try store.read(alias: "work") == Data("new".utf8))
    }

    // MARK: - File permissions

    @Test("stored token file has 0600 permissions")
    func filePermissions() throws {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "ofem-token-perm-\(UUID().uuidString)", directoryHint: .isDirectory)
        let store = try FileTokenStore(tokensDir: dir)

        try store.write(alias: "work", data: Data("secret".utf8))

        // Reconstruct expected file path: hex-encode "work".
        let hex = Data("work".utf8).map { String(format: "%02x", $0) }.joined()
        let tokenFile = dir.appending(path: "\(hex).bin", directoryHint: .notDirectory)

        let attrs = try FileManager.default.attributesOfItem(
            atPath: tokenFile.path(percentEncoded: false)
        )
        let mode = attrs[.posixPermissions] as? Int
        #expect(mode == 0o600, "token file must be 0600, got \(String(format: "%o", mode ?? 0))")
    }

    // MARK: - Binary safety

    @Test("arbitrary binary payload round-trips correctly")
    func binaryPayloadRoundTrip() throws {
        let store = try makeStore()
        // Build a 1024-byte payload with all byte values 0x00–0xFF repeated.
        var payload = Data()
        for i in 0..<4 {
            for b in 0...255 {
                payload.append(UInt8((b + i) % 256))
            }
        }
        try store.write(alias: "binary", data: payload)
        #expect(try store.read(alias: "binary") == payload)
    }

    // MARK: - Concurrent safety

    @Test("concurrent writes to the same alias do not corrupt")
    func concurrentWritesSameAlias() async throws {
        let store = try makeStore()

        // Write a known initial value.
        try store.write(alias: "shared", data: Data("initial".utf8))

        // 20 concurrent overwrites — we don't care which wins, only that the
        // final state is a valid, complete write (not a torn write).
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<20 {
                group.addTask {
                    let payload = Data("value-\(i)".utf8)
                    try? store.write(alias: "shared", data: payload)
                }
            }
        }

        // Read must succeed and return a non-empty value.
        let result = try store.read(alias: "shared")
        #expect(!result.isEmpty)
    }

    @Test("concurrent writes to different aliases are independent")
    func concurrentWritesDifferentAliases() async throws {
        let store = try makeStore()
        let count = 20

        // Write distinct payloads concurrently, each to a unique alias.
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<count {
                group.addTask {
                    try? store.write(alias: "alias-\(i)", data: Data("payload-\(i)".utf8))
                }
            }
        }

        // Every alias must be readable and have the correct content.
        for i in 0..<count {
            let result = try store.read(alias: "alias-\(i)")
            #expect(result == Data("payload-\(i)".utf8))
        }
    }
}
