// MenuStatusModelAutoRefreshTests.swift
// Unit tests for the two-tier auto-refresh design introduced for E3
// (2026-06-27 code review, revised after review round 2):
//   - startAutoRefresh()/stopAutoRefresh() (the 5s high-frequency loop)
//     must actually start/stop, since surfaceBecameVisible()/Hidden() and
//     MenuVisibilityController now rely on stopAutoRefresh() to keep the
//     timer from running for the whole process lifetime while nothing is
//     visible.
//   - startBackgroundRefresh() (the ~75s low-frequency loop) must keep
//     ticking regardless of visibility, so the ambient badge self-heals
//     while the dropdown/Settings are closed.
//   - surfaceBecameVisible()/surfaceBecameHidden() must refcount correctly
//     so two concurrently-visible surfaces (dropdown + Settings) don't
//     stop the high-frequency loop until both report hidden.
//   - The needsSignIn sweep over accounts 2..N must not round-trip to the
//     FPE (and its blobBytes() scan) on every single call to doRefresh(),
//     using a wall-clock throttle rather than a per-call counter (a
//     counter doesn't correspond to any predictable cadence now that two
//     independent loops plus ad-hoc action refreshes all call refresh()).
//
// These fakes are redeclared locally rather than reusing the `private`
// fakes in MenuStatusModelExtendedTests.swift, matching this test target's
// existing per-file convention (see AddAccountCoordinatorExtendedTests).

import OfemKit
import XCTest

// MARK: - Fakes

/// Tracks how many times listAccounts() is called, so tests can verify the
/// auto-refresh loop actually ticks (or has stopped ticking).
@MainActor
private final class CountingAccountProvider: AccountProvider, @unchecked Sendable {
    var accounts: [Account] = []
    private(set) var listAccountsCallCount = 0

    func listAccounts() async -> [Account] {
        listAccountsCallCount += 1
        return accounts
    }

    func defaultAccount() async -> String? {
        nil
    }

    func setDefaultAccount(alias _: String) async throws {}
    func removeAccount(alias _: String) async throws {}
}

/// Records every alias getEngineStatus()/getBadgeStatus() is called with, so
/// tests can verify the secondary-account throttle (E3) and, since #397,
/// which verb the background/secondary paths actually use.
@MainActor
private final class CallLoggingEngineStatusProvider: EngineStatusProvider, @unchecked Sendable {
    private(set) var calledAliases: [String] = []
    private(set) var calledBadgeAliases: [String] = []

    func getEngineStatus(alias: String) async throws -> XPCEngineStatus {
        calledAliases.append(alias)
        return XPCEngineStatus(
            cacheBytes: 0, cacheMaxBytes: 0, cacheMaxSizeGB: 0,
            telemetryEnabled: true, netMaxUploads: 1, netMaxDownloads: 1,
            logLevel: "info", pausedWorkspaces: [], needsSignIn: false
        )
    }

    func getBadgeStatus(alias: String) async throws -> XPCBadgeStatus {
        calledBadgeAliases.append(alias)
        return XPCBadgeStatus(needsSignIn: false, pausedWorkspaces: [])
    }

    func setConfig(alias _: String, key _: String, value _: String) async throws {}
    func clearCache(alias _: String) async throws -> Int64 {
        0
    }

    func reloadEngine(alias _: String) async throws {}
}

/// Like `CallLoggingEngineStatusProvider`, but the getBadgeStatus() call at
/// `gateCallIndex` (0-based, across all getBadgeStatus invocations) suspends
/// until `releaseGate()` is called. Used to reproduce the stamp-after-sweep
/// bug (#397): a secondary-sweep call in flight when a newer refresh()
/// supersedes it.
@MainActor
private final class GatedEngineStatusProvider: EngineStatusProvider, @unchecked Sendable {
    private(set) var calledAliases: [String] = []
    private(set) var calledBadgeAliases: [String] = []
    var gateCallIndex: Int?
    private var badgeCallIndex = 0
    private var gateContinuation: CheckedContinuation<Void, Never>?

    func getEngineStatus(alias: String) async throws -> XPCEngineStatus {
        calledAliases.append(alias)
        return XPCEngineStatus(
            cacheBytes: 0, cacheMaxBytes: 0, cacheMaxSizeGB: 0,
            telemetryEnabled: true, netMaxUploads: 1, netMaxDownloads: 1,
            logLevel: "info", pausedWorkspaces: [], needsSignIn: false
        )
    }

    func getBadgeStatus(alias: String) async throws -> XPCBadgeStatus {
        let myIndex = badgeCallIndex
        badgeCallIndex += 1
        calledBadgeAliases.append(alias)
        if myIndex == gateCallIndex {
            await withCheckedContinuation { cont in gateContinuation = cont }
        }
        return XPCBadgeStatus(needsSignIn: false, pausedWorkspaces: [])
    }

    /// Resumes the gated getBadgeStatus() call, if one is currently suspended.
    func releaseGate() {
        gateContinuation?.resume()
        gateContinuation = nil
    }

    func setConfig(alias _: String, key _: String, value _: String) async throws {}
    func clearCache(alias _: String) async throws -> Int64 {
        0
    }

    func reloadEngine(alias _: String) async throws {}
}

@MainActor
private final class NoOpDomainManager: DomainManager, @unchecked Sendable {
    func removeDomain(alias _: String) async {}
}

private func makeAccount(alias: String) -> Account {
    Account(
        alias: alias,
        tenantID: "tid-\(alias)",
        homeAccountID: "hid-\(alias)",
        username: "\(alias)@test.com",
        addedAt: "2026-01-01T00:00:00Z"
    )
}

// waitUntil lives in TestHelpers.swift, shared across the test target.

// MARK: - Tests

@MainActor
final class MenuStatusModelAutoRefreshTests: XCTestCase, @unchecked Sendable {
    // MARK: - startAutoRefresh / stopAutoRefresh (E3)

    func testStartAutoRefresh_ticksRepeatedly() async {
        let accountProvider = CountingAccountProvider()
        let model = MenuStatusModel(
            accountProvider: accountProvider,
            engineStatusProvider: CallLoggingEngineStatusProvider(),
            domainManager: NoOpDomainManager()
        )

        model.startAutoRefresh(interval: .milliseconds(15))
        await waitUntil { accountProvider.listAccountsCallCount >= 3 }
        model.stopAutoRefresh()

        XCTAssertGreaterThanOrEqual(
            accountProvider.listAccountsCallCount, 3,
            "startAutoRefresh must repeatedly re-invoke doRefresh() while running"
        )
    }

    func testStopAutoRefresh_haltsFurtherTicks() async {
        let accountProvider = CountingAccountProvider()
        let model = MenuStatusModel(
            accountProvider: accountProvider,
            engineStatusProvider: CallLoggingEngineStatusProvider(),
            domainManager: NoOpDomainManager()
        )

        model.startAutoRefresh(interval: .milliseconds(15))
        await waitUntil { accountProvider.listAccountsCallCount >= 2 }
        model.stopAutoRefresh()

        // stopAutoRefresh() only cancels the *next* loop iteration; a
        // refresh() already fired by the current iteration keeps running
        // independently and can still land after this call returns. Let it
        // settle before taking the "stopped" snapshot.
        try? await Task.sleep(for: .milliseconds(50))
        let countAtStop = accountProvider.listAccountsCallCount

        // Give the loop ample opportunity to tick again if stopAutoRefresh
        // failed to cancel it — this is exactly the bug this test guards
        // against. Before E3, nothing ever called stopAutoRefresh in
        // production, so a regression here would previously have gone
        // unnoticed and run the timer forever.
        try? await Task.sleep(for: .milliseconds(150))

        XCTAssertEqual(
            accountProvider.listAccountsCallCount, countAtStop,
            "No further refresh should occur after stopAutoRefresh()"
        )
    }

    // MARK: - Secondary-account needsSignIn throttle (E3)

    func testDoRefresh_secondaryAccountThrottled_notCheckedEveryTick() async {
        let accountProvider = CountingAccountProvider()
        accountProvider.accounts = [makeAccount(alias: "first"), makeAccount(alias: "second")]
        let engineProvider = CallLoggingEngineStatusProvider()
        let model = MenuStatusModel(
            accountProvider: accountProvider,
            engineStatusProvider: engineProvider,
            domainManager: NoOpDomainManager()
        )

        // Five consecutive, fully-sequential refreshes, all well within the
        // 30 s default secondaryAccountCheckInterval: only the first is
        // expected to check "second". The remaining four should reuse the
        // last-known membership instead of round-tripping — and paying
        // blobBytes() — again.
        //
        // accountsNeedingSignIn is unsuitable for content-polling here — its
        // value is identical across all five iterations once "second" is
        // throttled, so a `waitUntil` on its content could pass before the
        // corresponding refresh() has actually finished. Even the call
        // counters aren't safe to poll: getEngineStatus("first") is invoked
        // early in doRefresh, well before the secondary-account sweep that
        // this test is actually asserting on, so polling for it to tick would
        // let the next refresh() fire mid-sweep and cancel it. Await the
        // whole doRefresh pass directly instead: safe because refresh()
        // reassigns the underlying Task synchronously before this call
        // returns.
        for _ in 0 ..< 5 {
            model.refresh()
            await model.awaitCurrentRefresh()
        }

        // The secondary sweep always uses getBadgeStatus (#397), never
        // getEngineStatus — assert against calledBadgeAliases.
        let secondCallCount = engineProvider.calledBadgeAliases.count(where: { $0 == "second" })
        XCTAssertEqual(
            secondCallCount, 1,
            "getBadgeStatus for a secondary account must be throttled, not called on every tick"
        )
        // "second" (the secondary account) must never appear in calledAliases
        // (the full getEngineStatus verb) — but "first" (the primary account,
        // checked via the default refresh(full: true) used in this test)
        // legitimately does, so calledAliases as a whole is NOT expected to
        // be empty here. Asserting `.isEmpty` would be wrong: it conflates
        // "the secondary sweep never uses the full verb" with "nothing here
        // ever uses the full verb", and the primary fetch is supposed to.
        XCTAssertFalse(
            engineProvider.calledAliases.contains("second"),
            "The secondary sweep must never call the full getEngineStatus verb"
        )
        // The first account is not throttled — its cache stats must stay
        // fresh on every tick (default refresh() uses full: true).
        let firstCallCount = engineProvider.calledAliases.count(where: { $0 == "first" })
        XCTAssertEqual(firstCallCount, 5, "The first account must still be checked on every tick")
    }

    func testDoRefresh_secondaryAccountRechecked_afterIntervalElapses() async {
        // A short, injected interval so the "window elapsed" branch is
        // reachable without waiting out the 30 s production default.
        let accountProvider = CountingAccountProvider()
        accountProvider.accounts = [makeAccount(alias: "first"), makeAccount(alias: "second")]
        let engineProvider = CallLoggingEngineStatusProvider()
        let model = MenuStatusModel(
            accountProvider: accountProvider,
            engineStatusProvider: engineProvider,
            domainManager: NoOpDomainManager(),
            secondaryAccountCheckInterval: .milliseconds(30)
        )

        // See the comment in testDoRefresh_secondaryAccountThrottled_notCheckedEveryTick
        // for why this awaits the whole refresh directly rather than polling content.
        model.refresh()
        await model.awaitCurrentRefresh()
        try? await Task.sleep(for: .milliseconds(60)) // > secondaryAccountCheckInterval
        model.refresh()
        await model.awaitCurrentRefresh()

        let secondCallCount = engineProvider.calledBadgeAliases.count(where: { $0 == "second" })
        XCTAssertEqual(
            secondCallCount, 2,
            "getBadgeStatus for a secondary account must re-check once the throttle window elapses"
        )
    }

    // MARK: - Stamp-after-sweep (#397 paired nit)

    func testDoRefresh_secondarySweepAbortedMidway_doesNotStampCheckTime() async {
        // Reproduces the bug fixed alongside the getBadgeStatus RPC split:
        // lastSecondaryAccountCheckAt used to be stamped BEFORE the sweep
        // loop ran, so a sweep aborted partway through (by a newer refresh()
        // superseding it via the generation guard) still recorded a
        // "checked" timestamp — freezing accountsNeedingSignIn at a stale
        // value for a full secondaryAccountCheckInterval window even though
        // some accounts were never actually re-verified.
        //
        // This exercises the MID-loop abort (gated on the first secondary
        // call, caught by the per-iteration guard). A second review round
        // flagged that the tail-of-loop case — superseded while awaiting the
        // LAST account, which the per-iteration guard never gets a chance to
        // re-check — needed covering too: the fix moves both the stamp write
        // and `accountsNeedingSignIn = needsSignInSet` behind the SAME final
        // `guard myGeneration == refreshGeneration, !Task.isCancelled` at the
        // end of doRefresh(), so there is now exactly one code path deciding
        // whether a superseded task may write either value — the mid-loop
        // and tail-of-loop cases can no longer diverge by construction, so a
        // second timing-dependent test exercising the tail case specifically
        // would be redundant coverage of the same guard, not a genuinely
        // independent check.
        let accountProvider = CountingAccountProvider()
        accountProvider.accounts = [
            makeAccount(alias: "first"), makeAccount(alias: "second"), makeAccount(alias: "third"),
        ]
        let engineProvider = GatedEngineStatusProvider()
        // Gate only the very first getBadgeStatus call overall — Task A's
        // check of "second" — so Task B's own sweep below is unaffected.
        engineProvider.gateCallIndex = 0
        let model = MenuStatusModel(
            accountProvider: accountProvider,
            engineStatusProvider: engineProvider,
            domainManager: NoOpDomainManager()
        )

        // Task A: reaches "second" and suspends on the gate mid-sweep.
        model.refresh()
        await waitUntil { engineProvider.calledBadgeAliases.contains("second") }

        // Task B: fired while Task A is still suspended. refresh() cancels
        // Task A's underlying Task, so when Task A eventually resumes its
        // `!Task.isCancelled` guard fails before it reaches "third" or the
        // stamp. Task B's own sweep is well within the (default 30 s)
        // throttle window relative to Task A — if Task A had incorrectly
        // stamped lastSecondaryAccountCheckAt up front, Task B would skip
        // its sweep entirely and never reach "third".
        model.refresh()
        await waitUntil { engineProvider.calledBadgeAliases.contains("third") }

        // Release Task A so it can resume, hit the guard, and return.
        engineProvider.releaseGate()
        try? await Task.sleep(for: .milliseconds(50))

        XCTAssertEqual(
            engineProvider.calledBadgeAliases.count(where: { $0 == "third" }), 1,
            "Task B must have run its own secondary sweep and reached 'third' — proof that Task A's " +
                "aborted sweep did not prematurely stamp lastSecondaryAccountCheckAt"
        )
        XCTAssertEqual(
            engineProvider.calledBadgeAliases.count(where: { $0 == "second" }), 2,
            "'second' is checked once by Task A (before it suspends) and once by Task B"
        )
    }

    // MARK: - startBackgroundRefresh (E3)

    func testStartBackgroundRefresh_ticksRepeatedly() async {
        let accountProvider = CountingAccountProvider()
        let model = MenuStatusModel(
            accountProvider: accountProvider,
            engineStatusProvider: CallLoggingEngineStatusProvider(),
            domainManager: NoOpDomainManager()
        )

        // Never stopped — the low-frequency loop is meant to run for the
        // whole process lifetime, independent of visibility.
        model.startBackgroundRefresh(interval: .milliseconds(15))
        await waitUntil { accountProvider.listAccountsCallCount >= 3 }

        XCTAssertGreaterThanOrEqual(
            accountProvider.listAccountsCallCount, 3,
            "startBackgroundRefresh must keep ticking regardless of dropdown/Settings visibility"
        )
    }

    // MARK: - startBackgroundRefresh uses the slim badge verb (#397)

    func testStartBackgroundRefresh_usesBadgeStatus_notEngineStatus() async {
        let accountProvider = CountingAccountProvider()
        accountProvider.accounts = [makeAccount(alias: "first")]
        let engineProvider = CallLoggingEngineStatusProvider()
        let model = MenuStatusModel(
            accountProvider: accountProvider,
            engineStatusProvider: engineProvider,
            domainManager: NoOpDomainManager()
        )

        model.startBackgroundRefresh(interval: .milliseconds(15))
        await waitUntil { engineProvider.calledBadgeAliases.count >= 2 }

        XCTAssertTrue(
            engineProvider.calledAliases.isEmpty,
            "The always-on background tick must never call the full getEngineStatus verb (#397)"
        )
    }

    // MARK: - surfaceBecameVisible / surfaceBecameHidden refcounting (E3)

    func testSurfaceBecameVisible_startsHighFrequencyLoop() async {
        let accountProvider = CountingAccountProvider()
        let model = MenuStatusModel(
            accountProvider: accountProvider,
            engineStatusProvider: CallLoggingEngineStatusProvider(),
            domainManager: NoOpDomainManager()
        )

        model.surfaceBecameVisible(interval: .milliseconds(15))
        await waitUntil { accountProvider.listAccountsCallCount >= 1 }
        model.surfaceBecameHidden()

        XCTAssertGreaterThanOrEqual(accountProvider.listAccountsCallCount, 1)
    }

    func testSurfaceBecameHidden_onlyStopsAfterEverySurfaceReleases() async {
        // Two independently-visible surfaces (e.g. the dropdown and the
        // Settings window): releasing just one must not stop the shared
        // high-frequency loop.
        let accountProvider = CountingAccountProvider()
        let model = MenuStatusModel(
            accountProvider: accountProvider,
            engineStatusProvider: CallLoggingEngineStatusProvider(),
            domainManager: NoOpDomainManager()
        )

        model.surfaceBecameVisible(interval: .milliseconds(15)) // dropdown opens
        model.surfaceBecameVisible(interval: .milliseconds(15)) // Settings opens
        model.surfaceBecameHidden() // dropdown closes — Settings still open
        await waitUntil { accountProvider.listAccountsCallCount >= 2 }
        let countWhileSettingsStillOpen = accountProvider.listAccountsCallCount
        XCTAssertGreaterThanOrEqual(
            countWhileSettingsStillOpen, 2,
            "The high-frequency loop must keep running while any surface is still visible"
        )

        model.surfaceBecameHidden() // Settings closes — last surface gone
        try? await Task.sleep(for: .milliseconds(50)) // let any in-flight tick settle
        let countAtStop = accountProvider.listAccountsCallCount
        try? await Task.sleep(for: .milliseconds(150))

        XCTAssertEqual(
            accountProvider.listAccountsCallCount, countAtStop,
            "The high-frequency loop must stop once the last surface reports hidden"
        )
    }

    func testSurfaceBecameHidden_extraCallDoesNotUnderflow() async {
        // An unpaired surfaceBecameHidden() (defensive symmetry with
        // MenuVisibilityController's own clamp) must not leave the
        // refcount negative, which would require two hidden calls before
        // the loop could ever restart.
        let accountProvider = CountingAccountProvider()
        let model = MenuStatusModel(
            accountProvider: accountProvider,
            engineStatusProvider: CallLoggingEngineStatusProvider(),
            domainManager: NoOpDomainManager()
        )

        model.surfaceBecameHidden() // no matching surfaceBecameVisible()
        model.surfaceBecameVisible(interval: .milliseconds(15))
        await waitUntil { accountProvider.listAccountsCallCount >= 1 }
        model.surfaceBecameHidden()

        XCTAssertGreaterThanOrEqual(
            accountProvider.listAccountsCallCount, 1,
            "A single surfaceBecameVisible() must still start the loop after a stray hidden call"
        )
    }
}
