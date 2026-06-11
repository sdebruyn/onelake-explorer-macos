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

import FileProvider
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
final class OneShotContinuation<T>: @unchecked Sendable {
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

// MARK: - OfemFPEClient

/// Manages XPC connections to the FPE's control service.
@MainActor
final class OfemFPEClient {
    static let shared = OfemFPEClient()

    private static let log = Logger(subsystem: "dev.debruyn.ofem", category: "fpe-client")

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
        let proxy = try await proxy(for: alias)
        return try await withCheckedThrowingContinuation { rawContinuation in
            let cont = OneShotContinuation(rawContinuation)
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
        let proxy = try await proxy(for: alias)
        try await withCheckedThrowingContinuation { (rawContinuation: CheckedContinuation<Void, Error>) in
            let cont = OneShotContinuation(rawContinuation)
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
        let proxy = try await proxy(for: alias)
        return try await withCheckedThrowingContinuation { rawContinuation in
            let cont = OneShotContinuation(rawContinuation)
            proxy.clearCache { remaining, error in
                if let error {
                    cont.resume(throwing: error)
                } else {
                    cont.resume(returning: remaining)
                }
            }
        }
    }

    // MARK: - Connection management

    /// Cache of open connections keyed by domain identifier string.
    private var connections: [String: NSXPCConnection] = [:]

    /// In-flight connection-build tasks keyed by domain identifier string.
    /// Prevents check-then-insert races: concurrent callers for the same
    /// domain await the same Task rather than each building a connection.
    private var inFlightConnections: [String: Task<NSXPCConnection, Error>] = [:]

    /// Returns the proxy for the FPE's control service for the domain
    /// identified by `alias`. Creates a connection if needed.
    private func proxy(for alias: String) async throws -> any OfemClientControlProtocol {
        let domainIdentifier = "ofem.\(alias)"

        // Check for a cached, still-valid connection.
        if let conn = connections[domainIdentifier] {
            // Use remoteObjectProxyWithErrorHandler so a connection fault routes
            // into the OneShotContinuation's error path in the call site.
            guard let proxy = conn.remoteObjectProxyWithErrorHandler({ [weak self] error in
                Task { @MainActor [weak self] in
                    if let old = self?.connections.removeValue(forKey: domainIdentifier) {
                        old.invalidate()
                    }
                }
                OfemFPEClient.log.error(
                    "FPE XPC proxy error for \(domainIdentifier, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
            }) as? any OfemClientControlProtocol else {
                connections.removeValue(forKey: domainIdentifier)
                conn.invalidate()
                throw OfemFPEClientError.connectionFailed("proxy cast failed for \(domainIdentifier)")
            }
            return proxy
        }

        // If a build is already in flight for this domain, await it rather than
        // starting a second one (prevents the check-then-insert race).
        if let inFlight = inFlightConnections[domainIdentifier] {
            let connection = try await inFlight.value
            return try makeProxy(connection: connection, domainIdentifier: domainIdentifier)
        }

        // Build a new connection under a tracked Task so concurrent callers
        // can join the same build rather than racing.
        let buildTask: Task<NSXPCConnection, Error> = Task { [weak self] in
            guard let self else {
                throw OfemFPEClientError.connectionFailed("OfemFPEClient deallocated during connection build")
            }
            return try await self.buildConnection(domainIdentifier: domainIdentifier)
        }
        inFlightConnections[domainIdentifier] = buildTask

        let connection: NSXPCConnection
        do {
            connection = try await buildTask.value
        } catch {
            inFlightConnections.removeValue(forKey: domainIdentifier)
            throw error
        }
        inFlightConnections.removeValue(forKey: domainIdentifier)

        let proxy = try makeProxy(connection: connection, domainIdentifier: domainIdentifier)
        Self.log.info(
            "FPE XPC connection established for domain \(domainIdentifier, privacy: .public)"
        )
        return proxy
    }

    /// Wraps a connection in a proxy, wiring the error handler to evict + invalidate.
    private func makeProxy(
        connection: NSXPCConnection,
        domainIdentifier: String
    ) throws -> any OfemClientControlProtocol {
        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ [weak self] error in
            Task { @MainActor [weak self] in
                if let old = self?.connections.removeValue(forKey: domainIdentifier) {
                    old.invalidate()
                }
            }
            OfemFPEClient.log.error(
                "FPE XPC proxy error for \(domainIdentifier, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
        }) as? any OfemClientControlProtocol else {
            throw OfemFPEClientError.connectionFailed("proxy cast failed for \(domainIdentifier)")
        }
        return proxy
    }

    /// Build and configure a new NSXPCConnection for `domainIdentifier`.
    private func buildConnection(domainIdentifier: String) async throws -> NSXPCConnection {
        // Find the domain.
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
        connection.invalidationHandler = { [weak self] in
            Task { @MainActor [weak self] in
                // Evict and explicitly invalidate so libxpc releases the connection.
                if let old = self?.connections.removeValue(forKey: domainIdentifier) {
                    old.invalidate()
                }
                OfemFPEClient.log.info(
                    "FPE XPC connection invalidated for domain \(domainIdentifier, privacy: .public)"
                )
            }
        }
        connection.interruptionHandler = { [weak self] in
            Task { @MainActor [weak self] in
                // Evict and invalidate the interrupted connection; the next call
                // to proxy(for:) will rebuild it.
                if let old = self?.connections.removeValue(forKey: domainIdentifier) {
                    old.invalidate()
                }
                OfemFPEClient.log.warning(
                    "FPE XPC connection interrupted for domain \(domainIdentifier, privacy: .public)"
                )
            }
        }
        connection.resume()
        // Store the connection so subsequent calls reuse it.
        connections[domainIdentifier] = connection
        return connection
    }

    private func findDomain(identifier: String) async throws -> NSFileProviderDomain {
        let domains: [NSFileProviderDomain] = try await withCheckedThrowingContinuation { rawCont in
            let cont = OneShotContinuation(rawCont)
            NSFileProviderManager.getDomainsWithCompletionHandler { domains, error in
                if let error {
                    cont.resume(throwing: error)
                } else {
                    cont.resume(returning: domains)
                }
            }
        }
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
