import Foundation
import GRDB
@testable import OfemKit
import Testing

// MARK: - Tombstone TTL purge tests

/// Unit tests for ``CacheStore/purgeExpiredTombstones(accountAlias:)`` and the
/// ``CacheReader/tombstonesPurgedThroughNs(accountAlias:)`` watermark.
///
/// Timestamps are driven by an injected clock so the 30-day cutoff and the
/// monotonic watermark are exercised deterministically without wall-clock sleeps.
@Suite("Tombstone TTL purge")
struct TombstonePurgeTests {
    private static let alias = "acct"
    private static let ws = "ws-guid"
    private static let item = "item-guid"

    /// One day in nanoseconds — the granularity used throughout these tests so
    /// timestamps stay well clear of the 30-day TTL boundary.
    private static let day: Int64 = 86400 * 1_000_000_000

    /// A settable Unix-nanosecond clock (thread-safe: the store reads it off the
    /// actor's executor while the test body mutates it).
    private final class StepClock: @unchecked Sendable {
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

    private func tombstoneIDs(_ store: CacheStore) async throws -> [String] {
        try await store.dbPool.read { db in
            try String.fetchAll(db, sql: """
            SELECT identifier_string FROM deletion_tombstones
            WHERE account_alias = ? ORDER BY identifier_string
            """, arguments: [Self.alias])
        }
    }

    // MARK: - 1. Purge respects the 30-day cutoff

    @Test("purge deletes tombstones older than the TTL and keeps newer ones")
    func purgeRespectsCutoff() async throws {
        let clock = StepClock(0)
        let store = try makeTempStore(clock: { clock.now })
        defer { try? FileManager.default.removeItem(at: store.root) }

        // An old tombstone (10d) that is older than the 30-day TTL relative to the
        // purge time (100d ⇒ cutoff 70d), and a newer one (90d) that survives.
        clock.now = 10 * Self.day
        try await store.recordDeletion(accountAlias: Self.alias, identifierString: "\(Self.ws)/\(Self.item)/old.txt")
        clock.now = 90 * Self.day
        try await store.recordDeletion(accountAlias: Self.alias, identifierString: "\(Self.ws)/\(Self.item)/new.txt")

        clock.now = 100 * Self.day
        let deleted = try await store.purgeExpiredTombstones(accountAlias: Self.alias)

        #expect(deleted == 1)
        #expect(try await tombstoneIDs(store) == ["\(Self.ws)/\(Self.item)/new.txt"])

        // The watermark equals the cutoff (100d − 30d = 70d).
        let watermark = try await store.tombstonesPurgedThroughNs(accountAlias: Self.alias)
        #expect(watermark == 100 * Self.day - CacheStore.tombstoneTTLNs)
    }

    // MARK: - 2. Purge is alias-scoped

    @Test("purge only touches the given alias")
    func purgeIsAliasScoped() async throws {
        let clock = StepClock(0)
        let store = try makeTempStore(clock: { clock.now })
        defer { try? FileManager.default.removeItem(at: store.root) }

        // An ancient tombstone under a DIFFERENT alias must survive a purge of `alias`.
        clock.now = 1 * Self.day
        try await store.recordDeletion(accountAlias: "other", identifierString: "\(Self.ws)/\(Self.item)/x.txt")
        clock.now = 1 * Self.day
        try await store.recordDeletion(accountAlias: Self.alias, identifierString: "\(Self.ws)/\(Self.item)/x.txt")

        clock.now = 100 * Self.day
        let deleted = try await store.purgeExpiredTombstones(accountAlias: Self.alias)
        #expect(deleted == 1)

        // The other alias's tombstone and watermark are untouched.
        let otherRows = try await store.dbPool.read { db in
            try String.fetchAll(db, sql: """
            SELECT identifier_string FROM deletion_tombstones WHERE account_alias = 'other'
            """)
        }
        #expect(otherRows == ["\(Self.ws)/\(Self.item)/x.txt"])
        #expect(try await store.tombstonesPurgedThroughNs(accountAlias: "other") == 0)
    }

    // MARK: - 3. Watermark advances, is written when zero deleted, and never lowers

    @Test("watermark is written even with zero deletions, advances, and never regresses")
    func watermarkMonotonic() async throws {
        let clock = StepClock(0)
        let store = try makeTempStore(clock: { clock.now })
        defer { try? FileManager.default.removeItem(at: store.root) }

        // A) No tombstones at all: the purge deletes nothing but STILL writes the
        //    watermark, so the horizon is honest from the first pass.
        clock.now = 100 * Self.day
        let d0 = try await store.purgeExpiredTombstones(accountAlias: Self.alias)
        #expect(d0 == 0)
        #expect(try await store.tombstonesPurgedThroughNs(accountAlias: Self.alias) == 100 * Self.day - CacheStore.tombstoneTTLNs)

        // B) Later purge advances the watermark forward.
        clock.now = 200 * Self.day
        _ = try await store.purgeExpiredTombstones(accountAlias: Self.alias)
        #expect(try await store.tombstonesPurgedThroughNs(accountAlias: Self.alias) == 200 * Self.day - CacheStore.tombstoneTTLNs)

        // C) A backward clock step must NOT lower the watermark (MAX guard).
        clock.now = 50 * Self.day
        _ = try await store.purgeExpiredTombstones(accountAlias: Self.alias)
        #expect(try await store.tombstonesPurgedThroughNs(accountAlias: Self.alias) == 200 * Self.day - CacheStore.tombstoneTTLNs)
    }

    // MARK: - 4. Watermark of an un-purged alias is zero

    @Test("tombstonesPurgedThroughNs is zero for an alias that has never been purged")
    func watermarkZeroWhenNeverPurged() async throws {
        let store = try makeTempStore()
        defer { try? FileManager.default.removeItem(at: store.root) }
        #expect(try await store.tombstonesPurgedThroughNs(accountAlias: Self.alias) == 0)
    }
}
