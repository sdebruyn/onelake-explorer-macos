import Foundation
import GRDB
@testable import OfemKit

// MARK: - Test helpers

/// Creates a `CacheStore` backed by a unique temporary directory.
///
/// The returned store uses a real on-disk directory so that blob I/O tests
/// exercise the full sharded file system path. Call `store.root` to obtain
/// the directory path, and remove it in `defer` / teardown to avoid leaving
/// orphaned directories behind.
///
/// Usage:
/// ```swift
/// let store = try makeTempStore()
/// defer { try? FileManager.default.removeItem(at: store.root) }
/// ```
func makeTempStore(
    maxBlobBytes: Int64 = 0,
    clock: @escaping @Sendable () -> Int64 = wallClockNs,
    logger: OfemLogger = .init()
) throws -> CacheStore {
    let tmp = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    return try CacheStore(root: tmp, maxBlobBytes: maxBlobBytes, clock: clock, logger: logger)
}
