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

import XCTest
import Combine
import OfemKit

// MARK: - Fakes

/// Fake AccountProvider for unit tests.
@MainActor
private final class FakeAccountProvider: AccountProvider, @unchecked Sendable {
    var accounts: [Account] = []
    var defaultAccountAlias: String? = nil
    var setDefaultAccountCalled: [(String)] = []
    var removeAccountCalled: [(String)] = []
    var shouldThrowOnSetDefault = false
    var shouldThrowOnRemove = false

    func listAccounts() async -> [Account] { accounts }
    func defaultAccount() async -> String? { defaultAccountAlias }

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

    func getEngineStatus(alias: String) async throws -> XPCEngineStatus {
        guard let s = statusToReturn else { throw FakeError.noStatus }
        return s
    }

    func setConfig(alias: String, key: String, value: String) async throws {
        configSets.append((key: key, value: value))
    }

    func clearCache(alias: String) async throws -> Int64 {
        if shouldThrowOnClearCache { throw FakeError.actionFailed }
        cacheClearedAliases.append(alias)
        return 0
    }
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
final class MenuStatusModelExtendedTests: XCTestCase {

    private var accountProvider: FakeAccountProvider!
    private var engineProvider: FakeEngineStatusProvider!
    private var domainManager: FakeDomainManager!
    private var model: MenuStatusModel!
    private var cancellables = Set<AnyCancellable>()

    override func setUp() {
        super.setUp()
        accountProvider = FakeAccountProvider()
        engineProvider = FakeEngineStatusProvider()
        domainManager = FakeDomainManager()
        model = MenuStatusModel(
            accountProvider: accountProvider,
            engineStatusProvider: engineProvider,
            domainManager: domainManager
        )
    }

    override func tearDown() {
        cancellables.removeAll()
        super.tearDown()
    }

    // MARK: - Refresh with injected fakes

    func testRefresh_populatesAccounts() async {
        accountProvider.accounts = [makeAccount(alias: "work")]
        accountProvider.defaultAccountAlias = "work"

        let exp = expectation(description: "accounts published")
        model.$accounts.dropFirst().sink { accounts in
            if !accounts.isEmpty { exp.fulfill() }
        }.store(in: &cancellables)

        model.refresh()
        await fulfillment(of: [exp], timeout: 2)
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

        let exp = expectation(description: "setDefaultAccount completes")
        // Wait for refresh after action.
        model.$defaultAccount.dropFirst().sink { _ in exp.fulfill() }.store(in: &cancellables)

        model.setDefaultAccount(alias: "work")
        await fulfillment(of: [exp], timeout: 2)
        XCTAssertNil(model.lastActionError, "No error should be set on success")
    }

    func testSetDefaultAccount_failure_setsLastActionError() async {
        accountProvider.accounts = [makeAccount(alias: "work")]
        accountProvider.shouldThrowOnSetDefault = true

        let exp = expectation(description: "lastActionError set")
        model.$lastActionError.dropFirst().sink { error in
            if error != nil { exp.fulfill() }
        }.store(in: &cancellables)

        model.setDefaultAccount(alias: "work")
        await fulfillment(of: [exp], timeout: 2)
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

        let exp = expectation(description: "lastActionError set")
        model.$lastActionError.dropFirst().sink { error in
            if error != nil { exp.fulfill() }
        }.store(in: &cancellables)

        model.removeAccount(alias: "work")
        await fulfillment(of: [exp], timeout: 2)
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

        let exp = expectation(description: "lastActionError set")
        model.$lastActionError.dropFirst().sink { error in
            if error != nil { exp.fulfill() }
        }.store(in: &cancellables)

        model.cacheClear()
        await fulfillment(of: [exp], timeout: 2)
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
        // Wait for the debounce + some margin.
        try? await Task.sleep(for: .seconds(1))
        XCTAssertFalse(model.isFenced(.cacheMaxSize),
                       "Write fence must be released even when the Task is cancelled (host-03)")
    }

    func testSetNetMaxUploads_taskCancellation_releasesWriteFence() async {
        model.setNetMaxUploads(2)
        try? await Task.sleep(for: .milliseconds(10))
        model.setNetMaxUploads(3)
        try? await Task.sleep(for: .seconds(1))
        XCTAssertFalse(model.isFenced(.netMaxUploads),
                       "Fence must be released on cancel for netMaxUploads")
    }

    func testSetNetMaxDownloads_taskCancellation_releasesWriteFence() async {
        model.setNetMaxDownloads(4)
        try? await Task.sleep(for: .milliseconds(10))
        model.setNetMaxDownloads(8)
        try? await Task.sleep(for: .seconds(1))
        XCTAssertFalse(model.isFenced(.netMaxDownloads),
                       "Fence must be released on cancel for netMaxDownloads")
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

        let exp = expectation(description: "accountsNeedingSignIn populated")
        model.$accountsNeedingSignIn.dropFirst().sink { set in
            if !set.isEmpty { exp.fulfill() }
        }.store(in: &cancellables)

        model.refresh()
        await fulfillment(of: [exp], timeout: 2)

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

        let exp = expectation(description: "accountsNeedingSignIn populated")
        model.$accountsNeedingSignIn.dropFirst().sink { set in
            if !set.isEmpty { exp.fulfill() }
        }.store(in: &cancellables)

        model.refresh()
        await fulfillment(of: [exp], timeout: 2)

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
        await MainActor.run {
            let model = MenuStatusModel()
            XCTAssertEqual(
                model.accountStatusLabel(alias: "work"),
                "Running",
                "Healthy account must show 'Running' status label"
            )
        }
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

        let exp = expectation(description: "accountsNeedingSignIn populated")
        model.$accountsNeedingSignIn.dropFirst().sink { set in
            if !set.isEmpty { exp.fulfill() }
        }.store(in: &cancellables)

        model.refresh()
        await fulfillment(of: [exp], timeout: 2)

        XCTAssertEqual(
            model.accountStatusLabel(alias: "work"),
            "Sign-in required",
            "Account needing sign-in must show 'Sign-in required' status label"
        )
    }

    func testAccountNeedsSignIn_healthyAlias_returnsFalse() async {
        // "Sign In Again…" must be hidden for a healthy account. Verify the gate
        // condition returns false when the alias is not in accountsNeedingSignIn.
        await MainActor.run {
            let model = MenuStatusModel()
            XCTAssertFalse(
                model.accountNeedsSignIn(alias: "work"),
                "accountNeedsSignIn must be false for an alias not in the needs-sign-in set"
            )
        }
    }

    func testAccountNeedsSignIn_aliasInSet_returnsTrue() async {
        // Verify the gate condition returns true so "Sign In Again…" is visible.
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

        let exp = expectation(description: "accountsNeedingSignIn populated")
        model.$accountsNeedingSignIn.dropFirst().sink { set in
            if set.contains("corp") { exp.fulfill() }
        }.store(in: &cancellables)

        model.refresh()
        await fulfillment(of: [exp], timeout: 2)

        XCTAssertTrue(
            model.accountNeedsSignIn(alias: "corp"),
            "accountNeedsSignIn must return true so 'Sign In Again…' is shown for corp"
        )
    }

    func testAccountStatusLabel_multiAccount_correctPerAlias() async {
        // With two accounts where only one needs sign-in, the status labels must
        // be independent: the auth-error alias shows "Sign-in required" while the
        // healthy alias shows "Running".
        let statusNeedsSignIn = XPCEngineStatus(
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
        let statusHealthy = XPCEngineStatus(
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
            func setConfig(alias: String, key: String, value: String) async throws {}
            func clearCache(alias: String) async throws -> Int64 { 0 }
        }

        let perAliasProvider = PerAliasEngineProvider()
        let localAccountProvider = FakeAccountProvider()
        localAccountProvider.accounts = [makeAccount(alias: "corp"), makeAccount(alias: "personal")]
        let localModel = MenuStatusModel(
            accountProvider: localAccountProvider,
            engineStatusProvider: perAliasProvider,
            domainManager: FakeDomainManager()
        )

        let exp = expectation(description: "accountsNeedingSignIn updated")
        var cancellable: AnyCancellable?
        cancellable = localModel.$accountsNeedingSignIn.dropFirst().sink { set in
            // Wait until both accounts have been queried (corp must be in the set,
            // personal must not be).
            if set.contains("corp") && !set.contains("personal") {
                exp.fulfill()
                cancellable?.cancel()
            }
        }

        localModel.refresh()
        await fulfillment(of: [exp], timeout: 3)

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
        XCTAssertEqual(OfemConfigKey.cacheMaxSizeGB, "cache.max_size_gb")
        XCTAssertEqual(OfemConfigKey.telemetry, "telemetry")
        XCTAssertEqual(OfemConfigKey.netMaxUploads, "net.max_concurrent_uploads_per_account")
        XCTAssertEqual(OfemConfigKey.netMaxDownloads, "net.max_concurrent_downloads_per_account")
        XCTAssertEqual(OfemConfigKey.logLevel, "log.level")
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
final class AddAccountCoordinatorExtendedTests: XCTestCase {

    private var signInProvider: MockSignInProvider!
    private var domainRegistrar: MockDomainRegistrar!
    private var coordinator: AddAccountCoordinator!
    private var cancellables = Set<AnyCancellable>()

    // Reuse the mocks declared in AddAccountCoordinatorTests.swift via @testable import.
    // Since the test bundle includes both files we can reference the private types by
    // redeclaring compatible local versions here.

    override func setUp() {
        super.setUp()
        signInProvider = MockSignInProvider()
        domainRegistrar = MockDomainRegistrar()
        coordinator = AddAccountCoordinator(
            signInProvider: signInProvider,
            domainRegistrar: domainRegistrar
        )
    }

    override func tearDown() {
        cancellables.removeAll()
        super.tearDown()
    }

    // MARK: - readyToDismiss after success (host-16)

    func testStartLogin_success_transitionsToReadyToDismiss() async {
        let window = NSWindow()
        signInProvider.behaviour = .succeed(username: "alice@contoso.com")

        let exp = expectation(description: "phase becomes .readyToDismiss")
        coordinator.$phase.sink { phase in
            if case .readyToDismiss = phase { exp.fulfill() }
        }.store(in: &cancellables)

        coordinator.startLogin(alias: "work", tenant: nil, clientID: nil, window: window)
        // readyToDismiss arrives after successDisplayDuration (~1.2s) + task time.
        await fulfillment(of: [exp], timeout: 4)

        if case .readyToDismiss(let username) = coordinator.phase {
            XCTAssertEqual(username, "alice@contoso.com")
        } else {
            XCTFail("Expected .readyToDismiss, got \(coordinator.phase)")
        }
    }

    // MARK: - CancellationError resets to idle (host-04)

    func testCancellationError_fromProvider_resetsToIdle() async {
        let window = NSWindow()
        signInProvider.behaviour = .cancel  // throws CancellationError

        // Collect all phases after .waiting to avoid the initial .idle triggering
        // the expectation before startLogin runs.
        var sawWaiting = false
        let exp = expectation(description: "phase returns to idle after CancellationError")
        coordinator.$phase.sink { phase in
            if phase == .waiting { sawWaiting = true }
            // Only fulfil after we saw .waiting, so we know the task ran.
            if phase == .idle, sawWaiting { exp.fulfill() }
        }.store(in: &cancellables)

        coordinator.startLogin(alias: "work", tenant: nil, clientID: nil, window: window)
        // The mock throws CancellationError synchronously; the coordinator should
        // reset to .idle so the Sign In button is not permanently disabled (host-04).
        await fulfillment(of: [exp], timeout: 3)
        XCTAssertEqual(coordinator.phase, .idle,
                       "CancellationError from provider must not leave phase as .waiting (host-04)")
    }

    // MARK: - Field normalisation in coordinator (host-07)

    func testStartLogin_trimsAlias() async {
        let window = NSWindow()
        signInProvider.behaviour = .succeed(username: "u")
        var capturedAlias = ""
        signInProvider.onSignIn = { alias, _, _, _ in capturedAlias = alias }

        let exp = expectation(description: "success")
        coordinator.$phase.sink { if case .success = $0 { exp.fulfill() } }.store(in: &cancellables)
        coordinator.startLogin(alias: "  work  ", tenant: nil, clientID: nil, window: window)
        await fulfillment(of: [exp], timeout: 2)
        XCTAssertEqual(capturedAlias, "work", "Alias should be trimmed before passing to signIn")
    }

    func testStartLogin_blankTenant_passesNilToProvider() async {
        let window = NSWindow()
        signInProvider.behaviour = .succeed(username: "u")
        var capturedTenant: String? = "NOT_SET"
        signInProvider.onSignIn = { _, tenant, _, _ in capturedTenant = tenant }

        let exp = expectation(description: "success")
        coordinator.$phase.sink { if case .success = $0 { exp.fulfill() } }.store(in: &cancellables)
        coordinator.startLogin(alias: "work", tenant: "   ", clientID: nil, window: window)
        await fulfillment(of: [exp], timeout: 2)
        XCTAssertNil(capturedTenant, "Blank tenant should be normalised to nil")
    }
}

// MARK: - Extended MockSignInProvider with capture hook

// We can't extend the private MockSignInProvider from AddAccountCoordinatorTests.
// Redeclare a local version with the onSignIn capture hook.
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
        case .succeed(let username):
            return XPCAccountInfo(alias: alias, username: username, tenantId: "tid", tenantName: "")
        case .fail(let error):
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
