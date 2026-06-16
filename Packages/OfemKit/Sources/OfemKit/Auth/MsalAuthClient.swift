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

    /// Removes the account identified by `homeAccountID` from the MSAL
    /// Keychain cache, purging the stored refresh token.
    ///
    /// This is the documented MSAL API for sign-out: it deletes the Keychain
    /// item so the refresh token cannot be reused after account removal —
    /// including if the same alias is re-added for a different user later.
    ///
    /// - Parameter homeAccountID: MSAL's unique identifier (`objectId.tenantId`).
    /// - Throws: ``MsalAuthClientError/accountNotFound(_:)`` when no matching
    ///   account is in the cache (treated as a no-op by ``OfemAuth``).
    ///   Any other error is rethrown.
    func removeAccount(homeAccountID: String) throws
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
        // The account lookup and MSAL call are performed entirely inside the
        // withCheckedThrowingContinuation closure so that no non-Sendable
        // MSALAccount value is ever captured across an async suspension point.
        // Both `inner.allAccounts()` and `inner.acquireTokenSilent(with:completionBlock:)`
        // are called synchronously within the same closure execution, before any
        // suspension, so no data-race suppression is needed.
        let accessToken = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
            // Perform account lookup synchronously inside the closure.
            let msalAccount: MSALAccount
            do {
                msalAccount = try self.findAccount(homeAccountID: homeAccountID)
            } catch {
                continuation.resume(throwing: error)
                return
            }

            let params = MSALSilentTokenParameters(scopes: scopes, account: msalAccount)
            self.inner.acquireTokenSilent(with: params) { result, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let result {
                    // Extract only the plain String token inside the callback
                    // so the non-Sendable MSALResult does not cross any boundary.
                    continuation.resume(returning: result.accessToken)
                } else {
                    continuation.resume(throwing: MsalAuthClientError.nilResult)
                }
            }
        }
        return accessToken
    }

    public func removeAccount(homeAccountID: String) throws {
        let account = try findAccount(homeAccountID: homeAccountID)
        try inner.remove(account)
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
        // The redirect URI must use the msauth custom scheme so that
        // ASWebAuthenticationSession can capture the callback. MSAL for
        // Apple Platforms derives the AS callback scheme from this URI;
        // http/https schemes are rejected by ASWebAuthenticationSession
        // as invalid custom callback schemes. The Entra App Registration
        // must list this URI under "Mobile and desktop applications".
        //
        // Per-process bundle ID: MSAL validates that the redirect URI's
        // bundle-ID component matches the RUNNING process's bundle ID (local
        // check, no network). Using the hardcoded `OfemPaths.bundleID`
        // (= "dev.debruyn.ofem") worked for the host app but caused an
        // immediate -42011 failure in the FPE (bundle ID
        // "dev.debruyn.ofem.fileprovider") so every silent token call
        // failed before reaching the network — emptying the Finder mount.
        // Fix: derive the redirect URI from the running process's bundle ID.
        // `OfemPaths.bundleID` is intentionally unchanged — it is correct for
        // app-group container, Keychain group, and file paths; only the MSAL
        // redirect URI must be per-process.
        let processBundleID = Bundle.main.bundleIdentifier ?? OfemPaths.bundleID
        let config = MSALPublicClientApplicationConfig(
            clientId: clientID,
            redirectUri: "msauth.\(processBundleID)://auth",
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
/// `FileTokenStore.atomicUpdate(alias:transform:)` to guarantee that the
/// read-merge-write sequence is atomic with respect to other processes.
///
/// Cross-process safety: `willWriteCache` is a no-op; the entire
/// read-deserialize-serialize-write cycle is performed atomically inside
/// `didWriteCache` via `FileTokenStore.atomicUpdate`, which holds the
/// per-alias `fcntl` cross-process lock and the intra-process serial queue
/// for the full duration. This prevents a concurrent host-app or FPE write
/// from slipping between the read and the write.
///
/// Async bridging: `FileTokenStore.atomicUpdate` is `async` (uses
/// `F_SETLKW` on a dedicated thread). Since MSAL calls these delegate
/// methods synchronously on its own internal non-cooperative thread, we
/// bridge via `DispatchSemaphore.wait()` — blocking MSAL's thread (which is
/// not a Swift cooperative-pool thread) while the async operation completes.
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
        // before MSAL performs a cache lookup. `read` is synchronous (no lock).
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
        // No-op: the entire read-merge-write cycle is performed atomically
        // inside didWriteCache via FileTokenStore.atomicUpdate, which holds
        // the cross-process lock for the full read→deserialize→serialize→write
        // sequence. Doing a separate read here (without the lock) would reopen
        // the TOCTOU gap that atomicUpdate is designed to close.
    }

    func didWriteCache(_ cache: MSALSerializedADALCacheProvider) {
        // Atomically: read the current on-disk bytes, deserialize them into
        // the MSAL in-memory cache (merge), serialize the merged result, and
        // write it back — all while holding the per-alias cross-process lock.
        // Failures are logged explicitly rather than swallowed — a silent
        // failure here would lose the freshly minted refresh token.
        //
        // Thread model (deadlock analysis):
        //   1. MSAL calls didWriteCache on its own internal thread (neither a
        //      Swift cooperative-pool thread nor the main actor thread).
        //   2. `sema.wait()` blocks MSAL's thread. The Swift cooperative pool
        //      is never blocked here — safe. ✓
        //   3. The unstructured `Task {}` runs on the cooperative pool and
        //      calls `acquireAliasLockAsync`, which spawns a *dedicated* OS
        //      thread for the blocking `F_SETLKW` syscall. The cooperative-pool
        //      thread is released at the `await` suspension point. ✓
        //   4. After `F_SETLKW` succeeds, the continuation resumes on the
        //      cooperative pool and calls `serialQueue.sync`. This DOES block
        //      the cooperative-pool thread for the duration of the file write
        //      (typically microseconds to low milliseconds). Under simultaneous
        //      writes for N accounts, N cooperative-pool threads may be briefly
        //      blocked — not a deadlock, but it reduces pool availability. With
        //      OFEM's typical 1–3 accounts the practical impact is negligible.
        //   5. On Task completion, `sema.signal()` unblocks MSAL's thread.
        //   No deadlock path exists: the blocked MSAL thread is entirely
        //   unrelated to the Swift cooperative pool that the Task runs on.
        //   Do NOT restructure this into a sync call on MSAL's thread — that
        //   would block `F_SETLKW` on a cooperative-pool thread and risk
        //   starvation under high load.
        let sema = DispatchSemaphore(value: 0)
        let capturedAlias = alias
        let capturedStore = store
        Task {
            do {
                try await capturedStore.atomicUpdate(alias: capturedAlias) { existingData in
                    // Merge any on-disk changes into the MSAL in-memory cache
                    // before serialising, so we never overwrite a fresher token
                    // written by another process between our last read and now.
                    if !existingData.isEmpty {
                        do {
                            try cache.deserialize(existingData)
                        } catch {
                            Self.log.error(
                                "FileTokenStoreCacheDelegate: didWriteCache deserialize failed for alias=\(capturedAlias, privacy: .public): \(error)"
                            )
                            // Proceed without merging rather than losing the new token.
                        }
                    }
                    return try cache.serializeData()
                }
            } catch {
                Self.log.error("FileTokenStoreCacheDelegate: didWriteCache persist failed for alias=\(capturedAlias, privacy: .public): \(error)")
            }
            sema.signal()
        }
        sema.wait()
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
