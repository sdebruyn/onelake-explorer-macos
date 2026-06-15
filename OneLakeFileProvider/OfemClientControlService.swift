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
//   - setConfig(key:value:reply:) — write one config field, persist and trigger engine reload
//   - clearCache(reply:)          — wipe all cached blobs; reply carries freed byte count
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

// MARK: - XPC code-signing requirement

/// Code-signing requirement that the FPE enforces on incoming XPC connections.
///
/// Requires the exact host-app bundle identifier and the OFEM developer Team ID.
/// Encoded as a constant so the string is defined once and auditable — a change
/// to the bundle ID or Team ID that is not reflected here fails the connection
/// at runtime with a clear "connection invalid" rather than a silent security gap.
///
/// Syntax: Code Signing Requirement Language (man csreq / Security.framework).
///   - `identifier "..."` — exact CFBundleIdentifier match
///   - `anchor apple generic` — any Apple-issued cert chain
///   - `certificate leaf[subject.OU]` — Developer Team ID leaf field
let ofemXPCPeerRequirement = #"identifier "dev.debruyn.ofem" and anchor apple generic and certificate leaf[subject.OU] = "6D79CUWZ4J""#

// MARK: - OfemClientControlService

/// NSFileProviderServiceSource that vends the OfemClientControlProtocol XPC service.
///
/// Registered in the FPE via `NSFileProviderReplicatedExtension`'s
/// `supportedServiceSources(for:)`. One service source per domain instance;
/// all domains in the same FPE process share the same underlying
/// `OfemConfigStore` via `FPEEngineHost.sharedConfigStore()`.
///
/// A single NSXPCListener is created lazily on the first `makeListenerEndpoint`
/// call and reused for all subsequent calls. Replacing the listener on every
/// call would orphan the previous endpoint's connections.
final class OfemClientControlService: NSObject, NSFileProviderServiceSource {
    private static let log = Logger(
        subsystem: "dev.debruyn.ofem.fileprovider",
        category: "control-service"
    )

    let serviceName = NSFileProviderServiceName(ofemControlServiceName)

    private let engineHost: any EngineProviding

    // NSXPCListener.delegate is a weak property, so we must retain the delegate
    // ourselves for as long as the listener lives. Both listener and delegate are
    // stored here so they are released together when the service source is released.
    // Protected by listenerLock so makeListenerEndpoint is safe to call from any thread.
    private let listenerLock = NSLock()
    private var listener: NSXPCListener?
    private var listenerDelegate: OfemXPCListenerDelegate?

    init(engineHost: any EngineProviding) {
        self.engineHost = engineHost
        super.init()
    }

    func makeListenerEndpoint() throws -> NSXPCListenerEndpoint {
        listenerLock.withLock {
            // Reuse the existing listener if one already exists. Creating a new
            // listener on every call would orphan connections established against
            // the previous endpoint.
            if let existing = listener {
                Self.log.debug(
                    "OfemClientControlService: reusing existing XPC listener for alias=\(self.engineHost.alias, privacy: .public)"
                )
                return existing.endpoint
            }
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
}

// MARK: - XPC Listener Delegate

/// Accepts and configures incoming XPC connections for the control protocol.
private final class OfemXPCListenerDelegate: NSObject, NSXPCListenerDelegate {
    private let engineHost: any EngineProviding
    private static let log = Logger(
        subsystem: "dev.debruyn.ofem.fileprovider",
        category: "control-service"
    )

    init(engineHost: any EngineProviding) {
        self.engineHost = engineHost
        super.init()
    }

    func listener(
        _ listener: NSXPCListener,
        shouldAcceptNewConnection newConnection: NSXPCConnection
    ) -> Bool {
        // Validate that the connecting process is the OFEM host app by checking
        // its code-signing requirement. The requirement string is the single
        // authoritative definition; see `ofemXPCPeerRequirement`.
        //
        // `setCodeSigningRequirement` is available on macOS 13+ (our minimum is 14).
        // Peer validation is lazy and happens on the first message; this call
        // only records the requirement — the ObjC method is non-throwing.
        newConnection.setCodeSigningRequirement(ofemXPCPeerRequirement)
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
        //
        // Build the Set<AnyHashable> via NSSet with explicit bridging.
        // NSSet(array:) bridges AnyObject (class metatypes) to AnyHashable safely;
        // the cast is guaranteed to succeed because all elements are ObjC class metatypes
        // which bridge to AnyHashable via NSObjectProtocol.
        let classArray: [AnyObject] = [XPCEngineStatus.self, NSArray.self, XPCPausedWorkspace.self]
        let replyClasses = NSSet(array: classArray) as! Set<AnyHashable>  // safe: AnyObject metatypes
        iface.setClasses(
            replyClasses,
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

    private let engineHost: any EngineProviding

    init(engineHost: any EngineProviding) {
        self.engineHost = engineHost
        super.init()
    }

    // MARK: - getEngineStatus

    func getEngineStatus(reply: @escaping (XPCEngineStatus?, Error?) -> Void) {
        // xpc-02: reply-once guard — fires exactly once on every path,
        // including Task cancellation or connection teardown. Without this a
        // torn-down connection can leave the host app waiting forever.
        var replied = false
        let replyOnce: (XPCEngineStatus?, Error?) -> Void = { status, err in
            guard !replied else { return }
            replied = true
            reply(status, err)
        }
        Task { [self] in
            defer { replyOnce(nil, NSFileProviderError(.cannotSynchronize)) }
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
                replyOnce(status, nil)
            } catch {
                Self.log.error(
                    "getEngineStatus failed: \(error.localizedDescription, privacy: .public)"
                )
                replyOnce(nil, error)
            }
        }
    }

    // MARK: - setConfig

    func setConfig(key: String, value: String, reply: @escaping (Error?) -> Void) {
        // xpc-02: reply-once guard — fires exactly once on every path,
        // including Task cancellation or connection teardown.
        var replied = false
        let replyOnce: (Error?) -> Void = { err in
            guard !replied else { return }
            replied = true
            reply(err)
        }
        Task { [self] in
            defer { replyOnce(NSFileProviderError(.cannotSynchronize)) }
            do {
                let configStore = try engineHost.configStore()
                var applyError: SetConfigError? = nil
                try await configStore.updateAndSave { cfg in
                    switch key {
                    case "telemetry":
                        guard value == "on" || value == "off" else {
                            applyError = .invalidValue(key: key, value: value,
                                reason: "expected \"on\" or \"off\"")
                            return
                        }
                        cfg.telemetry = (value == "on")
                    case "cache.max_size_gb":
                        guard let gb = Int(value) else {
                            applyError = .invalidValue(key: key, value: value,
                                reason: "expected an integer")
                            return
                        }
                        // 0 is the "no limit" sentinel; positive values are
                        // clamped to [minSizeGB, maxSizeGB].
                        cfg.cache.maxSizeGB = gb == 0
                            ? 0
                            : min(max(gb, CacheConfig.minSizeGB), CacheConfig.maxSizeGB)
                    case "net.max_concurrent_uploads_per_account":
                        guard let n = Int(value) else {
                            applyError = .invalidValue(key: key, value: value,
                                reason: "expected an integer")
                            return
                        }
                        // xpc-07: use named constants from NetConfig.
                        // Upper bound is per-protocol (16 uploads); the shared
                        // NetConfig.maxConcurrent (64) is the absolute ceiling
                        // for any concurrency field — the XPC protocol caps
                        // uploads more tightly to avoid swamping the endpoint.
                        cfg.net.maxConcurrentUploadsPerAccount = min(max(n, NetConfig.minConcurrent), SetConfigLimits.maxUploadsPerAccount)
                    case "net.max_concurrent_downloads_per_account":
                        guard let n = Int(value) else {
                            applyError = .invalidValue(key: key, value: value,
                                reason: "expected an integer")
                            return
                        }
                        // xpc-08: use named constants from NetConfig.
                        cfg.net.maxConcurrentDownloadsPerAccount = min(max(n, NetConfig.minConcurrent), SetConfigLimits.maxDownloadsPerAccount)
                    case "log.level":
                        let allowed = ["debug", "info", "warn", "error"]
                        guard allowed.contains(value) else {
                            applyError = .invalidValue(key: key, value: value,
                                reason: "expected one of \(allowed.joined(separator: ", "))")
                            return
                        }
                        cfg.log.level = value
                    default:
                        applyError = .unknownKey(key)
                    }
                }

                if let applyError {
                    Self.log.warning(
                        "setConfig: key='\(key, privacy: .public)' rejected: \(applyError.localizedDescription, privacy: .public)"
                    )
                    // xpc-03: bridge SetConfigError to NSError so the host
                    // receives a decodable, classifiable error at the XPC
                    // boundary rather than an opaque SwiftErrorDomain blob.
                    replyOnce(applyError.asNSError())
                    return
                }

                Self.log.info(
                    "setConfig: key='\(key, privacy: .public)' value='\(value, privacy: .public)' applied"
                )

                // Reload the engine so the new config values take effect
                // without waiting for the FPE process to terminate.
                // OfemEngine reads the config snapshot once at init, so the
                // reload mechanism is: shut down the current engine, clear
                // _engine and _buildError, and let the next use rebuild lazily.
                await engineHost.reloadEngine()

                replyOnce(nil)
            } catch {
                Self.log.error(
                    "setConfig failed: key='\(key, privacy: .public)' error=\(error.localizedDescription, privacy: .public)"
                )
                replyOnce(error)
            }
        }
    }

    // MARK: - clearCache

    func clearCache(reply: @escaping (Int64, Error?) -> Void) {
        // xpc-02: reply-once guard — fires exactly once on every path,
        // including Task cancellation or connection teardown.
        var replied = false
        let replyOnce: (Int64, Error?) -> Void = { bytes, err in
            guard !replied else { return }
            replied = true
            reply(bytes, err)
        }
        Task { [self] in
            defer { replyOnce(0, NSFileProviderError(.cannotSynchronize)) }
            do {
                let engine = try await engineHost.engine()
                let (_, freedBytes) = try await engine.cache.wipe()
                Self.log.info("clearCache: \(freedBytes, privacy: .public) bytes freed")
                replyOnce(freedBytes, nil)
            } catch {
                Self.log.error(
                    "clearCache failed: \(error.localizedDescription, privacy: .public)"
                )
                replyOnce(0, error)
            }
        }
    }
}

// MARK: - SetConfig concurrency limits (xpc-07/08)

/// Per-field upper bounds for the XPC setConfig handler's concurrency fields.
///
/// These values are intentionally tighter than `NetConfig.maxConcurrent` (64)
/// to avoid saturating the OneLake / Fabric endpoints from a single client.
/// The XPC protocol comments document these numbers; keep them in sync.
enum SetConfigLimits {
    /// Maximum allowed concurrent uploads per account (maps to the protocol
    /// comment "integer string, 1–16").
    static let maxUploadsPerAccount = 16
    /// Maximum allowed concurrent downloads per account (maps to the protocol
    /// comment "integer string, 1–32").
    static let maxDownloadsPerAccount = 32
}

// MARK: - SetConfig errors

/// Errors returned when the host app sends a setConfig call with an unknown
/// key or a value that fails validation.
enum SetConfigError: Error, LocalizedError {
    case unknownKey(String)
    case invalidValue(key: String, value: String, reason: String)

    var errorDescription: String? {
        switch self {
        case .unknownKey(let k):
            return "setConfig: unknown key '\(k)'"
        case .invalidValue(let k, let v, let r):
            return "setConfig: invalid value '\(v)' for key '\(k)': \(r)"
        }
    }

    /// Bridges to `NSError` so the value survives the XPC boundary as a
    /// decodable, classifiable error (xpc-03). Sending a plain Swift enum
    /// across XPC produces a `SwiftErrorDomain` blob with no useful fields
    /// on the receiving side.
    func asNSError() -> NSError {
        let code: Int
        var userInfo: [String: Any] = [:]
        switch self {
        case .unknownKey(let k):
            code = 1
            userInfo["key"] = k
        case .invalidValue(let k, let v, let r):
            code = 2
            userInfo["key"] = k
            userInfo["value"] = v
            userInfo["reason"] = r
        }
        userInfo[NSLocalizedDescriptionKey] = errorDescription ?? localizedDescription
        return NSError(domain: "dev.debruyn.ofem.setConfig", code: code, userInfo: userInfo)
    }
}
