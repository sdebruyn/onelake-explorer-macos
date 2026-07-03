import Foundation
@testable import OfemKit
import Testing

// MARK: - SyncEngine tombstone-purge throttle tests

/// Tests that ``SyncEngine/refreshMaterialized(alias:keys:concurrencyCap:)``
/// drives ``CacheStore/purgeExpiredTombstones(accountAlias:)`` behind the 24-hour
/// throttle: at most once per window, and again once the window elapses.
///
/// Two independent injected clocks are used deliberately:
/// - the `CacheStore` clock drives the purge cutoff / watermark (the same basis
///   as tombstone `deleted_at_ns`);
/// - the engine `nowNsProvider` drives the throttle window.
/// Driving them separately lets the test advance the store clock (so a purge that
/// *does* run writes a visibly different watermark) while holding the throttle
/// clock inside its window.
@Suite("SyncEngine tombstone-purge throttle")
struct SyncEngineTombstonePurgeTests {
    private static let alias = "acct"
    private static let ws = "ws-1"
    private static let item = "item-1"
    private static let day: Int64 = 86400 * 1_000_000_000
    private static let hour: Int64 = 3600 * 1_000_000_000

    private static var containerKey: CacheKey {
        CacheKey(accountAlias: alias, workspaceID: ws, itemID: item, path: "")
    }

    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Int64
        init(_ v: Int64) {
            value = v
        }

        var now: Int64 {
            get { lock.withLock { value } }
            set { lock.withLock { value = newValue } }
        }
    }

    @Test("purge runs once per 24h window and again after it elapses")
    func purgeThrottledToOncePerWindow() async throws {
        let storeClock = Clock(0)
        let pollClock = Clock(0)

        let store = try makeTempStore(clock: { storeClock.now })
        defer { try? FileManager.default.removeItem(at: store.root) }
        let engine = SyncEngine(
            cache: store,
            onelake: MockOneLakeClient(), // no scripted listings ⇒ per-key list throws, swallowed
            fabric: MockFabricClient(),
            scratchBase: store.root.appending(path: "scratch", directoryHint: .isDirectory),
            nowNsProvider: { pollClock.now }
        )

        // A tombstone older than the 30-day TTL relative to the first purge time.
        storeClock.now = 10 * Self.day
        try await store.recordDeletion(
            accountAlias: Self.alias, identifierString: "\(Self.ws)/\(Self.item)/gone.txt"
        )
        storeClock.now = 100 * Self.day // cutoff 70d ⇒ the 10d tombstone is expired

        // Call 1 (window empty): purge runs, deletes the expired tombstone, and
        // stamps the watermark at 100d − 30d = 70d.
        pollClock.now = 0
        _ = await engine.refreshMaterialized(alias: Self.alias, keys: [Self.containerKey], concurrencyCap: 2)
        let wm1 = try await store.tombstonesPurgedThroughNs(accountAlias: Self.alias)
        #expect(wm1 == 100 * Self.day - CacheStore.tombstoneTTLNs)

        // Advance the STORE clock so any purge that runs now would write a
        // visibly different watermark (200d − 30d = 170d).
        storeClock.now = 200 * Self.day

        // Call 2 (within the window, +1h): throttle skips the purge, so the
        // watermark must be unchanged — proof the purge did NOT run again.
        pollClock.now = 1 * Self.hour
        _ = await engine.refreshMaterialized(alias: Self.alias, keys: [Self.containerKey], concurrencyCap: 2)
        let wm2 = try await store.tombstonesPurgedThroughNs(accountAlias: Self.alias)
        #expect(wm2 == wm1)

        // Call 3 (window elapsed, +25h): the purge runs again and advances the
        // watermark (writing it even though there is nothing left to delete).
        pollClock.now = 25 * Self.hour
        _ = await engine.refreshMaterialized(alias: Self.alias, keys: [Self.containerKey], concurrencyCap: 2)
        let wm3 = try await store.tombstonesPurgedThroughNs(accountAlias: Self.alias)
        #expect(wm3 == 200 * Self.day - CacheStore.tombstoneTTLNs)
    }
}
