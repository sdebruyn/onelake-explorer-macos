// ReSignInTests.swift
// Unit tests for the "Sign in again" flow in MenuStatusModel.
//
// Verifies:
//   - reSignIn(alias:window:) clears accountsNeedingSignIn on success.
//   - reSignIn(alias:window:) sends a setConfig to trigger engine reload.
//   - reSignIn(alias:window:) surfaces an error in lastActionError on failure.
//   - reSignIn(alias:window:) calls refresh() after completion.
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
    var errorDescription: String? { "User cancelled re-authentication" }
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
        // We do this by publishing directly since the field is private(set) —
        // call refresh() with a faked status that reports needsSignIn=true,
        // then verify reSignIn clears it.
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

        // Refresh to populate accountsNeedingSignIn.
        let refreshDone = expectation(description: "initial refresh sets needsSignIn")
        model.$accountsNeedingSignIn.dropFirst().sink { set in
            if set.contains("work") { refreshDone.fulfill() }
        }.store(in: &cancellables)
        model.refresh()
        await fulfillment(of: [refreshDone], timeout: 2)
        XCTAssertTrue(model.accountNeedsSignIn(alias: "work"),
                      "Pre-condition: work should need sign-in")

        // Now re-auth succeeds — the badge should clear.
        // Also clear the seeded needsSignIn status so the post-reSignIn refresh
        // does not immediately re-set the flag.
        reSignInProvider.behaviour = .succeed
        engineProvider.statusToReturn = defaultStatus

        let cleared = expectation(description: "accountsNeedingSignIn cleared")
        model.$accountsNeedingSignIn.dropFirst().sink { set in
            if !set.contains("work") { cleared.fulfill() }
        }.store(in: &cancellables)

        model.reSignIn(alias: "work", window: NSWindow())
        await fulfillment(of: [cleared], timeout: 2)

        XCTAssertFalse(model.accountNeedsSignIn(alias: "work"),
                       "After reSignIn success, work must no longer need sign-in")
    }

    func testReSignIn_success_callsReSignInProvider() async {
        accountProvider.accounts = [makeTestAccount(alias: "work")]
        reSignInProvider.behaviour = .succeed
        engineProvider.statusToReturn = defaultStatus

        // Wait for the badge to be cleared (accounts go to 0 needs-sign-in).
        let actionDone = expectation(description: "reSignIn action completes")
        // reSignIn clears accountsNeedingSignIn optimistically — use dropFirst to skip
        // the initial published value and only respond to changes.
        model.$accountsNeedingSignIn.dropFirst().sink { _ in actionDone.fulfill() }.store(in: &cancellables)
        model.reSignIn(alias: "work", window: NSWindow())
        await fulfillment(of: [actionDone], timeout: 2)

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

        // Prime the needs-sign-in state.
        let primed = expectation(description: "work needs sign-in")
        model.$accountsNeedingSignIn.dropFirst().sink { set in
            if set.contains("work") { primed.fulfill() }
        }.store(in: &cancellables)
        model.refresh()
        await fulfillment(of: [primed], timeout: 2)

        // Now fail the re-auth.
        reSignInProvider.behaviour = .fail(ReSignInFakeError.cancelled)
        let errSet = expectation(description: "error surfaced")
        model.$lastActionError.dropFirst().compactMap { $0 }.sink { _ in
            errSet.fulfill()
        }.store(in: &cancellables)
        model.reSignIn(alias: "work", window: NSWindow())
        await fulfillment(of: [errSet], timeout: 2)

        // Badge must still be present because re-auth failed.
        XCTAssertTrue(model.accountNeedsSignIn(alias: "work"),
                      "needsSignIn must remain set after a failed reSignIn")
    }

    // MARK: - accountNeedsSignIn helper

    func testAccountNeedsSignIn_falseForUnknownAlias() {
        XCTAssertFalse(model.accountNeedsSignIn(alias: "unknown"))
    }
}
