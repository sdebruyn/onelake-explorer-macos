// MenuStatusModelExtendedTests.swift
// Extended unit tests for MenuStatusModel covering the injectable seams
// introduced for host-13: fakes replace OfemFPEClient and DomainSyncManager
// so the refresh, action, fence, and error-surfacing logic can be tested
// without a live FPE or config stack.
//
// Also covers:
//   - host-03: fence release on Task cancellation in debounced setters
//   - host-09: lastActionError surfaced on removeAccount / cacheClear / setDefaultAccount failures
//   - host-10: copyrightYear / copyrightString free functions
//   - T2: the host-03 fence-release tests below poll for the effect
//     (waitUntil) instead of sleeping a fixed duration tied to the
//     production debounce value.

import OfemKit
import XCTest

// MARK: - Fakes

/// Fake AccountProvider for unit tests.
@MainActor
private final class FakeAccountProvider: AccountProvider, @unchecked Sendable {
    var accounts: [Account] = []
    var defaultAccountAlias: String?
    var setDefaultAccountCalled: [String] = []
    var removeAccountCalled: [String] = []
    var shouldThrowOnSetDefault = false
    var shouldThrowOnRemove = false

    func listAccounts() async -> [Account] {
        accounts
    }

    func defaultAccount() async -> String? {
        defaultAccountAlias
    }

    func setDefaultAccount(alias: String) async throws {
        if shouldThrowOnSetDefault { throw FakeError.actionFailed }
        setDefaultAccountCalled.append(alias)
        defaultAccountAlias = alias
    }

    func removeAccount(alias: String) async throws {
        if shouldThrowOnRemove { throw FakeError.actionFailed }
        removeAccountCalled.append(alias)
        accounts.removeAll { $0.alias == alias }
    }
}

/// Fake EngineStatusProvider for unit tests.
@MainActor
private final class FakeEngineStatusProvider: EngineStatusProvider, @unchecked Sendable {
    var statusToReturn: XPCEngineStatus?
    var configSets: [(key: String, value: String)] = []
    var cacheClearedAliases: [String] = []
    var shouldThrowOnClearCache = false

    func getEngineStatus(alias _: String) async throws -> XPCEngineStatus {
        guard let s = statusToReturn else { throw FakeError.noStatus }
        return s
    }

    func getBadgeStatus(alias _: String) async throws -> XPCBadgeStatus {
        guard let s = statusToReturn else { throw FakeError.noStatus }
        return XPCBadgeStatus(needsSignIn: s.needsSignIn, pausedWorkspaces: s.pausedWorkspaces)
    }

    func setConfig(alias _: String, key: String, value: String) async throws {
        configSets.append((key: key, value: value))
    }

    func clearCache(alias: String) async throws -> Int64 {
        if shouldThrowOnClearCache { throw FakeError.actionFailed }
        cacheClearedAliases.append(alias)
        return 0
    }

    func reloadEngine(alias _: String) async throws {}
}

/// Fake DomainManager for unit tests.
@MainActor
private final class FakeDomainManager: DomainManager, @unchecked Sendable {
    var removedAliases: [String] = []
    func removeDomain(alias: String) async {
        removedAliases.append(alias)
    }
}

private enum FakeError: Error { case noStatus, actionFailed }

// MARK: - Helpers

// waitUntil lives in TestHelpers.swift, shared across the test target.

private func makeAccount(alias: String) -> Account {
    Account(
        alias: alias,
        tenantID: "tid-\(alias)",
        homeAccountID: "hid-\(alias)",
        username: "\(alias)@test.com",
        addedAt: "2026-01-01T00:00:00Z"
    )
}

// MARK: - Tests

@MainActor
final class MenuStatusModelExtendedTests: XCTestCase, @unchecked Sendable {
    private var accountProvider: FakeAccountProvider!
    private var engineProvider: FakeEngineStatusProvider!
    private var domainManager: FakeDomainManager!
    private var model: MenuStatusModel!

    /// setUp overrides a nonisolated XCTestCase method and cannot be marked
    /// @MainActor. XCTest always runs setUp on the main thread; this is asserted
    /// via MainActor.assumeIsolated to satisfy Swift 6 strict concurrency.
    override func setUp() {
        super.setUp()
        MainActor.assumeIsolated {
            accountProvider = FakeAccountProvider()
            engineProvider = FakeEngineStatusProvider()
            domainManager = FakeDomainManager()
            model = MenuStatusModel(
                accountProvider: accountProvider,
                engineStatusProvider: engineProvider,
                domainManager: domainManager
            )
        }
    }

    // MARK: - Refresh with injected fakes

    func testRefresh_populatesAccounts() async {
        accountProvider.accounts = [makeAccount(alias: "work")]
        accountProvider.defaultAccountAlias = "work"

        model.refresh()
        await waitUntil { !model.accounts.isEmpty }
        XCTAssertEqual(model.accounts.count, 1)
        XCTAssertEqual(model.accounts.first?.alias, "work")
        XCTAssertEqual(model.defaultAccount, "work")
    }

    func testRefresh_noAccounts_leavesEmptyState() async {
        accountProvider.accounts = []

        let exp = expectation(description: "refresh complete")
        // After refresh with no accounts, hasAccounts is false.
        // We drive this by observing accounts (which starts empty and stays empty).
        // Use a post-refresh check after a brief delay instead.
        Task {
            model.refresh()
            // With no accounts, doRefresh() returns immediately without an XPC
            // call, so $accounts never fires a changed notification (it stays
            // empty). A short fixed sleep is the simplest deterministic option
            // here; 100 ms is ample for a synchronous no-op path but is fragile
            // under heavy CI load — harden to signal-based if this flakes.
            try? await Task.sleep(for: .milliseconds(100))
            exp.fulfill()
        }
        await fulfillment(of: [exp], timeout: 2)
        XCTAssertFalse(model.hasAccounts)
        XCTAssertEqual(model.menuIconState, .notRunning)
    }

    // MARK: - setDefaultAccount with error surfacing (host-09)

    func testSetDefaultAccount_success_clearsLastActionError() async {
        accountProvider.accounts = [makeAccount(alias: "work")]
        accountProvider.shouldThrowOnSetDefault = false

        // Wait for refresh after action.
        model.setDefaultAccount(alias: "work")
        await waitUntil { model.defaultAccount == "work" }
        XCTAssertNil(model.lastActionError, "No error should be set on success")
    }

    func testSetDefaultAccount_failure_setsLastActionError() async {
        accountProvider.accounts = [makeAccount(alias: "work")]
        accountProvider.shouldThrowOnSetDefault = true

        model.setDefaultAccount(alias: "work")
        await waitUntil { model.lastActionError != nil }
        XCTAssertNotNil(model.lastActionError, "Error should be surfaced to the UI")
    }

    // MARK: - removeAccount with error surfacing (host-09)

    func testRemoveAccount_success_removesDomain() async {
        accountProvider.accounts = [makeAccount(alias: "work")]
        accountProvider.shouldThrowOnRemove = false

        let exp = expectation(description: "removeAccount completes")
        Task {
            model.removeAccount(alias: "work")
            try? await Task.sleep(for: .milliseconds(200))
            exp.fulfill()
        }
        await fulfillment(of: [exp], timeout: 2)
        XCTAssertEqual(domainManager.removedAliases, ["work"],
                       "Domain should have been removed on success")
        XCTAssertNil(model.lastActionError)
    }

    func testRemoveAccount_failure_setsLastActionError() async {
        accountProvider.accounts = [makeAccount(alias: "work")]
        accountProvider.shouldThrowOnRemove = true

        model.removeAccount(alias: "work")
        await waitUntil { model.lastActionError != nil }
        XCTAssertNotNil(model.lastActionError,
                        "Sign-out failure should be visible to the user")
    }

    // MARK: - cacheClear with error surfacing (host-09)

    func testCacheClear_success_callsClearOnAllAccounts() async {
        accountProvider.accounts = [makeAccount(alias: "work"), makeAccount(alias: "personal")]
        engineProvider.shouldThrowOnClearCache = false

        let exp = expectation(description: "cacheClear completes")
        Task {
            model.cacheClear()
            try? await Task.sleep(for: .milliseconds(200))
            exp.fulfill()
        }
        await fulfillment(of: [exp], timeout: 2)
        XCTAssertEqual(engineProvider.cacheClearedAliases.count, 2,
                       "clearCache should be called once per account")
        XCTAssertNil(model.lastActionError)
    }

    func testCacheClear_failure_setsLastActionError() async {
        accountProvider.accounts = [makeAccount(alias: "work")]
        engineProvider.shouldThrowOnClearCache = true

        model.cacheClear()
        await waitUntil { model.lastActionError != nil }
        XCTAssertNotNil(model.lastActionError,
                        "Cache clear failure should be surfaced")
    }

    // MARK: - Write fence on Task cancellation (host-03)

    func testSetCacheLimitGB_taskCancellation_releasesWriteFence() async {
        // Call setCacheLimitGB twice rapidly. The first task is cancelled by the
        // second call. After both settle, the fence must be fully lifted.
        model.setCacheLimitGB(5)
        // Short pause to let the first task begin.
        try? await Task.sleep(for: .milliseconds(10))
        // Second call cancels the first.
        model.setCacheLimitGB(6)
        // Poll for the fence to lift rather than sleeping a fixed duration
        // tied to the production debounce value (T2).
        await waitUntil { !model.isFenced(.cacheMaxSize) }
        XCTAssertFalse(model.isFenced(.cacheMaxSize),
                       "Write fence must be released even when the Task is cancelled (host-03)")
    }

    func testSetNetMaxUploads_taskCancellation_releasesWriteFence() async {
        model.setNetMaxUploads(2)
        try? await Task.sleep(for: .milliseconds(10))
        model.setNetMaxUploads(3)
        await waitUntil { !model.isFenced(.netMaxUploads) }
        XCTAssertFalse(model.isFenced(.netMaxUploads),
                       "Fence must be released on cancel for netMaxUploads")
    }

    func testSetNetMaxDownloads_taskCancellation_releasesWriteFence() async {
        model.setNetMaxDownloads(4)
        try? await Task.sleep(for: .milliseconds(10))
        model.setNetMaxDownloads(8)
        await waitUntil { !model.isFenced(.netMaxDownloads) }
        XCTAssertFalse(model.isFenced(.netMaxDownloads),
                       "Fence must be released on cancel for netMaxDownloads")
    }

    // MARK: - Clamp bounds centralized in ConfigSchema (M9)

    /// The host's floor used to hardcode `max(1, min(100, gb))`, which
    /// silently turned the engine's `0 = no limit` sentinel into "1 GB"
    /// before the write ever reached the FPE. This asserts 0 now survives
    /// the full write path: optimistic publish + the XPC value actually sent.
    func testSetCacheLimitGB_zero_isPreservedAsNoLimitSentinel() async {
        // writeConfig resolves the target alias via accountProvider.listAccounts()
        // and bails out silently if it's empty — needed so the write actually
        // reaches the fake engineProvider and configSets gets populated.
        accountProvider.accounts = [makeAccount(alias: "work")]
        model.setCacheLimitGB(0)
        XCTAssertEqual(model.cacheMaxSizeGB, 0,
                       "the optimistic publish must not clamp 0 up to the old floor of 1")

        await waitUntil { !model.isFenced(.cacheMaxSize) }
        XCTAssertEqual(engineProvider.configSets.last?.key, OfemConfigKey.cacheMaxSizeGB.rawValue)
        XCTAssertEqual(engineProvider.configSets.last?.value, "0",
                       "0 must round-trip to the FPE unclamped, matching its own no-limit sentinel")
    }

    /// Existing clamp behaviour must be unchanged for in-range and
    /// out-of-range non-zero values — only the 0 sentinel is special-cased.
    func testSetCacheLimitGB_outOfRange_stillClampsTo_minSizeGB_maxSizeGB() async {
        accountProvider.accounts = [makeAccount(alias: "work")]
        model.setCacheLimitGB(-5)
        await waitUntil { !model.isFenced(.cacheMaxSize) }
        XCTAssertEqual(engineProvider.configSets.last?.value, String(CacheConfig.minSizeGB),
                       "a negative non-zero value must still clamp up to minSizeGB, not to 0")

        model.setCacheLimitGB(9999)
        await waitUntil { !model.isFenced(.cacheMaxSize) }
        XCTAssertEqual(engineProvider.configSets.last?.value, String(CacheConfig.maxSizeGB),
                       "an absurdly large value must still clamp down to maxSizeGB")
    }

    /// `setNetMaxUploads`/`setNetMaxDownloads` now clamp through
    /// `SetConfigLimits`, the same shared bounds the FPE validates against,
    /// instead of independently hardcoded `16`/`32` literals.
    func testSetNetMaxUploadsAndDownloads_clampThroughSharedLimits() async {
        accountProvider.accounts = [makeAccount(alias: "work")]
        model.setNetMaxUploads(9999)
        await waitUntil { !model.isFenced(.netMaxUploads) }
        XCTAssertEqual(engineProvider.configSets.last?.value, String(SetConfigLimits.maxUploadsPerAccount))

        model.setNetMaxDownloads(9999)
        await waitUntil { !model.isFenced(.netMaxDownloads) }
        XCTAssertEqual(engineProvider.configSets.last?.value, String(SetConfigLimits.maxDownloadsPerAccount))
    }

    // MARK: - headerLabel: sign-in + paused both visible when both conditions hold

    func testHeaderLabel_signInAndPaused_showsBoth() async {
        // When both needsSignIn and pausedWorkspaces are set, the header must
        // surface both fragments rather than silently suppressing the paused count.
        let pw = XPCPausedWorkspace(
            accountAlias: "work",
            workspaceID: "ws-1",
            reason: "capacity_paused",
            detectedAtSec: 1_700_000_000
        )
        let status = XPCEngineStatus(
            cacheBytes: 0,
            cacheMaxBytes: 0,
            cacheMaxSizeGB: 0,
            telemetryEnabled: true,
            netMaxUploads: 1,
            netMaxDownloads: 1,
            logLevel: "info",
            pausedWorkspaces: [pw],
            needsSignIn: true
        )
        accountProvider.accounts = [makeAccount(alias: "work")]
        engineProvider.statusToReturn = status

        model.refresh()
        await waitUntil { !model.accountsNeedingSignIn.isEmpty }

        let label = model.headerLabel
        XCTAssertTrue(
            label.contains("sign-in"),
            "headerLabel must include sign-in fragment when needsSignIn=true; got: \(label)"
        )
        XCTAssertTrue(
            label.contains("paused"),
            "headerLabel must include paused fragment when pausedWorkspaces non-empty; got: \(label)"
        )
    }

    func testHeaderLabel_signInOnly_noMentionOfPaused() async {
        let status = XPCEngineStatus(
            cacheBytes: 0,
            cacheMaxBytes: 0,
            cacheMaxSizeGB: 0,
            telemetryEnabled: true,
            netMaxUploads: 1,
            netMaxDownloads: 1,
            logLevel: "info",
            pausedWorkspaces: [],
            needsSignIn: true
        )
        accountProvider.accounts = [makeAccount(alias: "work")]
        engineProvider.statusToReturn = status

        model.refresh()
        await waitUntil { !model.accountsNeedingSignIn.isEmpty }

        let label = model.headerLabel
        XCTAssertTrue(label.contains("sign-in"),
                      "headerLabel must mention sign-in when only needsSignIn=true; got: \(label)")
        XCTAssertFalse(label.contains("paused"),
                       "headerLabel must not mention paused when no workspaces are paused; got: \(label)")
    }

    // MARK: - accountStatusLabel / accountNeedsSignIn gating (issue-273)

    func testAccountStatusLabel_healthy_returnsRunning() async {
        // A healthy account (not in accountsNeedingSignIn) must report "Running"
        // so the per-account submenu status row matches the global header state.
        // Registers a real account with needsSignIn: false so the test covers
        // the post-refresh healthy path, not just the trivial empty-model default.
        let status = XPCEngineStatus(
            cacheBytes: 0,
            cacheMaxBytes: 0,
            cacheMaxSizeGB: 0,
            telemetryEnabled: true,
            netMaxUploads: 1,
            netMaxDownloads: 1,
            logLevel: "info",
            pausedWorkspaces: [],
            needsSignIn: false
        )
        accountProvider.accounts = [makeAccount(alias: "work")]
        engineProvider.statusToReturn = status

        model.refresh()
        await waitUntil { !model.accounts.isEmpty }

        XCTAssertEqual(
            model.accountStatusLabel(alias: "work"),
            "Running",
            "Healthy account must show 'Running' status label"
        )
    }

    func testAccountStatusLabel_needsSignIn_returnsSignInRequired() async {
        // When an alias is in accountsNeedingSignIn the status label must convey
        // the auth error so the submenu header row makes the problem visible
        // without the user reading the orange callout text.
        let status = XPCEngineStatus(
            cacheBytes: 0,
            cacheMaxBytes: 0,
            cacheMaxSizeGB: 0,
            telemetryEnabled: true,
            netMaxUploads: 1,
            netMaxDownloads: 1,
            logLevel: "info",
            pausedWorkspaces: [],
            needsSignIn: true
        )
        accountProvider.accounts = [makeAccount(alias: "work")]
        engineProvider.statusToReturn = status

        model.refresh()
        await waitUntil { !model.accountsNeedingSignIn.isEmpty }

        XCTAssertEqual(
            model.accountStatusLabel(alias: "work"),
            "Sign-in required",
            "Account needing sign-in must show 'Sign-in required' status label"
        )
    }

    func testAccountNeedsSignIn_healthyAlias_returnsFalse() {
        // "Sign In…" must be hidden for a healthy account. Verify the gate
        // condition returns false when the alias is not in accountsNeedingSignIn.
        // The class is @MainActor so no MainActor.run hop is needed.
        XCTAssertFalse(
            model.accountNeedsSignIn(alias: "work"),
            "accountNeedsSignIn must be false for an alias not in the needs-sign-in set"
        )
    }

    func testAccountNeedsSignIn_aliasInSet_returnsTrue() async {
        // Verify the gate condition returns true so "Sign In…" is visible.
        let status = XPCEngineStatus(
            cacheBytes: 0,
            cacheMaxBytes: 0,
            cacheMaxSizeGB: 0,
            telemetryEnabled: true,
            netMaxUploads: 1,
            netMaxDownloads: 1,
            logLevel: "info",
            pausedWorkspaces: [],
            needsSignIn: true
        )
        accountProvider.accounts = [makeAccount(alias: "corp")]
        engineProvider.statusToReturn = status

        model.refresh()
        await waitUntil { model.accountsNeedingSignIn.contains("corp") }

        XCTAssertTrue(
            model.accountNeedsSignIn(alias: "corp"),
            "accountNeedsSignIn must return true so 'Sign In…' is shown for corp"
        )
    }

    func testAccountStatusLabel_multiAccount_correctPerAlias() async {
        // With two accounts where only one needs sign-in, the status labels must
        // be independent: the auth-error alias shows "Sign-in required" while the
        // healthy alias shows "Running".

        // Use a custom EngineStatusProvider that returns per-alias status.
        @MainActor
        final class PerAliasEngineProvider: EngineStatusProvider, @unchecked Sendable {
            func getEngineStatus(alias: String) async throws -> XPCEngineStatus {
                let needsSignIn = alias == "corp"
                return XPCEngineStatus(
                    cacheBytes: 0, cacheMaxBytes: 0, cacheMaxSizeGB: 0,
                    telemetryEnabled: true, netMaxUploads: 1, netMaxDownloads: 1,
                    logLevel: "info", pausedWorkspaces: [], needsSignIn: needsSignIn
                )
            }

            func getBadgeStatus(alias: String) async throws -> XPCBadgeStatus {
                XPCBadgeStatus(needsSignIn: alias == "corp", pausedWorkspaces: [])
            }

            func setConfig(alias _: String, key _: String, value _: String) async throws {}
            func clearCache(alias _: String) async throws -> Int64 {
                0
            }

            func reloadEngine(alias _: String) async throws {}
        }

        let perAliasProvider = PerAliasEngineProvider()
        let localAccountProvider = FakeAccountProvider()
        localAccountProvider.accounts = [makeAccount(alias: "corp"), makeAccount(alias: "personal")]
        let localModel = MenuStatusModel(
            accountProvider: localAccountProvider,
            engineStatusProvider: perAliasProvider,
            domainManager: FakeDomainManager()
        )

        localModel.refresh()
        // Wait until both accounts have been queried (corp must be in the set,
        // personal must not be).
        await waitUntil(timeout: .seconds(3)) {
            localModel.accountsNeedingSignIn.contains("corp") && !localModel.accountsNeedingSignIn.contains("personal")
        }

        XCTAssertEqual(
            localModel.accountStatusLabel(alias: "corp"),
            "Sign-in required",
            "corp (needs sign-in) must show 'Sign-in required'"
        )
        XCTAssertEqual(
            localModel.accountStatusLabel(alias: "personal"),
            "Running",
            "personal (healthy) must show 'Running'"
        )
    }

    // MARK: - Config key constants (host-05)

    func testConfigKeys_matchExpectedLiterals() {
        // Guards against an accidental rawValue change on the wire — the FPE
        // and config.toml both key off these exact dotted strings, and
        // OfemConfigKey.rawValue is what actually crosses the XPC boundary.
        XCTAssertEqual(OfemConfigKey.cacheMaxSizeGB.rawValue, "cache.max_size_gb")
        XCTAssertEqual(OfemConfigKey.telemetry.rawValue, "telemetry")
        XCTAssertEqual(OfemConfigKey.netMaxUploads.rawValue, "net.max_concurrent_uploads_per_account")
        XCTAssertEqual(OfemConfigKey.netMaxDownloads.rawValue, "net.max_concurrent_downloads_per_account")
        XCTAssertEqual(OfemConfigKey.logLevel.rawValue, "log.level")
        XCTAssertEqual(OfemConfigKey.syncMaterializedPollIntervalS.rawValue, "sync.materialized_poll_interval_s")
        XCTAssertEqual(OfemConfigKey.syncSelfHealIntervalM.rawValue, "sync.self_heal_interval_m")
    }
}

// MARK: - Copyright derivation tests (host-10)

final class CopyrightDerivationTests: XCTestCase {
    func testCopyrightYear_calverVersion_extractsYear() {
        XCTAssertEqual(copyrightYear(from: "2026.05.1"), "2026")
        XCTAssertEqual(copyrightYear(from: "2025.12.0"), "2025")
    }

    func testCopyrightYear_malformedVersion_fallsBackToCurrentYear() {
        let currentYear = String(Calendar.current.component(.year, from: Date()))
        // Placeholder not yet replaced (the bug this code guards against).
        XCTAssertEqual(copyrightYear(from: "$(CURRENT_YEAR).05.1"), currentYear)
        // Empty version.
        XCTAssertEqual(copyrightYear(from: ""), currentYear)
        // Non-numeric first component.
        XCTAssertEqual(copyrightYear(from: "dev.05.1"), currentYear)
    }

    func testCopyrightYear_threeDigitYear_fallsBackToCurrentYear() {
        let currentYear = String(Calendar.current.component(.year, from: Date()))
        XCTAssertEqual(copyrightYear(from: "202.05.1"), currentYear)
    }

    func testCopyrightString_containsYear() {
        let s = copyrightString(version: "2026.05.1")
        XCTAssertTrue(s.contains("2026"), "Copyright should contain the version year: \(s)")
        XCTAssertTrue(s.contains("Debruyn"), "Copyright should contain company name: \(s)")
        XCTAssertFalse(s.contains("  "), "Copyright should not have double spaces: \(s)")
    }
}

// MARK: - AddAccountCoordinator extended tests (host-04, host-16)

@MainActor
final class AddAccountCoordinatorExtendedTests: XCTestCase, @unchecked Sendable {
    private var signInProvider: MockSignInProvider!
    private var domainRegistrar: MockDomainRegistrar!
    private var coordinator: AddAccountCoordinator!

    // Reuse the mocks declared in AddAccountCoordinatorTests.swift via @testable import.
    // Since the test bundle includes both files we can reference the private types by
    // redeclaring compatible local versions here.

    /// setUp overrides a nonisolated XCTestCase method and cannot be marked
    /// @MainActor. XCTest always runs setUp on the main thread; this is asserted
    /// via MainActor.assumeIsolated to satisfy Swift 6 strict concurrency.
    override func setUp() {
        super.setUp()
        MainActor.assumeIsolated {
            signInProvider = MockSignInProvider()
            domainRegistrar = MockDomainRegistrar()
            coordinator = AddAccountCoordinator(
                signInProvider: signInProvider,
                domainRegistrar: domainRegistrar
            )
        }
    }

    // MARK: - readyToDismiss after success (host-16)

    func testStartLogin_success_transitionsToReadyToDismiss() async {
        let window = NSWindow()
        signInProvider.behaviour = .succeed(username: "alice@contoso.com")

        coordinator.startLogin(alias: "work", tenant: nil, clientID: nil, window: window)
        // readyToDismiss arrives after successDisplayDuration (~1.2s) + task time.
        await waitUntil(timeout: .seconds(4)) {
            if case .readyToDismiss = coordinator.phase { return true }
            return false
        }

        if case let .readyToDismiss(username) = coordinator.phase {
            XCTAssertEqual(username, "alice@contoso.com")
        } else {
            XCTFail("Expected .readyToDismiss, got \(coordinator.phase)")
        }
    }

    // MARK: - CancellationError resets to idle (host-04)

    func testCancellationError_fromProvider_resetsToIdle() async {
        let window = NSWindow()
        signInProvider.behaviour = .cancel // throws CancellationError

        coordinator.startLogin(alias: "work", tenant: nil, clientID: nil, window: window)
        // startLogin() sets phase = .waiting synchronously before spawning the
        // sign-in Task (see AddAccountCoordinator.startLogin), so by the time
        // this call returns, phase is already .waiting — never the pre-call
        // .idle default. Polling for .idle from here on can therefore only
        // observe the *post*-CancellationError reset (host-04), matching the
        // original sink's sawWaiting guard without needing one.
        await waitUntil(timeout: .seconds(3)) { coordinator.phase == .idle }
        XCTAssertEqual(coordinator.phase, .idle,
                       "CancellationError from provider must not leave phase as .waiting (host-04)")
    }

    // MARK: - Field normalisation in coordinator (host-07)

    func testStartLogin_trimsAlias() async {
        let window = NSWindow()
        signInProvider.behaviour = .succeed(username: "u")
        var capturedAlias = ""
        signInProvider.onSignIn = { alias, _, _, _ in capturedAlias = alias }

        coordinator.startLogin(alias: "  work  ", tenant: nil, clientID: nil, window: window)
        await waitUntil {
            if case .success = coordinator.phase { return true }
            return false
        }
        XCTAssertEqual(capturedAlias, "work", "Alias should be trimmed before passing to signIn")
    }

    func testStartLogin_blankTenant_passesNilToProvider() async {
        let window = NSWindow()
        signInProvider.behaviour = .succeed(username: "u")
        var capturedTenant: String? = "NOT_SET"
        signInProvider.onSignIn = { _, tenant, _, _ in capturedTenant = tenant }

        coordinator.startLogin(alias: "work", tenant: "   ", clientID: nil, window: window)
        await waitUntil {
            if case .success = coordinator.phase { return true }
            return false
        }
        XCTAssertNil(capturedTenant, "Blank tenant should be normalised to nil")
    }
}

// MARK: - Extended MockSignInProvider with capture hook

/// We can't extend the private MockSignInProvider from AddAccountCoordinatorTests.
/// Redeclare a local version with the onSignIn capture hook.
private final class MockSignInProvider: SignInProvider, @unchecked Sendable {
    enum Behaviour {
        case succeed(username: String)
        case fail(Error)
        case cancel
    }

    var behaviour: Behaviour = .succeed(username: "test@example.com")
    var onSignIn: ((String, String?, String?, NSWindow) -> Void)?

    func signIn(
        alias: String,
        tenant: String?,
        clientID: String?,
        window: NSWindow
    ) async throws -> XPCAccountInfo {
        onSignIn?(alias, tenant, clientID, window)
        switch behaviour {
        case let .succeed(username):
            return XPCAccountInfo(alias: alias, username: username, tenantId: "tid", tenantName: "")
        case let .fail(error):
            throw error
        case .cancel:
            throw CancellationError()
        }
    }
}

private final class MockDomainRegistrar: DomainRegistrar, @unchecked Sendable {
    var registeredAliases: [String] = []
    var onRegister: ((String) -> Void)?

    func registerDomain(alias: String) async {
        registeredAliases.append(alias)
        onRegister?(alias)
    }
}
