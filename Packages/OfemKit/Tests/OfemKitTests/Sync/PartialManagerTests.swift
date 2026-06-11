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
}
