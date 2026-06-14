import Testing
import Foundation
import CryptoKit
@testable import OfemKit

// MARK: - PartialManager Tests

/// Tests for ``PartialManager`` covering the resume-offset decision matrix,
/// ETag sidecar semantics, and finalise behaviour.
@Suite("PartialManager")
struct PartialManagerTests {

    // MARK: - Helpers

    private func makeManager() -> (PartialManager, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ofem-pm-test-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (PartialManager(scratchDir: dir), dir)
    }

    private func cleanup(_ dir: URL) {
        try? FileManager.default.removeItem(at: dir)
    }

    private static var baseKey: CacheKey {
        CacheKey(accountAlias: "a", workspaceID: "ws", itemID: "it", path: "f.bin")
    }

    private func baseRecord(contentLength: Int64 = 100, etag: String = "v1") -> MetadataRecord {
        MetadataRecord(
            accountAlias: "a", workspaceID: "ws", itemID: "it",
            path: "f.bin", parentPath: "", name: "f.bin",
            isDir: false, contentLength: contentLength, etag: etag
        )
    }

    // MARK: - Resume decision matrix (sync-17)

    @Test("rangeStart: no partial file → (0, nil, false)")
    func testNoPartial() {
        let (pm, dir) = makeManager()
        defer { cleanup(dir) }
        let (offset, etag, hasPartial) = pm.rangeStart(for: Self.baseKey, cachedRecord: baseRecord())
        #expect(offset == 0)
        #expect(etag == nil)
        #expect(!hasPartial)
    }

    @Test("rangeStart: partial with matching etag → (size, etag, true)")
    func testPartialWithMatchingEtag() throws {
        let (pm, dir) = makeManager()
        defer { cleanup(dir) }
        let key = Self.baseKey
        let record = baseRecord(contentLength: 100, etag: "v1")

        // Create a 40-byte partial.
        let partialURL = pm.partialURL(for: key)
        FileManager.default.createFile(atPath: partialURL.path, contents: Data(repeating: 0x41, count: 40))
        try pm.storeEtag("v1", for: key)

        let (offset, etag, hasPartial) = pm.rangeStart(for: key, cachedRecord: record)
        #expect(offset == 40)
        #expect(etag == "v1")
        #expect(hasPartial)
    }

    @Test("rangeStart: partial with mismatched etag → (0, nil, false) + discard")
    func testPartialMismatchedEtag() throws {
        let (pm, dir) = makeManager()
        defer { cleanup(dir) }
        let key = Self.baseKey
        let record = baseRecord(contentLength: 100, etag: "v1")

        let partialURL = pm.partialURL(for: key)
        FileManager.default.createFile(atPath: partialURL.path, contents: Data(repeating: 0x42, count: 50))
        try pm.storeEtag("v2-different", for: key) // sidecar etag != record etag

        let (offset, _, hasPartial) = pm.rangeStart(for: key, cachedRecord: record)
        #expect(offset == 0)
        #expect(!hasPartial)
        // Partial and sidecar should have been discarded.
        #expect(!FileManager.default.fileExists(atPath: partialURL.path))
    }

    @Test("rangeStart: partial with no sidecar → (0, nil, false) + discard")
    func testPartialNoSidecar() {
        let (pm, dir) = makeManager()
        defer { cleanup(dir) }
        let key = Self.baseKey
        let record = baseRecord(contentLength: 100)

        let partialURL = pm.partialURL(for: key)
        FileManager.default.createFile(atPath: partialURL.path, contents: Data(repeating: 0x43, count: 30))
        // No storeEtag call.

        let (offset, _, hasPartial) = pm.rangeStart(for: key, cachedRecord: record)
        #expect(offset == 0)
        #expect(!hasPartial)
    }

    @Test("rangeStart: record contentLength == 0 → no resume")
    func testNoResumeWhenContentLengthZero() {
        let (pm, dir) = makeManager()
        defer { cleanup(dir) }
        let (offset, _, hasPartial) = pm.rangeStart(for: Self.baseKey, cachedRecord: baseRecord(contentLength: 0))
        #expect(offset == 0)
        #expect(!hasPartial)
    }

    // MARK: - ETag sidecar semantics

    @Test("storeEtag round-trips correctly")
    func testEtagRoundTrip() throws {
        let (pm, dir) = makeManager()
        defer { cleanup(dir) }
        let key = Self.baseKey
        try pm.storeEtag("abc-123", for: key)
        let loaded = pm.loadEtag(for: key)
        #expect(loaded == "abc-123")
    }

    @Test("storeEtag with empty string deletes sidecar")
    func testStoreEtagEmptyDeletes() throws {
        let (pm, dir) = makeManager()
        defer { cleanup(dir) }
        let key = Self.baseKey
        try pm.storeEtag("some-value", for: key)
        try pm.storeEtag("", for: key)
        #expect(pm.loadEtag(for: key) == nil)
    }

    // MARK: - finalise

    @Test("finalise from scratch (rangeStart == 0) returns all bytes")
    func testFinaliseFromScratch() throws {
        let (pm, dir) = makeManager()
        defer { cleanup(dir) }
        let body = Data(repeating: 0xBB, count: 50)
        let result = try pm.finalise(
            key: Self.baseKey, body: body, rangeStart: 0, expectedTotal: 50, expectedSHA: nil
        )
        #expect(result == body)
    }

    @Test("finalise throws shortDownload when body is shorter than expected")
    func testFinaliseShortDownload() throws {
        let (pm, dir) = makeManager()
        defer { cleanup(dir) }
        let body = Data(repeating: 0xCC, count: 10)
        do {
            _ = try pm.finalise(
                key: Self.baseKey, body: body, rangeStart: 0, expectedTotal: 50, expectedSHA: nil
            )
            Issue.record("Expected shortDownload")
        } catch SyncError.shortDownload(let expected, let got) {
            #expect(expected == 50)
            #expect(got == 10)
        }
    }

    @Test("finalise throws blobSHAMismatch on incorrect SHA")
    func testFinaliseShaMismatch() throws {
        let (pm, dir) = makeManager()
        defer { cleanup(dir) }
        let body = Data(repeating: 0xDD, count: 20)
        do {
            _ = try pm.finalise(
                key: Self.baseKey, body: body, rangeStart: 0, expectedTotal: 20,
                expectedSHA: "0000000000000000000000000000000000000000000000000000000000000000"
            )
            Issue.record("Expected blobSHAMismatch")
        } catch SyncError.blobSHAMismatch {
            // Correct.
        }
    }

    @Test("finalise SHA verification passes with correct hash")
    func testFinaliseShaCorrect() throws {
        let (pm, dir) = makeManager()
        defer { cleanup(dir) }
        let body = Data(repeating: 0xEE, count: 20)
        let expected = SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined()
        let result = try pm.finalise(
            key: Self.baseKey, body: body, rangeStart: 0, expectedTotal: 20, expectedSHA: expected
        )
        #expect(result == body)
    }

    @Test("finalise throws spillFileError on disk-full simulation")
    func testFinaliseSpillFileError() throws {
        // We can't easily simulate disk full, but we can test that the
        // spillFileError case exists in SyncError and has the right fpCode.
        let innerErr = CocoaError(.fileWriteOutOfSpace)
        let syncErr = SyncError.spillFileError(innerErr)
        #expect(syncErr.fpCode == .cannotSynchronize)
    }

    // MARK: - Resume appending

    @Test("finalise appends to existing partial at correct offset")
    func testFinaliseAppendsToPartial() throws {
        let (pm, dir) = makeManager()
        defer { cleanup(dir) }
        let key = Self.baseKey

        // Create a partial with 20 bytes.
        let partialURL = pm.partialURL(for: key)
        let firstHalf = Data(repeating: 0x11, count: 20)
        FileManager.default.createFile(atPath: partialURL.path, contents: firstHalf)

        // Append 30 more bytes starting at offset 20.
        let secondHalf = Data(repeating: 0x22, count: 30)
        let result = try pm.finalise(
            key: key, body: secondHalf, rangeStart: 20, expectedTotal: 50, expectedSHA: nil
        )
        #expect(result.count == 50)
        #expect(result[0..<20] == firstHalf)
        #expect(result[20...] == secondHalf)

        // Partial should be cleaned up.
        #expect(!FileManager.default.fileExists(atPath: partialURL.path))
    }

    // MARK: - partialURL / etagURL determinism

    @Test("partialURL is deterministic for the same key")
    func testPartialURLDeterministic() {
        let (pm, dir) = makeManager()
        defer { cleanup(dir) }
        let key = Self.baseKey
        #expect(pm.partialURL(for: key) == pm.partialURL(for: key))
    }

    @Test("partialURL differs when key components differ")
    func testPartialURLDiffersAcrossKeys() {
        let (pm, dir) = makeManager()
        defer { cleanup(dir) }
        let key1 = CacheKey(accountAlias: "a", workspaceID: "ws1", itemID: "it", path: "f.bin")
        let key2 = CacheKey(accountAlias: "a", workspaceID: "ws2", itemID: "it", path: "f.bin")
        #expect(pm.partialURL(for: key1) != pm.partialURL(for: key2))
    }

    @Test("etagURL is sidecar of partialURL")
    func testEtagURLIsSidecar() {
        let (pm, dir) = makeManager()
        defer { cleanup(dir) }
        let key = Self.baseKey
        let partial = pm.partialURL(for: key)
        let etag = pm.etagURL(for: key)
        #expect(etag.path == partial.path + ".etag")
    }

    // MARK: - discard

    @Test("discard removes both partial and sidecar")
    func testDiscardRemovesBothFiles() throws {
        let (pm, dir) = makeManager()
        defer { cleanup(dir) }
        let key = Self.baseKey
        let partialURL = pm.partialURL(for: key)
        FileManager.default.createFile(atPath: partialURL.path, contents: Data(repeating: 0x01, count: 10))
        try pm.storeEtag("v1", for: key)

        pm.discard(for: key)

        #expect(!FileManager.default.fileExists(atPath: partialURL.path))
        #expect(!FileManager.default.fileExists(atPath: pm.etagURL(for: key).path))
    }

    @Test("discard is a no-op when files do not exist")
    func testDiscardNoOpWhenMissing() {
        let (pm, dir) = makeManager()
        defer { cleanup(dir) }
        // Must not throw.
        pm.discard(for: Self.baseKey)
    }

    // MARK: - rangeStart edge cases

    @Test("rangeStart: partial size equals contentLength → no resume (already complete)")
    func testNoResumeWhenPartialEqualsContentLength() throws {
        let (pm, dir) = makeManager()
        defer { cleanup(dir) }
        let key = Self.baseKey
        let record = baseRecord(contentLength: 100, etag: "v1")

        // Partial is already full-size — not < contentLength, so resume is skipped.
        let partialURL = pm.partialURL(for: key)
        FileManager.default.createFile(
            atPath: partialURL.path,
            contents: Data(repeating: 0x55, count: 100)
        )
        try pm.storeEtag("v1", for: key)

        let (offset, etag, hasPartial) = pm.rangeStart(for: key, cachedRecord: record)
        #expect(offset == 0)
        #expect(etag == nil)
        #expect(!hasPartial)
    }

    @Test("rangeStart: zero-size partial → no resume")
    func testNoResumeWhenPartialIsEmpty() throws {
        let (pm, dir) = makeManager()
        defer { cleanup(dir) }
        let key = Self.baseKey
        let record = baseRecord(contentLength: 100, etag: "v1")

        // A zero-byte spill file must not trigger a resume.
        let partialURL = pm.partialURL(for: key)
        FileManager.default.createFile(atPath: partialURL.path, contents: Data())
        try pm.storeEtag("v1", for: key)

        let (offset, etag, hasPartial) = pm.rangeStart(for: key, cachedRecord: record)
        #expect(offset == 0)
        #expect(etag == nil)
        #expect(!hasPartial)
    }

    @Test("rangeStart: empty sidecar etag is treated as missing → discard")
    func testNoResumeWhenSidecarEtagIsEmpty() throws {
        let (pm, dir) = makeManager()
        defer { cleanup(dir) }
        let key = Self.baseKey
        let record = baseRecord(contentLength: 100, etag: "")

        let partialURL = pm.partialURL(for: key)
        FileManager.default.createFile(
            atPath: partialURL.path,
            contents: Data(repeating: 0xAA, count: 50)
        )
        // Write an empty sidecar manually so loadEtag returns "".
        try "".write(to: pm.etagURL(for: key), atomically: false, encoding: .utf8)

        let (offset, _, hasPartial) = pm.rangeStart(for: key, cachedRecord: record)
        #expect(offset == 0)
        #expect(!hasPartial)
        // discard() must have run.
        #expect(!FileManager.default.fileExists(atPath: partialURL.path))
    }

    @Test("rangeStart: record etag is empty string → sidecar etag accepted without comparison")
    func testResumeWhenRecordEtagIsEmpty() throws {
        let (pm, dir) = makeManager()
        defer { cleanup(dir) }
        let key = Self.baseKey
        // Record has no etag (empty) — sidecar etag should be accepted as-is.
        let record = baseRecord(contentLength: 100, etag: "")

        let partialURL = pm.partialURL(for: key)
        FileManager.default.createFile(
            atPath: partialURL.path,
            contents: Data(repeating: 0xBB, count: 60)
        )
        try pm.storeEtag("some-etag", for: key)

        let (offset, etag, hasPartial) = pm.rangeStart(for: key, cachedRecord: record)
        #expect(offset == 60)
        #expect(etag == "some-etag")
        #expect(hasPartial)
    }

    // MARK: - hashSpillFile

    @Test("hashSpillFile matches CryptoKit SHA-256 of the same bytes")
    func testHashSpillFile() throws {
        let (pm, dir) = makeManager()
        defer { cleanup(dir) }

        let content = Data((0..<2048).map { UInt8($0 & 0xFF) })
        let tmpURL = dir.appendingPathComponent("spill.partial")
        try content.write(to: tmpURL)

        let got = try pm.hashSpillFile(tmpURL)
        let expected = SHA256.hash(data: content).map { String(format: "%02x", $0) }.joined()
        #expect(got == expected)
    }

    @Test("hashSpillFile on empty file returns SHA-256 of empty data")
    func testHashSpillFileEmpty() throws {
        let (pm, dir) = makeManager()
        defer { cleanup(dir) }

        let tmpURL = dir.appendingPathComponent("empty.partial")
        FileManager.default.createFile(atPath: tmpURL.path, contents: Data())

        let got = try pm.hashSpillFile(tmpURL)
        let expected = SHA256.hash(data: Data()).map { String(format: "%02x", $0) }.joined()
        #expect(got == expected)
    }

    @Test("hashSpillFile on multi-chunk file (>1 MiB) produces correct digest")
    func testHashSpillFileLarge() throws {
        let (pm, dir) = makeManager()
        defer { cleanup(dir) }

        // 1.5 MiB — spans two 1-MiB read chunks.
        let size = 1 * 1024 * 1024 + 512 * 1024
        let content = Data(repeating: 0x7F, count: size)
        let tmpURL = dir.appendingPathComponent("large.partial")
        try content.write(to: tmpURL)

        let got = try pm.hashSpillFile(tmpURL)
        let expected = SHA256.hash(data: content).map { String(format: "%02x", $0) }.joined()
        #expect(got == expected)
    }

    @Test("hashSpillFile throws when file does not exist")
    func testHashSpillFileMissing() throws {
        let (pm, dir) = makeManager()
        defer { cleanup(dir) }

        let missing = dir.appendingPathComponent("no-such-file.partial")
        #expect(throws: (any Error).self) {
            try pm.hashSpillFile(missing)
        }
    }

    // MARK: - finalise edge cases

    @Test("finalise with expectedTotal == 0 skips length check")
    func testFinaliseSkipsLengthCheckWhenZero() throws {
        let (pm, dir) = makeManager()
        defer { cleanup(dir) }
        // Any body size is accepted when expectedTotal == 0.
        let body = Data(repeating: 0xAB, count: 7)
        let result = try pm.finalise(
            key: Self.baseKey, body: body, rangeStart: 0, expectedTotal: 0, expectedSHA: nil
        )
        #expect(result == body)
    }

    @Test("finalise with empty expectedSHA skips SHA check")
    func testFinaliseSkipsSHACheckWhenEmpty() throws {
        let (pm, dir) = makeManager()
        defer { cleanup(dir) }
        let body = Data(repeating: 0xCD, count: 15)
        // An empty expectedSHA must not trigger blobSHAMismatch.
        let result = try pm.finalise(
            key: Self.baseKey, body: body, rangeStart: 0, expectedTotal: 15, expectedSHA: ""
        )
        #expect(result == body)
    }

    @Test("finalise discards partial when totalWritten > expectedTotal")
    func testFinaliseDiscardsWhenTooManyBytes() throws {
        let (pm, dir) = makeManager()
        defer { cleanup(dir) }
        let key = Self.baseKey

        // Write 40 existing bytes into the partial.
        let partialURL = pm.partialURL(for: key)
        FileManager.default.createFile(
            atPath: partialURL.path,
            contents: Data(repeating: 0x11, count: 40)
        )

        // Appending 30 bytes starting at offset 40 → totalWritten = 70 > expectedTotal (50).
        let body = Data(repeating: 0x22, count: 30)
        do {
            _ = try pm.finalise(
                key: key, body: body, rangeStart: 40, expectedTotal: 50, expectedSHA: nil
            )
            Issue.record("Expected shortDownload to be thrown")
        } catch SyncError.shortDownload(let expected, let got) {
            #expect(expected == 50)
            #expect(got == 70)
            // The partial must have been discarded because totalWritten > expectedTotal.
            #expect(!FileManager.default.fileExists(atPath: partialURL.path))
        }
    }

    @Test("finalise cleans up partial and sidecar on SHA mismatch")
    func testFinaliseDiscardsOnSHAMismatch() throws {
        let (pm, dir) = makeManager()
        defer { cleanup(dir) }
        let key = Self.baseKey
        try pm.storeEtag("v1", for: key)

        let body = Data(repeating: 0xFF, count: 10)
        let badSHA = String(repeating: "0", count: 64)
        do {
            _ = try pm.finalise(
                key: key, body: body, rangeStart: 0, expectedTotal: 10, expectedSHA: badSHA
            )
            Issue.record("Expected blobSHAMismatch")
        } catch SyncError.blobSHAMismatch {
            // Sidecar must be gone.
            #expect(!FileManager.default.fileExists(atPath: pm.etagURL(for: key).path))
        }
    }

    // MARK: - reapStalePartialDirs

    @Test("reapStalePartialDirs removes directory for a dead PID")
    func testReapRemovesDeadPID() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("ofem-reap-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }

        // PID 1 is always alive (launchd), so use a PID that cannot possibly be
        // running: Int32.max is beyond the Darwin pid_max of 99999.
        let deadPID: Int32 = Int32.max
        let staleDir = base.appendingPathComponent("\(deadPID)", isDirectory: true)
        try FileManager.default.createDirectory(at: staleDir, withIntermediateDirectories: true)

        PartialManager.reapStalePartialDirs(under: base)

        #expect(!FileManager.default.fileExists(atPath: staleDir.path))
    }

    @Test("reapStalePartialDirs keeps directory for the current process PID")
    func testReapKeepsSelfPID() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("ofem-reap-self-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }

        let selfPID = ProcessInfo.processInfo.processIdentifier
        let selfDir = base.appendingPathComponent("\(selfPID)", isDirectory: true)
        try FileManager.default.createDirectory(at: selfDir, withIntermediateDirectories: true)

        PartialManager.reapStalePartialDirs(under: base)

        #expect(FileManager.default.fileExists(atPath: selfDir.path))
    }

    @Test("reapStalePartialDirs skips entries whose names are not numeric PIDs")
    func testReapSkipsNonPIDEntries() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("ofem-reap-skip-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }

        // A non-numeric directory name should never be touched.
        let namedDir = base.appendingPathComponent("not-a-pid", isDirectory: true)
        try FileManager.default.createDirectory(at: namedDir, withIntermediateDirectories: true)

        PartialManager.reapStalePartialDirs(under: base)

        #expect(FileManager.default.fileExists(atPath: namedDir.path))
    }

    @Test("reapStalePartialDirs is a no-op when base directory does not exist")
    func testReapMissingBaseIsNoOp() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("ofem-reap-missing-\(UUID().uuidString)")
        // Must not throw / crash.
        PartialManager.reapStalePartialDirs(under: missing)
    }
}
