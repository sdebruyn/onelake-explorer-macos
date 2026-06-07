import Foundation
@preconcurrency import MSAL
import os.log

// MARK: - MsalAuthClientProtocol

/// Testable interface over `MSALPublicClientApplication`.
///
/// Declared here rather than imported from MSAL directly so tests can
/// substitute a stub without depending on the real MSAL transport.
/// Mirrors `internal/auth/msal.go` — `MSALClient` interface.
public protocol MsalAuthClientProtocol: Sendable {
    /// Attempts silent token acquisition from cache or via refresh token.
    func acquireTokenSilent(
        scopes: [String],
        account: MSALAccount
    ) async throws -> MSALResult

    /// Returns all accounts known to this client's MSAL token cache.
    func accounts() throws -> [MSALAccount]
}

// MARK: - MsalAuthClient

/// Wrapper around `MSALPublicClientApplication` for a single
/// `(clientID, tenantID)` pair.
///
/// One instance is created per account alias and cached for its lifetime.
/// The cache strategy controls whether tokens are persisted in the native
/// macOS login.keychain (preferred) or in a file-backed fallback.
///
/// Concurrency: `MSALPublicClientApplication` is thread-safe. The wrapper
/// is `Sendable` and does not add its own locking beyond MSAL's internal
/// synchronisation.
///
/// Mirrors `internal/auth/msal.go` — `DefaultClientFactory` +
/// `publicClientAdapter`.
public final class MsalAuthClient: MsalAuthClientProtocol {
    private let inner: MSALPublicClientApplication
    private static let log = Logger(subsystem: "dev.debruyn.ofem", category: "MsalAuthClient")

    // MARK: - Initialisation

    /// Creates a `MsalAuthClient` for the given `(clientID, tenantID)` pair.
    ///
    /// - Parameters:
    ///   - clientID: The Microsoft Entra App Registration GUID.
    ///   - tenantID: The Entra tenant GUID for this account. Pass `""` or
    ///     omit to use `"organizations"` (home-tenant routing).
    ///   - cacheStrategy: Where to persist tokens. Default: `.msalKeychain`.
    ///   - fileTokenStore: Required when `cacheStrategy == .fileBackedFallback`.
    /// - Throws: ``MsalAuthClientError`` on configuration or MSAL
    ///   initialisation failure.
    public init(
        clientID: String,
        tenantID: String,
        cacheStrategy: TokenCacheStrategy = .msalKeychain,
        fileTokenStore: FileTokenStore? = nil,
        alias: String? = nil
    ) throws {
        guard !clientID.isEmpty else {
            throw MsalAuthClientError.missingClientID
        }

        let authorityURL = try EntraAuthorityResolver.authority(tenantID: tenantID)
        let authority = try MSALAADAuthority(url: authorityURL)
        let config = MSALPublicClientApplicationConfig(
            clientId: clientID,
            redirectUri: "http://localhost",
            authority: authority
        )

        // Configure Keychain sharing group.
        // MSAL Swift on macOS defaults to `com.microsoft.identity.universalstorage`.
        // We override to the OFEM App Group so the FPE and host app share the
        // same token cache without cross-app SSO with other Microsoft apps.
        //
        // The App Group entitlement must list the keychain group; this is
        // configured in the Xcode target entitlements (not in this package).
        config.cacheConfig.keychainSharingGroup = OfemPaths.appGroupIdentifier

        // If the caller requests the file-backed fallback, configure MSAL to
        // use an `MSALSerializedADALCacheProvider` backed by a
        // `FileTokenStoreCacheDelegate` that reads/writes to `FileTokenStore`.
        if cacheStrategy == .fileBackedFallback {
            guard let store = fileTokenStore else {
                throw MsalAuthClientError.missingFileTokenStore
            }
            guard let aliasString = alias, !aliasString.isEmpty else {
                throw MsalAuthClientError.missingAlias
            }
            let delegate = FileTokenStoreCacheDelegate(store: store, alias: aliasString)
            let serializedCache = try MSALSerializedADALCacheProvider(delegate: delegate)
            config.cacheConfig.serializedADALCache = serializedCache
        }

        self.inner = try MSALPublicClientApplication(configuration: config)
        Self.log.debug("MsalAuthClient created: clientID=\(clientID, privacy: .public) tenantID=\(tenantID, privacy: .public)")
    }

    // MARK: - MsalAuthClientProtocol

    public func acquireTokenSilent(
        scopes: [String],
        account: MSALAccount
    ) async throws -> MSALResult {
        let params = MSALSilentTokenParameters(scopes: scopes, account: account)
        return try await withCheckedThrowingContinuation { continuation in
            inner.acquireTokenSilent(with: params) { result, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let result {
                    continuation.resume(returning: result)
                } else {
                    continuation.resume(throwing: MsalAuthClientError.nilResult)
                }
            }
        }
    }

    public func accounts() throws -> [MSALAccount] {
        // MSALPublicClientApplication.allAccounts() returns all accounts in
        // the MSAL cache. OFEM manages its own per-account filter by
        // homeAccountID in OfemAuth.msalAccount(for:homeAccountID:alias:).
        return try inner.allAccounts()
    }
}

// MARK: - FileTokenStoreCacheDelegate

/// Bridges MSAL's `MSALSerializedADALCacheProviderDelegate` to
/// `OfemKit`'s `FileTokenStore`.
///
/// Used when `TokenCacheStrategy == .fileBackedFallback`. MSAL calls
/// `willWriteCache` / `didWriteCache` around every token write, and
/// `willAccessCache` / `didAccessCache` around every token read. The
/// delegate serialises the in-memory MSAL cache to disk via
/// `FileTokenStore.write(alias:data:)` after each write.
///
/// Compatibility note: the serialised format produced by
/// `MSALSerializedADALCacheProvider.serializeDataWithError` is the ADAL
/// JSON format. The Go MSAL library produces a compatible JSON format
/// (Microsoft's MSAL cache schema v1.1), so token blobs written by this
/// delegate are cross-readable by the Go daemon during the migration period.
final class FileTokenStoreCacheDelegate: NSObject, MSALSerializedADALCacheProviderDelegate, @unchecked Sendable {
    private let store: FileTokenStore
    private let alias: String
    private static let log = Logger(subsystem: "dev.debruyn.ofem", category: "FileTokenStoreCacheDelegate")

    init(store: FileTokenStore, alias: String) {
        self.store = store
        self.alias = alias
    }

    func willAccessCache(_ cache: MSALSerializedADALCacheProvider) {
        // Load the latest cached bytes into the in-memory MSAL representation
        // before MSAL performs a cache lookup.
        // `deserialize(_:error:)` bridges to `try cache.deserialize(data)` in Swift.
        do {
            let data = try store.read(alias: alias)
            try cache.deserialize(data)
        } catch FileTokenStoreError.notFound {
            // No token yet for this alias — first login. MSAL starts with an
            // empty in-memory cache; the subsequent write populates the store.
        } catch {
            Self.log.error("FileTokenStoreCacheDelegate: willAccessCache failed for alias=\(self.alias, privacy: .public): \(error)")
        }
    }

    func didAccessCache(_ cache: MSALSerializedADALCacheProvider) {
        // No-op: we only need to load from disk before access, not after.
    }

    func willWriteCache(_ cache: MSALSerializedADALCacheProvider) {
        // Load the latest bytes so that concurrent writers from different
        // processes (e.g. host app and FPE) do not clobber each other.
        do {
            let data = try store.read(alias: alias)
            try cache.deserialize(data)
        } catch FileTokenStoreError.notFound {
            // First login: no existing cache to merge.
        } catch {
            Self.log.error("FileTokenStoreCacheDelegate: willWriteCache load failed for alias=\(self.alias, privacy: .public): \(error)")
        }
    }

    func didWriteCache(_ cache: MSALSerializedADALCacheProvider) {
        // Persist the updated in-memory cache to disk.
        // `serializeDataWithError:` bridges to `try cache.serializeData()` in Swift.
        do {
            let data = try cache.serializeData()
            try store.write(alias: alias, data: data)
        } catch {
            Self.log.error("FileTokenStoreCacheDelegate: didWriteCache persist failed for alias=\(self.alias, privacy: .public): \(error)")
        }
    }
}

// MARK: - MsalAuthClientError

/// Errors thrown by ``MsalAuthClient``.
public enum MsalAuthClientError: Error, CustomStringConvertible {
    case missingClientID
    case missingFileTokenStore
    case missingAlias
    case nilResult

    public var description: String {
        switch self {
        case .missingClientID:
            return "MsalAuthClient: clientID is required"
        case .missingFileTokenStore:
            return "MsalAuthClient: fileTokenStore is required when cacheStrategy is .fileBackedFallback"
        case .missingAlias:
            return "MsalAuthClient: alias is required when cacheStrategy is .fileBackedFallback"
        case .nilResult:
            return "MsalAuthClient: MSAL returned neither a result nor an error"
        }
    }
}
