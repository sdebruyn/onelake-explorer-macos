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

import Combine
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

/// Records every alias getEngineStatus() is called with, so tests can
/// verify the secondary-account throttle (E3).
@MainActor
private final class CallLoggingEngineStatusProvider: EngineStatusProvider, @unchecked Sendable {
    private(set) var calledAliases: [String] = []

    func getEngineStatus(alias: String) async throws -> XPCEngineStatus {
        calledAliases.append(alias)
        return XPCEngineStatus(
            cacheBytes: 0, cacheMaxBytes: 0, cacheMaxSizeGB: 0,
            telemetryEnabled: true, netMaxUploads: 1, netMaxDownloads: 1,
            logLevel: "info", pausedWorkspaces: [], needsSignIn: false
        )
    }

    func setConfig(alias _: String, key _: String, value _: String) async throws {}
    func clearCache(alias _: String) async throws -> Int64 {
        0
    }
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

/// Polls `condition` until it returns true or `timeout` elapses. Used
/// instead of a fixed sleep so tests aren't tied to a specific timing
/// value (T2) — see the identical helper in MenuStatusModelExtendedTests.swift.
private func waitUntil(
    timeout: Duration = .seconds(3),
    interval: Duration = .milliseconds(10),
    _ condition: () -> Bool
) async {
    let deadline = ContinuousClock.now + timeout
    while !condition(), ContinuousClock.now < deadline {
        try? await Task.sleep(for: interval)
    }
}

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

        var completedRefreshes = 0
        var cancellable: AnyCancellable?
        cancellable = model.$accountsNeedingSignIn.dropFirst().sink { _ in
            completedRefreshes += 1
        }

        // Five consecutive, fully-sequential refreshes, all well within the
        // 30 s default secondaryAccountCheckInterval: only the first is
        // expected to check "second". The remaining four should reuse the
        // last-known membership instead of round-tripping — and paying
        // blobBytes() — again.
        for i in 0 ..< 5 {
            model.refresh()
            await waitUntil { completedRefreshes == i + 1 }
        }
        cancellable?.cancel()

        let secondCallCount = engineProvider.calledAliases.count(where: { $0 == "second" })
        XCTAssertEqual(
            secondCallCount, 1,
            "getEngineStatus for a secondary account must be throttled, not called on every tick"
        )
        // The first account is not throttled — its cache stats must stay
        // fresh on every tick.
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

        var completedRefreshes = 0
        var cancellable: AnyCancellable?
        cancellable = model.$accountsNeedingSignIn.dropFirst().sink { _ in
            completedRefreshes += 1
        }

        model.refresh()
        await waitUntil { completedRefreshes == 1 }
        try? await Task.sleep(for: .milliseconds(60)) // > secondaryAccountCheckInterval
        model.refresh()
        await waitUntil { completedRefreshes == 2 }
        cancellable?.cancel()

        let secondCallCount = engineProvider.calledAliases.count(where: { $0 == "second" })
        XCTAssertEqual(
            secondCallCount, 2,
            "getEngineStatus for a secondary account must re-check once the throttle window elapses"
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
