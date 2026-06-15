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
    func writeReadRoundTrip() async throws {
        let store = try makeStore()
        let payload = Data([0x00, 0x01, 0xFF, 0xFE, 0x68, 0x69]) // includes non-UTF-8 bytes
        try await store.write(alias: "work", data: payload)
        let result = try store.read(alias: "work")
        #expect(result == payload)
    }

    @Test("read missing alias throws notFound")
    func readMissingThrowsNotFound() throws {
        let store = try makeStore()
        #expect(throws: FileTokenStoreError.self) {
            _ = try store.read(alias: "nope")
        }
        // Verify the error is specifically .notFound
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
    func deleteRemovesEntry() async throws {
        let store = try makeStore()
        try await store.write(alias: "work", data: Data("secret".utf8))
        try await store.delete(alias: "work")

        do {
            _ = try store.read(alias: "work")
            Issue.record("Expected notFound after delete")
        } catch FileTokenStoreError.notFound {
            // Expected — pass.
        }
    }

    @Test("delete missing alias is a no-op (not an error)")
    func deleteMissingIsNoop() async throws {
        let store = try makeStore()
        // Must not throw.
        try await store.delete(alias: "ghost")
    }

    // MARK: - Empty-value semantics

    @Test("write with empty Data() deletes the entry")
    func writeEmptyDataDeletes() async throws {
        let store = try makeStore()
        try await store.write(alias: "work", data: Data("secret".utf8))

        // Write empty — should delete.
        try await store.write(alias: "work", data: Data())

        do {
            _ = try store.read(alias: "work")
            Issue.record("Expected notFound after empty write")
        } catch FileTokenStoreError.notFound {
            // Expected — pass.
        }
    }

    @Test("write with empty Data() on missing entry is a no-op")
    func writeEmptyOnMissingIsNoop() async throws {
        let store = try makeStore()
        // No prior write — empty write must not throw.
        try await store.write(alias: "phantom", data: Data())
    }

    // MARK: - Multiple aliases

    @Test("different aliases are independent")
    func multipleAliasesIndependent() async throws {
        let store = try makeStore()
        let a = Data("payload-a".utf8)
        let b = Data("payload-b".utf8)

        try await store.write(alias: "alice", data: a)
        try await store.write(alias: "bob", data: b)

        #expect(try store.read(alias: "alice") == a)
        #expect(try store.read(alias: "bob") == b)

        try await store.delete(alias: "alice")

        do {
            _ = try store.read(alias: "alice")
            Issue.record("Expected notFound for alice after delete")
        } catch FileTokenStoreError.notFound { }

        #expect(try store.read(alias: "bob") == b, "bob must be unaffected by alice delete")
    }

    // MARK: - Alias encoding

    @Test("alias with slashes is handled safely")
    func aliasWithSlashes() async throws {
        let store = try makeStore()
        let alias = "some/tenant/path"
        let data = Data("token".utf8)
        try await store.write(alias: alias, data: data)
        #expect(try store.read(alias: alias) == data)
    }

    @Test("alias with non-ASCII characters is handled safely")
    func aliasWithNonASCII() async throws {
        let store = try makeStore()
        let alias = "werk-\u{00E9}-\u{00E0}"
        let data = Data("token-non-ascii".utf8)
        try await store.write(alias: alias, data: data)
        #expect(try store.read(alias: alias) == data)
    }

    // NOTE: The old test named "noAliasCollisions" used plain ASCII aliases
    // ("alias-a" vs "alias-b") which duplicated multipleAliasesIndependent and
    // proved nothing about collision resistance. It has been renamed to reflect
    // what it actually tests (tests-21).
    @Test("ASCII aliases that differ by one character produce distinct filenames")
    func asciiAliasesDifferByOneCharAreDistinct() async throws {
        let store = try makeStore()
        let a = Data("alias-a".utf8)
        let b = Data("alias-b".utf8)
        try await store.write(alias: "alias-a", data: a)
        try await store.write(alias: "alias-b", data: b)
        #expect(try store.read(alias: "alias-a") == a)
        #expect(try store.read(alias: "alias-b") == b)
    }

    // Real collision-resistance test: aliases that only differ after
    // URL / percent encoding or case folding — a naïve encoder might
    // produce the same filename for these pairs (tests-21).
    @Test("aliases differing only after percent-encoding produce distinct filenames")
    func aliasesWithPercentEncodingAmbiguityAreDistinct() async throws {
        let store = try makeStore()
        let aSlash = Data("token-slash".utf8)
        let aUnderscore = Data("token-underscore".utf8)
        try await store.write(alias: "a/b", data: aSlash)
        try await store.write(alias: "a_b", data: aUnderscore)
        #expect(try store.read(alias: "a/b") == aSlash)
        #expect(try store.read(alias: "a_b") == aUnderscore)
    }

    @Test("precomposed and decomposed Unicode aliases produce distinct filenames")
    func precomposedVsDecomposedAliasesAreDistinct() async throws {
        let store = try makeStore()
        let precomposed = "\u{00E9}"
        let decomposed  = "\u{0065}\u{0301}"
        let dataA = Data("precomposed".utf8)
        let dataB = Data("decomposed".utf8)
        try await store.write(alias: precomposed, data: dataA)
        try await store.write(alias: decomposed,  data: dataB)
        #expect(try store.read(alias: precomposed) == dataA)
        #expect(try store.read(alias: decomposed)  == dataB)
    }

    // MARK: - Overwrite

    @Test("second write overwrites first")
    func overwrite() async throws {
        let store = try makeStore()
        try await store.write(alias: "work", data: Data("old".utf8))
        try await store.write(alias: "work", data: Data("new".utf8))
        #expect(try store.read(alias: "work") == Data("new".utf8))
    }

    // MARK: - File permissions

    @Test("stored token file has 0600 permissions")
    func filePermissions() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "ofem-token-perm-\(UUID().uuidString)", directoryHint: .isDirectory)
        let store = try FileTokenStore(tokensDir: dir)

        try await store.write(alias: "work", data: Data("secret".utf8))

        // Reconstruct expected file path via the same hexStem helper.
        let hex = FileTokenStore.hexStem(alias: "work")
        let tokenFile = dir.appending(path: "\(hex).bin", directoryHint: .notDirectory)

        let attrs = try FileManager.default.attributesOfItem(
            atPath: tokenFile.path(percentEncoded: false)
        )
        let mode = attrs[.posixPermissions] as? Int
        #expect(mode == 0o600, "token file must be 0600, got \(String(format: "%o", mode ?? 0))")
    }

    // MARK: - Binary safety

    @Test("arbitrary binary payload round-trips correctly")
    func binaryPayloadRoundTrip() async throws {
        let store = try makeStore()
        var payload = Data()
        for i in 0..<4 {
            for b in 0...255 {
                payload.append(UInt8((b + i) % 256))
            }
        }
        try await store.write(alias: "binary", data: payload)
        #expect(try store.read(alias: "binary") == payload)
    }

    // MARK: - Concurrent safety

    @Test("concurrent writes to the same alias do not corrupt")
    func concurrentWritesSameAlias() async throws {
        let store = try makeStore()

        try await store.write(alias: "shared", data: Data("initial".utf8))

        await withTaskGroup(of: Void.self) { group in
            for i in 0..<20 {
                group.addTask {
                    let payload = Data("value-\(i)".utf8)
                    try? await store.write(alias: "shared", data: payload)
                }
            }
        }

        let result = try store.read(alias: "shared")
        #expect(!result.isEmpty)
    }

    @Test("concurrent writes to different aliases are independent")
    func concurrentWritesDifferentAliases() async throws {
        let store = try makeStore()
        let count = 20

        await withTaskGroup(of: Void.self) { group in
            for i in 0..<count {
                group.addTask {
                    try? await store.write(alias: "alias-\(i)", data: Data("payload-\(i)".utf8))
                }
            }
        }

        for i in 0..<count {
            let result = try store.read(alias: "alias-\(i)")
            #expect(result == Data("payload-\(i)".utf8))
        }
    }

    // MARK: - atomicUpdate

    @Test("atomicUpdate on missing alias receives empty Data and persists result")
    func atomicUpdateFirstWrite() async throws {
        let store = try makeStore()
        var callCount = 0

        try await store.atomicUpdate(alias: "fresh") { existing in
            callCount += 1
            #expect(existing.isEmpty, "first call must receive empty Data when no file exists")
            return Data("created".utf8)
        }

        #expect(callCount == 1)
        let result = try store.read(alias: "fresh")
        #expect(result == Data("created".utf8))
    }

    @Test("atomicUpdate read-modify-write round-trip")
    func atomicUpdateReadModifyWrite() async throws {
        let store = try makeStore()
        try await store.write(alias: "acct", data: Data("v1".utf8))

        try await store.atomicUpdate(alias: "acct") { existing in
            var updated = existing
            updated.append(Data("-patched".utf8))
            return updated
        }

        let result = try store.read(alias: "acct")
        #expect(result == Data("v1-patched".utf8))
    }

    @Test("atomicUpdate returning nil leaves the store unchanged")
    func atomicUpdateNilLeavesUnchanged() async throws {
        let store = try makeStore()
        let original = Data("keep-me".utf8)
        try await store.write(alias: "stable", data: original)

        try await store.atomicUpdate(alias: "stable") { _ in
            nil  // Signal: do not update.
        }

        let result = try store.read(alias: "stable")
        #expect(result == original)
    }

    @Test("atomicUpdate returning nil on missing entry stays missing")
    func atomicUpdateNilOnMissingStaysMissing() async throws {
        let store = try makeStore()

        try await store.atomicUpdate(alias: "void") { _ in nil }

        do {
            _ = try store.read(alias: "void")
            Issue.record("Expected notFound after nil atomicUpdate on missing entry")
        } catch FileTokenStoreError.notFound { }
    }

    @Test("atomicUpdate returning empty Data skips write; original entry remains")
    func atomicUpdateEmptyDataSkipsWrite() async throws {
        let store = try makeStore()
        try await store.write(alias: "going", data: Data("bye".utf8))

        // The `guard let data = newData, !data.isEmpty else { return }` branch
        // exits early — the original file is NOT removed.
        try await store.atomicUpdate(alias: "going") { _ in Data() }

        let result = try store.read(alias: "going")
        #expect(result == Data("bye".utf8),
                "atomicUpdate with empty return skips the write; original must still be present")
    }

    @Test("atomicUpdate propagates transform errors and leaves store unchanged")
    func atomicUpdateTransformErrorPropagate() async throws {
        let store = try makeStore()
        let original = Data("untouched".utf8)
        try await store.write(alias: "safe", data: original)

        struct TransformError: Error {}

        do {
            try await store.atomicUpdate(alias: "safe") { _ in
                throw TransformError()
            }
            Issue.record("Expected TransformError to propagate")
        } catch is TransformError {
            // Expected.
        }

        let result = try store.read(alias: "safe")
        #expect(result == original)
    }

    @Test("atomicUpdate result readable via read(alias:)")
    func atomicUpdateThenRead() async throws {
        let store = try makeStore()
        let payload = Data([0xDE, 0xAD, 0xBE, 0xEF])

        try await store.atomicUpdate(alias: "bin") { _ in payload }
        let result = try store.read(alias: "bin")
        #expect(result == payload)
    }

    @Test("atomicUpdate and write interleave correctly on same alias")
    func atomicUpdateInterleaveWithWrite() async throws {
        let store = try makeStore()
        try await store.write(alias: "seq", data: Data("step1".utf8))

        try await store.atomicUpdate(alias: "seq") { existing in
            var d = existing
            d.append(Data("|step2".utf8))
            return d
        }

        try await store.write(alias: "seq", data: Data("step3".utf8))

        let result = try store.read(alias: "seq")
        #expect(result == Data("step3".utf8))
    }

    @Test("concurrent atomicUpdate calls on the same alias are serialised")
    func concurrentAtomicUpdates() async throws {
        let store = try makeStore()

        func encode(_ n: UInt32) -> Data { Data(String(format: "%010u", n).utf8) }
        func decode(_ d: Data) -> UInt32 {
            UInt32(String(data: d, encoding: .utf8)?.trimmingCharacters(in: .whitespaces) ?? "0") ?? 0
        }

        try await store.write(alias: "counter", data: encode(0))

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<20 {
                group.addTask {
                    try? await store.atomicUpdate(alias: "counter") { existing in
                        let n = existing.isEmpty ? 0 : decode(existing)
                        return encode(n + 1)
                    }
                }
            }
        }

        let final = try store.read(alias: "counter")
        #expect(decode(final) == 20)
    }

    // MARK: - Directory permissions

    @Test("tokens directory is created with 0700 permissions")
    func tokensDirPermissions() throws {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "ofem-token-dirperm-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: dir) }

        _ = try FileTokenStore(tokensDir: dir)

        let attrs = try FileManager.default.attributesOfItem(atPath: dir.path(percentEncoded: false))
        let mode = attrs[.posixPermissions] as? Int
        #expect(mode == 0o700, "tokens dir must be 0700, got \(String(format: "%o", mode ?? 0))")
    }

    // MARK: - Lock sidecar file

    @Test("delete leaves the .lock sidecar file in place")
    func deleteKeepsLockSidecar() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "ofem-token-lock-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try FileTokenStore(tokensDir: dir)

        try await store.write(alias: "sidecar", data: Data("x".utf8))
        try await store.delete(alias: "sidecar")

        let hex = FileTokenStore.hexStem(alias: "sidecar")
        let binURL  = dir.appending(path: "\(hex).bin",  directoryHint: .notDirectory)
        let lockURL = dir.appending(path: "\(hex).lock", directoryHint: .notDirectory)

        #expect(!FileManager.default.fileExists(atPath: binURL.path(percentEncoded: false)),
                ".bin file must be removed after delete")
        #expect(FileManager.default.fileExists(atPath: lockURL.path(percentEncoded: false)),
                ".lock sidecar must NOT be deleted")
    }

    // MARK: - Shared serial queue registry

    @Test("two stores for the same directory share a serial queue (no deadlock)")
    func twoStoresSameDirectorySharedQueue() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "ofem-token-shared-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: dir) }

        let store1 = try FileTokenStore(tokensDir: dir)
        let store2 = try FileTokenStore(tokensDir: dir)

        try await store1.write(alias: "ping", data: Data("from-1".utf8))
        #expect(try store2.read(alias: "ping") == Data("from-1".utf8))

        try await store2.write(alias: "ping", data: Data("from-2".utf8))
        #expect(try store1.read(alias: "ping") == Data("from-2".utf8))
    }

    // MARK: - createDirectoryFailed error

    @Test("init throws createDirectoryFailed when parent directory is read-only")
    func initThrowsWhenDirectoryCreationFails() throws {
        let parent = FileManager.default.temporaryDirectory
            .appending(path: "ofem-ro-parent-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: parent,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o500]   // r-x: no write
        )
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700],
                                                    ofItemAtPath: parent.path(percentEncoded: false))
            try? FileManager.default.removeItem(at: parent)
        }

        let tokensDir = parent.appending(path: "tokens", directoryHint: .isDirectory)
        do {
            _ = try FileTokenStore(tokensDir: tokensDir)
            Issue.record("Expected createDirectoryFailed when parent is read-only")
        } catch FileTokenStoreError.createDirectoryFailed {
            // Expected.
        }
    }

    // MARK: - readFailed for non-ENOENT errors

    @Test("read throws readFailed when path is a directory instead of a file")
    func readFailedWhenPathIsDirectory() throws {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "ofem-token-readfail-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try FileTokenStore(tokensDir: dir)

        let hex = FileTokenStore.hexStem(alias: "dir-alias")
        let imposterURL = dir.appending(path: "\(hex).bin", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: imposterURL,
            withIntermediateDirectories: false,
            attributes: nil
        )

        do {
            _ = try store.read(alias: "dir-alias")
            Issue.record("Expected readFailed when path is a directory")
        } catch FileTokenStoreError.readFailed(let alias, _) {
            #expect(alias == "dir-alias")
        }
    }

    // MARK: - notFound carries correct alias

    @Test("notFound error carries the requested alias")
    func notFoundCarriesAlias() throws {
        let store = try makeStore()
        let alias = "specifically-this-one"
        do {
            _ = try store.read(alias: alias)
            Issue.record("Expected notFound")
        } catch FileTokenStoreError.notFound(let reported) {
            #expect(reported == alias)
        }
    }

    // MARK: - Large payload

    @Test("atomicUpdate persists a large payload (512 KB)")
    func atomicUpdateLargePayload() async throws {
        let store = try makeStore()
        var payload = Data(repeating: 0, count: 512 * 1024)
        for i in payload.indices { payload[i] = UInt8(i % 251) }

        try await store.atomicUpdate(alias: "big") { _ in payload }
        let result = try store.read(alias: "big")
        #expect(result == payload)
    }

    // MARK: - write then atomicUpdate sees written value

    @Test("write then atomicUpdate receives the previously written value")
    func writeBeforeAtomicUpdateSeesValue() async throws {
        let store = try makeStore()
        try await store.write(alias: "acc", data: Data("base".utf8))

        var received: Data?
        try await store.atomicUpdate(alias: "acc") { existing in
            received = existing
            return existing
        }

        #expect(received == Data("base".utf8))
    }

    // MARK: - hexStem consistency

    @Test("hexStem produces consistent output for .bin and .lock paths")
    func hexStemConsistency() {
        // Both tokenURL and aliasLockURL use hexStem — verify the stem is stable.
        let alias = "contoso.work"
        let stem1 = FileTokenStore.hexStem(alias: alias)
        let stem2 = FileTokenStore.hexStem(alias: alias)
        #expect(stem1 == stem2)
        // Known value for "contoso.work" encoded as UTF-8 hex.
        let expected = Data("contoso.work".utf8).map { String(format: "%02x", $0) }.joined()
        #expect(stem1 == expected)
    }

    // MARK: - async lock does not block cooperative pool

    @Test("write from async context completes without deadlock")
    func asyncWriteNoDeadlock() async throws {
        let store = try makeStore()
        // If the lock acquisition blocked a cooperative-pool thread, this
        // test would hang. Completion is the assertion.
        try await store.write(alias: "async-test", data: Data("hello".utf8))
        let result = try store.read(alias: "async-test")
        #expect(result == Data("hello".utf8))
    }
}
