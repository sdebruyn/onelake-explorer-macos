// OfemFPEClient.swift
// Host-app client for the FPE's OfemClientControlProtocol XPC service.
//
// The host app uses this class to call account-management and engine-status
// operations on the FPE over NSXPCConnection.
//
// Connection model:
//   - One connection per domain. Connections are created on demand and
//     cached weakly (the FPE may restart the service after an invalidation).
//   - Connections are per-domain because NSFileProviderManager.service is
//     domain-scoped.
//
// Error handling:
//   NSXPCConnection can fail at any point (FPE process terminated, service
//   not registered, domain not found). Every method falls back gracefully
//   by returning a typed error that the caller can log.

import FileProvider
import Foundation
import os.log

// MARK: - OfemFPEClient

/// Manages XPC connections to the FPE's control service.
@MainActor
final class OfemFPEClient {
    static let shared = OfemFPEClient()

    private static let log = Logger(subsystem: "dev.debruyn.ofem", category: "fpe-client")

    private nonisolated init() {}

    // MARK: - Public API

    /// Registers a new account with the system by adding a File Provider domain
    /// for the given alias.
    ///
    /// Call this after `SharedOfemAuth.signIn` persists the account to config.toml.
    /// The FPE process is started by macOS when the domain is added; it reads
    /// the account from the shared config.toml on first enumeration.
    ///
    /// This replaces the previous `CoreBridge.login()` flow for domain registration.
    ///
    /// - Parameter info: The account info returned by `SharedOfemAuth.signIn`.
    func addAccount(_ info: XPCAccountInfo) async {
        await DomainSyncManager.shared.addDomain(alias: info.alias)
        Self.log.info("addAccount: domain registered for alias=\(info.alias, privacy: .public)")
    }

    /// Returns the list of accounts from the FPE for the given domain alias.
    ///
    /// - Parameter alias: The account alias identifying the domain.
    /// - Returns: Array of XPCAccountInfo, or empty on error.
    func listAccounts(alias: String) async throws -> [XPCAccountInfo] {
        let proxy = try await proxy(for: alias)
        return try await withCheckedThrowingContinuation { continuation in
            proxy.listAccounts { accounts, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: accounts)
                }
            }
        }
    }

    /// Removes an account via the FPE XPC service.
    func removeAccount(alias: String) async throws {
        let proxy = try await proxy(for: alias)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            proxy.removeAccount(alias: alias) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    /// Sets the default account via the FPE XPC service.
    func setDefaultAccount(alias: String) async throws {
        let proxy = try await proxy(for: alias)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            proxy.setDefaultAccount(alias: alias) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    /// Fetches a status snapshot from the FPE for the given domain alias.
    func status(alias: String) async throws -> [String: Any] {
        let proxy = try await proxy(for: alias)
        return try await withCheckedThrowingContinuation { continuation in
            proxy.status { dict, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: dict ?? [:])
                }
            }
        }
    }

    // MARK: - Engine status (Fase 7.3b-1)

    /// Fetches the engine status (cache stats + config snapshot) via XPC.
    ///
    /// - Parameter alias: Account alias identifying the domain.
    /// - Returns: `XPCEngineStatus` on success.
    func getEngineStatus(alias: String) async throws -> XPCEngineStatus {
        let proxy = try await proxy(for: alias)
        return try await withCheckedThrowingContinuation { continuation in
            proxy.getEngineStatus { status, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let status {
                    continuation.resume(returning: status)
                } else {
                    continuation.resume(throwing: OfemFPEClientError.connectionFailed(
                        "getEngineStatus returned nil status for alias \(alias)"
                    ))
                }
            }
        }
    }

    // MARK: - Config mutation (Fase 7.3b-1)

    /// Writes a config key/value pair through the FPE.
    ///
    /// - Parameters:
    ///   - alias: Account alias identifying the domain.
    ///   - key:   Config key in dot notation.
    ///   - value: New value as a string.
    func setConfig(alias: String, key: String, value: String) async throws {
        let proxy = try await proxy(for: alias)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            proxy.setConfig(key: key, value: value) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    // MARK: - Cache (Fase 7.3b-1)

    /// Clears all cached blobs via the FPE.
    ///
    /// - Parameter alias: Account alias identifying the domain.
    /// - Returns: Byte count remaining after the wipe (always 0 on success).
    @discardableResult
    func clearCache(alias: String) async throws -> Int64 {
        let proxy = try await proxy(for: alias)
        return try await withCheckedThrowingContinuation { continuation in
            proxy.clearCache { remaining, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: remaining)
                }
            }
        }
    }

    // MARK: - Connection management

    /// Cache of open connections keyed by domain identifier string.
    private var connections: [String: NSXPCConnection] = [:]

    /// Returns the proxy for the FPE's control service for the domain
    /// identified by `alias`. Creates a connection if needed.
    private func proxy(for alias: String) async throws -> any OfemClientControlProtocol {
        let domainIdentifier = "ofem.\(alias)"

        // Check for a cached, still-valid connection.
        if let conn = connections[domainIdentifier] {
            // Use remoteObjectProxyWithErrorHandler so that a connection fault (FPE
            // process crash, interruption) delivers an error to the reply block rather
            // than raising an ObjC exception that would crash the host app.
            guard let proxy = conn.remoteObjectProxyWithErrorHandler({ error in
                OfemFPEClient.log.error(
                    "FPE XPC proxy error for \(domainIdentifier, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
            }) as? any OfemClientControlProtocol else {
                connections.removeValue(forKey: domainIdentifier)
                throw OfemFPEClientError.connectionFailed("proxy cast failed for \(domainIdentifier)")
            }
            return proxy
        }

        // Find the domain.
        let domain = try await findDomain(identifier: domainIdentifier)

        // Ask NSFileProviderManager for the XPC service.
        let manager = NSFileProviderManager(for: domain)
        guard let manager else {
            throw OfemFPEClientError.connectionFailed("NSFileProviderManager unavailable for \(domainIdentifier)")
        }

        // Get the NSFileProviderService object for the control service.
        // macOS 13+ API: service(named:for:) returns NSFileProviderService.
        let service: NSFileProviderService = try await withCheckedThrowingContinuation { cont in
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
        let connection: NSXPCConnection = try await withCheckedThrowingContinuation { cont in
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
        connections[domainIdentifier] = connection

        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
            OfemFPEClient.log.error(
                "FPE XPC proxy error for \(domainIdentifier, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
        }) as? any OfemClientControlProtocol else {
            throw OfemFPEClientError.connectionFailed("proxy cast failed after connection setup")
        }
        Self.log.info(
            "FPE XPC connection established for domain \(domainIdentifier, privacy: .public)"
        )
        return proxy
    }

    private func findDomain(identifier: String) async throws -> NSFileProviderDomain {
        let domains: [NSFileProviderDomain] = try await withCheckedThrowingContinuation { cont in
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
        iface.setClasses(
            NSSet(array: [NSArray.self, XPCAccountInfo.self]) as! Set<AnyHashable>,
            for: #selector(OfemClientControlProtocol.listAccounts(reply:)),
            argumentIndex: 0,
            ofReply: true
        )
        iface.setClasses(
            NSSet(array: [XPCAccountInfo.self]) as! Set<AnyHashable>,
            for: #selector(
                OfemClientControlProtocol.addAccount(alias:tenant:clientID:reply:)
            ),
            argumentIndex: 0,
            ofReply: true
        )
        // status reply: ([String: Any]?, Error?)
        // NSDictionary contains NSArray of NSDictionary of NSString.
        iface.setClasses(
            NSSet(array: [NSDictionary.self, NSArray.self, NSString.self]) as! Set<AnyHashable>,
            for: #selector(OfemClientControlProtocol.status(reply:)),
            argumentIndex: 0,
            ofReply: true
        )
        // getEngineStatus reply: (XPCEngineStatus?, Error?)
        iface.setClasses(
            NSSet(array: [XPCEngineStatus.self]) as! Set<AnyHashable>,
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
