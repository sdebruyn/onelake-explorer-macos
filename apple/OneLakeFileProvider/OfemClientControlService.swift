// OfemClientControlService.swift
// NSFileProviderServiceSource implementation for the FPE.
//
// The FPE exposes one NSFileProviderService named
// "dev.debruyn.ofem.control". The host app connects to this service
// via NSFileProviderManager.service(name:for:) and obtains an
// NSXPCConnection that it uses to call OfemClientControlProtocol
// methods (listAccounts, removeAccount, setDefaultAccount, status).
//
// Interactive authentication (addAccount) is NOT handled via XPC in
// Fase 7.2 because the interactive sign-in flow (MSAL +
// ASWebAuthenticationSession) requires a UI window — something only
// the host app process can own. The host app continues to call
// CoreBridge.login() over the Unix socket for interactive auth;
// account metadata is written to the shared config.toml by the
// daemon, which the FPE engine then reads on next engine build.
// This hybrid is removed in Fase 7.3.
//
// NSXPCInterface setup notes:
//   - allowedClasses must include XPCAccountInfo and NSArray for
//     the listAccounts reply.
//   - The "reply" closures in the protocol are ObjC blocks; they
//     must be listed as reply blocks in the XPC interface via
//     setClasses(_:for:argumentIndex:ofReply:).

import FileProvider
import Foundation
import OfemKit
import os.log

/// NSFileProviderServiceSource that vends the OfemClientControlProtocol XPC service.
///
/// Registered in the FPE via `NSFileProviderReplicatedExtension`'s
/// `supportedServiceSources(for:)`. One service source per domain instance,
/// but all domains share the same underlying OfemConfigStore.
final class OfemClientControlService: NSObject, NSFileProviderServiceSource {
    private static let log = Logger(
        subsystem: "dev.debruyn.ofem.fileprovider",
        category: "control-service"
    )

    let serviceName = NSFileProviderServiceName(ofemControlServiceName)

    private let engineHost: FPEEngineHost

    // NSXPCListener.delegate is a weak property, so we must retain the delegate
    // ourselves for as long as the listener lives. Both listener and delegate are
    // stored here so they are released together when the service source is released.
    private var listener: NSXPCListener?
    private var listenerDelegate: OfemXPCListenerDelegate?

    init(engineHost: FPEEngineHost) {
        self.engineHost = engineHost
        super.init()
    }

    func makeListenerEndpoint() throws -> NSXPCListenerEndpoint {
        let delegate = OfemXPCListenerDelegate(engineHost: engineHost)
        let l = NSXPCListener.anonymous()
        l.delegate = delegate
        l.resume()
        // Retain both strongly so neither is released before the endpoint is used.
        self.listenerDelegate = delegate
        self.listener = l
        Self.log.info(
            "OfemClientControlService: XPC listener endpoint created for alias=\(self.engineHost.alias, privacy: .public)"
        )
        return l.endpoint
    }
}

// MARK: - XPC Listener Delegate

/// Accepts and configures incoming XPC connections for the control protocol.
private final class OfemXPCListenerDelegate: NSObject, NSXPCListenerDelegate {
    private let engineHost: FPEEngineHost

    init(engineHost: FPEEngineHost) {
        self.engineHost = engineHost
        super.init()
    }

    func listener(
        _ listener: NSXPCListener,
        shouldAcceptNewConnection newConnection: NSXPCConnection
    ) -> Bool {
        newConnection.exportedInterface = makeInterface()
        newConnection.exportedObject = OfemControlXPCHandler(engineHost: engineHost)
        newConnection.resume()
        return true
    }

    private func makeInterface() -> NSXPCInterface {
        let iface = NSXPCInterface(with: OfemClientControlProtocol.self)

        // listAccounts reply: ([XPCAccountInfo], Error?)
        // Argument index 0 of the reply block is an NSArray of XPCAccountInfo.
        iface.setClasses(
            NSSet(array: [NSArray.self, XPCAccountInfo.self]) as! Set<AnyHashable>,
            for: #selector(OfemClientControlProtocol.listAccounts(reply:)),
            argumentIndex: 0,
            ofReply: true
        )

        // addAccount reply: (XPCAccountInfo?, Error?)
        // Argument index 0 is XPCAccountInfo or nil.
        iface.setClasses(
            NSSet(array: [XPCAccountInfo.self]) as! Set<AnyHashable>,
            for: #selector(
                OfemClientControlProtocol.addAccount(alias:tenant:clientID:reply:)
            ),
            argumentIndex: 0,
            ofReply: true
        )

        // status reply: ([String: Any]?, Error?)
        // Argument index 0 is NSDictionary containing NSArray of NSDictionary of NSString.
        // All three container types must be listed so XPC's secure-coding policy allows them.
        iface.setClasses(
            NSSet(array: [NSDictionary.self, NSArray.self, NSString.self]) as! Set<AnyHashable>,
            for: #selector(OfemClientControlProtocol.status(reply:)),
            argumentIndex: 0,
            ofReply: true
        )

        return iface
    }
}

// MARK: - XPC Handler (the "exported object" on the FPE side)

/// Implements OfemClientControlProtocol — called by the host app via XPC.
private final class OfemControlXPCHandler: NSObject, OfemClientControlProtocol {
    private static let log = Logger(
        subsystem: "dev.debruyn.ofem.fileprovider",
        category: "xpc-handler"
    )

    private let engineHost: FPEEngineHost

    init(engineHost: FPEEngineHost) {
        self.engineHost = engineHost
        super.init()
    }

    // MARK: - addAccount

    func addAccount(
        alias: String,
        tenant: String,
        clientID: String,
        reply: @escaping (XPCAccountInfo?, Error?) -> Void
    ) {
        // Interactive sign-in requires a UI window. In Fase 7.2 the host app
        // still drives the MSAL interactive flow via the Go-daemon Unix socket.
        // This XPC method is defined for forward-compatibility (Fase 7.3) but
        // currently returns an error to route the caller back to the legacy path.
        let error = NSError(
            domain: "dev.debruyn.ofem.control",
            code: 501,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "addAccount via XPC is not yet implemented; use the host app's sign-in flow",
            ]
        )
        Self.log.info(
            "addAccount(alias:\(alias, privacy: .public)) via XPC — not yet implemented, returning 501"
        )
        reply(nil, error)
    }

    // MARK: - removeAccount

    func removeAccount(alias: String, reply: @escaping (Error?) -> Void) {
        Task { [self] in
            do {
                let engine = try await engineHost.engine()
                try await MainActor.run {
                    try engine.auth.removeAccount(alias: alias)
                }
                Self.log.info("removeAccount: alias=\(alias, privacy: .public) removed via XPC")
                reply(nil)
            } catch {
                Self.log.error(
                    "removeAccount failed: alias=\(alias, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
                )
                reply(error)
            }
        }
    }

    // MARK: - listAccounts

    func listAccounts(reply: @escaping ([XPCAccountInfo], Error?) -> Void) {
        Task { [self] in
            do {
                let engine = try await engineHost.engine()
                let accounts = await MainActor.run {
                    engine.auth.listAccounts()
                }
                let xpcAccounts = accounts.map { XPCAccountInfo(from: $0) }
                reply(xpcAccounts, nil)
            } catch {
                Self.log.error(
                    "listAccounts failed: \(error.localizedDescription, privacy: .public)"
                )
                reply([], error)
            }
        }
    }

    // MARK: - setDefaultAccount

    func setDefaultAccount(alias: String, reply: @escaping (Error?) -> Void) {
        Task { [self] in
            do {
                let engine = try await engineHost.engine()
                try await MainActor.run {
                    try engine.auth.setDefaultAccount(alias: alias)
                }
                reply(nil)
            } catch {
                Self.log.error(
                    "setDefaultAccount failed: \(error.localizedDescription, privacy: .public)"
                )
                reply(error)
            }
        }
    }

    // MARK: - notifyAuthComplete

    func notifyAuthComplete(sessionID: String, reply: @escaping (Error?) -> Void) {
        // Reserved for the future two-phase auth flow (Fase 7.3).
        // In Fase 7.2 the host app drives the entire MSAL interactive flow.
        Self.log.debug(
            "notifyAuthComplete(sessionID:\(sessionID, privacy: .private)) — no-op in Fase 7.2"
        )
        reply(nil)
    }

    // MARK: - status

    func status(reply: @escaping ([String: Any]?, Error?) -> Void) {
        Task { [self] in
            do {
                let engine = try await engineHost.engine()
                let accounts = await MainActor.run {
                    engine.auth.listAccounts()
                }
                let defaultAlias = await MainActor.run {
                    engine.auth.defaultAccount() ?? ""
                }
                let accountDicts: [[String: String]] = accounts.map { acc in
                    [
                        "alias": acc.alias,
                        "username": acc.username,
                        "tenantId": acc.tenantID,
                        "tenantName": acc.tenantName ?? "",
                    ]
                }
                let result: [String: Any] = [
                    "accounts": accountDicts,
                    "defaultAccount": defaultAlias,
                ]
                reply(result, nil)
            } catch {
                reply(nil, error)
            }
        }
    }
}
