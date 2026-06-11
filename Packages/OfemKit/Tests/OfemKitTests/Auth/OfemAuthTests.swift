import Testing
import Foundation
@testable import OfemKit

// MARK: - OfemAuthTests

/// Unit tests for ``OfemAuth`` account management.
///
/// Token acquisition tests require a real MSAL instance and are gated by
/// ``MsalAuthClientTests``. The tests here cover the config-store layer
/// only (add/remove/list/default) using a stub `OfemConfigStore` backed
/// by a temp directory.
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
    @MainActor
    func listAccountsEmpty() throws {
        let (store, _) = try makeStore()
        let auth = OfemAuth(configStore: store)
        #expect(auth.listAccounts().isEmpty)
    }

    @Test("listAccounts returns accounts sorted by alias")
    @MainActor
    func listAccountsSorted() async throws {
        let (store, _) = try makeStore()
        let auth = OfemAuth(configStore: store)

        try await auth.addAccount(makeAccount(alias: "zebra"))
        try await auth.addAccount(makeAccount(alias: "alpha"))
        try await auth.addAccount(makeAccount(alias: "middle"))

        let accounts = auth.listAccounts()
        #expect(accounts.map(\.alias) == ["alpha", "middle", "zebra"])
    }

    // MARK: - addAccount

    @Test("addAccount persists the account to the config store")
    @MainActor
    func addAccountPersists() async throws {
        let (store, _) = try makeStore()
        let auth = OfemAuth(configStore: store)
        let account = makeAccount(alias: "work")

        try await auth.addAccount(account)

        let accounts = auth.listAccounts()
        #expect(accounts.count == 1)
        #expect(accounts.first?.alias == "work")
        #expect(accounts.first?.tenantID == account.tenantID)
    }

    @Test("addAccount rejects duplicate alias")
    @MainActor
    func addAccountDuplicateAlias() async throws {
        let (store, _) = try makeStore()
        let auth = OfemAuth(configStore: store)

        try await auth.addAccount(makeAccount(alias: "work"))
        await #expect(throws: OfemAuthError.self) {
            try await auth.addAccount(makeAccount(alias: "work"))
        }
    }

    @Test("addAccount rejects invalid alias")
    @MainActor
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
    @MainActor
    func removeAccountRemoves() async throws {
        let (store, _) = try makeStore()
        let auth = OfemAuth(configStore: store)

        try await auth.addAccount(makeAccount(alias: "work"))
        try await auth.removeAccount(alias: "work")

        #expect(auth.listAccounts().isEmpty)
    }

    @Test("removeAccount throws on unknown alias")
    @MainActor
    func removeAccountUnknown() async throws {
        let (store, _) = try makeStore()
        let auth = OfemAuth(configStore: store)
        await #expect(throws: OfemAuthError.self) {
            try await auth.removeAccount(alias: "nonexistent")
        }
    }

    @Test("removeAccount clears the default if the removed account was default")
    @MainActor
    func removeAccountClearsDefault() async throws {
        let (store, _) = try makeStore()
        let auth = OfemAuth(configStore: store)

        try await auth.addAccount(makeAccount(alias: "work"))
        try await auth.setDefaultAccount(alias: "work")
        #expect(auth.defaultAccount() == "work")

        try await auth.removeAccount(alias: "work")
        #expect(auth.defaultAccount() == nil)
    }

    // MARK: - defaultAccount / setDefaultAccount

    @Test("defaultAccount returns nil when no default is set")
    @MainActor
    func defaultAccountNilWhenNotSet() throws {
        let (store, _) = try makeStore()
        let auth = OfemAuth(configStore: store)
        #expect(auth.defaultAccount() == nil)
    }

    @Test("setDefaultAccount persists and reads back correctly")
    @MainActor
    func setDefaultAccountRoundTrips() async throws {
        let (store, _) = try makeStore()
        let auth = OfemAuth(configStore: store)

        try await auth.addAccount(makeAccount(alias: "work"))
        try await auth.setDefaultAccount(alias: "work")
        #expect(auth.defaultAccount() == "work")
    }

    @Test("setDefaultAccount throws on unknown alias")
    @MainActor
    func setDefaultAccountUnknown() async throws {
        let (store, _) = try makeStore()
        let auth = OfemAuth(configStore: store)
        await #expect(throws: OfemAuthError.self) {
            try await auth.setDefaultAccount(alias: "nonexistent")
        }
    }

    @Test("Removing one account does not remove others")
    @MainActor
    func removeAccountIsolated() async throws {
        let (store, _) = try makeStore()
        let auth = OfemAuth(configStore: store)

        try await auth.addAccount(makeAccount(alias: "work"))
        try await auth.addAccount(makeAccount(alias: "home"))
        try await auth.removeAccount(alias: "work")

        let remaining = auth.listAccounts()
        #expect(remaining.count == 1)
        #expect(remaining.first?.alias == "home")
    }
}
