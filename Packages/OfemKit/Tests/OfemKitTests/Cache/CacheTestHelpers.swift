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

/// Ages every blob (and `*.tmp`) file under `store`'s blob root to `date`,
/// well before the init-time orphan sweep's grace window, so the sweep treats
/// them as stale crash-orphans eligible for reclamation.
///
/// A freshly written orphan is otherwise *spared* by the grace window — the
/// sweep cannot tell it apart from a blob a concurrent, in-flight `storeBlob`
/// has written but not yet DB-committed. Tests that deliberately create an
/// orphan and expect it swept must first age it to simulate a prior process's
/// crash-orphan. `date` defaults to the Unix epoch (decades in the past), so
/// the fixture is reaped regardless of the exact grace interval.
func ageOrphanBlobFiles(in store: CacheStore, to date: Date = Date(timeIntervalSince1970: 0)) throws {
    let fm = FileManager.default
    guard let enumerator = fm.enumerator(
        at: store.blobRoot,
        includingPropertiesForKeys: [.isRegularFileKey],
        options: [.skipsHiddenFiles]
    ) else { return }
    while let url = enumerator.nextObject() as? URL {
        guard let vals = try? url.resourceValues(forKeys: [.isRegularFileKey]), vals.isRegularFile == true else { continue }
        try fm.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }
}
