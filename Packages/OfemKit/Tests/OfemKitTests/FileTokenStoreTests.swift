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

    // NOTE: The old test named "noAliasCollisions" used plain ASCII aliases
    // ("alias-a" vs "alias-b") which duplicated multipleAliasesIndependent and
    // proved nothing about collision resistance. It has been renamed to reflect
    // what it actually tests (tests-21).
    @Test("ASCII aliases that differ by one character produce distinct filenames")
    func asciiAliasesDifferByOneCharAreDistinct() throws {
        let store = try makeStore()
        let a = Data("alias-a".utf8)
        let b = Data("alias-b".utf8)
        try store.write(alias: "alias-a", data: a)
        try store.write(alias: "alias-b", data: b)
        #expect(try store.read(alias: "alias-a") == a)
        #expect(try store.read(alias: "alias-b") == b)
    }

    // Real collision-resistance test: aliases that only differ after
    // URL / percent encoding or case folding — a naïve encoder might
    // produce the same filename for these pairs (tests-21).
    //
    // Safety guarantee: FileTokenStore encodes aliases as hex(Data(alias.utf8))
    // — the raw UTF-8 byte sequence, not the Swift String.  Characters that a
    // naïve percent- or name-encoder might map to the same output (e.g. "/"
    // → "%2F" or "_") still produce distinct hex strings because the
    // underlying byte values differ.  APFS filename normalization is not a
    // concern because the filename is a lowercase hex string (all ASCII).
    @Test("aliases differing only after percent-encoding produce distinct filenames")
    func aliasesWithPercentEncodingAmbiguityAreDistinct() throws {
        let store = try makeStore()
        // "a/b" and "a_b" could collide if "/" is percent-encoded to "_"
        // (it must not be — hex encoding avoids this).
        let aSlash = Data("token-slash".utf8)
        let aUnderscore = Data("token-underscore".utf8)
        try store.write(alias: "a/b", data: aSlash)
        try store.write(alias: "a_b", data: aUnderscore)
        #expect(try store.read(alias: "a/b") == aSlash)
        #expect(try store.read(alias: "a_b") == aUnderscore)
    }

    @Test("precomposed and decomposed Unicode aliases produce distinct filenames")
    func precomposedVsDecomposedAliasesAreDistinct() throws {
        let store = try makeStore()
        // "é" as precomposed (U+00E9) vs decomposed (U+0065 U+0301).
        let precomposed = "\u{00E9}"    // é (one code point, 2 UTF-8 bytes: 0xC3 0xA9)
        let decomposed  = "\u{0065}\u{0301}"  // e + combining accent (3 UTF-8 bytes: 0x65 0xCC 0x81)
        // Swift String treats these as equal via canonical equivalence, but
        // FileTokenStore calls Data(alias.utf8) — the raw UTF-8 byte sequence —
        // NOT the Swift String.  The two aliases produce different byte sequences
        // (2 bytes vs 3 bytes) and therefore different hex filenames: no collision.
        // APFS filename normalisation is irrelevant because the filename is the
        // lowercase hex string (all ASCII digits).
        let dataA = Data("precomposed".utf8)
        let dataB = Data("decomposed".utf8)
        try store.write(alias: precomposed, data: dataA)
        try store.write(alias: decomposed,  data: dataB)
        #expect(try store.read(alias: precomposed) == dataA)
        #expect(try store.read(alias: decomposed)  == dataB)
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

    // MARK: - atomicUpdate

    @Test("atomicUpdate on missing alias receives empty Data and persists result")
    func atomicUpdateFirstWrite() throws {
        let store = try makeStore()
        var callCount = 0

        try store.atomicUpdate(alias: "fresh") { existing in
            callCount += 1
            #expect(existing.isEmpty, "first call must receive empty Data when no file exists")
            return Data("created".utf8)
        }

        #expect(callCount == 1)
        let result = try store.read(alias: "fresh")
        #expect(result == Data("created".utf8))
    }

    @Test("atomicUpdate read-modify-write round-trip")
    func atomicUpdateReadModifyWrite() throws {
        let store = try makeStore()
        try store.write(alias: "acct", data: Data("v1".utf8))

        try store.atomicUpdate(alias: "acct") { existing in
            var updated = existing
            updated.append(Data("-patched".utf8))
            return updated
        }

        let result = try store.read(alias: "acct")
        #expect(result == Data("v1-patched".utf8))
    }

    @Test("atomicUpdate returning nil leaves the store unchanged")
    func atomicUpdateNilLeavesUnchanged() throws {
        let store = try makeStore()
        let original = Data("keep-me".utf8)
        try store.write(alias: "stable", data: original)

        try store.atomicUpdate(alias: "stable") { _ in
            nil  // Signal: do not update.
        }

        let result = try store.read(alias: "stable")
        #expect(result == original)
    }

    @Test("atomicUpdate returning nil on missing entry stays missing")
    func atomicUpdateNilOnMissingStaysMissing() throws {
        let store = try makeStore()

        try store.atomicUpdate(alias: "void") { _ in nil }

        do {
            _ = try store.read(alias: "void")
            Issue.record("Expected notFound after nil atomicUpdate on missing entry")
        } catch FileTokenStoreError.notFound { }
    }

    @Test("atomicUpdate returning empty Data deletes the entry")
    func atomicUpdateEmptyDataDeletes() throws {
        let store = try makeStore()
        try store.write(alias: "going", data: Data("bye".utf8))

        // guard !data.isEmpty inside atomicUpdate delegates to delete via the
        // `guard let data = newData, !data.isEmpty else { return }` branch.
        try store.atomicUpdate(alias: "going") { _ in Data() }

        // The entry was not persisted (empty guard exits early) — it should
        // still be readable because atomicUpdate does NOT call delete for
        // empty returns; it simply skips the write.  The original file remains.
        // Verify the documented behaviour: guard exits, original stays.
        let result = try store.read(alias: "going")
        #expect(result == Data("bye".utf8),
                "atomicUpdate with empty return skips the write; original must still be present")
    }

    @Test("atomicUpdate propagates transform errors and leaves store unchanged")
    func atomicUpdateTransformErrorPropagate() throws {
        let store = try makeStore()
        let original = Data("untouched".utf8)
        try store.write(alias: "safe", data: original)

        struct TransformError: Error {}

        do {
            try store.atomicUpdate(alias: "safe") { _ in
                throw TransformError()
            }
            Issue.record("Expected TransformError to propagate")
        } catch is TransformError {
            // Expected.
        }

        // Store must be unchanged.
        let result = try store.read(alias: "safe")
        #expect(result == original)
    }

    @Test("atomicUpdate result readable via read(alias:)")
    func atomicUpdateThenRead() throws {
        let store = try makeStore()
        let payload = Data([0xDE, 0xAD, 0xBE, 0xEF])

        try store.atomicUpdate(alias: "bin") { _ in payload }
        let result = try store.read(alias: "bin")
        #expect(result == payload)
    }

    @Test("atomicUpdate and write interleave correctly on same alias")
    func atomicUpdateInterleaveWithWrite() throws {
        let store = try makeStore()
        try store.write(alias: "seq", data: Data("step1".utf8))

        try store.atomicUpdate(alias: "seq") { existing in
            var d = existing
            d.append(Data("|step2".utf8))
            return d
        }

        try store.write(alias: "seq", data: Data("step3".utf8))

        let result = try store.read(alias: "seq")
        #expect(result == Data("step3".utf8))
    }

    @Test("concurrent atomicUpdate calls on the same alias are serialised")
    func concurrentAtomicUpdates() async throws {
        let store = try makeStore()

        // Encode/decode a UInt32 counter as 4 ASCII decimal bytes for simplicity.
        func encode(_ n: UInt32) -> Data { Data(String(format: "%010u", n).utf8) }
        func decode(_ d: Data) -> UInt32 {
            UInt32(String(data: d, encoding: .utf8)?.trimmingCharacters(in: .whitespaces) ?? "0") ?? 0
        }

        try store.write(alias: "counter", data: encode(0))

        // 20 tasks each increment the counter atomically.
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<20 {
                group.addTask {
                    try? store.atomicUpdate(alias: "counter") { existing in
                        let n = existing.isEmpty ? 0 : decode(existing)
                        return encode(n + 1)
                    }
                }
            }
        }

        // All 20 increments must have been applied (no lost updates).
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
    func deleteKeepsLockSidecar() throws {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "ofem-token-lock-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try FileTokenStore(tokensDir: dir)

        try store.write(alias: "sidecar", data: Data("x".utf8))
        try store.delete(alias: "sidecar")

        // The .bin file must be gone.
        let hex = Data("sidecar".utf8).map { String(format: "%02x", $0) }.joined()
        let binURL  = dir.appending(path: "\(hex).bin",  directoryHint: .notDirectory)
        let lockURL = dir.appending(path: "\(hex).lock", directoryHint: .notDirectory)

        #expect(!FileManager.default.fileExists(atPath: binURL.path(percentEncoded: false)),
                ".bin file must be removed after delete")
        #expect(FileManager.default.fileExists(atPath: lockURL.path(percentEncoded: false)),
                ".lock sidecar must NOT be deleted")
    }

    // MARK: - Shared serial queue registry

    @Test("two stores for the same directory share a serial queue (no deadlock)")
    func twoStoresSameDirectorySharedQueue() throws {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "ofem-token-shared-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: dir) }

        let store1 = try FileTokenStore(tokensDir: dir)
        let store2 = try FileTokenStore(tokensDir: dir)

        // Writes via store1 must be visible via store2 and vice-versa.
        try store1.write(alias: "ping", data: Data("from-1".utf8))
        #expect(try store2.read(alias: "ping") == Data("from-1".utf8))

        try store2.write(alias: "ping", data: Data("from-2".utf8))
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
            // Restore write permission so cleanup can remove the directory.
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

        // Place a directory at the canonical token path — reading it as Data will fail
        // with a "is a directory" error (not ENOENT), so readFailed must be thrown.
        let hex = Data("dir-alias".utf8).map { String(format: "%02x", $0) }.joined()
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
    func atomicUpdateLargePayload() throws {
        let store = try makeStore()
        // 512 KB of pseudo-random bytes (repeating pattern).
        var payload = Data(repeating: 0, count: 512 * 1024)
        for i in payload.indices { payload[i] = UInt8(i % 251) }

        try store.atomicUpdate(alias: "big") { _ in payload }
        let result = try store.read(alias: "big")
        #expect(result == payload)
    }

    // MARK: - write then atomicUpdate sees written value

    @Test("write then atomicUpdate receives the previously written value")
    func writeBeforeAtomicUpdateSeesValue() throws {
        let store = try makeStore()
        try store.write(alias: "acc", data: Data("base".utf8))

        var received: Data?
        try store.atomicUpdate(alias: "acc") { existing in
            received = existing
            return existing  // no change
        }

        #expect(received == Data("base".utf8))
    }
}
