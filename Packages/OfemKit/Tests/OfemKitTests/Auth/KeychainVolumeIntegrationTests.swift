import Testing
import Foundation
import Security
@testable import OfemKit

// MARK: - KeychainVolumeIntegrationTests

/// GO / NO-GO checkpoint: measures Keychain item sizes for the MSAL Swift
/// token cache under realistic multi-account, multi-tenant scenarios.
///
/// ## What this tests
///
/// MSAL Swift on macOS stores its token cache as **two JSON blobs** in the
/// macOS login.keychain (not iCloud Keychain):
///
/// 1. **Shared blob** — refresh tokens + account records for all apps
///    sharing the `com.microsoft.identity.universalstorage` access group.
/// 2. **Non-shared (app) blob** — access tokens, ID tokens, app metadata,
///    scoped to this app's bundle ID.
///
/// The macOS login.keychain does NOT enforce the ~16 KB per-item limit that
/// applies to iCloud Keychain sync items. The limit for login.keychain data
/// values is controlled by the host process address space — effectively
/// unlimited for practical purposes.
///
/// By contrast, the Go daemon previously used `go-keyring` which targeted
/// the iCloud-sync path and hit the 16 KB limit after a single Entra login.
/// That is why `internal/auth/keychain.go` switched to file-backed storage.
///
/// ## Test method
///
/// Because we cannot produce real MSAL token blobs without an interactive
/// login, these tests construct **realistic mock cache blobs** that match the
/// JSON structure of `MSIDMacKeychainTokenCache`'s shared and non-shared
/// blobs. Each fake account produces entries of the same magnitude as a real
/// login (approximately 4–6 KB per account based on the MSAL Go integration
/// test cache at `apps/tests/integration/serialized_cache_1.1.1.json`,
/// which is ~11.9 KB for a single-account session).
///
/// The test writes these blobs to a **private keychain item** using a
/// temporary service name so existing MSAL cache items are never disturbed.
/// Each test cleans up its own keychain items.
///
/// ## Running manually
///
/// These tests are **disabled by default** because they write to the real
/// macOS keychain and require the test runner to have keychain access (i.e.
/// they cannot run headlessly in CI without special entitlements).
///
/// To run manually from the command line (with a signed build):
/// ```bash
/// cd Packages/OfemKit
/// swift test --filter KeychainVolumeIntegrationTests
/// ```
///
/// Or from Xcode: Product > Test, then filter by "KeychainVolumeIntegration".
///
/// ## GO / NO-GO conclusion
///
/// See `docs/swift-migration-msal-keychain-test.md` for the recorded
/// results of the manual run. Summary:
///
/// - The login.keychain does NOT have a 16 KB item limit.
/// - Realistic MSAL cache blobs for 15 accounts / 3 tenants fit well within
///   available limits (estimated ~60–90 KB per blob).
/// - **GO**: MSAL Swift's default keychain strategy is viable for OFEM's
///   multi-account, multi-tenant use case.
@Suite("Keychain volume checkpoint (requires keychain access — run manually)")
struct KeychainVolumeIntegrationTests {
    // MARK: - Helpers

    /// Approximate byte size of one MSAL token cache entry for a single
    /// account/tenant pair. Derived from the MSAL Go integration test
    /// reference file `serialized_cache_1.1.1.json` (11,964 bytes for one
    /// account), which includes:
    ///   - One AccessToken entry (~2.5 KB with base64 JWT)
    ///   - One RefreshToken entry (~1.0 KB)
    ///   - One IdToken entry (~1.5 KB)
    ///   - One Account entry (~0.5 KB)
    ///   - AppMetadata + AccountMetadata (~0.5 KB)
    /// Total: ~6 KB per account per tenant in the MSAL JSON format.
    private static let bytesPerAccount = 6_000

    /// Makes a realistic mock cache blob for N accounts across M tenants.
    ///
    /// The JSON structure mirrors `MSIDMacKeychainTokenCache` shared/non-shared
    /// blob schemas documented in `MSIDMacKeychainTokenCache.m`:
    ///
    ///     { "RefreshToken": { "<key>": {...} }, "Account": { "<key>": {...} } }
    ///
    /// and:
    ///
    ///     { "AccessToken": { "<key>": {...} }, "IdToken": { "<key>": {...} },
    ///       "AppMetadata": {...}, "AccountMetadata": {...} }
    private static func makeSharedBlob(accounts: Int, tenantsPerAccount: Int) -> Data {
        var refreshTokens: [String: [String: String]] = [:]
        var accountEntries: [String: [String: String]] = [:]

        for a in 0..<accounts {
            for t in 0..<tenantsPerAccount {
                let homeAccountID = "objectid\(a).tenantid\(t)"
                let env = "login.windows.net"
                let realm = "tenantid\(t)"
                let clientID = ofemEntraClientID

                // RefreshToken entry key: <home_account_id>-<env>-RefreshToken-<client_id>--
                let rtKey = "\(homeAccountID)-\(env)-RefreshToken-\(clientID)--"
                refreshTokens[rtKey] = [
                    "secret": String(repeating: "r", count: 512), // ~512 byte refresh token
                    "environment": env,
                    "credential_type": "RefreshToken",
                    "home_account_id": homeAccountID,
                    "client_id": clientID,
                    "last_modification_time": "1748000000.000",
                    "last_modification_app": "dev.debruyn.ofem;1",
                ]

                // Account entry key: <home_account_id>-<env>-<realm>
                let accountKey = "\(homeAccountID)-\(env)-\(realm)"
                accountEntries[accountKey] = [
                    "home_account_id": homeAccountID,
                    "environment": env,
                    "realm": realm,
                    "authority_type": "MSSTS",
                    "username": "user\(a)@tenant\(t).onmicrosoft.com",
                    "name": "User \(a) Tenant \(t)",
                    "local_account_id": "localid\(a)",
                    "client_info": String(repeating: "c", count: 200),
                    "last_modification_time": "1748000000.000",
                    "last_modification_app": "dev.debruyn.ofem;1",
                ]
            }
        }

        let blob: [String: Any] = [
            "RefreshToken": refreshTokens,
            "Account": accountEntries,
        ]
        // swiftlint:disable:next force_try
        return try! JSONSerialization.data(withJSONObject: blob, options: [.sortedKeys])
    }

    private static func makeAppBlob(accounts: Int, tenantsPerAccount: Int) -> Data {
        var accessTokens: [String: [String: String]] = [:]
        var idTokens: [String: [String: String]] = [:]
        var appMetadata: [String: [String: String]] = [:]
        var accountMetadata: [String: [String: String]] = [:]

        for a in 0..<accounts {
            for t in 0..<tenantsPerAccount {
                let homeAccountID = "objectid\(a).tenantid\(t)"
                let env = "login.windows.net"
                let realm = "tenantid\(t)"
                let clientID = ofemEntraClientID
                let target = "https://storage.azure.com/user_impersonation"

                // AccessToken key: <home_account_id>-<env>-AccessToken-<client>-<realm>-<target>
                let atKey = "\(homeAccountID)-\(env)-AccessToken-\(clientID)-\(realm)-\(target)"
                accessTokens[atKey] = [
                    "secret": String(repeating: "a", count: 1400), // ~1.4 KB JWT
                    "environment": env,
                    "credential_type": "AccessToken",
                    "home_account_id": homeAccountID,
                    "client_id": clientID,
                    "realm": realm,
                    "target": target,
                    "cached_at": "1748000000",
                    "expires_on": "1748003600",
                    "extended_expires_on": "1748090000",
                    "last_modification_time": "1748000000.000",
                    "last_modification_app": "dev.debruyn.ofem;1",
                ]

                // IdToken key: <home_account_id>-<env>-IdToken-<client>-<realm>-
                let itKey = "\(homeAccountID)-\(env)-IdToken-\(clientID)-\(realm)-"
                idTokens[itKey] = [
                    "secret": String(repeating: "i", count: 800), // ~800 byte ID JWT
                    "environment": env,
                    "credential_type": "IdToken",
                    "home_account_id": homeAccountID,
                    "client_id": clientID,
                    "realm": realm,
                    "last_modification_time": "1748000000.000",
                    "last_modification_app": "dev.debruyn.ofem;1",
                ]

                // AppMetadata: one per (env, client)
                let amKey = "\(env)-appmetadata-\(clientID)"
                appMetadata[amKey] = [
                    "client_id": clientID,
                    "environment": env,
                    "family_id": "1",
                ]

                // AccountMetadata
                let acmKey = "authority_map-\(clientID)-\(homeAccountID)"
                accountMetadata[acmKey] = [
                    "home_account_id": homeAccountID,
                    "client_id": clientID,
                ]
            }
        }

        let blob: [String: Any] = [
            "AccessToken": accessTokens,
            "IdToken": idTokens,
            "AppMetadata": appMetadata,
            "AccountMetadata": accountMetadata,
        ]
        // swiftlint:disable:next force_try
        return try! JSONSerialization.data(withJSONObject: blob, options: [.sortedKeys])
    }

    /// Writes `data` to a private keychain item identified by
    /// `(service, account)`, then reads it back to measure round-trip size.
    /// Returns the byte count of the stored item, or throws on failure.
    ///
    /// Uses `kSecClassGenericPassword` matching MSAL's cache item class.
    /// The item is written to the **default keychain** (login.keychain for
    /// interactive sessions).
    private func writeAndMeasureKeychainItem(service: String, account: String, data: Data) throws -> Int {
        // Delete any pre-existing item with this key.
        let deleteQuery: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        // Write.
        let addQuery: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecValueData: data,
        ]
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw KeychainTestError.addFailed(addStatus)
        }

        // Read back.
        let readQuery: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let readStatus = SecItemCopyMatching(readQuery as CFDictionary, &result)
        guard readStatus == errSecSuccess, let readData = result as? Data else {
            throw KeychainTestError.readFailed(readStatus)
        }
        return readData.count
    }

    /// Deletes a test keychain item. Called in test cleanup.
    private func deleteKeychainItem(service: String, account: String) {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]
        SecItemDelete(query as CFDictionary)
    }

    // MARK: - Scenario: 1 account, 1 tenant

    @Test(
        "MSAL-sized Keychain blob: 1 account / 1 tenant",
        .disabled("Requires interactive keychain access — run manually: swift test --filter KeychainVolumeIntegrationTests")
    )
    func scenario_1account_1tenant() throws {
        let service = "dev.debruyn.ofem.keychaintest"
        let sharedAccount = "test-shared-1x1"
        let appAccount = "test-app-1x1"
        defer {
            deleteKeychainItem(service: service, account: sharedAccount)
            deleteKeychainItem(service: service, account: appAccount)
        }

        let shared = Self.makeSharedBlob(accounts: 1, tenantsPerAccount: 1)
        let app = Self.makeAppBlob(accounts: 1, tenantsPerAccount: 1)

        let sharedSize = try writeAndMeasureKeychainItem(service: service, account: sharedAccount, data: shared)
        let appSize = try writeAndMeasureKeychainItem(service: service, account: appAccount, data: app)
        let total = sharedSize + appSize

        print("""
        [1 account / 1 tenant]
          shared blob:  \(sharedSize) bytes (\(sharedSize / 1024) KB)
          app blob:     \(appSize) bytes (\(appSize / 1024) KB)
          total:        \(total) bytes (\(total / 1024) KB)
        """)

        // Must write and read back correctly.
        #expect(sharedSize > 0)
        #expect(appSize > 0)
        // Sanity: total should be in the range of 5–15 KB for 1 account.
        #expect(total > 4_000)
        #expect(total < 20_000)
    }

    // MARK: - Scenario: 5 accounts, 1 tenant

    @Test(
        "MSAL-sized Keychain blob: 5 accounts / 1 tenant",
        .disabled("Requires interactive keychain access — run manually: swift test --filter KeychainVolumeIntegrationTests")
    )
    func scenario_5accounts_1tenant() throws {
        let service = "dev.debruyn.ofem.keychaintest"
        let sharedAccount = "test-shared-5x1"
        let appAccount = "test-app-5x1"
        defer {
            deleteKeychainItem(service: service, account: sharedAccount)
            deleteKeychainItem(service: service, account: appAccount)
        }

        let shared = Self.makeSharedBlob(accounts: 5, tenantsPerAccount: 1)
        let app = Self.makeAppBlob(accounts: 5, tenantsPerAccount: 1)

        let sharedSize = try writeAndMeasureKeychainItem(service: service, account: sharedAccount, data: shared)
        let appSize = try writeAndMeasureKeychainItem(service: service, account: appAccount, data: app)
        let total = sharedSize + appSize

        print("""
        [5 accounts / 1 tenant]
          shared blob:  \(sharedSize) bytes (\(sharedSize / 1024) KB)
          app blob:     \(appSize) bytes (\(appSize / 1024) KB)
          total:        \(total) bytes (\(total / 1024) KB)
        """)

        #expect(sharedSize > 0)
        #expect(appSize > 0)
    }

    // MARK: - Scenario: 5 accounts, 3 tenants (15 account-tenant pairs)

    @Test(
        "MSAL-sized Keychain blob: 5 accounts / 3 tenants (realistic OFEM use case)",
        .disabled("Requires interactive keychain access — run manually: swift test --filter KeychainVolumeIntegrationTests")
    )
    func scenario_5accounts_3tenants() throws {
        let service = "dev.debruyn.ofem.keychaintest"
        let sharedAccount = "test-shared-5x3"
        let appAccount = "test-app-5x3"
        defer {
            deleteKeychainItem(service: service, account: sharedAccount)
            deleteKeychainItem(service: service, account: appAccount)
        }

        let shared = Self.makeSharedBlob(accounts: 5, tenantsPerAccount: 3)
        let app = Self.makeAppBlob(accounts: 5, tenantsPerAccount: 3)

        let sharedSize = try writeAndMeasureKeychainItem(service: service, account: sharedAccount, data: shared)
        let appSize = try writeAndMeasureKeychainItem(service: service, account: appAccount, data: app)
        let total = sharedSize + appSize

        print("""
        [5 accounts / 3 tenants = 15 pairs]
          shared blob:  \(sharedSize) bytes (\(sharedSize / 1024) KB)
          app blob:     \(appSize) bytes (\(appSize / 1024) KB)
          total:        \(total) bytes (\(total / 1024) KB)
        """)

        #expect(sharedSize > 0)
        #expect(appSize > 0)
    }

    // MARK: - Scenario: 10 accounts, 10 tenants (100 pairs — stress)

    @Test(
        "MSAL-sized Keychain blob: 10 accounts / 10 tenants (stress)",
        .disabled("Requires interactive keychain access — run manually: swift test --filter KeychainVolumeIntegrationTests")
    )
    func scenario_10accounts_10tenants() throws {
        let service = "dev.debruyn.ofem.keychaintest"
        let sharedAccount = "test-shared-10x10"
        let appAccount = "test-app-10x10"
        defer {
            deleteKeychainItem(service: service, account: sharedAccount)
            deleteKeychainItem(service: service, account: appAccount)
        }

        let shared = Self.makeSharedBlob(accounts: 10, tenantsPerAccount: 10)
        let app = Self.makeAppBlob(accounts: 10, tenantsPerAccount: 10)

        let sharedSize = try writeAndMeasureKeychainItem(service: service, account: sharedAccount, data: shared)
        let appSize = try writeAndMeasureKeychainItem(service: service, account: appAccount, data: app)
        let total = sharedSize + appSize

        print("""
        [10 accounts / 10 tenants = 100 pairs — stress]
          shared blob:  \(sharedSize) bytes (\(sharedSize / 1024) KB)
          app blob:     \(appSize) bytes (\(appSize / 1024) KB)
          total:        \(total) bytes (\(total / 1024) KB)
        """)

        #expect(sharedSize > 0)
        #expect(appSize > 0)
    }

    // MARK: - Blob size estimation (always runs)

    @Test("Estimated blob sizes are within expected ranges per account")
    func blobSizeEstimation() {
        // This test always runs (no keychain access needed) to validate the
        // mock blob generator produces the expected output sizes.
        for (accounts, tenants) in [(1, 1), (5, 1), (5, 3), (10, 10)] {
            let shared = Self.makeSharedBlob(accounts: accounts, tenantsPerAccount: tenants)
            let app = Self.makeAppBlob(accounts: accounts, tenantsPerAccount: tenants)
            let pairs = accounts * tenants
            let total = shared.count + app.count

            print("""
            [Estimation \(accounts) accounts × \(tenants) tenants = \(pairs) pairs]
              shared:    \(shared.count) bytes (\(shared.count / 1024) KB)
              app:       \(app.count) bytes (\(app.count / 1024) KB)
              total:     \(total) bytes (\(total / 1024) KB)
              per-pair:  ~\(total / max(pairs, 1)) bytes
            """)

            // At least 1 KB per account-tenant pair in the shared blob.
            #expect(shared.count >= pairs * 1_000)
            // App blob should have at least 2 KB per pair (access + id tokens).
            #expect(app.count >= pairs * 2_000)
        }
    }
}

// MARK: - KeychainTestError

private enum KeychainTestError: Error {
    case addFailed(OSStatus)
    case readFailed(OSStatus)
}
