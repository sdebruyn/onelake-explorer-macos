// OfemFPEClient.swift
// Host-app client for the FPE's OfemClientControlProtocol XPC service.
//
// The host app uses this class to call account-management operations on
// the FPE over NSXPCConnection, replacing (or supplementing) the existing
// CoreBridge / Unix-socket path.
//
// Connection model:
//   - One connection per domain. Connections are created on demand and
//     cached weakly (the FPE may restart the service after an invalidation).
//   - Connections are per-domain because NSFileProviderManager.service is
//     domain-scoped.
//
// Fase 7.2 usage:
//   The host app's DomainSyncManager and MenuStatusModel continue to use
//   CoreBridge for status / account list. OfemFPEClient is wired in as an
//   addition — the host app calls it for removeAccount and setDefaultAccount
//   so the FPE's engine state is kept in sync without needing the Go daemon.
//   Phase 7.3 will replace CoreBridge calls entirely.
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

    // MARK: - Connection management

    /// Cache of open connections keyed by domain identifier string.
    private var connections: [String: NSXPCConnection] = [:]

    /// Returns the proxy for the FPE's control service for the domain
    /// identified by `alias`. Creates a connection if needed.
    private func proxy(for alias: String) async throws -> any OfemClientControlProtocol {
        let domainIdentifier = "ofem.\(alias)"

        // Check for a cached, still-valid connection.
        if let conn = connections[domainIdentifier] {
            guard let proxy = conn.remoteObjectProxy as? any OfemClientControlProtocol else {
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

        guard let proxy = connection.remoteObjectProxy as? any OfemClientControlProtocol else {
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
