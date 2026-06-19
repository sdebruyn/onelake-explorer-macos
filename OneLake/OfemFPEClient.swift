// OfemFPEClient.swift
// Host-app client for the FPE's OfemClientControlProtocol XPC service.
//
// The host app uses this class to call engine-status and config operations
// on the FPE over NSXPCConnection. Account management (add / remove) is
// handled in-process via SharedOfemAuth and DomainSyncManager; it does not
// go through this XPC surface.
//
// Connection model:
//   - One connection per domain. Connections are created on demand and
//     cached (the FPE may restart the service after an invalidation).
//   - Connections are per-domain because NSFileProviderManager.service is
//     domain-scoped.
//   - A per-key in-flight Task prevents concurrent callers from racing to
//     build two connections for the same domain (check-then-insert race).
//
// Error handling:
//   NSXPCConnection can fail at any point (FPE process terminated, service
//   not registered, domain not found). Every method routes the proxy error
//   handler into the waiting continuation via a resume-once guard so no
//   task ever hangs forever.

@preconcurrency import FileProvider
import Foundation
import os.log

// MARK: - Resume-once continuation wrapper

/// Ensures a `CheckedContinuation` is resumed at most once regardless of
/// whether the XPC reply block or the `remoteObjectProxyWithErrorHandler`
/// error handler fires first.
///
/// NSXPCConnection can invoke EITHER the reply block OR the error handler
/// (never both) — but both may run from different queues and close over the
/// same continuation, so a naïve implementation can leak tasks. This wrapper
/// uses a lock so the second resume is a no-op.
final class OneShotContinuation<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var resumed = false
    private let continuation: CheckedContinuation<T, Error>

    init(_ continuation: CheckedContinuation<T, Error>) {
        self.continuation = continuation
    }

    func resume(returning value: T) {
        lock.withLock {
            guard !resumed else { return }
            resumed = true
            continuation.resume(returning: value)
        }
    }

    func resume(throwing error: Error) {
        lock.withLock {
            guard !resumed else { return }
            resumed = true
            continuation.resume(throwing: error)
        }
    }
}

// MARK: - NSXPCConnection sendable box

/// Boxes an `NSXPCConnection` so it can be stored in `Sendable` contexts such as
/// `Task<XPCConnectionBox, Error>`. NSXPCConnection is `@_nonSendable` in the SDK,
/// but all access to the connection goes through `@MainActor`-isolated
/// `OfemFPEClient`, so there is no concurrent access in practice.
/// `@unchecked Sendable` is the correct annotation here — it mirrors the
/// `OneShotContinuation` precedent in the same file.
final class XPCConnectionBox: @unchecked Sendable {
    let connection: NSXPCConnection
    init(_ connection: NSXPCConnection) { self.connection = connection }
}

// MARK: - Shared async domain listing bridge

/// Async wrapper for `NSFileProviderManager.getDomainsWithCompletionHandler`.
///
/// We funnel through `withCheckedThrowingContinuation` rather than relying
/// on Swift's auto-bridged `getDomains()` overload because the latter has
/// shifted shape across macOS SDK revisions. The explicit bridge keeps the
/// call site predictable across DomainSyncManager, ChangeWatcher, and
/// OfemFPEClient — all three formerly maintained separate copies of this
/// identical bridge.
func ofemGetAllDomains() async throws -> [NSFileProviderDomain] {
    // NSFileProviderDomain is @_nonSendable in the SDK, but the system callback
    // hands us a freshly-created array that no other context holds a reference
    // to. Box it in an @unchecked Sendable wrapper so it can cross the
    // continuation boundary. The box is discarded immediately after unpacking.
    struct DomainsBox: @unchecked Sendable { let value: [NSFileProviderDomain] }
    let box: DomainsBox = try await withCheckedThrowingContinuation { continuation in
        NSFileProviderManager.getDomainsWithCompletionHandler { domains, error in
            if let error {
                continuation.resume(throwing: error)
            } else {
                continuation.resume(returning: DomainsBox(value: domains))
            }
        }
    }
    return box.value
}

// MARK: - OfemFPEClient

/// Manages XPC connections to the FPE's control service.
@MainActor
final class OfemFPEClient {
    static let shared = OfemFPEClient()

    private static let log = Logger(subsystem: ofemSubsystem, category: "fpe-client")

    nonisolated init() {}

    // MARK: - Public API

    /// Registers a new File Provider domain for the given alias.
    ///
    /// Call this after a successful sign-in so the account appears in the
    /// Finder sidebar immediately.
    ///
    /// - Parameter alias: The account alias to register as a domain.
    func registerDomain(alias: String) async {
        await DomainSyncManager.shared.addDomain(alias: alias)
        Self.log.info("registerDomain: domain registered for alias=\(alias, privacy: .public)")
    }

    // MARK: - Engine status

    /// Fetches the engine status (cache stats + config snapshot) via XPC.
    ///
    /// - Parameter alias: Account alias identifying the domain.
    /// - Returns: `XPCEngineStatus` on success.
    func getEngineStatus(alias: String) async throws -> XPCEngineStatus {
        try await withProxy(alias: alias) { proxy, cont in
            proxy.getEngineStatus { status, error in
                if let error {
                    cont.resume(throwing: error)
                } else if let status {
                    cont.resume(returning: status)
                } else {
                    cont.resume(throwing: OfemFPEClientError.connectionFailed(
                        "getEngineStatus returned nil status for alias \(alias)"
                    ))
                }
            }
        }
    }

    // MARK: - Config mutation

    /// Writes a config key/value pair through the FPE.
    ///
    /// - Parameters:
    ///   - alias: Account alias identifying the domain.
    ///   - key:   Config key in dot notation.
    ///   - value: New value as a string.
    func setConfig(alias: String, key: String, value: String) async throws {
        let _: Void = try await withProxy(alias: alias) { proxy, cont in
            proxy.setConfig(key: key, value: value) { error in
                if let error {
                    cont.resume(throwing: error)
                } else {
                    cont.resume(returning: ())
                }
            }
        }
    }

    // MARK: - Cache

    /// Clears all cached blobs via the FPE.
    ///
    /// - Parameter alias: Account alias identifying the domain.
    /// - Returns: Byte count remaining after the wipe (always 0 on success).
    @discardableResult
    func clearCache(alias: String) async throws -> Int64 {
        try await withProxy(alias: alias) { proxy, cont in
            proxy.clearCache { remaining, error in
                if let error {
                    cont.resume(throwing: error)
                } else {
                    cont.resume(returning: remaining)
                }
            }
        }
    }

    // MARK: - Protocol version check

    /// Queries the FPE's protocol version via an already-typed proxy and
    /// surfaces a mismatch via the model.
    ///
    /// Extracted from the NSXPCConnection-level helper so tests can inject a
    /// fake proxy without needing a real XPC connection.
    ///
    /// - Parameters:
    ///   - proxy:            A typed proxy conforming to `OfemClientControlProtocol`.
    ///   - domainIdentifier: Used for log messages only (not logged as PII).
    /// - Returns: The FPE's reported version.
    @discardableResult
    func checkProtocolVersion(
        proxy: any OfemClientControlProtocol,
        domainIdentifier: String
    ) async -> Int {
        let fpeVersion: Int = await withCheckedContinuation { continuation in
            proxy.getProtocolVersion { version in
                continuation.resume(returning: version)
            }
        }

        if fpeVersion != ofemControlProtocolVersion {
            Self.log.warning(
                "Protocol version mismatch for \(domainIdentifier, privacy: .public): host=\(ofemControlProtocolVersion) fpe=\(fpeVersion)"
            )
            notifyVersionMismatch(fpeVersion: fpeVersion, domainIdentifier: domainIdentifier)
        } else {
            Self.log.info(
                "Protocol version OK for \(domainIdentifier, privacy: .public): v\(fpeVersion)"
            )
        }
        return fpeVersion
    }

    /// Connection-level wrapper: obtains a proxy from the connection and
    /// delegates to `checkProtocolVersion(proxy:domainIdentifier:)`.
    ///
    /// Called once per new connection in `connection(for:)` after the
    /// connection is cached and resumed.
    private func checkProtocolVersion(
        connection: NSXPCConnection,
        domainIdentifier: String
    ) async {
        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
            // Log only; failure here is non-fatal — the connection is already
            // cached and subsequent method calls will surface their own errors.
            OfemFPEClient.log.warning(
                "getProtocolVersion proxy error for \(domainIdentifier, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
        }) as? any OfemClientControlProtocol else {
            // Cast failure means the connection is already broken; skip check.
            return
        }
        await checkProtocolVersion(proxy: proxy, domainIdentifier: domainIdentifier)
    }

    /// Surfaces a version mismatch to the user via `MenuStatusModel.lastActionError`.
    @MainActor
    private func notifyVersionMismatch(fpeVersion: Int, domainIdentifier: String) {
        MenuStatusModel.shared.setVersionMismatchError(
            hostVersion: ofemControlProtocolVersion,
            fpeVersion: fpeVersion
        )
    }

    // MARK: - Generic proxy helper

    /// Acquires a typed proxy for `alias`, invokes `body`, and returns the result.
    ///
    /// Centralises the shared boilerplate that all public API methods used to repeat:
    ///   1. Resolve the cached/built connection.
    ///   2. Construct the proxy with `remoteObjectProxyWithErrorHandler`; the error
    ///      handler resumes the continuation and is the *only* place that evicts the
    ///      cached connection — the per-call handler no longer invalidates connections
    ///      itself, because `buildConnection` already installs `invalidationHandler`
    ///      and `interruptionHandler` for that purpose.
    ///   3. Cast to `any OfemClientControlProtocol` (fails immediately if cast fails).
    ///   4. Call `body` with the typed proxy and the one-shot continuation.
    ///
    /// - Parameters:
    ///   - alias: Account alias identifying the domain.
    ///   - body:  Closure that calls one method on the proxy and resumes `cont`.
    private func withProxy<T>(
        alias: String,
        _ body: @escaping (any OfemClientControlProtocol, OneShotContinuation<T>) -> Void
    ) async throws -> T {
        let (connection, domainIdentifier) = try await connection(for: alias)
        return try await withCheckedThrowingContinuation { rawContinuation in
            let cont = OneShotContinuation<T>(rawContinuation)
            guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
                // The per-call error handler's only job is to resume the
                // continuation so the awaiting Task doesn't hang. Connection
                // eviction/invalidation is handled exclusively by the
                // `invalidationHandler` and `interruptionHandler` installed in
                // `buildConnection` — not here — so there is exactly one
                // code path responsible for cache eviction.
                OfemFPEClient.log.error(
                    "FPE XPC proxy error for \(domainIdentifier, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
                cont.resume(throwing: error)
            }) as? any OfemClientControlProtocol else {
                cont.resume(throwing: OfemFPEClientError.connectionFailed(
                    "proxy cast failed for \(domainIdentifier)"
                ))
                return
            }
            body(proxy, cont)
        }
    }

    // MARK: - Connection management

    /// Cache of open connections keyed by domain identifier string.
    private var connections: [String: XPCConnectionBox] = [:]

    /// In-flight connection-build tasks keyed by domain identifier string.
    /// Prevents check-then-insert races: concurrent callers for the same
    /// domain await the same Task rather than each building a connection.
    private var inFlightConnections: [String: Task<XPCConnectionBox, Error>] = [:]

    /// Returns the NSXPCConnection (and its domain identifier) for the domain
    /// identified by `alias`. Creates a connection if needed.
    ///
    /// Callers use `withProxy(alias:_:)` rather than calling this directly.
    private func connection(for alias: String) async throws -> (NSXPCConnection, String) {
        let domainIdentifier = DomainSyncManager.shared.domainIdentifier(for: alias)

        // Return a cached connection if one exists.
        if let box = connections[domainIdentifier] {
            return (box.connection, domainIdentifier)
        }

        // If a build is already in flight for this domain, await it rather than
        // starting a second one (prevents the check-then-insert race).
        if let inFlight = inFlightConnections[domainIdentifier] {
            let box = try await inFlight.value
            return (box.connection, domainIdentifier)
        }

        // Build a new connection under a tracked Task so concurrent callers
        // can join the same build rather than racing.
        let buildTask: Task<XPCConnectionBox, Error> = Task { [weak self] in
            guard let self else {
                throw OfemFPEClientError.connectionFailed("OfemFPEClient deallocated during connection build")
            }
            return try await self.buildConnection(domainIdentifier: domainIdentifier)
        }
        inFlightConnections[domainIdentifier] = buildTask

        let box: XPCConnectionBox
        do {
            box = try await buildTask.value
        } catch {
            inFlightConnections.removeValue(forKey: domainIdentifier)
            throw error
        }
        inFlightConnections.removeValue(forKey: domainIdentifier)

        // Cache here — after buildTask.value returns — so the connection is
        // stored exactly once. `buildConnection` must NOT store it; otherwise
        // concurrent in-flight waiters joining via the task above would each
        // call makeProxy on the same connection, creating double error-handlers
        // that both try to invalidate the same connection on fault.
        connections[domainIdentifier] = box
        Self.log.info(
            "FPE XPC connection established for domain \(domainIdentifier, privacy: .public)"
        )

        // Perform the protocol version handshake on each new connection (xpc-06).
        // Non-fatal: a mismatch is logged and surfaced to the user but does not
        // prevent the connection from being used.
        await checkProtocolVersion(connection: box.connection, domainIdentifier: domainIdentifier)

        return (box.connection, domainIdentifier)
    }

    /// Build and configure a new NSXPCConnection for `domainIdentifier`.
    private func buildConnection(domainIdentifier: String) async throws -> XPCConnectionBox {
        // Find the domain using the shared helper.
        let domain = try await findDomain(identifier: domainIdentifier)

        // Ask NSFileProviderManager for the XPC service.
        let manager = NSFileProviderManager(for: domain)
        guard let manager else {
            throw OfemFPEClientError.connectionFailed("NSFileProviderManager unavailable for \(domainIdentifier)")
        }

        // Get the NSFileProviderService object for the control service.
        let service: NSFileProviderService = try await withCheckedThrowingContinuation { rawCont in
            let cont = OneShotContinuation(rawCont)
            manager.getService(
                named: NSFileProviderServiceName(ofemControlServiceName),
                for: .rootContainer
            ) { svc, error in
                if let error {
                    cont.resume(throwing: error)
                } else if let svc {
                    cont.resume(returning: svc)
                } else {
                    cont.resume(throwing: OfemFPEClientError.connectionFailed(
                        "getService returned nil for \(domainIdentifier)"
                    ))
                }
            }
        }

        // Obtain the NSXPCConnection from the service.
        let connection: NSXPCConnection = try await withCheckedThrowingContinuation { rawCont in
            let cont = OneShotContinuation(rawCont)
            service.getFileProviderConnection(completionHandler: { conn, error in
                if let error {
                    cont.resume(throwing: error)
                } else if let conn {
                    cont.resume(returning: conn)
                } else {
                    cont.resume(throwing: OfemFPEClientError.connectionFailed(
                        "getFileProviderConnection returned nil for \(domainIdentifier)"
                    ))
                }
            })
        }

        // Configure the connection interface.
        connection.remoteObjectInterface = makeInterface()

        // The invalidation and interruption handlers are the single canonical
        // place for connection cache eviction. The per-call proxy error handler
        // (in withProxy) only resumes the waiting continuation; it does NOT
        // evict — avoiding the triple-eviction race (host-11).
        connection.invalidationHandler = { [weak self] in
            Task { @MainActor [weak self] in
                self?.connections.removeValue(forKey: domainIdentifier)
                OfemFPEClient.log.info(
                    "FPE XPC connection invalidated for domain \(domainIdentifier, privacy: .public)"
                )
            }
        }
        connection.interruptionHandler = { [weak self] in
            Task { @MainActor [weak self] in
                self?.connections.removeValue(forKey: domainIdentifier)
                OfemFPEClient.log.warning(
                    "FPE XPC connection interrupted for domain \(domainIdentifier, privacy: .public)"
                )
            }
        }
        connection.resume()
        return XPCConnectionBox(connection)
    }

    private func findDomain(identifier: String) async throws -> NSFileProviderDomain {
        let domains = try await ofemGetAllDomains()
        guard let domain = domains.first(where: { $0.identifier.rawValue == identifier }) else {
            throw OfemFPEClientError.domainNotFound(identifier)
        }
        return domain
    }

    private func makeInterface() -> NSXPCInterface {
        let iface = NSXPCInterface(with: OfemClientControlProtocol.self)
        // getEngineStatus reply: (XPCEngineStatus?, Error?)
        // XPCEngineStatus carries an NSArray of XPCPausedWorkspace; all three
        // types must be listed so XPC's secure-coding policy allows them.
        //
        // `setClasses(_:for:argumentIndex:ofReply:)` requires `Set<AnyHashable>`.
        // NSObject subclasses bridge to AnyHashable through ObjC, so the
        // NSSet(array:) bridge is the idiomatic Swift way to construct this set.
        // The force-cast is safe: ObjC class objects always bridge to AnyHashable.
        iface.setClasses(
            NSSet(array: [XPCEngineStatus.self, NSArray.self, XPCPausedWorkspace.self]) as! Set<AnyHashable>,
            for: #selector(OfemClientControlProtocol.getEngineStatus(reply:)),
            argumentIndex: 0,
            ofReply: true
        )
        return iface
    }
}

// MARK: - Errors

enum OfemFPEClientError: Error, CustomStringConvertible {
    case connectionFailed(String)
    case domainNotFound(String)

    var description: String {
        switch self {
        case .connectionFailed(let msg): return "FPE XPC connection failed: \(msg)"
        case .domainNotFound(let id):    return "FPE domain not found: \(id)"
        }
    }
}
