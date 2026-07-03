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

        // The watermark equals the newest deleted_at_ns actually purged (10d),
        // NOT the cutoff (70d) — the sole purged tombstone was recorded at 10d,
        // strictly below the 70d cutoff.
        let watermark = try await store.tombstonesPurgedThroughNs(accountAlias: Self.alias)
        #expect(watermark == 10 * Self.day)
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

    // MARK: - 3. Watermark advances only on an actual purge, and never regresses

    @Test("watermark advances to the newest purged deletion, is untouched by a zero-row purge, and never regresses")
    func watermarkAdvancesOnPurgeAndNeverRegresses() async throws {
        let clock = StepClock(0)
        let store = try makeTempStore(clock: { clock.now })
        defer { try? FileManager.default.removeItem(at: store.root) }

        // A) No tombstones at all: the purge deletes nothing, so the watermark is
        //    left untouched (stays at its never-purged default of 0). Jumping it
        //    to the cutoff on every empty pass — the old behavior — is exactly
        //    the spurious re-enumeration bug this refinement fixes.
        clock.now = 100 * Self.day
        let d0 = try await store.purgeExpiredTombstones(accountAlias: Self.alias)
        #expect(d0 == 0)
        #expect(try await store.tombstonesPurgedThroughNs(accountAlias: Self.alias) == 0)

        // B) A tombstone recorded at 20d, purged in a pass whose cutoff (170d) is
        //    far ahead of it: the watermark advances to the PURGED ROW'S OWN
        //    timestamp (20d), not the cutoff.
        clock.now = 20 * Self.day
        try await store.recordDeletion(accountAlias: Self.alias, identifierString: "\(Self.ws)/\(Self.item)/a.txt")
        clock.now = 200 * Self.day // cutoff 170d ⇒ the 20d tombstone is expired
        let d1 = try await store.purgeExpiredTombstones(accountAlias: Self.alias)
        #expect(d1 == 1)
        #expect(try await store.tombstonesPurgedThroughNs(accountAlias: Self.alias) == 20 * Self.day)

        // C) Another empty pass (nothing left to purge): the watermark stays at
        //    20d — it is not bumped forward to this pass's (much later) cutoff.
        clock.now = 250 * Self.day
        let d2 = try await store.purgeExpiredTombstones(accountAlias: Self.alias)
        #expect(d2 == 0)
        #expect(try await store.tombstonesPurgedThroughNs(accountAlias: Self.alias) == 20 * Self.day)

        // D) A backward clock step, then a tombstone recorded and purged whose
        //    own timestamp (5d) is BELOW the existing watermark (20d): the
        //    MAX(existing, maxPurged) guard keeps the watermark at 20d rather
        //    than regressing it to 5d, even though a real purge just happened.
        clock.now = 5 * Self.day
        try await store.recordDeletion(accountAlias: Self.alias, identifierString: "\(Self.ws)/\(Self.item)/b.txt")
        clock.now = 40 * Self.day // cutoff 10d ⇒ the 5d tombstone is expired
        let d3 = try await store.purgeExpiredTombstones(accountAlias: Self.alias)
        #expect(d3 == 1)
        #expect(try await store.tombstonesPurgedThroughNs(accountAlias: Self.alias) == 20 * Self.day)

        // E) A later tombstone purged past the existing watermark advances it
        //    forward again, to ITS OWN timestamp.
        clock.now = 90 * Self.day
        try await store.recordDeletion(accountAlias: Self.alias, identifierString: "\(Self.ws)/\(Self.item)/c.txt")
        clock.now = 300 * Self.day // cutoff 270d ⇒ the 90d tombstone is expired
        let d4 = try await store.purgeExpiredTombstones(accountAlias: Self.alias)
        #expect(d4 == 1)
        #expect(try await store.tombstonesPurgedThroughNs(accountAlias: Self.alias) == 90 * Self.day)
    }

    // MARK: - 4. Watermark of an un-purged alias is zero

    @Test("tombstonesPurgedThroughNs is zero for an alias that has never been purged")
    func watermarkZeroWhenNeverPurged() async throws {
        let store = try makeTempStore()
        defer { try? FileManager.default.removeItem(at: store.root) }
        #expect(try await store.tombstonesPurgedThroughNs(accountAlias: Self.alias) == 0)
    }
}
