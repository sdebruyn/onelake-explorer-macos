import CryptoKit
import Foundation
@testable import OfemKit
import Testing

// MARK: - PartialManager Tests

/// Tests for ``PartialManager`` covering the resume-offset decision matrix
/// and ETag sidecar semantics. `finalise` was dead code removed in sync-08.
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
    func noPartial() {
        let (pm, dir) = makeManager()
        defer { cleanup(dir) }
        let plan = pm.rangeStart(for: Self.baseKey, cachedRecord: baseRecord())
        #expect(plan.rangeStart == 0)
        #expect(plan.pinnedEtag == nil)
        #expect(!plan.hasPartial)
    }

    @Test("rangeStart: partial with matching etag → (size, etag, true)")
    func partialWithMatchingEtag() throws {
        let (pm, dir) = makeManager()
        defer { cleanup(dir) }
        let key = Self.baseKey
        let record = baseRecord(contentLength: 100, etag: "v1")

        // Create a 40-byte partial.
        let partialURL = pm.partialURL(for: key)
        FileManager.default.createFile(atPath: partialURL.path, contents: Data(repeating: 0x41, count: 40))
        try pm.storeEtag("v1", for: key)

        let plan = pm.rangeStart(for: key, cachedRecord: record)
        #expect(plan.rangeStart == 40)
        #expect(plan.pinnedEtag == "v1")
        #expect(plan.hasPartial)
    }

    @Test("rangeStart: partial with mismatched etag → (0, nil, false) + discard")
    func partialMismatchedEtag() throws {
        let (pm, dir) = makeManager()
        defer { cleanup(dir) }
        let key = Self.baseKey
        let record = baseRecord(contentLength: 100, etag: "v1")

        let partialURL = pm.partialURL(for: key)
        FileManager.default.createFile(atPath: partialURL.path, contents: Data(repeating: 0x42, count: 50))
        try pm.storeEtag("v2-different", for: key) // sidecar etag != record etag

        let plan = pm.rangeStart(for: key, cachedRecord: record)
        #expect(plan.rangeStart == 0)
        #expect(!plan.hasPartial)
        // Partial and sidecar should have been discarded.
        #expect(!FileManager.default.fileExists(atPath: partialURL.path))
    }

    @Test("rangeStart: partial with no sidecar → (0, nil, false) + discard")
    func partialNoSidecar() {
        let (pm, dir) = makeManager()
        defer { cleanup(dir) }
        let key = Self.baseKey
        let record = baseRecord(contentLength: 100)

        let partialURL = pm.partialURL(for: key)
        FileManager.default.createFile(atPath: partialURL.path, contents: Data(repeating: 0x43, count: 30))
        // No storeEtag call.

        let plan = pm.rangeStart(for: key, cachedRecord: record)
        #expect(plan.rangeStart == 0)
        #expect(!plan.hasPartial)
    }

    @Test("rangeStart: record contentLength == 0 → no resume")
    func noResumeWhenContentLengthZero() {
        let (pm, dir) = makeManager()
        defer { cleanup(dir) }
        let plan = pm.rangeStart(for: Self.baseKey, cachedRecord: baseRecord(contentLength: 0))
        #expect(plan.rangeStart == 0)
        #expect(!plan.hasPartial)
    }

    // MARK: - ETag sidecar semantics

    @Test("storeEtag round-trips correctly")
    func etagRoundTrip() throws {
        let (pm, dir) = makeManager()
        defer { cleanup(dir) }
        let key = Self.baseKey
        try pm.storeEtag("abc-123", for: key)
        let loaded = pm.loadEtag(for: key)
        #expect(loaded == "abc-123")
    }

    @Test("storeEtag with empty string deletes sidecar")
    func storeEtagEmptyDeletes() throws {
        let (pm, dir) = makeManager()
        defer { cleanup(dir) }
        let key = Self.baseKey
        try pm.storeEtag("some-value", for: key)
        try pm.storeEtag("", for: key)
        #expect(pm.loadEtag(for: key) == nil)
    }

    // MARK: - SyncError error types (retained from finalise tests — still valid)

    @Test("spillFileError has cannotSynchronize fpCode")
    func spillFileErrorFpCode() {
        let innerErr = CocoaError(.fileWriteOutOfSpace)
        let syncErr = SyncError.spillFileError(innerErr)
        #expect(syncErr.fpCode == .cannotSynchronize)
    }

    // MARK: - partialURL / etagURL determinism

    @Test("partialURL is deterministic for the same key")
    func partialURLDeterministic() {
        let (pm, dir) = makeManager()
        defer { cleanup(dir) }
        let key = Self.baseKey
        #expect(pm.partialURL(for: key) == pm.partialURL(for: key))
    }

    @Test("partialURL differs when key components differ")
    func partialURLDiffersAcrossKeys() {
        let (pm, dir) = makeManager()
        defer { cleanup(dir) }
        let key1 = CacheKey(accountAlias: "a", workspaceID: "ws1", itemID: "it", path: "f.bin")
        let key2 = CacheKey(accountAlias: "a", workspaceID: "ws2", itemID: "it", path: "f.bin")
        #expect(pm.partialURL(for: key1) != pm.partialURL(for: key2))
    }

    @Test("etagURL is sidecar of partialURL")
    func etagURLIsSidecar() {
        let (pm, dir) = makeManager()
        defer { cleanup(dir) }
        let key = Self.baseKey
        let partial = pm.partialURL(for: key)
        let etag = pm.etagURL(for: key)
        #expect(etag.path == partial.path + ".etag")
    }

    // MARK: - discard

    @Test("discard removes both partial and sidecar")
    func discardRemovesBothFiles() throws {
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
    func discardNoOpWhenMissing() {
        let (pm, dir) = makeManager()
        defer { cleanup(dir) }
        // Must not throw.
        pm.discard(for: Self.baseKey)
    }

    // MARK: - rangeStart edge cases

    @Test("rangeStart: partial size equals contentLength → no resume (already complete)")
    func noResumeWhenPartialEqualsContentLength() throws {
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

        let plan = pm.rangeStart(for: key, cachedRecord: record)
        #expect(plan.rangeStart == 0)
        #expect(plan.pinnedEtag == nil)
        #expect(!plan.hasPartial)
    }

    @Test("rangeStart: zero-size partial → no resume")
    func noResumeWhenPartialIsEmpty() throws {
        let (pm, dir) = makeManager()
        defer { cleanup(dir) }
        let key = Self.baseKey
        let record = baseRecord(contentLength: 100, etag: "v1")

        // A zero-byte spill file must not trigger a resume.
        let partialURL = pm.partialURL(for: key)
        FileManager.default.createFile(atPath: partialURL.path, contents: Data())
        try pm.storeEtag("v1", for: key)

        let plan = pm.rangeStart(for: key, cachedRecord: record)
        #expect(plan.rangeStart == 0)
        #expect(plan.pinnedEtag == nil)
        #expect(!plan.hasPartial)
    }

    @Test("rangeStart: empty sidecar etag is treated as missing → discard")
    func noResumeWhenSidecarEtagIsEmpty() throws {
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

        let plan = pm.rangeStart(for: key, cachedRecord: record)
        #expect(plan.rangeStart == 0)
        #expect(!plan.hasPartial)
        // discard() must have run.
        #expect(!FileManager.default.fileExists(atPath: partialURL.path))
    }

    @Test("rangeStart: record etag is empty string → sidecar etag accepted without comparison")
    func resumeWhenRecordEtagIsEmpty() throws {
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

        let plan = pm.rangeStart(for: key, cachedRecord: record)
        #expect(plan.rangeStart == 60)
        #expect(plan.pinnedEtag == "some-etag")
        #expect(plan.hasPartial)
    }

    // MARK: - hashSpillFile

    @Test("hashSpillFile matches CryptoKit SHA-256 of the same bytes")
    func testHashSpillFile() throws {
        let (pm, dir) = makeManager()
        defer { cleanup(dir) }

        let content = Data((0 ..< 2048).map { UInt8($0 & 0xFF) })
        let tmpURL = dir.appendingPathComponent("spill.partial")
        try content.write(to: tmpURL)

        let got = try pm.hashSpillFile(tmpURL)
        let expected = SHA256.hash(data: content).map { String(format: "%02x", $0) }.joined()
        #expect(got == expected)
    }

    @Test("hashSpillFile on empty file returns SHA-256 of empty data")
    func hashSpillFileEmpty() throws {
        let (pm, dir) = makeManager()
        defer { cleanup(dir) }

        let tmpURL = dir.appendingPathComponent("empty.partial")
        FileManager.default.createFile(atPath: tmpURL.path, contents: Data())

        let got = try pm.hashSpillFile(tmpURL)
        let expected = SHA256.hash(data: Data()).map { String(format: "%02x", $0) }.joined()
        #expect(got == expected)
    }

    @Test("hashSpillFile on multi-chunk file (>1 MiB) produces correct digest")
    func hashSpillFileLarge() throws {
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
    func hashSpillFileMissing() throws {
        let (pm, dir) = makeManager()
        defer { cleanup(dir) }

        let missing = dir.appendingPathComponent("no-such-file.partial")
        #expect(throws: (any Error).self) {
            try pm.hashSpillFile(missing)
        }
    }

    // MARK: - reapStalePartialDirs

    @Test("reapStalePartialDirs removes directory for a dead PID")
    func reapRemovesDeadPID() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("ofem-reap-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }

        // PID 1 is always alive (launchd), so use a PID that cannot possibly be
        // running: Int32.max is beyond the Darwin pid_max of 99999.
        let deadPID = Int32.max
        let staleDir = base.appendingPathComponent("\(deadPID)", isDirectory: true)
        try FileManager.default.createDirectory(at: staleDir, withIntermediateDirectories: true)

        PartialManager.reapStalePartialDirs(under: base)

        #expect(!FileManager.default.fileExists(atPath: staleDir.path))
    }

    @Test("reapStalePartialDirs keeps directory for the current process PID")
    func reapKeepsSelfPID() throws {
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
    func reapSkipsNonPIDEntries() throws {
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
    func reapMissingBaseIsNoOp() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("ofem-reap-missing-\(UUID().uuidString)")
        // Must not throw / crash.
        PartialManager.reapStalePartialDirs(under: missing)
    }

    // MARK: - 412 resume discard (tests-12: moved from SyncEngineTests)

    @Test("discard+reset after 412: rangeStart returns 0 and hasPartial is false")
    func test412DiscardResetsRangeStart() throws {
        // Tests the PartialManager discard path triggered by a 412 response in
        // SyncEngine — after discard the partial state is fully cleared.
        let (pm, dir) = makeManager()
        defer { cleanup(dir) }

        let key = CacheKey(accountAlias: "a", workspaceID: "ws", itemID: "it", path: "Files/data.csv")

        // Seed a 10-byte partial with etag so the manager reports a resume offset.
        let partialURL = pm.partialURL(for: key)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: partialURL.path, contents: Data(repeating: 0x41, count: 10))
        try pm.storeEtag("old-etag", for: key)

        let record = MetadataRecord(
            accountAlias: "a", workspaceID: "ws", itemID: "it",
            path: "Files/data.csv", parentPath: "Files", name: "data.csv",
            isDir: false, contentLength: 100, etag: "old-etag"
        )

        // Before discard: partial at offset 10.
        let before = pm.rangeStart(for: key, cachedRecord: record)
        #expect(before.rangeStart == 10)
        #expect(before.hasPartial)

        // Discard (412 path) and verify state is fully cleared.
        pm.discard(for: key)
        let after = pm.rangeStart(for: key, cachedRecord: record)
        #expect(after.rangeStart == 0)
        #expect(after.pinnedEtag == nil)
        #expect(!after.hasPartial)
    }
}
