import Foundation
@testable import OfemKit

// MARK: - Shared helpers for Auth test files

// Consolidates makeStore() and makeAccount() that were re-implemented
// independently in OfemAuthTests and OfemAuthTokenTests (tests-15).

/// Creates a fresh temporary directory, a matching `OfemPaths`, and an
/// `OfemConfigStore` backed by it.
///
/// `label` is embedded in the directory name so test failures are easier
/// to attribute. The caller is responsible for deleting the returned `root`
/// URL (typically via `defer`).
func makeStore(label: String = "Auth") throws -> (store: OfemConfigStore, root: URL) {
    let tmp = FileManager.default.temporaryDirectory
        .appending(path: "\(label)-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    let paths = OfemPaths(root: tmp)
    let store = try OfemConfigStore(paths: paths)
    return (store, tmp)
}

/// Builds a minimal `Account` suitable for use in unit tests.
///
/// - Parameters:
///   - alias: Short alias for the account (must pass `AccountAlias` validation).
///   - tenantID: Tenant identifier; defaults to a fresh UUID string so
///     unrelated test accounts do not accidentally share MSAL client state.
///   - homeAccountID: Home account ID; defaults to a fresh UUID string.
func makeAccount(
    alias: String,
    tenantID: String = "tenant-\(UUID().uuidString)",
    homeAccountID: String = "home-\(UUID().uuidString)"
) -> Account {
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
