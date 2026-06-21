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

import AppKit
import Combine
import OfemKit
import XCTest

// MARK: - Fakes

/// Fake ReSignInProvider for unit tests.
@MainActor
private final class FakeReSignInProvider: ReSignInProvider, @unchecked Sendable {
    enum Behaviour { case succeed; case fail(Error) }
    var behaviour: Behaviour = .succeed
    /// Aliases passed to reSignIn, in call order.
    var calledAliases: [String] = []

    func reSignIn(alias: String, window _: NSWindow) async throws {
        calledAliases.append(alias)
        switch behaviour {
        case .succeed: return
        case let .fail(error): throw error
        }
    }
}

/// Minimal fake AccountProvider for ReSignIn tests.
@MainActor
private final class FakeReSignInAccountProvider: AccountProvider, @unchecked Sendable {
    var accounts: [Account] = []
    func listAccounts() async -> [Account] {
        accounts
    }

    func defaultAccount() async -> String? {
        nil
    }

    func setDefaultAccount(alias _: String) async throws {}
    func removeAccount(alias _: String) async throws {}
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

    func getEngineStatus(alias _: String) async throws -> XPCEngineStatus {
        statusToReturn
    }

    func setConfig(alias: String, key: String, value: String) async throws {
        configSets.append((alias: alias, key: key, value: value))
    }

    func clearCache(alias _: String) async throws -> Int64 {
        0
    }
}

/// Fake DomainManager for ReSignIn tests (no-op).
@MainActor
private final class FakeReSignInDomainManager: DomainManager, @unchecked Sendable {
    func removeDomain(alias _: String) async {}
}

private enum ReSignInFakeError: Error, LocalizedError {
    case cancelled
    case identityMismatch
    var errorDescription: String? {
        switch self {
        case .cancelled: "User cancelled re-authentication"
        case .identityMismatch: "Identity mismatch: signed in as a different account"
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
final class ReSignInTests: XCTestCase, @unchecked Sendable {
    private var accountProvider: FakeReSignInAccountProvider!
    private var engineProvider: FakeReSignInEngineProvider!
    private var domainManager: FakeReSignInDomainManager!
    private var reSignInProvider: FakeReSignInProvider!
    private var model: MenuStatusModel!
    private var cancellables = Set<AnyCancellable>()

    /// setUp and tearDown override nonisolated XCTestCase methods, so they
    /// cannot be marked @MainActor. XCTest always runs them on the main thread;
    /// MainActor.assumeIsolated asserts this invariant and satisfies Swift 6.
    override func setUp() {
        super.setUp()
        MainActor.assumeIsolated {
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
    }

    override func tearDown() {
        MainActor.assumeIsolated {
            cancellables.removeAll()
        }
        super.tearDown()
    }

    // MARK: - Success path

    func testReSignIn_success_clearsAccountsNeedingSignIn() async {
        // Seed the model so the "work" alias is in accountsNeedingSignIn.
        // Phase 1: fail first so reSignIn's post-failure refresh() seeds the badge —
        // avoids an explicit model.refresh() whose lingering subscriptions cause
        // double-fulfill crashes on the next publish. All subscriptions use first()
        // to auto-cancel after a single event.
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
        reSignInProvider.behaviour = .fail(ReSignInFakeError.cancelled)

        // Subscribe to both signals BEFORE triggering the action to avoid a race
        // where the async refresh Task completes before the test subscribes.
        let seedError = expectation(description: "seed failure error")
        model.$lastActionError.dropFirst().compactMap(\.self).first().sink { _ in
            seedError.fulfill()
        }.store(in: &cancellables)

        let seedRefresh = expectation(description: "seed refresh accounts")
        model.$accounts.dropFirst().first().sink { _ in seedRefresh.fulfill() }.store(in: &cancellables)

        model.reSignIn(alias: "work", window: NSWindow())
        await fulfillment(of: [seedError, seedRefresh], timeout: 5)
        // Allow accountsNeedingSignIn (published after accounts in doRefresh) to settle.
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(model.accountNeedsSignIn(alias: "work"),
                      "Pre-condition: badge must be set before testing the clear path")

        // Phase 2: now succeed — reset engine to needsSignIn=false so the
        // post-reSignIn refresh does NOT re-assert the badge.
        reSignInProvider.behaviour = .succeed
        engineProvider.statusToReturn = defaultStatus

        // Wait for the post-reSignIn refresh accounts publication.
        let postReAuthRefreshDone = expectation(description: "post-reSignIn refresh")
        model.$accounts.dropFirst().first().sink { _ in postReAuthRefreshDone.fulfill() }.store(in: &cancellables)
        model.reSignIn(alias: "work", window: NSWindow())
        await fulfillment(of: [postReAuthRefreshDone], timeout: 5)
        // Allow accountsNeedingSignIn to settle.
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
        // reliable low-latency completion signal on CI. first() auto-cancels after
        // the first publish so lingering subscriptions cannot cause double-fulfills.
        let actionDone = expectation(description: "reSignIn action completes")
        model.$accounts.dropFirst().first().sink { _ in actionDone.fulfill() }.store(in: &cancellables)
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
        // first() auto-cancels after one event to prevent double-fulfill crashes.
        let refreshed = expectation(description: "refresh after reSignIn completes")
        model.$accounts.dropFirst().first().sink { _ in refreshed.fulfill() }.store(in: &cancellables)
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
        // Use first() to auto-cancel after the first publish so the subscription
        // does not linger and fire again during phase 2.
        reSignInProvider.behaviour = .fail(ReSignInFakeError.cancelled)
        let seeded = expectation(description: "error seeded")
        model.$lastActionError.dropFirst().compactMap(\.self).first().sink { _ in
            seeded.fulfill()
        }.store(in: &cancellables)
        model.reSignIn(alias: "work", window: NSWindow())
        await fulfillment(of: [seeded], timeout: 2)
        XCTAssertNotNil(model.lastActionError, "Pre-condition: error must be set")

        // Now succeed — error should clear (reSignIn sets it to nil then refresh).
        reSignInProvider.behaviour = .succeed
        let cleared = expectation(description: "error cleared on success")
        model.$lastActionError.dropFirst().first { $0 == nil }.sink { _ in
            cleared.fulfill()
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
        model.$lastActionError.dropFirst().compactMap(\.self).first().sink { msg in
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
        // Verifies the needs-sign-in badge is set (or re-established) after
        // a failed re-auth. The failure path must NOT call
        // accountsNeedingSignIn.remove(), so the badge must be present after
        // the post-failure refresh() picks up needsSignIn=true from the engine.
        accountProvider.accounts = [makeTestAccount(alias: "work")]
        engineProvider.statusToReturn = XPCEngineStatus(
            cacheBytes: 0, cacheMaxBytes: 0, cacheMaxSizeGB: 10,
            telemetryEnabled: true, netMaxUploads: 4, netMaxDownloads: 8,
            logLevel: "info", pausedWorkspaces: [], needsSignIn: true
        )
        reSignInProvider.behaviour = .fail(ReSignInFakeError.cancelled)

        // Use first() on every Combine subscription to guarantee auto-cancel
        // and prevent double-fulfill crashes when the publisher fires more than once.
        let errSet = expectation(description: "error surfaced after failure")
        model.$lastActionError.dropFirst().compactMap(\.self).first().sink { _ in
            errSet.fulfill()
        }.store(in: &cancellables)

        let refreshDone = expectation(description: "post-failure refresh done")
        model.$accounts.dropFirst().first().sink { _ in refreshDone.fulfill() }.store(in: &cancellables)

        model.reSignIn(alias: "work", window: NSWindow())
        await fulfillment(of: [errSet, refreshDone], timeout: 5)
        // Allow accountsNeedingSignIn (published after accounts in doRefresh) to settle.
        try? await Task.sleep(for: .milliseconds(100))

        // Badge must be set because the FPE returns needsSignIn=true.
        XCTAssertTrue(model.accountNeedsSignIn(alias: "work"),
                      "needsSignIn must be set after a failed reSignIn when FPE reports needsSignIn=true")
    }

    // MARK: - Identity mismatch

    func testReSignIn_identityMismatch_keepsNeedsSignInBadge() async {
        // Simulate the provider rejecting the re-auth because the returned
        // identity does not match the registered homeAccountID (items 1 & 2 fix).
        // Use first() on every Combine subscription to prevent double-fulfill crashes.
        accountProvider.accounts = [makeTestAccount(alias: "work")]
        engineProvider.statusToReturn = XPCEngineStatus(
            cacheBytes: 0, cacheMaxBytes: 0, cacheMaxSizeGB: 10,
            telemetryEnabled: true, netMaxUploads: 4, netMaxDownloads: 8,
            logLevel: "info", pausedWorkspaces: [], needsSignIn: true
        )
        reSignInProvider.behaviour = .fail(ReSignInFakeError.identityMismatch)

        // Subscribe before triggering the action so we cannot miss the publish.
        let errSet = expectation(description: "identity mismatch error surfaced")
        model.$lastActionError.dropFirst().compactMap(\.self).first().sink { msg in
            if !msg.isEmpty { errSet.fulfill() }
        }.store(in: &cancellables)

        let refreshDone = expectation(description: "post-failure refresh done")
        model.$accounts.dropFirst().first().sink { _ in refreshDone.fulfill() }.store(in: &cancellables)

        model.reSignIn(alias: "work", window: NSWindow())
        await fulfillment(of: [errSet, refreshDone], timeout: 5)

        // The error message must mention sign-in failure.
        XCTAssertNotNil(model.lastActionError,
                        "lastActionError must be set on identity mismatch")
        XCTAssertTrue(model.lastActionError?.contains("Sign in failed") == true,
                      "Error must surface as a sign-in failure; got: \(model.lastActionError ?? "(nil)")")

        // No setConfig call should have been sent because signalEngineReload
        // must not fire when re-auth fails.
        XCTAssertTrue(engineProvider.configSets.isEmpty,
                      "signalEngineReload must NOT be called when re-auth fails due to identity mismatch")

        // Allow accountsNeedingSignIn (published after accounts in doRefresh) to settle.
        try? await Task.sleep(for: .milliseconds(100))

        XCTAssertTrue(model.accountNeedsSignIn(alias: "work"),
                      "needsSignIn must remain set after an identity-mismatch rejection")
    }

    // MARK: - accountNeedsSignIn helper

    func testAccountNeedsSignIn_falseForUnknownAlias() {
        XCTAssertFalse(model.accountNeedsSignIn(alias: "unknown"))
    }
}
