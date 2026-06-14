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

    /// Buffer size (1 MiB) used when computing the SHA-256 of a spill file.
    private static let hashBufferSize = 1 * 1024 * 1024

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
    ///
    /// Uses ``CacheKey/stableKeyString`` so the field order is guaranteed
    /// consistent with ``SyncEngine``'s coalescing map (sync-11).
    func partialURL(for key: CacheKey) -> URL {
        let digest = SHA256.hash(data: Data(key.stableKeyString.utf8))
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
    /// Returns a ``ResumePlan/fullRestart`` when resuming is not safe.
    func rangeStart(for key: CacheKey, cachedRecord: MetadataRecord) -> ResumePlan {
        guard cachedRecord.contentLength > 0 else { return .fullRestart }

        let url = partialURL(for: key)
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let fileSize = (attrs[.size] as? NSNumber)?.int64Value,
              fileSize > 0, fileSize < cachedRecord.contentLength
        else { return .fullRestart }

        guard let etag = loadEtag(for: key), !etag.isEmpty else {
            discard(for: key)
            return .fullRestart
        }

        // If we know the cached etag, it must match the sidecar.
        if !cachedRecord.etag.isEmpty && cachedRecord.etag != etag {
            discard(for: key)
            return .fullRestart
        }

        return ResumePlan(rangeStart: fileSize, pinnedEtag: etag, hasPartial: true)
    }

    // MARK: - SHA hash of a spill file

    /// Computes the hex SHA-256 of the file at `url` by reading it in 1 MiB
    /// chunks, without loading the entire file into memory (sync-02).
    func hashSpillFile(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk = try handle.read(upToCount: Self.hashBufferSize) ?? Data()
            guard !chunk.isEmpty else { break }
            hasher.update(data: chunk)
        }
        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
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
