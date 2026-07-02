// MenuStatusModelAutoRefreshTests.swift
// Unit tests for the auto-refresh gating and blobBytes throttle introduced
// for E3 (2026-06-27 code review):
//   - startAutoRefresh()/stopAutoRefresh() must actually start/stop the
//     periodic loop, since MenuVisibilityController (OneLakeApp.swift) now
//     relies on stopAutoRefresh() to keep the timer from running for the
//     whole process lifetime while the menu is closed.
//   - The needsSignIn sweep over accounts 2..N must not round-trip to the
//     FPE (and its blobBytes() scan) on every single tick.
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

        // Five consecutive, fully-sequential refreshes: only the first is
        // expected to check "second" (the throttle stride is 6). The
        // remaining four should reuse the last-known membership instead of
        // round-tripping — and paying blobBytes() — again.
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
}
