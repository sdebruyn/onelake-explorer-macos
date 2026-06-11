// AddAccountCoordinatorTests.swift
// Unit tests for AddAccountCoordinator's state transitions.
//
// Uses mock implementations of SignInProvider and DomainRegistrar so
// no MSAL / FPE / Keychain stack is required.

import XCTest
import AppKit
import OfemKit

// MARK: - Mocks

private final class MockSignInProvider: SignInProvider, @unchecked Sendable {
    enum Behaviour {
        case succeed(username: String)
        case fail(Error)
        case cancel
    }

    var behaviour: Behaviour = .succeed(username: "test@example.com")
    var callCount = 0

    func signIn(
        alias: String,
        tenant: String?,
        clientID: String?,
        window: NSWindow
    ) async throws -> XPCAccountInfo {
        callCount += 1
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

    func registerDomain(alias: String) async {
        registeredAliases.append(alias)
    }
}

// MARK: - Tests

@MainActor
final class AddAccountCoordinatorTests: XCTestCase {

    private var signInProvider: MockSignInProvider!
    private var domainRegistrar: MockDomainRegistrar!
    private var coordinator: AddAccountCoordinator!

    override func setUp() {
        super.setUp()
        signInProvider = MockSignInProvider()
        domainRegistrar = MockDomainRegistrar()
        coordinator = AddAccountCoordinator(
            signInProvider: signInProvider,
            domainRegistrar: domainRegistrar
        )
    }

    // MARK: - Initial state

    func testInitialPhase_isIdle() {
        XCTAssertEqual(coordinator.phase, .idle)
    }

    // MARK: - Success path

    func testStartLogin_success_transitionsToSuccess() async {
        let window = NSWindow()
        signInProvider.behaviour = .succeed(username: "alice@contoso.com")

        // Start login and wait for the task to complete.
        let expectation = expectation(description: "phase becomes .success")
        let observation = coordinator.$phase.sink { phase in
            if case .success = phase { expectation.fulfill() }
        }
        coordinator.startLogin(alias: "work", tenant: nil, clientID: nil, window: window)
        await fulfillment(of: [expectation], timeout: 2)
        observation.cancel()

        if case .success(let username) = coordinator.phase {
            XCTAssertEqual(username, "alice@contoso.com")
        } else {
            XCTFail("Expected .success, got \(coordinator.phase)")
        }
    }

    func testStartLogin_success_registersDomain() async {
        let window = NSWindow()
        signInProvider.behaviour = .succeed(username: "alice@contoso.com")

        // Wait for success phase first, then verify domain was registered.
        let successExpectation = expectation(description: "phase becomes .success")
        let observation = coordinator.$phase.sink { phase in
            if case .success = phase { successExpectation.fulfill() }
        }
        coordinator.startLogin(alias: "work", tenant: nil, clientID: nil, window: window)
        await fulfillment(of: [successExpectation], timeout: 2)
        observation.cancel()

        // Give the async domain registration a moment to complete.
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(domainRegistrar.registeredAliases, ["work"],
                       "Domain should have been registered for alias 'work'")
    }

    // MARK: - Failure path

    func testStartLogin_failure_transitionsToFailure() async {
        enum TestError: Error { case oops }
        let window = NSWindow()
        signInProvider.behaviour = .fail(TestError.oops)

        let expectation = expectation(description: "phase becomes .failure")
        let observation = coordinator.$phase.sink { phase in
            if case .failure = phase { expectation.fulfill() }
        }
        coordinator.startLogin(alias: "work", tenant: nil, clientID: nil, window: window)
        await fulfillment(of: [expectation], timeout: 2)
        observation.cancel()

        if case .failure(let msg) = coordinator.phase {
            XCTAssertFalse(msg.isEmpty, "Error message should not be empty")
        } else {
            XCTFail("Expected .failure, got \(coordinator.phase)")
        }
    }

    func testStartLogin_failure_doesNotRegisterDomain() async {
        enum TestError: Error { case oops }
        let window = NSWindow()
        signInProvider.behaviour = .fail(TestError.oops)

        let expectation = expectation(description: "phase becomes .failure")
        let observation = coordinator.$phase.sink { phase in
            if case .failure = phase { expectation.fulfill() }
        }
        coordinator.startLogin(alias: "work", tenant: nil, clientID: nil, window: window)
        await fulfillment(of: [expectation], timeout: 2)
        observation.cancel()

        XCTAssertTrue(domainRegistrar.registeredAliases.isEmpty,
                      "Domain must not be registered on failure")
    }

    // MARK: - Cancel

    func testCancel_resetsToIdle() {
        coordinator.cancel()
        XCTAssertEqual(coordinator.phase, .idle)
    }

    // MARK: - Error mapping

    func testFriendlyError_duplicateAlias() {
        let err = OfemAuthError.duplicateAlias("foo")
        let msg = AddAccountCoordinator.friendlyError(err)
        XCTAssertTrue(msg.contains("foo"), "Message should include the alias: \(msg)")
    }

    func testFriendlyError_emptyAlias() {
        let msg = AddAccountCoordinator.friendlyError(OfemAuthError.emptyAlias)
        XCTAssertTrue(msg.lowercased().contains("alias"), "Message should mention alias: \(msg)")
    }

    func testFriendlyError_unknownError_usesLocalizedDescription() {
        enum E: Error, LocalizedError {
            case boom
            var errorDescription: String? { "Something went wrong" }
        }
        let msg = AddAccountCoordinator.friendlyError(E.boom)
        XCTAssertEqual(msg, "Something went wrong")
    }
}
