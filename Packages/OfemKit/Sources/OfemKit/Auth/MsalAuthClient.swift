import Foundation
@preconcurrency import MSAL
import os.log

// MARK: - MsalAuthClientProtocol

/// Testable interface over `MSALPublicClientApplication`.
///
/// Declared here rather than imported from MSAL directly so tests can
/// substitute a stub without depending on the real MSAL transport.
/// Inject via ``MsalAuthClientFactory`` into ``OfemAuth``.
///
/// The protocol operates on `homeAccountID` strings rather than `MSALAccount`
/// objects so test doubles do not need to construct non-Sendable MSAL types.
/// The real implementation looks up the `MSALAccount` internally.
public protocol MsalAuthClientProtocol: Sendable {
    /// Attempts silent token acquisition from cache or via refresh token.
    ///
    /// - Parameters:
    ///   - scopes: OAuth scope strings.
    ///   - homeAccountID: MSAL's unique identifier for the account
    ///     (`objectId.tenantId` format). The implementation looks up the
    ///     `MSALAccount` internally.
    /// - Returns: The access token string.
    /// - Throws: Any MSAL error. ``OfemAuth`` maps
    ///   `MSALError.interactionRequired` to ``OfemAuthError/interactionRequired``.
    func acquireTokenSilent(
        scopes: [String],
        homeAccountID: String
    ) async throws -> String
}

// MARK: - MsalAuthClient

/// Wrapper around `MSALPublicClientApplication` for a single
/// `(clientID, tenantID)` pair.
///
/// One instance is created per `(clientID, tenantID)` pair and cached in
/// ``OfemAuth`` for its lifetime. The cache strategy controls whether tokens
/// are persisted in the native macOS login.keychain (preferred) or in a
/// file-backed fallback.
///
/// Concurrency: `MSALPublicClientApplication` is thread-safe. The wrapper
/// is `Sendable` and does not add its own locking beyond MSAL's internal
/// synchronisation.
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
    ///   - alias: Account alias, required when `cacheStrategy == .fileBackedFallback`.
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

        let config = try MsalApplicationConfig.make(
            clientID: clientID,
            tenantID: tenantID,
            cacheStrategy: cacheStrategy,
            fileTokenStore: fileTokenStore,
            alias: alias
        )
        self.inner = try MSALPublicClientApplication(configuration: config)
        Self.log.debug("MsalAuthClient created: clientID=\(clientID, privacy: .public) tenantID=\(tenantID, privacy: .public)")
    }

    // MARK: - MsalAuthClientProtocol

    public func acquireTokenSilent(
        scopes: [String],
        homeAccountID: String
    ) async throws -> String {
        // Look up the MSALAccount internally so callers never need to handle
        // the non-Sendable MSAL type across async boundaries.
        let msalAccount = try findAccount(homeAccountID: homeAccountID)

        // Capture account in a nonisolated(unsafe) wrapper to cross the
        // async boundary. MSALAccount is an Objective-C class; MSAL documents
        // it as safe to read from any thread after full initialisation.
        nonisolated(unsafe) let capturedAccount = msalAccount

        let params = MSALSilentTokenParameters(scopes: scopes, account: capturedAccount)
        let result = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<MSALResult, Error>) in
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
        return result.accessToken
    }

    // MARK: - Private helpers

    /// Finds the `MSALAccount` in this client's cache matching `homeAccountID`.
    private func findAccount(homeAccountID: String) throws -> MSALAccount {
        guard !homeAccountID.isEmpty else {
            throw MsalAuthClientError.accountNotFound(homeAccountID)
        }
        let allAccounts = try inner.allAccounts()
        for account in allAccounts {
            guard let identifier = account.identifier, !identifier.isEmpty else { continue }
            if identifier == homeAccountID {
                return account
            }
        }
        throw MsalAuthClientError.accountNotFound(homeAccountID)
    }
}

// MARK: - MsalApplicationConfig

/// Single factory for `MSALPublicClientApplicationConfig`.
///
/// Both ``MsalAuthClient`` (silent acquisition) and ``InteractiveSignIn``
/// (interactive flow) must use byte-identical configuration — any mismatch in
/// redirect URI or Keychain group silently breaks token sharing between the
/// two code paths. This factory is the single source of truth for
/// security-sensitive MSAL config.
enum MsalApplicationConfig {
    /// Builds a `MSALPublicClientApplicationConfig` ready for use by either
    /// ``MsalAuthClient`` or ``InteractiveSignIn``.
    ///
    /// - Parameters:
    ///   - clientID: Entra App Registration GUID.
    ///   - tenantID: Tenant GUID or `""` for `organizations` routing.
    ///   - cacheStrategy: `.msalKeychain` or `.fileBackedFallback`.
    ///   - fileTokenStore: Required when `cacheStrategy == .fileBackedFallback`.
    ///   - alias: Account alias, required when `cacheStrategy == .fileBackedFallback`.
    /// - Returns: Configured `MSALPublicClientApplicationConfig`.
    /// - Throws: ``MsalAuthClientError`` on validation or MSAL init failure.
    static func make(
        clientID: String,
        tenantID: String,
        cacheStrategy: TokenCacheStrategy,
        fileTokenStore: FileTokenStore?,
        alias: String?
    ) throws -> MSALPublicClientApplicationConfig {
        let authorityURL = try EntraAuthorityResolver.authority(tenantID: tenantID)
        let authority = try MSALAADAuthority(url: authorityURL)
        let config = MSALPublicClientApplicationConfig(
            clientId: clientID,
            redirectUri: "http://localhost",
            authority: authority
        )

        // Configure Keychain sharing group.
        // MSAL Swift on macOS defaults to `com.microsoft.identity.universalstorage`.
        // Override to the OFEM App Group so the FPE and host app share the
        // same token cache without cross-app SSO with other Microsoft apps.
        //
        // The App Group entitlement must list the keychain group; this is
        // configured in the Xcode target entitlements (not in this package).
        config.cacheConfig.keychainSharingGroup = OfemPaths.appGroupIdentifier

        // Wire the file-backed fallback cache if requested.
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

        return config
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
/// Cross-process safety: `willWriteCache`/`didWriteCache` run while
/// `FileTokenStore.lock` is held (via `write`), which uses an in-process
/// `NSLock` for same-process protection and relies on `FileTokenStore`'s
/// cross-process locking mechanism (see ``FileTokenStore`` docs) for
/// host-app vs FPE exclusion.
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
        // Load the latest bytes so that the upcoming write merges any changes
        // written since the last read.
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
        // Persist the updated in-memory cache to disk. Log failures explicitly
        // rather than swallowing them — a silent failure here loses the freshly
        // minted refresh token.
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
    case accountNotFound(String)

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
        case let .accountNotFound(id):
            return "MsalAuthClient: no account found in MSAL cache for homeAccountID=\(id)"
        }
    }
}
