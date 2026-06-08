import Foundation
import os.log

// MARK: - BlobShardCache

/// Manages the sharded on-disk blob store at `<root>/blobs/<shard>/<filename>`.
///
/// Blob bytes live **on disk**, not in SQLite. SQLite holds only the
/// `blob_sha256`, `blob_size`, and `last_accessed_ns` metadata that the LRU
/// eviction logic in ``CacheStore`` uses to decide which blobs to drop.
///
/// Shard layout:
/// ```
/// <blobRoot>/
///   ab/
///     cdef…  (62 hex chars)
///   ff/
///     …
/// ```
///
/// The first two hex characters of the SHA-256 digest form the shard directory
/// name; the remaining 62 characters form the file name inside that directory.
/// This is identical to the layout produced by the Go implementation in
/// `internal/cache/blob.go` — `blobShardPath`.
///
/// `BlobShardCache` is a `Sendable` value type (all operations are stateless
/// path computations + synchronous filesystem calls). The caller is responsible
/// for concurrency — typically it is driven by the `CacheStore` actor.
public struct BlobShardCache: Sendable {

    // MARK: Constants

    /// SHA-256 digest length in lowercase hex characters.
    static let shaLength = 64

    /// Subdirectory under the cache root that holds blob shards.
    public static let blobsSubdir = "blobs"

    // MARK: Properties

    /// Root directory of all blob shards (`<cacheRoot>/blobs`).
    public let blobRoot: URL

    private static let log = Logger(subsystem: "dev.debruyn.ofem", category: "BlobShardCache")

    // MARK: Initialiser

    /// Creates a `BlobShardCache` that stores blobs under `blobRoot`.
    ///
    /// - Parameter blobRoot: The directory that holds shard subdirectories.
    ///   It is created if it does not exist.
    public init(blobRoot: URL) throws {
        self.blobRoot = blobRoot
        try FileManager.default.createDirectory(at: blobRoot, withIntermediateDirectories: true)
    }

    // MARK: - Store

    /// Writes `data` into the blob store and returns its lowercase hex SHA-256
    /// digest and the number of bytes written.
    ///
    /// The write is atomic: bytes go to a temporary file first and are renamed
    /// into place only after the write finishes successfully. A crash mid-write
    /// never leaves a partial file at the canonical path.
    ///
    /// Idempotent: if a blob with this SHA-256 already exists on disk, the
    /// temporary file is discarded and the existing size is returned.
    ///
    /// Mirrors `internal/cache/blob.go` — `Cache.StoreBlob`.
    public func store(_ data: Data) throws -> (sha256: String, size: Int64) {
        // Compute SHA-256.
        let digest = CryptoSHA256.hash(data: data)
        let sha = digest.hexString

        let (shardDir, destURL) = shardPath(for: sha)

        // If the blob already exists, deduplicate.
        if FileManager.default.fileExists(atPath: destURL.path) {
            let attrs = try FileManager.default.attributesOfItem(atPath: destURL.path)
            let size = (attrs[.size] as? Int64) ?? Int64(data.count)
            Self.log.debug("BlobShardCache: blob already present sha=\(sha, privacy: .public) bytes=\(size, privacy: .public)")
            return (sha, size)
        }

        // Write to a temp file then rename atomically.
        try FileManager.default.createDirectory(at: shardDir, withIntermediateDirectories: true)
        let tmpURL = blobRoot.appendingPathComponent("blob-\(UUID().uuidString).tmp")
        defer { try? FileManager.default.removeItem(at: tmpURL) }
        try data.write(to: tmpURL, options: .atomic)

        // Move to canonical path.
        do {
            try FileManager.default.moveItem(at: tmpURL, to: destURL)
        } catch CocoaError.fileWriteFileExists {
            // Race: another writer arrived first — deduplicate.
        }

        let size = Int64(data.count)
        Self.log.debug("BlobShardCache: stored sha=\(sha, privacy: .public) bytes=\(size, privacy: .public)")
        return (sha, size)
    }

    // MARK: - Load

    /// Reads the blob file for `sha256` and returns its bytes.
    ///
    /// Throws ``CacheError/notFound(_:)`` when the blob is not on disk.
    ///
    /// Mirrors `internal/cache/blob.go` — `Cache.OpenBlob`.
    public func load(sha256: String) throws -> Data {
        try validateSHA(sha256)
        let (_, fileURL) = shardPath(for: sha256)
        do {
            return try Data(contentsOf: fileURL)
        } catch {
            if (error as NSError).domain == NSCocoaErrorDomain,
               (error as NSError).code == NSFileReadNoSuchFileError {
                throw CacheError.notFound("blob \(sha256)")
            }
            throw CacheError.blobIOError(error)
        }
    }

    // MARK: - Delete

    /// Removes the blob file for `sha256`. A no-op if the file does not exist.
    ///
    /// Also removes the shard directory when it is now empty (mirrors Go's
    /// behaviour of cleaning up empty `<ab>/` directories after eviction).
    public func delete(sha256: String) throws {
        try validateSHA(sha256)
        let (shardDir, fileURL) = shardPath(for: sha256)
        do {
            try FileManager.default.removeItem(at: fileURL)
        } catch let err as NSError where err.code == NSFileNoSuchFileError {
            return  // already gone
        } catch {
            throw CacheError.blobIOError(error)
        }
        // Best-effort: remove empty shard directory.
        try? FileManager.default.removeItem(at: shardDir)
    }

    // MARK: - Disk usage

    /// Returns the total number of blob files and their combined size in bytes
    /// by walking the blob root. Temporary `*.tmp` files are excluded.
    ///
    /// Mirrors `internal/cache/blob.go` — `Cache.DiskUsage`.
    public func diskUsage() throws -> (count: Int, bytes: Int64) {
        guard FileManager.default.fileExists(atPath: blobRoot.path) else {
            return (0, 0)
        }
        var count = 0
        var bytes: Int64 = 0
        let enumerator = FileManager.default.enumerator(
            at: blobRoot,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        while let url = enumerator?.nextObject() as? URL {
            // Skip temp files.
            if url.pathExtension == "tmp" { continue }
            // Only count regular files (excludes shard subdirectories).
            guard let vals = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  vals.isRegularFile == true else { continue }
            count += 1
            bytes += Int64(vals.fileSize ?? 0)
        }
        return (count, bytes)
    }

    // MARK: - Wipe

    /// Removes all blob shard directories under `blobRoot`.
    ///
    /// Mirrors `internal/cache/blob.go` — `Cache.Wipe` (the disk portion).
    public func wipeAll() throws {
        let entries = try FileManager.default.contentsOfDirectory(
            at: blobRoot,
            includingPropertiesForKeys: nil
        )
        for entry in entries {
            do {
                try FileManager.default.removeItem(at: entry)
            } catch {
                Self.log.warning(
                    "BlobShardCache: wipeAll failed to remove entry=\(entry.lastPathComponent, privacy: .public) error=\(error, privacy: .public)"
                )
            }
        }
    }

    // MARK: - Private helpers

    /// Returns `(shardDirectory, blobFileURL)` for the given SHA-256 digest.
    ///
    /// Mirrors `internal/cache/helpers.go` — `blobShardPath`.
    func shardPath(for sha256: String) -> (dir: URL, file: URL) {
        let prefix = String(sha256.prefix(2))
        let suffix = String(sha256.dropFirst(2))
        let dir = blobRoot.appendingPathComponent(prefix, isDirectory: true)
        let file = dir.appendingPathComponent(suffix)
        return (dir, file)
    }

    /// Validates that `sha` is a 64-character lowercase hex string.
    ///
    /// Mirrors `internal/cache/blob.go` — `validateSHA`.
    func validateSHA(_ sha: String) throws {
        guard sha.count == Self.shaLength else {
            throw CacheError.invalidSHA(sha)
        }
        let valid = sha.unicodeScalars.allSatisfy { c in
            (c.value >= 0x30 && c.value <= 0x39)  // '0'–'9'
            || (c.value >= 0x61 && c.value <= 0x66)  // 'a'–'f'
        }
        if !valid { throw CacheError.invalidSHA(sha) }
    }
}

// MARK: - Minimal SHA-256 wrapper (no CryptoKit import in older targets)

import CryptoKit

private enum CryptoSHA256 {
    static func hash(data: Data) -> SHA256Digest { SHA256.hash(data: data) }
}

private extension SHA256Digest {
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
