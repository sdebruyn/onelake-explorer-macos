import Foundation
@testable import OfemKit
import Testing

// MARK: - refreshMaterialized skip-gate pure-logic tests

/// Unit tests for the pure decision cores extracted from
/// ``SyncEngine/refreshMaterialized(alias:keys:concurrencyCap:selfHealIntervalMinutes:)``:
/// ``SyncEngine/shouldSkip(parentVouched:healDue:prior:current:)`` (the #380
/// skip-gate) and ``SyncEngine/healDue(nowNs:last:thresholdNs:)`` (the self-heal
/// floor). These pin the exact truth tables the orchestrator relies on.
struct SyncEngineSkipGateUnitTests {
    private static let oneMinuteNs: Int64 = 60 * 1_000_000_000

    // MARK: - shouldSkip

    @Test func skipsWhenVouchedAndTokenUnchanged() {
        #expect(SyncEngine.shouldSkip(parentVouched: true, healDue: false, prior: "etag-1", current: "etag-1"))
    }

    @Test func doesNotSkipWhenHealDue() {
        // The self-heal floor overrides an unchanged token.
        #expect(!SyncEngine.shouldSkip(parentVouched: true, healDue: true, prior: "etag-1", current: "etag-1"))
    }

    @Test func doesNotSkipWhenParentDidNotVouch() {
        #expect(!SyncEngine.shouldSkip(parentVouched: false, healDue: false, prior: "etag-1", current: "etag-1"))
    }

    @Test func doesNotSkipWhenTokenChanged() {
        #expect(!SyncEngine.shouldSkip(parentVouched: true, healDue: false, prior: "etag-1", current: "etag-2"))
    }

    @Test func doesNotSkipWhenCurrentEmptyEvenIfPriorEmpty() {
        // An empty current token (missing row / never harvested) is never
        // "unchanged", so the container always lists.
        #expect(!SyncEngine.shouldSkip(parentVouched: true, healDue: false, prior: "", current: ""))
    }

    @Test func doesNotSkipWhenCurrentEmptyButPriorSet() {
        #expect(!SyncEngine.shouldSkip(parentVouched: true, healDue: false, prior: "etag-1", current: ""))
    }

    @Test func doesNotSkipWhenPriorEmptyButCurrentSet() {
        // First harvest: prior "" vs a freshly stamped current → treated as
        // changed, so the container lists once to seed the token.
        #expect(!SyncEngine.shouldSkip(parentVouched: true, healDue: false, prior: "", current: "etag-1"))
    }

    // MARK: - healDue

    @Test func healDueDisabledWhenThresholdZero() {
        // Threshold 0 disables the floor: never due, with or without a prior heal.
        #expect(!SyncEngine.healDue(nowNs: 1000, last: 0, thresholdNs: 0))
        #expect(!SyncEngine.healDue(nowNs: 1000, last: nil, thresholdNs: 0))
    }

    @Test func healDueOnFirstSightWhenNoPriorHeal() {
        // No prior heal recorded (last == nil) with the floor enabled ⇒ due, so
        // the token is seeded on the first poll.
        #expect(SyncEngine.healDue(nowNs: 5000, last: nil, thresholdNs: Self.oneMinuteNs))
    }

    @Test func healDueWhenIntervalElapsed() {
        let last: Int64 = 1000
        #expect(SyncEngine.healDue(nowNs: last + Self.oneMinuteNs + 1, last: last, thresholdNs: Self.oneMinuteNs))
    }

    @Test func healDueExactlyAtThresholdBoundary() {
        // The comparison is `>=`, so an elapsed delta exactly equal to the
        // threshold is due.
        let last: Int64 = 1000
        #expect(SyncEngine.healDue(nowNs: last + Self.oneMinuteNs, last: last, thresholdNs: Self.oneMinuteNs))
    }

    @Test func notHealDueWhenIntervalNotElapsed() {
        let last: Int64 = 1000
        #expect(!SyncEngine.healDue(nowNs: last + 1, last: last, thresholdNs: Self.oneMinuteNs))
    }

    @Test func healDueOnBackwardClockStep() {
        // Monotonic-safe branch: a backward wall-clock step makes nowNs <= last;
        // fail TOWARD healing rather than silently disabling the floor.
        let last: Int64 = 10_000_000_000
        #expect(SyncEngine.healDue(nowNs: last - 1, last: last, thresholdNs: Self.oneMinuteNs))
        #expect(SyncEngine.healDue(nowNs: last, last: last, thresholdNs: Self.oneMinuteNs))
    }
}
