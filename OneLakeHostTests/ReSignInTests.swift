// ReSignInTests.swift
// Unit tests for the "Sign in again" flow in MenuStatusModel.
//
// Verifies:
//   - reSignIn(alias:window:) clears accountsNeedingSignIn on success.
//   - reSignIn(alias:window:) calls reloadEngine(alias:) to trigger engine reload.
//   - reSignIn(alias:window:) surfaces an error in lastActionError on failure.
//   - reSignIn(alias:window:) calls refresh() after completion.
//   - reSignIn(alias:window:) keeps the badge set on failure (re-established by refresh).
//   - reSignIn(alias:window:) rejects an identity mismatch from the provider.
//
// Uses mock implementations of ReSignInProvider and EngineStatusProvider
// so no MSAL / FPE / Keychain stack is required.

import AppKit
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

/// Fake EngineStatusProvider that records setConfig and reloadEngine calls.
@MainActor
private final class FakeReSignInEngineProvider: EngineStatusProvider, @unchecked Sendable {
    var statusToReturn: XPCEngineStatus = defaultStatus
    var configSets: [(alias: String, key: String, value: String)] = []
    /// Aliases passed to reloadEngine(alias:), in call order.
    var reloadEngineCalls: [String] = []
    var shouldThrowOnReloadEngine = false

    func getEngineStatus(alias _: String) async throws -> XPCEngineStatus {
        statusToReturn
    }

    func getBadgeStatus(alias _: String) async throws -> XPCBadgeStatus {
        XPCBadgeStatus(needsSignIn: statusToReturn.needsSignIn, pausedWorkspaces: statusToReturn.pausedWorkspaces)
    }

    func setConfig(alias: String, key: String, value: String) async throws {
        configSets.append((alias: alias, key: key, value: value))
    }

    func clearCache(alias _: String) async throws -> Int64 {
        0
    }

    func reloadEngine(alias: String) async throws {
        reloadEngineCalls.append(alias)
        if shouldThrowOnReloadEngine {
            throw ReSignInFakeError.cancelled
        }
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

/// Polls `condition` until it returns true or `timeout` elapses. Used
/// instead of a Combine `$property.sink` subscription — see the identical
/// helper in MenuStatusModelExtendedTests.swift.
///
/// `@MainActor`-isolated (matching every call site, which is always a
/// `@MainActor` test method) so the non-escaping `condition` closure —
/// which reads `@MainActor`-isolated model state — never has to cross an
/// actor boundary.
@MainActor
private func waitUntil(
    timeout: Duration = .seconds(3),
    interval: Duration = .milliseconds(20),
    _ condition: () -> Bool
) async {
    let deadline = ContinuousClock.now + timeout
    while !condition(), ContinuousClock.now < deadline {
        try? await Task.sleep(for: interval)
    }
}

// MARK: - Tests

@MainActor
final class ReSignInTests: XCTestCase, @unchecked Sendable {
    private var accountProvider: FakeReSignInAccountProvider!
    private var engineProvider: FakeReSignInEngineProvider!
    private var domainManager: FakeReSignInDomainManager!
    private var reSignInProvider: FakeReSignInProvider!
    private var model: MenuStatusModel!

    /// setUp overrides a nonisolated XCTestCase method and cannot be marked
    /// @MainActor. XCTest always runs setUp on the main thread; this is asserted
    /// via MainActor.assumeIsolated to satisfy Swift 6 strict concurrency.
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

        // Seed: wait directly for the settled post-refresh state (both the
        // error and the badge) rather than an intermediate "accounts
        // republished" signal — more precise than the original two-signal
        // wait, and avoids the extra settle-sleep it needed.
        model.reSignIn(alias: "work", window: NSWindow())
        await waitUntil(timeout: .seconds(5)) {
            model.lastActionError != nil && model.accountNeedsSignIn(alias: "work")
        }
        XCTAssertTrue(model.accountNeedsSignIn(alias: "work"),
                      "Pre-condition: badge must be set before testing the clear path")

        // Phase 2: now succeed — reset engine to needsSignIn=false so the
        // post-reSignIn refresh does NOT re-assert the badge.
        reSignInProvider.behaviour = .succeed
        engineProvider.statusToReturn = defaultStatus

        model.reSignIn(alias: "work", window: NSWindow())
        await waitUntil(timeout: .seconds(5)) { !model.accountNeedsSignIn(alias: "work") }

        XCTAssertFalse(model.accountNeedsSignIn(alias: "work"),
                       "After reSignIn success, work must no longer need sign-in")
    }

    func testReSignIn_success_callsReSignInProvider() async {
        accountProvider.accounts = [makeTestAccount(alias: "work")]
        reSignInProvider.behaviour = .succeed
        engineProvider.statusToReturn = defaultStatus

        // reSignInProvider.reSignIn(alias:) is called synchronously near the
        // start of the coordinator Task, well before the trailing refresh() —
        // poll directly on it rather than an indirect "accounts republished"
        // signal.
        model.reSignIn(alias: "work", window: NSWindow())
        await waitUntil(timeout: .seconds(5)) { !reSignInProvider.calledAliases.isEmpty }

        XCTAssertEqual(reSignInProvider.calledAliases.count, 1,
                       "reSignIn should be called exactly once")
        XCTAssertEqual(reSignInProvider.calledAliases.first, "work")
    }

    func testReSignIn_success_triggersEngineReloadViaReloadEngineVerb() async {
        accountProvider.accounts = [makeTestAccount(alias: "work")]
        reSignInProvider.behaviour = .succeed
        engineProvider.statusToReturn = defaultStatus

        // reloadEngine runs before the trailing refresh() in reSignIn — poll
        // directly on reloadEngineCalls, the actual thing under test, rather
        // than an indirect "accounts republished" signal.
        model.reSignIn(alias: "work", window: NSWindow())
        await waitUntil(timeout: .seconds(3)) { !engineProvider.reloadEngineCalls.isEmpty }

        // The dedicated reloadEngine(alias:) verb must have been called for the
        // re-authed alias (xpc-11) — no setConfig side effect is used anymore.
        XCTAssertEqual(engineProvider.reloadEngineCalls, ["work"],
                       "reloadEngine(alias:) must be called once for the re-authed alias")
        XCTAssertTrue(engineProvider.configSets.isEmpty,
                      "reSignIn must not fall back to a setConfig side effect to trigger reload")
    }

    func testReSignIn_reloadEngineFailure_isNonFatal_stillClearsBadge() async {
        // reloadEngine is best-effort: a failure must be logged but must not
        // prevent the badge from clearing or surface a UI error, since the
        // FPE's own auto-refresh timer will eventually clear needsSignIn.
        accountProvider.accounts = [makeTestAccount(alias: "work")]

        // Phase 1: seed the badge via a failed re-auth attempt so phase 2's
        // clear assertion is meaningful (mirrors
        // testReSignIn_success_clearsAccountsNeedingSignIn's two-phase setup).
        engineProvider.statusToReturn = XPCEngineStatus(
            cacheBytes: 0, cacheMaxBytes: 0, cacheMaxSizeGB: 10,
            telemetryEnabled: true, netMaxUploads: 4, netMaxDownloads: 8,
            logLevel: "info", pausedWorkspaces: [], needsSignIn: true
        )
        reSignInProvider.behaviour = .fail(ReSignInFakeError.cancelled)
        model.reSignIn(alias: "work", window: NSWindow())
        await waitUntil(timeout: .seconds(5)) { model.accountNeedsSignIn(alias: "work") }
        XCTAssertTrue(model.accountNeedsSignIn(alias: "work"),
                      "Pre-condition: badge must be set before testing the clear path")

        // Phase 2: succeed, but make reloadEngine fail.
        engineProvider.statusToReturn = defaultStatus
        engineProvider.shouldThrowOnReloadEngine = true
        reSignInProvider.behaviour = .succeed

        model.reSignIn(alias: "work", window: NSWindow())
        await waitUntil(timeout: .seconds(3)) { !model.accountNeedsSignIn(alias: "work") }

        XCTAssertEqual(engineProvider.reloadEngineCalls, ["work"],
                       "reloadEngine must still be attempted even though it will fail")
        XCTAssertFalse(model.accountNeedsSignIn(alias: "work"),
                       "A failed reloadEngine must not block clearing the needs-sign-in badge")
        XCTAssertNil(model.lastActionError,
                     "A failed reloadEngine must not surface as a user-visible error")
    }

    func testReSignIn_success_clearsLastActionError() async {
        accountProvider.accounts = [makeTestAccount(alias: "work")]
        engineProvider.statusToReturn = defaultStatus

        // Seed lastActionError from a previous failure.
        reSignInProvider.behaviour = .fail(ReSignInFakeError.cancelled)
        model.reSignIn(alias: "work", window: NSWindow())
        await waitUntil(timeout: .seconds(2)) { model.lastActionError != nil }
        XCTAssertNotNil(model.lastActionError, "Pre-condition: error must be set")

        // Now succeed — error should clear (reSignIn resets it to nil synchronously
        // at the top of the call, before the sign-in Task even runs).
        reSignInProvider.behaviour = .succeed
        model.reSignIn(alias: "work", window: NSWindow())
        await waitUntil(timeout: .seconds(2)) { model.lastActionError == nil }
        XCTAssertNil(model.lastActionError, "lastActionError must be nil after successful reSignIn")
    }

    // MARK: - Failure path

    func testReSignIn_failure_setsLastActionError() async {
        accountProvider.accounts = [makeTestAccount(alias: "work")]
        reSignInProvider.behaviour = .fail(ReSignInFakeError.cancelled)

        model.reSignIn(alias: "work", window: NSWindow())
        await waitUntil(timeout: .seconds(2)) {
            guard let msg = model.lastActionError else { return false }
            return !msg.isEmpty
        }

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

        // Wait directly for the settled post-refresh state (error surfaced AND
        // the badge re-established) rather than an intermediate "accounts
        // republished" signal.
        model.reSignIn(alias: "work", window: NSWindow())
        await waitUntil(timeout: .seconds(5)) {
            model.lastActionError != nil && model.accountNeedsSignIn(alias: "work")
        }

        // Badge must be set because the FPE returns needsSignIn=true.
        XCTAssertTrue(model.accountNeedsSignIn(alias: "work"),
                      "needsSignIn must be set after a failed reSignIn when FPE reports needsSignIn=true")
    }

    // MARK: - Identity mismatch

    func testReSignIn_identityMismatch_keepsNeedsSignInBadge() async {
        // Simulate the provider rejecting the re-auth because the returned
        // identity does not match the registered homeAccountID (items 1 & 2 fix).
        accountProvider.accounts = [makeTestAccount(alias: "work")]
        engineProvider.statusToReturn = XPCEngineStatus(
            cacheBytes: 0, cacheMaxBytes: 0, cacheMaxSizeGB: 10,
            telemetryEnabled: true, netMaxUploads: 4, netMaxDownloads: 8,
            logLevel: "info", pausedWorkspaces: [], needsSignIn: true
        )
        reSignInProvider.behaviour = .fail(ReSignInFakeError.identityMismatch)

        model.reSignIn(alias: "work", window: NSWindow())
        await waitUntil(timeout: .seconds(5)) {
            guard let msg = model.lastActionError, !msg.isEmpty else { return false }
            return model.accountNeedsSignIn(alias: "work")
        }

        // The error message must mention sign-in failure.
        XCTAssertNotNil(model.lastActionError,
                        "lastActionError must be set on identity mismatch")
        XCTAssertTrue(model.lastActionError?.contains("Sign in failed") == true,
                      "Error must surface as a sign-in failure; got: \(model.lastActionError ?? "(nil)")")

        // reloadEngine must not fire when re-auth fails.
        XCTAssertTrue(engineProvider.reloadEngineCalls.isEmpty,
                      "reloadEngine must NOT be called when re-auth fails due to identity mismatch")

        XCTAssertTrue(model.accountNeedsSignIn(alias: "work"),
                      "needsSignIn must remain set after an identity-mismatch rejection")
    }

    // MARK: - accountNeedsSignIn helper

    func testAccountNeedsSignIn_falseForUnknownAlias() {
        XCTAssertFalse(model.accountNeedsSignIn(alias: "unknown"))
    }
}
