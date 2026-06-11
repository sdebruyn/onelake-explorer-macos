import Foundation
import CryptoKit
import os.log

// MARK: - PartialManager

/// Manages in-flight download spill files and their ETag sidecars.
///
/// A partial-blob spill file lives in a per-process subdirectory of the
/// engine's scratch directory. The spill file accumulates the bytes streamed
/// from OneLake; on completion it is handed to ``CacheStore`` for content-
/// addressable storage. If a download is interrupted the partial survives
/// so the next ``SyncEngine/open(key:)`` call can resume from the existing
/// offset via a `Range` request (pinned to the same ETag via `If-Match`).
///
/// `PartialManager` is `nonisolated` (a class with no mutable shared state
/// after construction); concurrency isolation is delegated to the caller
/// (``SyncEngine``, which is an `actor`).
final class PartialManager: Sendable {

    // MARK: - Constants

    /// Base directory name used when `scratchDir` is not configured.
    static let partialsDirName = "ofem-download-partials"

    // MARK: - State

    private let scratchDir: URL
    private static let log = Logger(subsystem: "dev.debruyn.ofem", category: "PartialManager")

    // MARK: - Init

    /// Creates a `PartialManager`.
    ///
    /// - Parameter scratchDir: Per-process directory under which partial spill
    /// files are written. Must be writable by the calling process.
    init(scratchDir: URL) {
        self.scratchDir = scratchDir
    }

    // MARK: - Partial path

    /// Returns the on-disk path for the partial spill of `key`.
    func partialURL(for key: CacheKey) -> URL {
        let input = "\(key.accountAlias)\0\(key.workspaceID)\0\(key.itemID)\0\(key.path)"
        let digest = SHA256.hash(data: Data(input.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return scratchDir.appendingPathComponent("\(hex).partial")
    }

    /// Returns the ETag sidecar URL for `key`.
    func etagURL(for key: CacheKey) -> URL {
        partialURL(for: key).appendingPathExtension("etag")
    }

    // MARK: - Sidecar read/write

    func loadEtag(for key: CacheKey) -> String? {
        try? String(contentsOf: etagURL(for: key), encoding: .utf8)
    }

    func storeEtag(_ etag: String, for key: CacheKey) throws {
        if etag.isEmpty {
            try? FileManager.default.removeItem(at: etagURL(for: key))
            return
        }
        try FileManager.default.createDirectory(at: scratchDir, withIntermediateDirectories: true)
        try etag.write(to: etagURL(for: key), atomically: false, encoding: .utf8)
    }

    // MARK: - Discard

    func discard(for key: CacheKey) {
        try? FileManager.default.removeItem(at: partialURL(for: key))
        try? FileManager.default.removeItem(at: etagURL(for: key))
    }

    // MARK: - Resume decision

    /// Determines the byte offset from which to resume a download, the ETag
    /// the partial is pinned to, and whether a partial was found.
    ///
    /// Returns `(0, nil, false)` when resuming is not safe.
    func rangeStart(for key: CacheKey, cachedRecord: MetadataRecord) -> (offset: Int64, etag: String?, hasPartial: Bool) {
        guard cachedRecord.contentLength > 0 else { return (0, nil, false) }

        let url = partialURL(for: key)
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let fileSize = attrs[.size] as? Int64,
              fileSize > 0, fileSize < cachedRecord.contentLength
        else { return (0, nil, false) }

        guard let etag = loadEtag(for: key), !etag.isEmpty else {
            discard(for: key)
            return (0, nil, false)
        }

        // If we know the cached etag, it must match the sidecar.
        if !cachedRecord.etag.isEmpty && cachedRecord.etag != etag {
            discard(for: key)
            return (0, nil, false)
        }

        return (fileSize, etag, true)
    }

    // MARK: - Finalise

    /// Appends `body` to any existing partial spill for `key`, SHA-verifies
    /// (when `expectedSHA` is provided), and returns all assembled bytes.
    ///
    /// The caller is responsible for storing the returned bytes in the blob
    /// cache (via ``CacheStore/storeBlob(key:data:)`` after upserting the
    /// metadata row).
    func finalise(
        key: CacheKey,
        body: Data,
        rangeStart: Int64,
        expectedTotal: Int64,
        expectedSHA: String?
    ) throws -> Data {
        let url = partialURL(for: key)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        // Open (or create) the spill file and seek to rangeStart.
        // Always open for update (read+write) so we can later seek to 0 and
        // readToEnd() for SHA verification (sync-08).
        let handle: FileHandle
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }

        try handle.seek(toOffset: UInt64(rangeStart))
        // Use the throwing write variant (sync-08): the legacy `write(_:)` raises
        // an ObjC NSException on disk-full, which crashes the process; `write(contentsOf:)`
        // throws a typed Swift error instead.
        do {
            try handle.write(contentsOf: body)
        } catch {
            discard(for: key)
            throw SyncError.spillFileError(error)
        }
        let totalWritten = rangeStart + Int64(body.count)

        if expectedTotal > 0 && totalWritten != expectedTotal {
            if totalWritten > expectedTotal { discard(for: key) }
            throw SyncError.shortDownload(expected: expectedTotal, got: totalWritten)
        }

        // Read all assembled bytes (single read — reused for SHA if needed).
        try handle.seek(toOffset: 0)
        let allBytes = try handle.readToEnd() ?? Data()

        // SHA verification when an expected hash is known (sync-08: reuse buffer).
        if let expected = expectedSHA, !expected.isEmpty {
            let got = SHA256.hash(data: allBytes).map { String(format: "%02x", $0) }.joined()
            if got != expected {
                discard(for: key)
                throw SyncError.blobSHAMismatch(got: got, expected: expected)
            }
        }

        // Remove partial and sidecar on success.
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(at: etagURL(for: key))

        return allBytes
    }

    // MARK: - Stale partial cleanup

    /// Removes per-process spill directories under `base` whose owning process
    /// is no longer alive.
    static func reapStalePartialDirs(under base: URL) {
        let selfPID = ProcessInfo.processInfo.processIdentifier
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: base, includingPropertiesForKeys: [.isDirectoryKey]
        ) else { return }

        for entry in entries {
            guard let pid = Int32(entry.lastPathComponent), pid != selfPID else { continue }
            if !processAlive(pid) {
                try? FileManager.default.removeItem(at: entry)
            }
        }
    }

    /// Returns `true` when the process identified by `pid` is currently alive.
    private static func processAlive(_ pid: Int32) -> Bool {
        // POSIX signal 0: checks existence/permission without delivering a signal.
        return kill(pid, 0) == 0 || errno == EPERM
    }
}
