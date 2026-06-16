// ReSignInTests.swift
// Unit tests for the "Sign in again" flow in MenuStatusModel.
//
// Verifies:
//   - reSignIn(alias:window:) clears accountsNeedingSignIn on success.
//   - reSignIn(alias:window:) sends a setConfig to trigger engine reload.
//   - reSignIn(alias:window:) surfaces an error in lastActionError on failure.
//   - reSignIn(alias:window:) calls refresh() after completion.
//   - reSignIn(alias:window:) keeps the badge set on failure (re-established by refresh).
//   - reSignIn(alias:window:) rejects an identity mismatch from the provider.
//
// Uses mock implementations of ReSignInProvider and EngineStatusProvider
// so no MSAL / FPE / Keychain stack is required.

import XCTest
import AppKit
import Combine
import OfemKit

// MARK: - Fakes

/// Fake ReSignInProvider for unit tests.
@MainActor
private final class FakeReSignInProvider: ReSignInProvider, @unchecked Sendable {
    enum Behaviour { case succeed; case fail(Error) }
    var behaviour: Behaviour = .succeed
    /// Aliases passed to reSignIn, in call order.
    var calledAliases: [String] = []

    func reSignIn(alias: String, window: NSWindow) async throws {
        calledAliases.append(alias)
        switch behaviour {
        case .succeed: return
        case .fail(let error): throw error
        }
    }
}

/// Minimal fake AccountProvider for ReSignIn tests.
@MainActor
private final class FakeReSignInAccountProvider: AccountProvider, @unchecked Sendable {
    var accounts: [Account] = []
    func listAccounts() async -> [Account] { accounts }
    func defaultAccount() async -> String? { nil }
    func setDefaultAccount(alias: String) async throws {}
    func removeAccount(alias: String) async throws {}
}

private let defaultStatus = XPCEngineStatus(
    cacheBytes: 0,
    cacheMaxBytes: 0,
    cacheMaxSizeGB: 10,
    telemetryEnabled: true,
    netMaxUploads: 4,
    netMaxDownloads: 8,
    logLevel: "info",
    pausedWorkspaces: [],
    needsSignIn: false
)

/// Fake EngineStatusProvider that records setConfig calls.
@MainActor
private final class FakeReSignInEngineProvider: EngineStatusProvider, @unchecked Sendable {
    var statusToReturn: XPCEngineStatus = defaultStatus
    var configSets: [(alias: String, key: String, value: String)] = []

    func getEngineStatus(alias: String) async throws -> XPCEngineStatus { statusToReturn }

    func setConfig(alias: String, key: String, value: String) async throws {
        configSets.append((alias: alias, key: key, value: value))
    }

    func clearCache(alias: String) async throws -> Int64 { 0 }
}

/// Fake DomainManager for ReSignIn tests (no-op).
@MainActor
private final class FakeReSignInDomainManager: DomainManager, @unchecked Sendable {
    func removeDomain(alias: String) async {}
}

private enum ReSignInFakeError: Error, LocalizedError {
    case cancelled
    case identityMismatch
    var errorDescription: String? {
        switch self {
        case .cancelled: return "User cancelled re-authentication"
        case .identityMismatch: return "Identity mismatch: signed in as a different account"
        }
    }
}

// MARK: - Helper

private func makeTestAccount(alias: String) -> Account {
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
final class ReSignInTests: XCTestCase {

    private var accountProvider: FakeReSignInAccountProvider!
    private var engineProvider: FakeReSignInEngineProvider!
    private var domainManager: FakeReSignInDomainManager!
    private var reSignInProvider: FakeReSignInProvider!
    private var model: MenuStatusModel!
    private var cancellables = Set<AnyCancellable>()

    override func setUp() {
        super.setUp()
        accountProvider = FakeReSignInAccountProvider()
        engineProvider = FakeReSignInEngineProvider()
        domainManager = FakeReSignInDomainManager()
        reSignInProvider = FakeReSignInProvider()
        model = MenuStatusModel(
            accountProvider: accountProvider,
            engineStatusProvider: engineProvider,
            domainManager: domainManager,
            reSignInProvider: reSignInProvider
        )
    }

    override func tearDown() {
        cancellables.removeAll()
        super.tearDown()
    }

    // MARK: - Success path

    func testReSignIn_success_clearsAccountsNeedingSignIn() async {
        // Seed the model so the "work" alias is in accountsNeedingSignIn.
        accountProvider.accounts = [makeTestAccount(alias: "work")]
        engineProvider.statusToReturn = XPCEngineStatus(
            cacheBytes: 0,
            cacheMaxBytes: 0,
            cacheMaxSizeGB: 10,
            telemetryEnabled: true,
            netMaxUploads: 4,
            netMaxDownloads: 8,
            logLevel: "info",
            pausedWorkspaces: [],
            needsSignIn: true
        )

        // Refresh to populate accountsNeedingSignIn. Wait on `accounts` (fast)
        // then sleep briefly so the later-published accountsNeedingSignIn settles.
        let initialRefreshDone = expectation(description: "initial refresh accounts")
        model.$accounts.dropFirst().sink { accs in
            if !accs.isEmpty { initialRefreshDone.fulfill() }
        }.store(in: &cancellables)
        model.refresh()
        await fulfillment(of: [initialRefreshDone], timeout: 5)
        // Let accountsNeedingSignIn (published after accounts in doRefresh) settle.
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(model.accountNeedsSignIn(alias: "work"),
                      "Pre-condition: work should need sign-in after refresh with needsSignIn=true")

        // Now re-auth succeeds — the badge should clear.
        // Reset the engine to needsSignIn=false so the post-reSignIn refresh
        // does not immediately re-set the flag.
        reSignInProvider.behaviour = .succeed
        engineProvider.statusToReturn = defaultStatus

        // Wait for the post-reSignIn refresh to complete via `accounts` (fast proxy),
        // then assert the badge was cleared (by remove() before refresh or by refresh).
        let postReAuthRefreshDone = expectation(description: "post-reSignIn refresh")
        model.$accounts.dropFirst().sink { _ in postReAuthRefreshDone.fulfill() }.store(in: &cancellables)
        model.reSignIn(alias: "work", window: NSWindow())
        await fulfillment(of: [postReAuthRefreshDone], timeout: 5)
        // Allow accountsNeedingSignIn to settle after the refresh completes.
        try? await Task.sleep(for: .milliseconds(100))

        XCTAssertFalse(model.accountNeedsSignIn(alias: "work"),
                       "After reSignIn success, work must no longer need sign-in")
    }

    func testReSignIn_success_callsReSignInProvider() async {
        accountProvider.accounts = [makeTestAccount(alias: "work")]
        reSignInProvider.behaviour = .succeed
        engineProvider.statusToReturn = defaultStatus

        // Wait for the post-action refresh to complete. `accounts` is published
        // early in doRefresh() (before getEngineStatus awaits), making it a
        // reliable low-latency completion signal on CI.
        let actionDone = expectation(description: "reSignIn action completes")
        model.$accounts.dropFirst().sink { _ in actionDone.fulfill() }.store(in: &cancellables)
        model.reSignIn(alias: "work", window: NSWindow())
        await fulfillment(of: [actionDone], timeout: 5)

        XCTAssertEqual(reSignInProvider.calledAliases.count, 1,
                       "reSignIn should be called exactly once")
        XCTAssertEqual(reSignInProvider.calledAliases.first, "work")
    }

    func testReSignIn_success_triggersEngineReloadViaSetConfig() async {
        accountProvider.accounts = [makeTestAccount(alias: "work")]
        reSignInProvider.behaviour = .succeed
        engineProvider.statusToReturn = defaultStatus

        // Wait for the post-action refresh to complete. The refresh() call is the last
        // step in reSignIn, so by the time model.accounts is repopulated, signalEngineReload
        // (which runs before refresh()) has already sent the setConfig call.
        let refreshed = expectation(description: "refresh after reSignIn completes")
        model.$accounts.dropFirst().sink { _ in refreshed.fulfill() }.store(in: &cancellables)
        model.reSignIn(alias: "work", window: NSWindow())
        await fulfillment(of: [refreshed], timeout: 3)

        // A setConfig call must have been sent to trigger engine reload.
        XCTAssertGreaterThanOrEqual(engineProvider.configSets.count, 1,
                                    "setConfig must be called after reSignIn to trigger engine reload")
        let reloadCall = engineProvider.configSets.first(where: { $0.alias == "work" })
        XCTAssertNotNil(reloadCall,
                        "setConfig must target the re-authed alias")
        XCTAssertEqual(reloadCall?.key, "log.level",
                       "reload is triggered via log.level setConfig")
    }

    func testReSignIn_success_clearsLastActionError() async {
        accountProvider.accounts = [makeTestAccount(alias: "work")]
        engineProvider.statusToReturn = defaultStatus

        // Seed lastActionError from a previous failure.
        reSignInProvider.behaviour = .fail(ReSignInFakeError.cancelled)
        let seeded = expectation(description: "error seeded")
        model.$lastActionError.dropFirst().compactMap { $0 }.sink { _ in
            seeded.fulfill()
        }.store(in: &cancellables)
        model.reSignIn(alias: "work", window: NSWindow())
        await fulfillment(of: [seeded], timeout: 2)
        XCTAssertNotNil(model.lastActionError, "Pre-condition: error must be set")

        // Now succeed — error should clear.
        reSignInProvider.behaviour = .succeed
        let cleared = expectation(description: "error cleared on success")
        model.$lastActionError.sink { err in
            if err == nil { cleared.fulfill() }
        }.store(in: &cancellables)

        model.reSignIn(alias: "work", window: NSWindow())
        await fulfillment(of: [cleared], timeout: 2)
        XCTAssertNil(model.lastActionError, "lastActionError must be nil after successful reSignIn")
    }

    // MARK: - Failure path

    func testReSignIn_failure_setsLastActionError() async {
        accountProvider.accounts = [makeTestAccount(alias: "work")]
        reSignInProvider.behaviour = .fail(ReSignInFakeError.cancelled)

        let exp = expectation(description: "lastActionError is set")
        model.$lastActionError.dropFirst().compactMap { $0 }.sink { msg in
            if !msg.isEmpty { exp.fulfill() }
        }.store(in: &cancellables)

        model.reSignIn(alias: "work", window: NSWindow())
        await fulfillment(of: [exp], timeout: 2)

        XCTAssertNotNil(model.lastActionError,
                        "lastActionError must be set on reSignIn failure")
        XCTAssertTrue(model.lastActionError?.contains("Sign in failed") == true,
                      "Error message should contain 'Sign in failed'; got: \(model.lastActionError ?? "(nil)")")
    }

    func testReSignIn_failure_doesNotClearAccountsNeedingSignIn() async {
        // Verifies the needs-sign-in badge is NOT cleared on re-auth failure.
        //
        // Strategy: prime the badge, then fail re-auth while keeping the engine
        // in needsSignIn=true so the post-failure refresh re-establishes it.
        // The critical property under test: the failure path must NOT call
        // accountsNeedingSignIn.remove(), so the badge cannot be gone after failure.
        accountProvider.accounts = [makeTestAccount(alias: "work")]
        let needsSignInTrue = XPCEngineStatus(
            cacheBytes: 0, cacheMaxBytes: 0, cacheMaxSizeGB: 10,
            telemetryEnabled: true, netMaxUploads: 4, netMaxDownloads: 8,
            logLevel: "info", pausedWorkspaces: [], needsSignIn: true
        )

        // Prime: wait for accounts to publish (fast), then let accountsNeedingSignIn settle.
        engineProvider.statusToReturn = needsSignInTrue
        let initialRefreshDone = expectation(description: "initial refresh accounts")
        model.$accounts.dropFirst().sink { accs in
            if !accs.isEmpty { initialRefreshDone.fulfill() }
        }.store(in: &cancellables)
        model.refresh()
        await fulfillment(of: [initialRefreshDone], timeout: 5)
        try? await Task.sleep(for: .milliseconds(100))
        // Pre-condition: badge must be set after the initial refresh.
        XCTAssertTrue(model.accountNeedsSignIn(alias: "work"),
                      "Pre-condition: work needs sign-in after initial refresh")

        // Fail the re-auth.
        reSignInProvider.behaviour = .fail(ReSignInFakeError.cancelled)
        // Keep needsSignIn=true so the post-failure refresh re-establishes the badge.

        let errSet = expectation(description: "error surfaced after failure")
        model.$lastActionError.dropFirst().compactMap { $0 }.sink { _ in
            errSet.fulfill()
        }.store(in: &cancellables)
        model.reSignIn(alias: "work", window: NSWindow())
        await fulfillment(of: [errSet], timeout: 5)

        // Wait for the post-failure refresh to settle via accounts (fast proxy),
        // then allow accountsNeedingSignIn to settle.
        let refreshSettled = expectation(description: "post-failure refresh settled")
        model.$accounts.dropFirst().sink { _ in refreshSettled.fulfill() }.store(in: &cancellables)
        await fulfillment(of: [refreshSettled], timeout: 5)
        try? await Task.sleep(for: .milliseconds(100))

        XCTAssertTrue(model.accountNeedsSignIn(alias: "work"),
                      "needsSignIn must remain set after a failed reSignIn")
    }

    // MARK: - Identity mismatch

    func testReSignIn_identityMismatch_keepsNeedsSignInBadge() async {
        // Simulate the provider rejecting the re-auth because the returned
        // identity does not match the registered homeAccountID (items 1 & 2 fix).
        accountProvider.accounts = [makeTestAccount(alias: "work")]

        // Prime the needs-sign-in badge via accounts (fast) + sleep for settle.
        engineProvider.statusToReturn = XPCEngineStatus(
            cacheBytes: 0, cacheMaxBytes: 0, cacheMaxSizeGB: 10,
            telemetryEnabled: true, netMaxUploads: 4, netMaxDownloads: 8,
            logLevel: "info", pausedWorkspaces: [], needsSignIn: true
        )
        let initialRefreshDone = expectation(description: "initial refresh accounts")
        model.$accounts.dropFirst().sink { accs in
            if !accs.isEmpty { initialRefreshDone.fulfill() }
        }.store(in: &cancellables)
        model.refresh()
        await fulfillment(of: [initialRefreshDone], timeout: 5)
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(model.accountNeedsSignIn(alias: "work"),
                      "Pre-condition: badge set after refresh with needsSignIn=true")

        // The provider throws an identity mismatch error (simulating what
        // SharedOfemAuth.reSignIn throws when homeAccountIDs differ).
        reSignInProvider.behaviour = .fail(ReSignInFakeError.identityMismatch)

        // Keep the engine returning needsSignIn=true so the post-failure refresh
        // re-establishes the badge.
        let errSet = expectation(description: "identity mismatch error surfaced")
        model.$lastActionError.dropFirst().compactMap { $0 }.sink { msg in
            if !msg.isEmpty { errSet.fulfill() }
        }.store(in: &cancellables)

        model.reSignIn(alias: "work", window: NSWindow())
        await fulfillment(of: [errSet], timeout: 5)

        // The error message must mention sign-in failure.
        XCTAssertNotNil(model.lastActionError,
                        "lastActionError must be set on identity mismatch")
        XCTAssertTrue(model.lastActionError?.contains("Sign in failed") == true,
                      "Error must surface as a sign-in failure; got: \(model.lastActionError ?? "(nil)")")

        // No setConfig call should have been sent because signalEngineReload
        // must not fire when re-auth fails.
        XCTAssertTrue(engineProvider.configSets.isEmpty,
                      "signalEngineReload must NOT be called when re-auth fails due to identity mismatch")

        // Wait for the post-failure refresh to settle, then assert badge is still set.
        let refreshSettled = expectation(description: "post-failure refresh settled")
        model.$accounts.dropFirst().sink { _ in refreshSettled.fulfill() }.store(in: &cancellables)
        await fulfillment(of: [refreshSettled], timeout: 5)
        try? await Task.sleep(for: .milliseconds(100))

        XCTAssertTrue(model.accountNeedsSignIn(alias: "work"),
                      "needsSignIn must remain set after an identity-mismatch rejection")
    }

    // MARK: - accountNeedsSignIn helper

    func testAccountNeedsSignIn_falseForUnknownAlias() {
        XCTAssertFalse(model.accountNeedsSignIn(alias: "unknown"))
    }
}
