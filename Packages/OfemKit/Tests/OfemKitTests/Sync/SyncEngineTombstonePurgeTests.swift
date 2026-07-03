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

        // Two tombstones, staggered so each purge pass that actually RUNS has
        // something new to reclaim: a watermark that changes is proof the purge
        // ran, and one that doesn't change is proof it was throttled — instead
        // of the ambiguous "it ran but there was nothing left to purge".
        storeClock.now = 10 * Self.day
        try await store.recordDeletion(
            accountAlias: Self.alias, identifierString: "\(Self.ws)/\(Self.item)/gone1.txt"
        )
        storeClock.now = 80 * Self.day
        try await store.recordDeletion(
            accountAlias: Self.alias, identifierString: "\(Self.ws)/\(Self.item)/gone2.txt"
        )
        storeClock.now = 100 * Self.day // cutoff 70d ⇒ only gone1.txt (10d) is expired

        // Call 1 (window empty): purge runs, deletes gone1.txt, and stamps the
        // watermark at ITS OWN timestamp (10d) — not the cutoff (70d).
        pollClock.now = 0
        _ = await engine.refreshMaterialized(alias: Self.alias, keys: [Self.containerKey], concurrencyCap: 2)
        let wm1 = try await store.tombstonesPurgedThroughNs(accountAlias: Self.alias)
        #expect(wm1 == 10 * Self.day)

        // Advance the STORE clock so gone2.txt (80d) is now expired too — if
        // the throttle did NOT suppress the next purge attempt, it would be
        // reclaimed and the watermark would jump to 80d.
        storeClock.now = 200 * Self.day // cutoff 170d ⇒ gone2.txt (80d) is now expired

        // Call 2 (within the window, +1h): throttle skips the purge, so
        // gone2.txt survives and the watermark stays at wm1 — proof the purge
        // did NOT run again.
        pollClock.now = 1 * Self.hour
        _ = await engine.refreshMaterialized(alias: Self.alias, keys: [Self.containerKey], concurrencyCap: 2)
        let wm2 = try await store.tombstonesPurgedThroughNs(accountAlias: Self.alias)
        #expect(wm2 == wm1)

        // Call 3 (window elapsed, +25h): the purge runs again, reclaims
        // gone2.txt, and advances the watermark to ITS OWN timestamp (80d).
        pollClock.now = 25 * Self.hour
        _ = await engine.refreshMaterialized(alias: Self.alias, keys: [Self.containerKey], concurrencyCap: 2)
        let wm3 = try await store.tombstonesPurgedThroughNs(accountAlias: Self.alias)
        #expect(wm3 == 80 * Self.day)
    }
}
