import Foundation

// MARK: - FileTokenStore

/// File-backed token store that holds per-account opaque byte blobs under
/// `<configDir>/tokens/<hex-encoded-alias>.bin`.
///
/// This is a 1:1 port of `internal/auth/keychain.go` — `fileKeychain`. The
/// name "token store" is used here because the type is a pure file-I/O
/// primitive; the macOS Keychain (`SecItem*`) integration is deferred to
/// Phase 3 when MSAL Swift takes over.
///
/// **Thread safety**: all public methods are safe for concurrent use.
///
/// **Path layout**: the alias is hex-encoded so any byte sequence (including
/// slashes and non-ASCII characters) maps to a safe, unique filename — the
/// same scheme the Go implementation uses. The resulting filename is the
/// lowercase hex encoding of the UTF-8 byte sequence of the alias, suffixed
/// with `.bin`.
///
/// **Atomic writes**: `write` writes to a temp file in the same directory
/// and then renames it, so a crash mid-write can never leave a half-written
/// token blob at the canonical path. The file is `chmod`'d to 0600 before
/// the rename so the destination always has restricted permissions.
///
/// **Empty-value semantics**: calling `write` with `Data()` or a zero-length
/// buffer is equivalent to `delete` — the existing entry is removed and no
/// file is written. This matches the Go `Set(account, nil)` contract.
///
/// Mirrors `internal/auth/keychain.go` — `fileKeychain` + `Keychain` interface.
public final class FileTokenStore: Sendable {
    private let root: URL
    private let lock = NSLock()

    // MARK: - Initialisers

    /// Creates a `FileTokenStore` rooted at `<configDir>/tokens/`.
    /// The directory is created (0700) if it does not exist.
    ///
    /// - Throws: ``FileTokenStoreError/createDirectoryFailed(_:)`` if the
    ///   directory cannot be created.
    public convenience init() throws {
        try self.init(tokensDir: OfemPaths().tokensDir)
    }

    /// Creates a `FileTokenStore` rooted at an explicit directory. Use this
    /// from sandboxed processes or tests that need a custom root.
    ///
    /// - Parameter tokensDir: Directory under which token files are stored.
    /// - Throws: ``FileTokenStoreError/createDirectoryFailed(_:)`` if the
    ///   directory cannot be created.
    public init(tokensDir: URL) throws {
        self.root = tokensDir
        do {
            try FileManager.default.createDirectory(
                at: tokensDir,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            throw FileTokenStoreError.createDirectoryFailed(error)
        }
    }

    // MARK: - Public API

    /// Reads the opaque byte blob previously stored for `alias`.
    ///
    /// - Parameter alias: The user-chosen account alias.
    /// - Returns: The stored bytes.
    /// - Throws: ``FileTokenStoreError/notFound(_:)`` (wrapping
    ///   `CocoaError.fileReadNoSuchFile`) when no entry exists for `alias`;
    ///   ``FileTokenStoreError/readFailed(_:_:)`` for other I/O failures.
    ///
    /// Mirrors `internal/auth/keychain.go` — `fileKeychain.Get()`.
    public func read(alias: String) throws -> Data {
        let url = tokenURL(for: alias)
        do {
            return try Data(contentsOf: url)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            throw FileTokenStoreError.notFound(alias)
        } catch {
            throw FileTokenStoreError.readFailed(alias, error)
        }
    }

    /// Stores `data` for `alias`. Passing an empty `Data()` is equivalent to
    /// calling ``delete(alias:)``.
    ///
    /// - Parameters:
    ///   - alias: The user-chosen account alias.
    ///   - data: The opaque byte blob to store.
    /// - Throws: ``FileTokenStoreError`` variants on I/O failures.
    ///
    /// Mirrors `internal/auth/keychain.go` — `fileKeychain.Set()`.
    public func write(alias: String, data: Data) throws {
        guard !data.isEmpty else {
            try delete(alias: alias)
            return
        }

        let dest = tokenURL(for: alias)

        // Write to a unique temp file in the same directory, chmod, then
        // rename. All three steps run under the lock so concurrent writes to
        // the same alias cannot interleave.
        try lock.withLock {
            let tmpURL = root.appending(
                path: ".tmp-\(ProcessInfo.processInfo.globallyUniqueString).bin",
                directoryHint: .notDirectory
            )
            let fm = FileManager.default

            do {
                try data.write(to: tmpURL)
            } catch {
                throw FileTokenStoreError.writeFailed(alias, error)
            }

            do {
                try fm.setAttributes(
                    [.posixPermissions: 0o600],
                    ofItemAtPath: tmpURL.path(percentEncoded: false)
                )
            } catch {
                try? fm.removeItem(at: tmpURL)
                throw FileTokenStoreError.chmodFailed(alias, error)
            }

            do {
                _ = try fm.replaceItemAt(dest, withItemAt: tmpURL)
            } catch {
                try? fm.removeItem(at: tmpURL)
                throw FileTokenStoreError.renameFailed(alias, error)
            }
        }
    }

    /// Removes the stored entry for `alias`. Deleting a missing entry is a
    /// no-op (not an error).
    ///
    /// - Parameter alias: The user-chosen account alias.
    /// - Throws: ``FileTokenStoreError/deleteFailed(_:_:)`` on unexpected
    ///   I/O errors.
    ///
    /// Mirrors `internal/auth/keychain.go` — `fileKeychain.Delete()`.
    public func delete(alias: String) throws {
        let url = tokenURL(for: alias)
        do {
            try FileManager.default.removeItem(at: url)
        } catch let error as CocoaError where error.code == .fileNoSuchFile {
            // Missing entry — no-op, matching the Go contract.
            return
        } catch {
            throw FileTokenStoreError.deleteFailed(alias, error)
        }
    }

    // MARK: - Private helpers

    /// Returns the file URL for an alias's token blob.
    ///
    /// The alias is hex-encoded so any byte value (including `/`) produces a
    /// valid, unique filename. Matches the scheme in `fileKeychain.path()` in
    /// the Go implementation.
    private func tokenURL(for alias: String) -> URL {
        let hex = Data(alias.utf8).map { String(format: "%02x", $0) }.joined()
        return root.appending(path: "\(hex).bin", directoryHint: .notDirectory)
    }
}

// MARK: - Errors

/// Errors thrown by ``FileTokenStore``.
public enum FileTokenStoreError: Error {
    /// No token is stored for the given alias. Equivalent to `os.ErrNotExist`
    /// in the Go implementation.
    case notFound(String)
    /// The token file could not be read.
    case readFailed(String, Error)
    /// The token file could not be written.
    case writeFailed(String, Error)
    /// `chmod 0600` on the temp file failed.
    case chmodFailed(String, Error)
    /// Renaming the temp file to the canonical path failed.
    case renameFailed(String, Error)
    /// The token directory could not be deleted for an alias.
    case deleteFailed(String, Error)
    /// The tokens directory could not be created.
    case createDirectoryFailed(Error)
}
