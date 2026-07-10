import Foundation
@testable import OfemKit
import Testing

// MARK: - SyncEngine Tests

/// Tests for ``SyncEngine`` covering all previously-unverified paths.
@Suite("SyncEngine")
struct SyncEngineTests {
    // MARK: - Helpers

    /// Defaults to `.zero` (always revalidate with a HEAD), not
    /// `SyncEngine.defaultBlobFreshnessTTL`. Most of this suite's `open()`
    /// tests seed the cache row moments before asserting on `getPropertiesCalls`
    /// — with the production default those rows would land inside the TTL
    /// window and the HEAD they assert on would never fire. The TTL-skip
    /// behaviour itself is covered by dedicated tests below that pass a
    /// non-zero `blobFreshnessTTL` explicitly.
    func makeEngine(
        onelake: any OneLakeClientProtocol = MockOneLakeClient(),
        fabric: MockFabricClient = MockFabricClient(),
        store: CacheStore? = nil,
        blobFreshnessTTL: Duration = .zero
    ) throws -> (SyncEngine, CacheStore) {
        let s = try store ?? makeTempStore()
        // tests-07: nest the scratch dir under store.root so the single
        // `defer { try? FileManager.default.removeItem(at: store.root) }` at
        // each call site cleans both the cache and the partial-download scratch
        // directory — no orphaned temp dirs left in $TMPDIR.
        let scratchDir = s.root.appending(path: "scratch", directoryHint: .isDirectory)
        let engine = SyncEngine(
            cache: s,
            onelake: onelake,
            fabric: fabric,
            scratchBase: scratchDir,
            blobFreshnessTTL: blobFreshnessTTL
        )
        return (engine, s)
    }

    static let alias = "test"
    static let wsID = "ws-1"
    static let itID = "item-1"
    static let path = "Files/data.csv"

    static var baseKey: CacheKey {
        CacheKey(accountAlias: alias, workspaceID: wsID, itemID: itID, path: path)
    }

    // NOTE: PartialManager.discard+reset (412 path) coverage has been moved to
    // Sync/PartialManagerTests.swift (tests-12: was misplaced in SyncEngine suite).

    // MARK: - #461 review round 2: SyncEngine.absoluteDownloadProgress unit tests

    /// Deterministic, non-networked coverage of the pure wrapping function
    /// behind every `onProgress` tick — the CI-flaky Alamofire-integration
    /// path (`OneLakeStreamProgressTests` in `OneLakeStreamingTests.swift`)
    /// only smoke-tests that real chunked delivery reaches this function at
    /// all; the actual guarantees (absolute byte accounting, the
    /// completed-never-exceeds-total invariant, indeterminate handling, and
    /// overflow safety) are pinned here instead.
    @Suite("SyncEngine.absoluteDownloadProgress (#461)")
    struct AbsoluteDownloadProgressTests {
        @Test("a fresh (non-resumed) download passes completed/total through unchanged")
        func freshDownloadPassesThrough() {
            let result = SyncEngine.absoluteDownloadProgress(rangeStart: 0, completedInRequest: 40, totalInRequest: 100)
            #expect(result.completed == 40)
            #expect(result.total == 100)
        }

        @Test("a resumed download adds rangeStart to both completed and total")
        func resumedDownloadAddsRangeStart() {
            let result = SyncEngine.absoluteDownloadProgress(rangeStart: 500, completedInRequest: 2, totalInRequest: 5)
            #expect(result.completed == 502)
            #expect(result.total == 505)
        }

        @Test("completed never exceeds total, by construction, across a range of inputs")
        func completedNeverExceedsTotal() {
            let cases: [(rangeStart: Int64, completedInRequest: Int64, totalInRequest: Int64)] = [
                (0, 0, 0), (0, 100, 100), (500, 0, 505), (500, 505, 505), (1, 1, 1), (12345, 6789, 20000),
            ]
            for testCase in cases {
                let result = SyncEngine.absoluteDownloadProgress(
                    rangeStart: testCase.rangeStart,
                    completedInRequest: testCase.completedInRequest,
                    totalInRequest: testCase.totalInRequest
                )
                if result.total > 0 {
                    #expect(result.completed <= result.total, "completed must never exceed total: \(testCase) -> \(result)")
                }
            }
        }

        @Test("an unknown per-request total (<= 0) reports indeterminate (total == 0), not a fabricated number")
        func unknownTotalReportsIndeterminate() {
            let zero = SyncEngine.absoluteDownloadProgress(rangeStart: 500, completedInRequest: 10, totalInRequest: 0)
            #expect(zero.completed == 510)
            #expect(zero.total == 0)

            let negative = SyncEngine.absoluteDownloadProgress(rangeStart: 500, completedInRequest: 10, totalInRequest: -1)
            #expect(negative.completed == 510)
            #expect(negative.total == 0)
        }

        @Test("an overflowing completed addition degrades to indeterminate rather than trapping")
        func overflowingCompletedDegradesToIndeterminate() {
            let result = SyncEngine.absoluteDownloadProgress(
                rangeStart: Int64.max - 5, completedInRequest: 10, totalInRequest: 20
            )
            #expect(result.completed == 0)
            #expect(result.total == 0)
        }

        @Test("an overflowing total addition still reports completed but drops total to indeterminate")
        func overflowingTotalDropsToIndeterminateButKeepsCompleted() {
            let result = SyncEngine.absoluteDownloadProgress(
                rangeStart: Int64.max - 5, completedInRequest: 3, totalInRequest: 20
            )
            #expect(result.completed == Int64.max - 2)
            #expect(result.total == 0)
        }

        @Test("a 412-retry-as-full-restart re-wrap with rangeStart 0 matches a fresh download")
        func fullRestartRewrapMatchesFreshDownload() {
            // Mirrors performNetworkRead's 412 branch: the retry passes
            // rangeStart: 0 regardless of the original (now-stale) resume
            // offset, since that attempt is a brand-new unranged GET.
            let result = SyncEngine.absoluteDownloadProgress(rangeStart: 0, completedInRequest: 30, totalInRequest: 90)
            #expect(result.completed == 30)
            #expect(result.total == 90)
        }
    }

    // MARK: - #461 review round 3: SyncEngine.MonotonicProgressClamp unit tests

    /// Deterministic coverage of the high-water-mark clamp that keeps
    /// `completed` from regressing across a silent Alamofire-level retry or
    /// the 412-full-restart boundary, both of which restart the underlying
    /// transfer from byte 0.
    @Suite("SyncEngine.MonotonicProgressClamp (#461)")
    struct MonotonicProgressClampTests {
        @Test("an increasing sequence passes through unchanged")
        func increasingSequencePassesThrough() {
            let clamp = SyncEngine.MonotonicProgressClamp()
            #expect(clamp.clamp(10) == 10)
            #expect(clamp.clamp(20) == 20)
            #expect(clamp.clamp(20) == 20)
            #expect(clamp.clamp(500) == 500)
        }

        @Test("a value below the high-water mark is clamped up to it, never regressing")
        func regressionIsClampedToHighWaterMark() {
            let clamp = SyncEngine.MonotonicProgressClamp()
            #expect(clamp.clamp(800) == 800)
            // Simulates a silent Alamofire-level retry (or the 412 restart)
            // resetting the underlying request's progress back toward 0.
            #expect(clamp.clamp(0) == 800, "must not regress below the prior high-water mark")
            #expect(clamp.clamp(400) == 800, "still clamped even partway back up")
            #expect(clamp.clamp(900) == 900, "climbing past the high-water mark is reported normally")
        }

        @Test("a fresh instance per download starts its own high-water mark at zero")
        func freshInstanceStartsAtZero() {
            let first = SyncEngine.MonotonicProgressClamp()
            #expect(first.clamp(1000) == 1000)

            // A NEW download (a new performNetworkRead call) gets a NEW
            // clamp instance, so it does not inherit the prior download's
            // high-water mark.
            let second = SyncEngine.MonotonicProgressClamp()
            #expect(second.clamp(10) == 10)
        }
    }
}
