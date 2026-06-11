// OfemClientControlService.swift
// NSFileProviderServiceSource implementation for the FPE.
//
// The FPE exposes one NSFileProviderService named
// "dev.debruyn.ofem.control". The host app connects to this service
// via NSFileProviderManager.service(name:for:) and obtains an
// NSXPCConnection that it uses to call OfemClientControlProtocol
// methods (getEngineStatus, setConfig, clearCache).
//
// Account management (add / remove) is handled in the host process via
// SharedOfemAuth and DomainSyncManager and does not cross the XPC boundary.
//
// XPC methods exposed:
//   - getEngineStatus(reply:)     — cache stats + config snapshot
//   - setConfig(key:value:reply:) — write one config field and reload
//   - clearCache(reply:)          — wipe all cached blobs
//
// NSXPCInterface setup notes:
//   - XPCEngineStatus must be listed for the getEngineStatus reply.
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

        // getEngineStatus reply: (XPCEngineStatus?, Error?)
        // Argument index 0 is XPCEngineStatus (which contains an NSArray of
        // XPCPausedWorkspace). All three types must be listed so XPC's
        // secure-coding policy allows them to cross the boundary.
        iface.setClasses(
            NSSet(array: [XPCEngineStatus.self, NSArray.self, XPCPausedWorkspace.self]) as! Set<AnyHashable>,
            for: #selector(OfemClientControlProtocol.getEngineStatus(reply:)),
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

    // MARK: - getEngineStatus

    func getEngineStatus(reply: @escaping (XPCEngineStatus?, Error?) -> Void) {
        Task { [self] in
            do {
                // Read config snapshot via the shared configStore — does NOT
                // require the engine to be built yet (cheaper for first call).
                let configStore = try engineHost.configStore()
                let cfg = configStore.snapshot()

                // Measure cached blob bytes only if the engine is already up;
                // if the engine has never been started we return -1 (not measured).
                let cacheBytes: Int64
                var pausedWorkspaces: [XPCPausedWorkspace] = []

                if let engine = engineHost.existingEngine() {
                    cacheBytes = (try? await engine.cache.blobBytes()) ?? -1

                    // Query the workspace_status table for paused entries.
                    // Best-effort — a failure leaves the list empty rather than
                    // causing the whole status call to fail.
                    if let rows = try? await engine.cache.listPausedWorkspaces() {
                        pausedWorkspaces = rows.map { row in
                            XPCPausedWorkspace(
                                accountAlias: row.accountAlias,
                                workspaceID: row.workspaceID,
                                reason: row.reason,
                                detectedAtSec: row.detectedAtNs > 0
                                    ? Double(row.detectedAtNs) / 1_000_000_000
                                    : 0
                            )
                        }
                    }
                } else {
                    cacheBytes = -1
                }

                let cacheMaxGB = cfg.cache.maxSizeGB
                let cacheMaxBytes = cfg.cache.maxBytes

                let status = XPCEngineStatus(
                    cacheBytes: cacheBytes,
                    cacheMaxBytes: cacheMaxBytes,
                    cacheMaxSizeGB: cacheMaxGB,
                    telemetryEnabled: cfg.telemetry,
                    netMaxUploads: cfg.net.maxConcurrentUploadsPerAccount,
                    netMaxDownloads: cfg.net.maxConcurrentDownloadsPerAccount,
                    logLevel: cfg.log.level,
                    pausedWorkspaces: pausedWorkspaces
                )
                reply(status, nil)
            } catch {
                Self.log.error(
                    "getEngineStatus failed: \(error.localizedDescription, privacy: .public)"
                )
                reply(nil, error)
            }
        }
    }

    // MARK: - setConfig

    func setConfig(key: String, value: String, reply: @escaping (Error?) -> Void) {
        Task { [self] in
            do {
                let configStore = try engineHost.configStore()
                try configStore.updateAndSave { cfg in
                    switch key {
                    case "telemetry":
                        cfg.telemetry = (value == "on")
                    case "cache.max_size_gb":
                        if let gb = Int(value) {
                            cfg.cache.maxSizeGB = min(max(gb, 1), 100)
                        }
                    case "net.max_concurrent_uploads_per_account":
                        if let n = Int(value) {
                            cfg.net.maxConcurrentUploadsPerAccount = min(max(n, 1), 16)
                        }
                    case "net.max_concurrent_downloads_per_account":
                        if let n = Int(value) {
                            cfg.net.maxConcurrentDownloadsPerAccount = min(max(n, 1), 32)
                        }
                    case "log.level":
                        let allowed = ["debug", "info", "warn", "error"]
                        if allowed.contains(value) {
                            cfg.log.level = value
                        }
                    default:
                        Self.log.warning(
                            "setConfig: unknown key '\(key, privacy: .public)' — ignoring"
                        )
                    }
                }
                Self.log.info(
                    "setConfig: key='\(key, privacy: .public)' value='\(value, privacy: .public)' applied"
                )
                reply(nil)
            } catch {
                Self.log.error(
                    "setConfig failed: key='\(key, privacy: .public)' error=\(error.localizedDescription, privacy: .public)"
                )
                reply(error)
            }
        }
    }

    // MARK: - clearCache

    func clearCache(reply: @escaping (Int64, Error?) -> Void) {
        Task { [self] in
            do {
                let engine = try await engineHost.engine()
                let (_, _) = try await engine.cache.wipe()
                Self.log.info("clearCache: blobs wiped")
                reply(0, nil)
            } catch {
                Self.log.error(
                    "clearCache failed: \(error.localizedDescription, privacy: .public)"
                )
                reply(0, error)
            }
        }
    }
}
