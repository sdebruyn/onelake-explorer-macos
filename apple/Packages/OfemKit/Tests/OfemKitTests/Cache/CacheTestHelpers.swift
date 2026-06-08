import Foundation
import GRDB

@testable import OfemKit

// MARK: - Test helpers

/// Creates a `CacheStore` backed by a temporary directory on disk.
///
/// Using a real directory (rather than `:memory:`) ensures blob I/O tests
/// exercise the full sharded file system path. Each call creates a unique
/// subdirectory under `NSTemporaryDirectory()` and the caller is responsible
/// for cleanup (or relies on the OS to reclaim temp space).
func makeInMemoryStore() throws -> CacheStore {
    let tmp = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    return try CacheStore(root: tmp)
}
