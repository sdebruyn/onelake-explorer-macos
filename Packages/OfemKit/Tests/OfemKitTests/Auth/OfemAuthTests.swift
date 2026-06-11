import Testing
import Foundation
@preconcurrency import MSAL // needed for MSALErrorDomain and MSALError constants
@testable import OfemKit

// MARK: - OfemAuthTests

/// Unit tests for ``OfemAuth`` account management and token acquisition.
///
/// Token acquisition is tested via a ``MockMsalAuthClientFactory`` that
/// injects ``MockMsalAuthClient`` stubs, covering cache hit/miss,
/// interaction-required propagation, and per-(clientID, tenantID) client reuse.
@Suite("OfemAuth account management")
struct OfemAuthTests {
    // MARK: - Helpers

    /// Creates a fresh temp dir + `OfemPaths` + `OfemConfigStore`.
    private func makeStore() throws -> (store: OfemConfigStore, root: URL) {
        let tmp = FileManager.default.temporaryDirectory
            .appending(path: "OfemAuthTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let paths = OfemPaths(root: tmp)
        let store = try OfemConfigStore(paths: paths)
        return (store, tmp)
    }

    private func makeAccount(alias: String, tenantID: String = "tenant-\(UUID().uuidString)") -> Account {
        Account(
            alias: alias,
            tenantID: tenantID,
            tenantName: nil,
            homeAccountID: "home-\(UUID().uuidString)",
            username: "\(alias)@contoso.com",
            addedAt: ISO8601DateFormatter().string(from: Date()),
            clientID: nil
        )
    }

    // MARK: - listAccounts

    @Test("listAccounts returns empty list when no accounts exist")
    func listAccountsEmpty() async throws {
        let (store, _) = try makeStore()
        let auth = OfemAuth(configStore: store)
        let accounts = await auth.listAccounts()
        #expect(accounts.isEmpty)
    }

    @Test("listAccounts returns accounts sorted by alias")
    func listAccountsSorted() async throws {
        let (store, _) = try makeStore()
        let auth = OfemAuth(configStore: store)

        try await auth.addAccount(makeAccount(alias: "zebra"))
        try await auth.addAccount(makeAccount(alias: "alpha"))
        try await auth.addAccount(makeAccount(alias: "middle"))

        let accounts = await auth.listAccounts()
        #expect(accounts.map(\.alias) == ["alpha", "middle", "zebra"])
    }

    // MARK: - addAccount

    @Test("addAccount persists the account to the config store")
    func addAccountPersists() async throws {
        let (store, _) = try makeStore()
        let auth = OfemAuth(configStore: store)
        let account = makeAccount(alias: "work")

        try await auth.addAccount(account)

        let accounts = await auth.listAccounts()
        #expect(accounts.count == 1)
        #expect(accounts.first?.alias == "work")
        #expect(accounts.first?.tenantID == account.tenantID)
    }

    @Test("addAccount rejects duplicate alias")
    func addAccountDuplicateAlias() async throws {
        let (store, _) = try makeStore()
        let auth = OfemAuth(configStore: store)

        try await auth.addAccount(makeAccount(alias: "work"))
        await #expect(throws: OfemAuthError.self) {
            try await auth.addAccount(makeAccount(alias: "work"))
        }
    }

    @Test("addAccount rejects invalid alias")
    func addAccountInvalidAlias() async throws {
        let (store, _) = try makeStore()
        let auth = OfemAuth(configStore: store)
        let bad = Account(
            alias: "-bad-alias",
            tenantID: "t1",
            homeAccountID: "h1",
            username: "u@c.com",
            addedAt: "2026-01-01T00:00:00Z"
        )
        await #expect(throws: (any Error).self) {
            try await auth.addAccount(bad)
        }
    }

    // MARK: - removeAccount

    @Test("removeAccount removes the account from the config store")
    func removeAccountRemoves() async throws {
        let (store, _) = try makeStore()
        let auth = OfemAuth(configStore: store)

        try await auth.addAccount(makeAccount(alias: "work"))
        try await auth.removeAccount(alias: "work")

        let accounts = await auth.listAccounts()
        #expect(accounts.isEmpty)
    }

    @Test("removeAccount throws on unknown alias")
    func removeAccountUnknown() async throws {
        let (store, _) = try makeStore()
        let auth = OfemAuth(configStore: store)
        await #expect(throws: OfemAuthError.self) {
            try await auth.removeAccount(alias: "nonexistent")
        }
    }

    @Test("removeAccount clears the default if the removed account was default")
    func removeAccountClearsDefault() async throws {
        let (store, _) = try makeStore()
        let auth = OfemAuth(configStore: store)

        try await auth.addAccount(makeAccount(alias: "work"))
        try await auth.setDefaultAccount(alias: "work")
        let def1 = await auth.defaultAccount()
        #expect(def1 == "work")

        try await auth.removeAccount(alias: "work")
        let def2 = await auth.defaultAccount()
        #expect(def2 == nil)
    }

    @Test("removeAccount deletes FileTokenStore blob for the alias")
    func removeAccountDeletesTokenBlob() async throws {
        let (store, root) = try makeStore()
        let paths = OfemPaths(root: root)
        let tokenStore = try FileTokenStore(tokensDir: paths.tokensDir)
        let auth = OfemAuth(
            configStore: store,
            cacheStrategy: .fileBackedFallback,
            fileTokenStore: tokenStore
        )

        let alias = "work"
        try await auth.addAccount(makeAccount(alias: alias))
        // Write a fake token blob.
        try tokenStore.write(alias: alias, data: Data("refresh-token".utf8))

        // Verify the blob exists before removal.
        let blobBefore = try? tokenStore.read(alias: alias)
        #expect(blobBefore != nil)

        try await auth.removeAccount(alias: alias)

        // After removal the blob should be gone.
        var blobAfter: Data?
        do {
            blobAfter = try tokenStore.read(alias: alias)
        } catch FileTokenStoreError.notFound {
            blobAfter = nil
        }
        #expect(blobAfter == nil)
    }

    // MARK: - defaultAccount / setDefaultAccount

    @Test("defaultAccount returns nil when no default is set")
    func defaultAccountNilWhenNotSet() async throws {
        let (store, _) = try makeStore()
        let auth = OfemAuth(configStore: store)
        let def = await auth.defaultAccount()
        #expect(def == nil)
    }

    @Test("setDefaultAccount persists and reads back correctly")
    func setDefaultAccountRoundTrips() async throws {
        let (store, _) = try makeStore()
        let auth = OfemAuth(configStore: store)

        try await auth.addAccount(makeAccount(alias: "work"))
        try await auth.setDefaultAccount(alias: "work")
        let def = await auth.defaultAccount()
        #expect(def == "work")
    }

    @Test("setDefaultAccount throws on unknown alias")
    func setDefaultAccountUnknown() async throws {
        let (store, _) = try makeStore()
        let auth = OfemAuth(configStore: store)
        await #expect(throws: OfemAuthError.self) {
            try await auth.setDefaultAccount(alias: "nonexistent")
        }
    }

    @Test("Removing one account does not remove others")
    func removeAccountIsolated() async throws {
        let (store, _) = try makeStore()
        let auth = OfemAuth(configStore: store)

        try await auth.addAccount(makeAccount(alias: "work"))
        try await auth.addAccount(makeAccount(alias: "home"))
        try await auth.removeAccount(alias: "work")

        let remaining = await auth.listAccounts()
        #expect(remaining.count == 1)
        #expect(remaining.first?.alias == "home")
    }
}

// MARK: - OfemAuthTokenTests

/// Token-acquisition path tests using a ``MockMsalAuthClientFactory``.
@Suite("OfemAuth token acquisition")
struct OfemAuthTokenTests {
    // MARK: - Helpers

    private func makeStore() throws -> (store: OfemConfigStore, root: URL) {
        let tmp = FileManager.default.temporaryDirectory
            .appending(path: "OfemAuthTokenTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let paths = OfemPaths(root: tmp)
        let store = try OfemConfigStore(paths: paths)
        return (store, tmp)
    }

    private func makeAccount(alias: String, tenantID: String, homeAccountID: String) -> Account {
        Account(
            alias: alias,
            tenantID: tenantID,
            tenantName: nil,
            homeAccountID: homeAccountID,
            username: "\(alias)@contoso.com",
            addedAt: ISO8601DateFormatter().string(from: Date()),
            clientID: nil
        )
    }

    // MARK: - Token cache hit

    @Test("tokenForScope returns cached access token on success")
    func tokenCacheHit() async throws {
        let (store, _) = try makeStore()
        let factory = MockMsalAuthClientFactory()
        let mockClient = MockMsalAuthClient()
        mockClient.stubbedAccessToken = "access-token-123"
        factory.stubbedClient = mockClient

        let auth = OfemAuth(configStore: store, msalClientFactory: factory)
        let account = makeAccount(alias: "work", tenantID: "tenant-1", homeAccountID: "home-abc")
        try await auth.addAccount(account)

        let token = try await auth.tokenForScope(alias: "work", scope: .oneLake)
        #expect(token == "access-token-123")
    }

    // MARK: - Unknown alias

    @Test("tokenForScope throws unknownAlias when account does not exist")
    func tokenUnknownAlias() async throws {
        let (store, _) = try makeStore()
        let auth = OfemAuth(configStore: store, msalClientFactory: MockMsalAuthClientFactory())

        await #expect(throws: OfemAuthError.self) {
            _ = try await auth.tokenForScope(alias: "nobody", scope: .oneLake)
        }
    }

    // MARK: - interaction-required propagation (typed error)

    @Test("tokenForScope propagates interactionRequired when MSAL returns the typed error code")
    func tokenInteractionRequiredTyped() async throws {
        let (store, _) = try makeStore()
        let factory = MockMsalAuthClientFactory()
        let mockClient = MockMsalAuthClient()
        // Inject the typed MSAL error.
        mockClient.stubbedError = NSError(
            domain: MSALErrorDomain,
            code: MSALError.interactionRequired.rawValue,
            userInfo: nil
        )
        factory.stubbedClient = mockClient

        let auth = OfemAuth(configStore: store, msalClientFactory: factory)
        try await auth.addAccount(makeAccount(alias: "work", tenantID: "t1", homeAccountID: "home-xyz"))

        await #expect(throws: OfemAuthError.interactionRequired) {
            _ = try await auth.tokenForScope(alias: "work", scope: .oneLake)
        }
    }

    @Test("tokenForScope does not treat non-MSAL errors as interaction-required")
    func tokenNonMsalErrorNotInteractionRequired() async throws {
        let (store, _) = try makeStore()
        let factory = MockMsalAuthClientFactory()
        let mockClient = MockMsalAuthClient()
        mockClient.stubbedHomeAccountID = "home-xyz"
        let nonMsalError = NSError(domain: "SomeOtherDomain", code: 42, userInfo: nil)
        mockClient.stubbedError = nonMsalError
        factory.stubbedClient = mockClient

        let auth = OfemAuth(configStore: store, msalClientFactory: factory)
        try await auth.addAccount(makeAccount(alias: "work", tenantID: "t1", homeAccountID: "home-xyz"))

        // Should throw silentTokenFailed (not interactionRequired).
        var caughtCorrectError = false
        do {
            _ = try await auth.tokenForScope(alias: "work", scope: .oneLake)
            #expect(Bool(false), "Expected an error to be thrown")
        } catch OfemAuthError.interactionRequired {
            #expect(Bool(false), "Expected silentTokenFailed, not interactionRequired")
        } catch OfemAuthError.silentTokenFailed {
            caughtCorrectError = true
        }
        #expect(caughtCorrectError)
    }

    // MARK: - Per-(clientID, tenantID) client reuse

    @Test("clientFor reuses the same client instance for the same (clientID, tenantID)")
    func clientReuseForSamePair() async throws {
        let (store, _) = try makeStore()
        let factory = MockMsalAuthClientFactory()
        let mockClient = MockMsalAuthClient()
        mockClient.stubbedAccessToken = "tok"
        factory.stubbedClient = mockClient

        let auth = OfemAuth(configStore: store, msalClientFactory: factory)
        let tenantID = "t-shared"

        // Two aliases in the same tenant → same (clientID, tenantID) pair.
        try await auth.addAccount(makeAccount(alias: "a1", tenantID: tenantID, homeAccountID: "home-1"))
        try await auth.addAccount(makeAccount(alias: "a2", tenantID: tenantID, homeAccountID: "home-1"))

        _ = try await auth.tokenForScope(alias: "a1", scope: .oneLake)
        _ = try await auth.tokenForScope(alias: "a2", scope: .oneLake)

        // Factory should have been called once (the second call reuses the cached client).
        #expect(factory.makeClientCallCount == 1)
    }

    @Test("clientFor builds separate clients for different tenantIDs")
    func clientSeparateForDifferentTenants() async throws {
        let (store, _) = try makeStore()
        let factory = MockMsalAuthClientFactory()
        let mockClient = MockMsalAuthClient()
        mockClient.stubbedAccessToken = "tok"
        factory.stubbedClient = mockClient

        let auth = OfemAuth(configStore: store, msalClientFactory: factory)

        try await auth.addAccount(makeAccount(alias: "a1", tenantID: "t1", homeAccountID: "home-1"))
        try await auth.addAccount(makeAccount(alias: "a2", tenantID: "t2", homeAccountID: "home-1"))

        _ = try await auth.tokenForScope(alias: "a1", scope: .oneLake)
        _ = try await auth.tokenForScope(alias: "a2", scope: .oneLake)

        // Factory should have been called twice — one per tenant.
        #expect(factory.makeClientCallCount == 2)
    }

    // MARK: - isInteractionRequired unit test

    @Test("isInteractionRequired returns true for MSALError.interactionRequired")
    func isInteractionRequiredTypedCode() async throws {
        let (store, _) = try makeStore()
        let auth = OfemAuth(configStore: store)

        let msalError = NSError(
            domain: MSALErrorDomain,
            code: MSALError.interactionRequired.rawValue,
            userInfo: nil
        )
        let result = await auth.isInteractionRequired(msalError)
        #expect(result)
    }

    @Test("isInteractionRequired returns false for a non-MSAL error domain")
    func isInteractionRequiredNonMsal() async throws {
        let (store, _) = try makeStore()
        let auth = OfemAuth(configStore: store)

        let otherError = NSError(domain: "NSURLErrorDomain", code: -1009, userInfo: nil)
        let result = await auth.isInteractionRequired(otherError)
        #expect(!result)
    }

    @Test("isInteractionRequired returns false for unrelated MSAL error codes")
    func isInteractionRequiredOtherMsalCode() async throws {
        let (store, _) = try makeStore()
        let auth = OfemAuth(configStore: store)

        let otherMsalError = NSError(
            domain: MSALErrorDomain,
            code: MSALError.serverDeclinedScopes.rawValue,
            userInfo: nil
        )
        let result = await auth.isInteractionRequired(otherMsalError)
        #expect(!result)
    }
}

// MARK: - Mock helpers

/// Test double for ``MsalAuthClientFactory``.
final class MockMsalAuthClientFactory: MsalAuthClientFactory, @unchecked Sendable {
    var stubbedClient: MockMsalAuthClient?
    private(set) var makeClientCallCount = 0
    private let _lock = NSLock()

    func makeClient(
        clientID: String,
        tenantID: String,
        cacheStrategy: TokenCacheStrategy,
        fileTokenStore: FileTokenStore?,
        alias: String
    ) throws -> any MsalAuthClientProtocol {
        _lock.withLock { makeClientCallCount += 1 }
        guard let client = stubbedClient else {
            throw MockError.noClientStubbed
        }
        return client
    }

    enum MockError: Error { case noClientStubbed }
}

/// Test double for ``MsalAuthClientProtocol``.
///
/// Returns `stubbedAccessToken` or throws `stubbedError` from
/// `acquireTokenSilent`. No `MSALAccount` or `MSALResult` is involved.
final class MockMsalAuthClient: MsalAuthClientProtocol, @unchecked Sendable {
    var stubbedAccessToken: String = "mock-token"
    var stubbedHomeAccountID: String = "mock-home-id"
    var stubbedError: Error?

    func acquireTokenSilent(
        scopes: [String],
        homeAccountID: String
    ) async throws -> String {
        if let error = stubbedError { throw error }
        return stubbedAccessToken
    }
}

// MARK: - OfemAuthIsInteractionRequiredTests

/// Direct unit tests for ``OfemAuth/isInteractionRequired(_:)`` — ensuring
/// only the typed MSAL error code triggers the interaction-required path.
@Suite("OfemAuth isInteractionRequired")
struct OfemAuthIsInteractionRequiredTests {
    private func makeAuth() throws -> OfemAuth {
        let tmp = FileManager.default.temporaryDirectory
            .appending(path: "IsIRTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let paths = OfemPaths(root: tmp)
        let store = try OfemConfigStore(paths: paths)
        return OfemAuth(configStore: store)
    }

    @Test("MSALError.interactionRequired typed code → true")
    func typedInteractionRequired() async throws {
        let auth = try makeAuth()
        let err = NSError(domain: MSALErrorDomain, code: MSALError.interactionRequired.rawValue)
        #expect(await auth.isInteractionRequired(err))
    }

    @Test("Non-MSAL domain → false")
    func nonMsalDomain() async throws {
        let auth = try makeAuth()
        let err = NSError(domain: "NSURLErrorDomain", code: -1009)
        #expect(await auth.isInteractionRequired(err) == false)
    }

    @Test("MSALError.serverDeclinedScopes (different code) → false")
    func serverDeclinedScopes() async throws {
        let auth = try makeAuth()
        let err = NSError(domain: MSALErrorDomain, code: MSALError.serverDeclinedScopes.rawValue)
        #expect(await auth.isInteractionRequired(err) == false)
    }
}
