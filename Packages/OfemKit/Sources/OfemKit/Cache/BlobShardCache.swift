import CryptoKit
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
/// ab/
/// cdef… (62 hex chars)
/// ff/
/// …
/// ```
///
/// The first two hex characters of the SHA-256 digest form the shard directory
/// name; the remaining 62 characters form the file name inside that directory.
///
/// `BlobShardCache` is a `Sendable` value type (all operations are stateless
/// path computations + synchronous filesystem calls). The caller is responsible
/// for concurrency — typically it is driven by the `CacheStore` actor.
public struct BlobShardCache: Sendable {
    // MARK: Constants

    /// SHA-256 digest length in lowercase hex characters.
    static let shaLength = 64

    /// Number of leading hex characters used as the shard directory name.
    /// The remaining `shaLength - shardPrefixLength` characters form the filename.
    /// This constant is the single source of truth for `prefix(N)` / `dropFirst(N)`
    /// calls and for sweep SHA reconstruction in `CacheStore`.
    static let shardPrefixLength = 2

    /// Subdirectory under the cache root that holds blob shards.
    public static let blobsSubdir = "blobs"

    /// Read-buffer size used when hashing a source file in `storeFromURL`.
    private static let hashBufferSize = 1 * 1024 * 1024 // 1 MiB

    // MARK: Properties

    /// Root directory of all blob shards (`<cacheRoot>/blobs`).
    public let blobRoot: URL

    private static let log = Logger(subsystem: "dev.debruyn.ofem", category: "BlobShardCache")

    // MARK: Initialiser

    /// Creates a `BlobShardCache` that stores blobs under `blobRoot`.
    ///
    /// - Parameter blobRoot: The directory that holds shard subdirectories.
    /// It is created if it does not exist.
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
    public func store(_ data: Data) throws -> (sha256: String, size: Int64) {
        // Compute SHA-256.
        let sha = SHA256.hash(data: data).hexString

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
            // Verify the winning file is actually present before claiming success.
            guard FileManager.default.fileExists(atPath: destURL.path) else {
                throw CacheError.blobIOError(
                    CocoaError(.fileWriteUnknown,
                               userInfo: [NSLocalizedDescriptionKey: "Blob dedup race: dest absent after fileWriteFileExists for sha \(sha)"])
                )
            }
        }

        let size = Int64(data.count)
        Self.log.debug("BlobShardCache: stored sha=\(sha, privacy: .public) bytes=\(size, privacy: .public)")
        return (sha, size)
    }

    // MARK: - Load

    /// Reads the blob file for `sha256` and returns its bytes.
    ///
    /// Throws ``CacheError/notFound(_:)`` when the blob is not on disk.
    public func load(sha256: String) throws -> Data {
        try validateSHA(sha256)
        let (_, fileURL) = shardPath(for: sha256)
        do {
            return try Data(contentsOf: fileURL)
        } catch {
            if (error as NSError).domain == NSCocoaErrorDomain,
               (error as NSError).code == NSFileReadNoSuchFileError
            {
                throw CacheError.notFound("blob \(sha256)")
            }
            throw CacheError.blobIOError(error)
        }
    }

    // MARK: - Store from URL

    /// Hashes the file at `sourceURL`, moves/copies it into the blob store, and
    /// returns its lowercase hex SHA-256 digest and size.
    ///
    /// Prefers an atomic `moveItem` from the same volume; falls back to a
    /// copy + rename when the source is on a different volume or is read-only.
    /// The existing blob is reused when a file with the same SHA-256 is already
    /// present (deduplication).
    ///
    /// - Parameter sourceURL: Writable temporary file on the same volume as the
    ///   blob store for a zero-copy move; any URL for a copy fallback.
    public func storeFromURL(_ sourceURL: URL) throws -> (sha256: String, size: Int64) {
        // Hash the source file in chunks — never load into memory.
        var hasher = SHA256()
        let hashHandle = try FileHandle(forReadingFrom: sourceURL)
        defer { try? hashHandle.close() }
        let bufSize = Self.hashBufferSize
        while true {
            let chunk = try hashHandle.read(upToCount: bufSize) ?? Data()
            guard !chunk.isEmpty else { break }
            hasher.update(data: chunk)
        }
        // The defer above closes hashHandle; no explicit close needed here.
        let sha = hasher.finalize().hexString

        let (shardDir, destURL) = shardPath(for: sha)

        // Deduplicate: blob already on disk.
        // Read the actual size from the source file (already hashed above) rather
        // than the dest blob to avoid a silent zero when the NSNumber-typed
        // FileAttributeKey.size cannot be cast to Int64 (blocker-4).
        let srcAttrs = try FileManager.default.attributesOfItem(atPath: sourceURL.path)
        let size = (srcAttrs[.size] as? NSNumber)?.int64Value ?? 0

        if FileManager.default.fileExists(atPath: destURL.path) {
            Self.log.debug("BlobShardCache: blob already present sha=\(sha, privacy: .public) bytes=\(size, privacy: .public)")
            return (sha, size)
        }

        try FileManager.default.createDirectory(at: shardDir, withIntermediateDirectories: true)

        // Try atomic move first (same-volume, zero-copy).
        do {
            try FileManager.default.moveItem(at: sourceURL, to: destURL)
        } catch CocoaError.fileWriteFileExists {
            // Race: another writer arrived first — deduplicate.
        } catch let err as NSError
            where err.domain == NSCocoaErrorDomain
            && (err.code == NSFileWriteVolumeReadOnlyError
                || (err.underlyingErrors.first as? NSError).map { $0.code == EXDEV } == true)
        {
            // Cross-volume move (EXDEV) or read-only source: fall back to copy + rename.
            // NSFileWriteOutOfSpaceError is intentionally excluded — a disk-full
            // destination would cause the copy fallback to fail too, wasting I/O.
            let tmpURL = blobRoot.appendingPathComponent("blob-\(UUID().uuidString).tmp")
            defer { try? FileManager.default.removeItem(at: tmpURL) }
            try FileManager.default.copyItem(at: sourceURL, to: tmpURL)
            do {
                try FileManager.default.moveItem(at: tmpURL, to: destURL)
            } catch CocoaError.fileWriteFileExists {
                // Race during fallback — deduplicate.
            }
        }
        // Any other moveItem error (permissions, disk full, I/O) propagates to the caller.

        Self.log.debug("BlobShardCache: storedFromURL sha=\(sha, privacy: .public) bytes=\(size, privacy: .public)")
        return (sha, size)
    }

    // MARK: - File URL

    /// Returns the on-disk URL for the blob identified by `sha256`, or `nil`
    /// when no such blob is stored.
    public func fileURL(sha256: String) -> URL? {
        guard sha256.count == Self.shaLength else { return nil }
        let (_, url) = shardPath(for: sha256)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    // MARK: - Delete

    /// Removes the blob file for `sha256`. A no-op if the file does not exist.
    ///
    /// Attempts to remove the shard directory only when it is empty after the
    /// file deletion, using `rmdir`-semantics (fails silently when siblings remain).
    public func delete(sha256: String) throws {
        try validateSHA(sha256)
        let (shardDir, fileURL) = shardPath(for: sha256)
        do {
            try FileManager.default.removeItem(at: fileURL)
        } catch let err as NSError where err.code == NSFileNoSuchFileError {
            return // already gone
        } catch {
            throw CacheError.blobIOError(error)
        }
        // Best-effort: prune the shard directory when it is now empty.
        // Darwin.rmdir(2) is atomic and returns ENOTEMPTY when the directory
        // still has siblings — so this can never delete a non-empty directory
        // and is not subject to a TOCTOU race with a concurrent store(_:) call.
        _ = Darwin.rmdir(shardDir.path)
    }

    // MARK: - Disk usage

    /// Returns the total number of blob files and their combined size in bytes
    /// by walking the blob root. Temporary `*.tmp` files are excluded.
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
    /// Per-entry errors are logged and silenced; the function always returns normally.
    public func wipeAll() {
        let entries: [URL]
        do {
            entries = try FileManager.default.contentsOfDirectory(
                at: blobRoot,
                includingPropertiesForKeys: nil
            )
        } catch {
            Self.log.warning(
                "BlobShardCache: wipeAll failed to list blobRoot error=\(error, privacy: .public)"
            )
            return
        }
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
    func shardPath(for sha256: String) -> (dir: URL, file: URL) {
        let prefix = String(sha256.prefix(Self.shardPrefixLength))
        let suffix = String(sha256.dropFirst(Self.shardPrefixLength))
        let dir = blobRoot.appendingPathComponent(prefix, isDirectory: true)
        let file = dir.appendingPathComponent(suffix)
        return (dir, file)
    }

    /// Reconstructs the SHA-256 string from a shard directory name and filename.
    ///
    /// This is the inverse of `shardPath(for:)`. Centralising it here means
    /// `CacheStore.sweepOrphanBlobs` does not need to duplicate the shard layout logic.
    func sha(fromShard shard: String, file: String) -> String? {
        let sha = shard + file
        guard sha.count == Self.shaLength else { return nil }
        return sha
    }

    /// Validates that `sha` is a 64-character lowercase hex string.
    func validateSHA(_ sha: String) throws {
        guard sha.count == Self.shaLength else {
            throw CacheError.invalidSHA(sha)
        }
        let valid = sha.unicodeScalars.allSatisfy { c in
            (c.value >= 0x30 && c.value <= 0x39) // '0'–'9'
                || (c.value >= 0x61 && c.value <= 0x66) // 'a'–'f'
        }
        if !valid { throw CacheError.invalidSHA(sha) }
    }
}

// MARK: - SHA256Digest helpers

private extension SHA256Digest {
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
