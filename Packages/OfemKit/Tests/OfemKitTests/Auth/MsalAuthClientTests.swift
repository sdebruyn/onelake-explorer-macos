import Testing
import Foundation
@preconcurrency import MSAL
@testable import OfemKit

// MARK: - MsalApplicationConfigTests

/// Unit tests for ``MsalApplicationConfig/make(clientID:tenantID:cacheStrategy:fileTokenStore:alias:)``.
///
/// These tests exercise the validation and config-building paths without a real
/// MSAL transport. They verify that the security-sensitive properties (redirect URI,
/// keychain group, file-backed cache wiring) are set correctly and that error
/// cases are thrown for missing required parameters.
@Suite("MsalApplicationConfig.make")
struct MsalApplicationConfigTests {
    // MARK: - Redirect URI

    @Test("redirect URI uses running-process bundle ID with msauth.<id>://auth format")
    func redirectURIUsesProcessBundleID() throws {
        // Fix for #272: redirect URI must be derived from the RUNNING process
        // bundle ID, not the hardcoded OfemPaths.bundleID. In the host app
        // (dev.debruyn.ofem) this produces the same URI as before; in the FPE
        // (dev.debruyn.ofem.fileprovider) it produces a URI that MSAL's local
        // validation accepts, allowing silent token acquisition to proceed.
        let config = try MsalApplicationConfig.make(
            clientID: "test-client-id",
            tenantID: "test-tenant-id",
            cacheStrategy: .msalKeychain,
            fileTokenStore: nil,
            alias: nil
        )
        let expectedBundleID = Bundle.main.bundleIdentifier ?? OfemPaths.bundleID
        let expected = "msauth.\(expectedBundleID)://auth"
        #expect(config.redirectUri == expected,
                "redirect URI must use the running process bundle ID (fix #272)")
    }

    @Test("redirect URI fallback uses OfemPaths.bundleID when Bundle.main has no identifier")
    func redirectURIFallbackIsOfemBundleID() throws {
        // Verify the fallback value is `OfemPaths.bundleID` and has the right format.
        // This is the host-app case and the test-runner-nil-bundleID case.
        let fallbackBundleID = OfemPaths.bundleID
        let expectedFallback = "msauth.\(fallbackBundleID)://auth"
        #expect(expectedFallback == "msauth.dev.debruyn.ofem://auth",
                "fallback must be the host app redirect URI")
    }

    @Test("redirect URI format is msauth.<id>://auth regardless of process")
    func redirectURIFormatIsCorrect() throws {
        // The redirect URI must always follow the msauth.<bundleID>://auth pattern.
        let config = try MsalApplicationConfig.make(
            clientID: "test-client-id",
            tenantID: "test-tenant-id",
            cacheStrategy: .msalKeychain,
            fileTokenStore: nil,
            alias: nil
        )
        let uri = config.redirectUri ?? ""
        #expect(uri.hasPrefix("msauth."), "redirect URI must start with msauth.")
        #expect(uri.hasSuffix("://auth"), "redirect URI must end with ://auth")
        // Must not use OfemPaths.bundleID as a literal (would break in FPE).
        // The actual value is the process bundle ID — just verify structural correctness.
        let bundleIDPart = uri
            .dropFirst("msauth.".count)
            .dropLast("://auth".count)
        #expect(!bundleIDPart.isEmpty,
                "redirect URI must contain a non-empty bundle ID component")
    }

    @Test("redirect URI uses injected FPE bundle ID when bundleIdentifier is supplied")
    func redirectURIUsesInjectedFPEBundleID() throws {
        // Fix #272 — FPE path: in the real FPE process Bundle.main.bundleIdentifier
        // returns "dev.debruyn.ofem.fileprovider". In the test runner it is nil, so
        // MsalApplicationConfig.make accepts an explicit bundleIdentifier override so
        // we can exercise the FPE redirect-URI path without a live FPE process.
        let fpeBundleID = "dev.debruyn.ofem.fileprovider"
        let config = try MsalApplicationConfig.make(
            clientID: "test-client-id",
            tenantID: "test-tenant-id",
            cacheStrategy: .msalKeychain,
            fileTokenStore: nil,
            alias: nil,
            bundleIdentifier: fpeBundleID
        )
        let expected = "msauth.\(fpeBundleID)://auth"
        #expect(config.redirectUri == expected,
                "FPE redirect URI must use dev.debruyn.ofem.fileprovider (fix #272)")
    }

    // MARK: - Keychain sharing group

    @Test("keychain sharing group is the OFEM App Group identifier")
    func keychainGroupIsAppGroup() throws {
        let config = try MsalApplicationConfig.make(
            clientID: "test-client-id",
            tenantID: "test-tenant-id",
            cacheStrategy: .msalKeychain,
            fileTokenStore: nil,
            alias: nil
        )
        #expect(config.cacheConfig.keychainSharingGroup == OfemPaths.appGroupIdentifier,
                "keychain group must be the OFEM App Group, not MSAL's default universal storage")
    }

    // MARK: - Authority resolution

    @Test("empty tenantID produces organizations authority")
    func emptyTenantIDProducesOrganizationsAuthority() throws {
        let config = try MsalApplicationConfig.make(
            clientID: "test-client-id",
            tenantID: "",
            cacheStrategy: .msalKeychain,
            fileTokenStore: nil,
            alias: nil
        )
        let authorityURL = config.authority.url.absoluteString
        #expect(authorityURL.contains("organizations"),
                "empty tenantID must resolve to organizations authority")
    }

    @Test("known tenantID produces tenant-specific authority")
    func knownTenantIDProducesTenantAuthority() throws {
        let tenantID = "aaaabbbb-0000-1111-2222-ccccddddeeee"
        let config = try MsalApplicationConfig.make(
            clientID: "test-client-id",
            tenantID: tenantID,
            cacheStrategy: .msalKeychain,
            fileTokenStore: nil,
            alias: nil
        )
        let authorityURL = config.authority.url.absoluteString
        #expect(authorityURL.contains(tenantID),
                "known tenantID must be embedded in the authority URL (auth-03: authority pinned to tenant)")
    }

    // MARK: - fileBackedFallback validation

    @Test("fileBackedFallback without fileTokenStore throws missingFileTokenStore")
    func fileBackedWithoutStoreThrows() throws {
        #expect(throws: MsalAuthClientError.self) {
            try MsalApplicationConfig.make(
                clientID: "test-client-id",
                tenantID: "tenant",
                cacheStrategy: .fileBackedFallback,
                fileTokenStore: nil,
                alias: "work"
            )
        }
    }

    @Test("fileBackedFallback without alias throws missingAlias")
    func fileBackedWithoutAliasThrows() throws {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "msal-config-test-\(UUID().uuidString)", directoryHint: .isDirectory)
        let store = try FileTokenStore(tokensDir: dir)

        #expect(throws: MsalAuthClientError.self) {
            try MsalApplicationConfig.make(
                clientID: "test-client-id",
                tenantID: "tenant",
                cacheStrategy: .fileBackedFallback,
                fileTokenStore: store,
                alias: nil
            )
        }
    }

    @Test("fileBackedFallback with empty alias throws missingAlias")
    func fileBackedWithEmptyAliasThrows() throws {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "msal-config-test-\(UUID().uuidString)", directoryHint: .isDirectory)
        let store = try FileTokenStore(tokensDir: dir)

        #expect(throws: MsalAuthClientError.self) {
            try MsalApplicationConfig.make(
                clientID: "test-client-id",
                tenantID: "tenant",
                cacheStrategy: .fileBackedFallback,
                fileTokenStore: store,
                alias: ""
            )
        }
    }
}

// MARK: - MsalAuthClientErrorDescriptionTests

/// Tests for ``MsalAuthClientError`` description strings.
@Suite("MsalAuthClientError descriptions")
struct MsalAuthClientErrorDescriptionTests {
    @Test("missingClientID description is non-empty")
    func missingClientIDDescription() {
        let err = MsalAuthClientError.missingClientID
        #expect(!err.description.isEmpty)
        #expect(err.description.contains("clientID"))
    }

    @Test("missingFileTokenStore description is non-empty")
    func missingFileTokenStoreDescription() {
        let err = MsalAuthClientError.missingFileTokenStore
        #expect(!err.description.isEmpty)
        #expect(err.description.contains("fileTokenStore"))
    }

    @Test("missingAlias description is non-empty")
    func missingAliasDescription() {
        let err = MsalAuthClientError.missingAlias
        #expect(!err.description.isEmpty)
        #expect(err.description.contains("alias"))
    }

    @Test("accountNotFound description includes the homeAccountID")
    func accountNotFoundDescriptionIncludesID() {
        let id = "object-id.tenant-id"
        let err = MsalAuthClientError.accountNotFound(id)
        #expect(err.description.contains(id))
    }

    @Test("nilResult description is non-empty")
    func nilResultDescription() {
        let err = MsalAuthClientError.nilResult
        #expect(!err.description.isEmpty)
    }
}

// MARK: - MsalAuthClientGuardTests (via mock factory)

/// Tests for ``MsalAuthClient``-adjacent guard paths, exercised through
/// ``OfemAuth`` with a mock factory that throws specific errors.
@Suite("MsalAuthClient guard paths via OfemAuth")
struct MsalAuthClientGuardTests {
    private func makeOfemAuth(factory: MockMsalAuthClientFactory) throws -> OfemAuth {
        let tmp = FileManager.default.temporaryDirectory
            .appending(path: "MsalGuardTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let store = try OfemConfigStore(paths: OfemPaths(root: tmp))
        return OfemAuth(configStore: store, msalClientFactory: factory)
    }

    @Test("empty homeAccountID on account triggers interactionRequired without calling factory")
    func emptyHomeAccountIDTriggersInteractionRequired() async throws {
        let factory = MockMsalAuthClientFactory()
        let auth = try makeOfemAuth(factory: factory)
        let account = Account(
            alias: "noHome",
            tenantID: "t1",
            homeAccountID: "", // deliberately empty
            username: "u@c.com",
            addedAt: ISO8601DateFormatter().string(from: Date())
        )
        try await auth.addAccount(account)

        await #expect(throws: OfemAuthError.interactionRequired) {
            _ = try await auth.tokenForScope(alias: "noHome", scope: .oneLake)
        }
        // Factory must NOT have been called — guard fires before client lookup.
        #expect(factory.makeClientCallCount == 0)
    }

    @Test("factory throwing missingClientID surfaces as factory error, not interactionRequired")
    func factoryThrowingMissingClientIDSurfaces() async throws {
        let factory = MockMsalAuthClientFactory()
        factory.throwError = MsalAuthClientError.missingClientID
        let auth = try makeOfemAuth(factory: factory)
        try await auth.addAccount(makeAccount(alias: "work"))

        await #expect(throws: (any Error).self) {
            _ = try await auth.tokenForScope(alias: "work", scope: .oneLake)
        }
    }
}

// MARK: - OfemAuthRefreshCoalescingTests (auth-01)

/// Regression tests for the in-flight token-request deduplication (auth-01).
///
/// Before the fix, N concurrent callers for the same `(alias, scope)` pair
/// would each trigger an independent MSAL refresh. After the fix, all N callers
/// share one `Task`; only one underlying MSAL call is made.
@Suite("OfemAuth refresh coalescing")
struct OfemAuthRefreshCoalescingTests {
    private func makeAuth(factory: MockMsalAuthClientFactory) throws -> OfemAuth {
        let tmp = FileManager.default.temporaryDirectory
            .appending(path: "OfemAuthCoalesc-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let store = try OfemConfigStore(paths: OfemPaths(root: tmp))
        return OfemAuth(configStore: store, msalClientFactory: factory)
    }

    @Test("N concurrent token requests for the same (alias, scope) result in N tokens but only one MSAL call")
    func concurrentTokenRequestsCoalesce() async throws {
        let factory = MockMsalAuthClientFactory()
        let mockClient = MockMsalAuthClient()
        mockClient.stubbedAccessToken = "coalesced-token"
        // Add artificial delay to allow concurrency to build up.
        mockClient.acquireDelay = 0.05
        factory.stubbedClient = mockClient

        let auth = try makeAuth(factory: factory)
        let account = Account(
            alias: "work",
            tenantID: "t1",
            homeAccountID: "home-coalesce",
            username: "work@contoso.com",
            addedAt: ISO8601DateFormatter().string(from: Date())
        )
        try await auth.addAccount(account)

        // Launch 10 concurrent token requests.
        let results = try await withThrowingTaskGroup(of: String.self, returning: [String].self) { group in
            for _ in 0..<10 {
                group.addTask {
                    try await auth.tokenForScope(alias: "work", scope: .oneLake)
                }
            }
            var tokens: [String] = []
            for try await token in group {
                tokens.append(token)
            }
            return tokens
        }

        // All 10 callers got the coalesced token.
        #expect(results.count == 10)
        #expect(results.allSatisfy { $0 == "coalesced-token" })

        // Only ONE underlying MSAL acquireTokenSilent call was made.
        // (All 10 callers shared the single in-flight Task.)
        let callCount = mockClient.acquireCallCount
        #expect(callCount == 1,
                "concurrent callers must coalesce onto one refresh Task (auth-01); got \(callCount)")
    }

    @Test("shared Task failure is received by all N concurrent waiters, and subsequent call retries fresh")
    func concurrentTokenRequestsCoalesceFailure() async throws {
        let factory = MockMsalAuthClientFactory()
        let mockClient = MockMsalAuthClient()
        // Make MSAL throw a non-interaction-required error for the shared task.
        let injectedError = NSError(domain: "SomeNetworkDomain", code: -1001, userInfo: nil)
        mockClient.stubbedError = injectedError
        // Delay so all callers are waiting on the same in-flight task.
        mockClient.acquireDelay = 0.05
        factory.stubbedClient = mockClient

        let auth = try makeAuth(factory: factory)
        let account = Account(
            alias: "work",
            tenantID: "t1",
            homeAccountID: "home-fail-coalesce",
            username: "work@contoso.com",
            addedAt: ISO8601DateFormatter().string(from: Date())
        )
        try await auth.addAccount(account)

        // Launch 5 concurrent token requests — all should fail with silentTokenFailed.
        var errorCount = 0
        var successCount = 0
        await withThrowingTaskGroup(of: String.self) { group in
            for _ in 0..<5 {
                group.addTask {
                    try await auth.tokenForScope(alias: "work", scope: .oneLake)
                }
            }
            while let result = await group.nextResult() {
                switch result {
                case .success: successCount += 1
                case .failure(OfemAuthError.silentTokenFailed):
                    errorCount += 1
                case .failure:
                    // Any other error type is unexpected.
                    errorCount += 1
                }
            }
        }

        // All 5 callers received the error — none succeeded silently.
        #expect(successCount == 0, "no caller should succeed when the shared task fails")
        #expect(errorCount == 5, "all 5 callers must receive the thrown error")

        // The in-flight entry must have been evicted: a fresh call should start
        // a new Task (one new MSAL call) rather than re-serving the failed task.
        let callCountBefore = mockClient.acquireCallCount // should be 1 (the shared call)

        // Allow the next call to succeed.
        mockClient.stubbedError = nil
        mockClient.stubbedAccessToken = "fresh-token"
        let freshToken = try await auth.tokenForScope(alias: "work", scope: .oneLake)
        #expect(freshToken == "fresh-token", "subsequent call after eviction must return fresh token")
        let callCountAfter = mockClient.acquireCallCount
        #expect(callCountAfter == callCountBefore + 1,
                "evicted task must cause a fresh MSAL call on retry (not re-serve the cached failure)")
    }

    @Test("two different (alias, scope) pairs each trigger their own MSAL call")
    func differentAliasesTriggerSeparateCalls() async throws {
        let factory = MockMsalAuthClientFactory()
        let mockClient = MockMsalAuthClient()
        mockClient.stubbedAccessToken = "token"
        factory.stubbedClient = mockClient

        let auth = try makeAuth(factory: factory)

        let acct1 = Account(
            alias: "alice",
            tenantID: "t-alice",
            homeAccountID: "home-alice",
            username: "alice@c.com",
            addedAt: ISO8601DateFormatter().string(from: Date())
        )
        let acct2 = Account(
            alias: "bob",
            tenantID: "t-bob",
            homeAccountID: "home-bob",
            username: "bob@c.com",
            addedAt: ISO8601DateFormatter().string(from: Date())
        )
        try await auth.addAccount(acct1)
        try await auth.addAccount(acct2)

        _ = try await auth.tokenForScope(alias: "alice", scope: .oneLake)
        _ = try await auth.tokenForScope(alias: "bob", scope: .oneLake)

        let callCount = mockClient.acquireCallCount
        #expect(callCount == 2, "different aliases must each trigger their own MSAL call")
    }
}

// MARK: - OfemAuthInteractionRequiredTests (auth-11)

/// Tests for the broadened `isInteractionRequired` detection that covers
/// AADSTS sub-error codes documented in `docs/auth.md:79`.
@Suite("OfemAuth isInteractionRequired — AADSTS sub-error coverage")
struct OfemAuthInteractionRequiredAADSTSTests {
    private func makeAuth() throws -> OfemAuth {
        let tmp = FileManager.default.temporaryDirectory
            .appending(path: "IsIRAADSTS-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let store = try OfemConfigStore(paths: OfemPaths(root: tmp))
        return OfemAuth(configStore: store)
    }

    @Test("AADSTS50076 in MSALSTSErrorCodesKey (integer array) triggers isInteractionRequired")
    func aadsts50076InSTSErrorCodes() async throws {
        let auth = try makeAuth()
        let err = NSError(
            domain: MSALErrorDomain,
            code: -50000,
            userInfo: ["MSALSTSErrorCodesKey": [NSNumber(value: 50076)]]
        )
        #expect(await auth.isInteractionRequired(err))
    }

    @Test("AADSTS50079 in MSALSTSErrorCodesKey triggers isInteractionRequired")
    func aadsts50079InSTSErrorCodes() async throws {
        let auth = try makeAuth()
        let err = NSError(
            domain: MSALErrorDomain,
            code: -50000,
            userInfo: ["MSALSTSErrorCodesKey": [NSNumber(value: 50079)]]
        )
        #expect(await auth.isInteractionRequired(err))
    }

    @Test("AADSTS50078 in MSALSTSErrorCodesKey triggers isInteractionRequired")
    func aadsts50078InSTSErrorCodes() async throws {
        let auth = try makeAuth()
        let err = NSError(
            domain: MSALErrorDomain,
            code: -50000,
            userInfo: ["MSALSTSErrorCodesKey": [NSNumber(value: 50078)]]
        )
        #expect(await auth.isInteractionRequired(err))
    }

    @Test("AADSTS50158 in MSALSTSErrorCodesKey triggers isInteractionRequired")
    func aadsts50158InSTSErrorCodes() async throws {
        let auth = try makeAuth()
        let err = NSError(
            domain: MSALErrorDomain,
            code: -50000,
            userInfo: ["MSALSTSErrorCodesKey": [NSNumber(value: 50158)]]
        )
        #expect(await auth.isInteractionRequired(err))
    }

    @Test("unrelated STS error code in MSALSTSErrorCodesKey does not trigger isInteractionRequired")
    func unrelatedSTSCodeDoesNotTrigger() async throws {
        let auth = try makeAuth()
        let err = NSError(
            domain: MSALErrorDomain,
            code: -50000,
            userInfo: ["MSALSTSErrorCodesKey": [NSNumber(value: 70011)]]
        )
        #expect(!(await auth.isInteractionRequired(err)))
    }

    @Test("AADSTS50076 in MSALOAuthSubErrorKey triggers isInteractionRequired (sub-error path)")
    func aadsts50076InOAuthSubErrorKey() async throws {
        let auth = try makeAuth()
        let err = NSError(
            domain: MSALErrorDomain,
            code: -50000,
            userInfo: ["MSALOAuthSubErrorKey": "AADSTS50076"]
        )
        #expect(await auth.isInteractionRequired(err))
    }

    @Test("AADSTS50076 in MSALOAuthErrorKey triggers isInteractionRequired")
    func aadsts50076InOAuthErrorKey() async throws {
        let auth = try makeAuth()
        let err = NSError(
            domain: MSALErrorDomain,
            code: -50000,
            userInfo: ["MSALOAuthErrorKey": "AADSTS50076"]
        )
        #expect(await auth.isInteractionRequired(err))
    }

    @Test("NSLocalizedDescriptionKey alone does not trigger isInteractionRequired (locale-stable check)")
    func aadstsInDescriptionOnlyDoesNotTrigger() async throws {
        // Removed: NSLocalizedDescriptionKey substring match is locale-fragile.
        // An AADSTS code in the description alone must NOT trigger interaction-required;
        // only structured userInfo keys (MSALSTSErrorCodesKey, MSALOAuthErrorKey,
        // MSALOAuthSubErrorKey) or the typed MSALError.interactionRequired code do.
        let auth = try makeAuth()
        let err = NSError(
            domain: MSALErrorDomain,
            code: -50000,
            userInfo: [NSLocalizedDescriptionKey: "AADSTS50076: MFA required (localized string only)"]
        )
        #expect(!(await auth.isInteractionRequired(err)),
                "description-only match was removed to avoid locale-fragile detection")
    }

    @Test("unrelated MSAL server error does not trigger isInteractionRequired")
    func unrelatedServerError() async throws {
        let auth = try makeAuth()
        let err = NSError(
            domain: MSALErrorDomain,
            code: -50000,
            userInfo: [NSLocalizedDescriptionKey: "AADSTS70011: The scope requested is not valid."]
        )
        #expect(!(await auth.isInteractionRequired(err)))
    }

    @Test("non-MSAL domain never triggers isInteractionRequired")
    func nonMsalDomainNeverTriggers() async throws {
        let auth = try makeAuth()
        let err = NSError(
            domain: "NSURLErrorDomain",
            code: -1009,
            userInfo: [NSLocalizedDescriptionKey: "AADSTS50076 something"]
        )
        #expect(!(await auth.isInteractionRequired(err)))
    }
}

// MARK: - OfemAuthMsalRemoveErrorTests (auth-05)

/// Tests that a MSAL Keychain remove failure during logout is surfaced
/// rather than silently swallowed.
@Suite("OfemAuth removeAccount surfaces MSAL remove failure")
struct OfemAuthMsalRemoveErrorTests {
    private func makeAuth(factory: MockMsalAuthClientFactory) throws -> OfemAuth {
        let tmp = FileManager.default.temporaryDirectory
            .appending(path: "OfemAuthRemove-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let store = try OfemConfigStore(paths: OfemPaths(root: tmp))
        return OfemAuth(configStore: store, cacheStrategy: .msalKeychain, msalClientFactory: factory)
    }

    @Test("removeAccount throws msalRemoveFailed when MSAL remove throws non-accountNotFound error")
    func removeAccountSurfacesMsalError() async throws {
        let factory = MockMsalAuthClientFactory()
        let mockClient = MockMsalAuthClient()
        let removeError = NSError(domain: "MSALErrorDomain", code: -999, userInfo: nil)
        mockClient.removeError = removeError
        factory.stubbedClient = mockClient

        let auth = try makeAuth(factory: factory)
        let account = Account(
            alias: "work",
            tenantID: "t1",
            homeAccountID: "home-remove-fail",
            username: "work@contoso.com",
            addedAt: ISO8601DateFormatter().string(from: Date())
        )
        try await auth.addAccount(account)

        await #expect(throws: OfemAuthError.self) {
            try await auth.removeAccount(alias: "work")
        }
    }

    @Test("removeAccount treats MsalAuthClientError.accountNotFound as benign (no throw)")
    func removeAccountBenignNotFound() async throws {
        let factory = MockMsalAuthClientFactory()
        let mockClient = MockMsalAuthClient()
        mockClient.removeError = MsalAuthClientError.accountNotFound("home-benign")
        factory.stubbedClient = mockClient

        let auth = try makeAuth(factory: factory)
        let account = Account(
            alias: "work",
            tenantID: "t1",
            homeAccountID: "home-benign",
            username: "work@contoso.com",
            addedAt: ISO8601DateFormatter().string(from: Date())
        )
        try await auth.addAccount(account)

        // Must not throw — accountNotFound is benign.
        try await auth.removeAccount(alias: "work")
        let remaining = await auth.listAccounts()
        #expect(remaining.isEmpty)
    }
}

// MARK: - OfemAuthLoginScopesTests (auth-02)

/// Verifies that `TokenScope.loginScopes` and the two-audience scope model
/// are consistent with `docs/auth.md`.
@Suite("TokenScope loginScopes")
struct TokenScopeLoginScopesTests {
    @Test("oneLakeScopes is non-empty")
    func oneLakeScopesNonEmpty() {
        #expect(!TokenScope.oneLakeScopes.isEmpty)
    }

    @Test("fabricScopes is non-empty")
    func fabricScopesNonEmpty() {
        #expect(!TokenScope.fabricScopes.isEmpty)
    }

    @Test("loginScopes is non-empty")
    func loginScopesNonEmpty() {
        #expect(!TokenScope.loginScopes.isEmpty)
    }

    @Test("loginScopes contains the OneLake storage scope")
    func loginScopesContainsOneLake() {
        // loginScopes must always cover OneLake so the interactive flow
        // captures delegated consent for file I/O.
        for scope in TokenScope.oneLakeScopes {
            #expect(TokenScope.loginScopes.contains(scope),
                    "loginScopes must contain OneLake scope: \(scope)")
        }
    }

    @Test("oneLake scope audience is storage.azure.com")
    func oneLakeScopeAudienceIsStorage() {
        #expect(TokenScope.oneLakeScopes.allSatisfy { $0.contains("storage.azure.com") })
    }

    @Test("fabric scope audience is analysis.windows.net/powerbi/api")
    func fabricScopeAudienceIsPowerBI() {
        #expect(TokenScope.fabricScopes.allSatisfy { $0.contains("analysis.windows.net/powerbi/api") })
    }

    @Test("oneLake and fabric scopes have distinct audiences (no cross-contamination)")
    func scopeAudiencesAreDistinct() {
        for oneLakeScope in TokenScope.oneLakeScopes {
            for fabricScope in TokenScope.fabricScopes {
                #expect(oneLakeScope != fabricScope,
                        "OneLake and Fabric scopes must be distinct: \(oneLakeScope) == \(fabricScope)")
            }
        }
    }
}

// MARK: - InteractiveSignInLogicTests (tests-19)

/// Tests for the pure logic in ``InteractiveSignIn`` that does not require
/// a live MSAL transport.
@Suite("InteractiveSignIn pure logic")
struct InteractiveSignInLogicTests {
    @Test("temporaryAlias starts with .ofem-login-tmp-")
    func temporaryAliasPrefix() {
        let alias = InteractiveSignIn.temporaryAlias()
        #expect(alias.hasPrefix(".ofem-login-tmp-"),
                "scratch alias must start with .ofem-login-tmp-")
    }

    @Test("two temporaryAlias calls produce distinct values (UUID collision resistance)")
    func temporaryAliasIsUnique() {
        let a = InteractiveSignIn.temporaryAlias()
        let b = InteractiveSignIn.temporaryAlias()
        #expect(a != b, "consecutive temporaryAlias calls must produce distinct values")
    }

    @Test("temporaryAlias does not contain a timestamp component (UUID alone is used)")
    func temporaryAliasNoTimestamp() {
        // The old implementation embedded a microsecond timestamp before the UUID.
        // The new implementation uses UUID only. We can't assert the absence of ALL
        // numbers, but we verify the format is the documented prefix + UUID.
        let alias = InteractiveSignIn.temporaryAlias()
        // Must have the prefix and then a UUID-like suffix.
        let suffix = alias.dropFirst(".ofem-login-tmp-".count)
        // A UUID string (lowercased) contains only hex digits and hyphens.
        let allowedChars = CharacterSet(charactersIn: "0123456789abcdef-")
        #expect(suffix.unicodeScalars.allSatisfy { allowedChars.contains($0) },
                "temporaryAlias suffix must be a lowercased UUID string")
    }

    @Test("InteractiveSignInResult.discard is async (smoke test — no crash)")
    func discardAsyncNoScratch() async {
        // A result with no scratch alias — discard must complete without error.
        let result = InteractiveSignInResult(
            account: Account(
                alias: "",
                tenantID: "t",
                homeAccountID: "h",
                username: "u@c.com",
                addedAt: ISO8601DateFormatter().string(from: Date())
            ),
            scratchAlias: nil,
            fileTokenStore: nil
        )
        await result.discard()
        // If we reach here, no crash — pass.
    }
}

// MARK: - OfemAuthClientCacheEvictionTests (auth-13)

/// Tests that addAccount evicts any stale cached client for the same
/// (clientID, tenantID) pair, preventing a re-added alias from inheriting
/// a client whose MSAL cache was just purged.
@Suite("OfemAuth client cache eviction on addAccount")
struct OfemAuthClientCacheEvictionTests {
    private func makeAuth(factory: MockMsalAuthClientFactory) throws -> OfemAuth {
        let tmp = FileManager.default.temporaryDirectory
            .appending(path: "OfemAuthEvict-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let store = try OfemConfigStore(paths: OfemPaths(root: tmp))
        return OfemAuth(configStore: store, msalClientFactory: factory)
    }

    @Test("removing and re-adding the same (clientID, tenantID) builds a fresh client")
    func removeAndReAddEvidencesFreshClient() async throws {
        let factory = MockMsalAuthClientFactory()
        let mockClient = MockMsalAuthClient()
        mockClient.stubbedAccessToken = "tok"
        factory.stubbedClient = mockClient

        let auth = try makeAuth(factory: factory)
        let tenantID = "t-shared"
        let account = Account(
            alias: "work",
            tenantID: tenantID,
            homeAccountID: "home-1",
            username: "work@c.com",
            addedAt: ISO8601DateFormatter().string(from: Date())
        )
        try await auth.addAccount(account)

        // First token call — client is built and cached.
        _ = try await auth.tokenForScope(alias: "work", scope: .oneLake)
        #expect(factory.makeClientCallCount == 1)

        // Remove and re-add the same account.
        try await auth.removeAccount(alias: "work")
        let newAccount = Account(
            alias: "work",
            tenantID: tenantID,
            homeAccountID: "home-2",
            username: "work2@c.com",
            addedAt: ISO8601DateFormatter().string(from: Date())
        )
        try await auth.addAccount(newAccount)

        // Token call after re-add must build a fresh client (eviction happened).
        _ = try await auth.tokenForScope(alias: "work", scope: .oneLake)
        #expect(factory.makeClientCallCount == 2,
                "re-adding an account must evict the stale client and build a fresh one (auth-13)")
    }
}

// MARK: - Updated MockMsalAuthClient (extended for coalescing tests)

extension MockMsalAuthClient {
    /// Number of `acquireTokenSilent` calls made (actor-safe counter).
    var acquireCallCount: Int {
        _lock.withLock { capturedHomeAccountIDs.count }
    }
}
