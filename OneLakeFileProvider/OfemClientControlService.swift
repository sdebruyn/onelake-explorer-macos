// OfemClientControlService.swift
// NSFileProviderServiceSource implementation for the FPE.
//
// The FPE exposes one NSFileProviderService named
// "dev.debruyn.ofem.control". The host app connects to this service
// via NSFileProviderManager.service(name:for:) and obtains an
// NSXPCConnection that it uses to call OfemClientControlProtocol
// methods (getProtocolVersion, getEngineStatus, setConfig, clearCache).
//
// Account management (add / remove) is handled in the host process via
// SharedOfemAuth and DomainSyncManager and does not cross the XPC boundary.
//
// XPC methods exposed:
//   - getProtocolVersion(reply:)  — version handshake; called on every new connection
//   - getEngineStatus(reply:)     — cache stats + config snapshot
//   - setConfig(key:value:reply:) — write one config field, persist and trigger engine reload
//   - clearCache(reply:)          — wipe all cached blobs; reply carries freed byte count
//
// NSXPCInterface setup notes:
//   - XPCEngineStatus must be listed for the getEngineStatus reply.
//   - The "reply" closures in the protocol are ObjC blocks; they
//     must be listed as reply blocks in the XPC interface via
//     setClasses(_:for:argumentIndex:ofReply:).

@preconcurrency import FileProvider
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

// MARK: - Reply-once helper

/// Ensures an XPC reply block is called at most once regardless of which code path
/// completes first (Task body, defer, or connection teardown).
///
/// NSXPCConnection invokes the reply block from an arbitrary queue; the Swift Task
/// body runs on a cooperative thread pool. Without this guard both paths can race to
/// call `reply` — the second call is undefined behaviour at the XPC boundary.
/// The lock makes the second call a no-op.
///
/// Usage: wrap each distinct reply invocation in a `() -> Void` closure so the
/// helper stays generic over the unit type.
///
/// `@unchecked Sendable`: the only mutable state is `replied`, guarded by `lock`.
private final class ReplyOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var replied = false

    func callOnce(_ body: () -> Void) {
        lock.withLock {
            guard !replied else { return }
            replied = true
            body()
        }
    }
}

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
///
/// `@unchecked Sendable`: `NSFileProviderServiceSource` is a synchronous
/// non-isolated ObjC protocol; actors are not viable here. All mutable state
/// (`listener`, `listenerDelegate`) is guarded by `listenerLock`.
final class OfemClientControlService: NSObject, NSFileProviderServiceSource, @unchecked Sendable {
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
///
/// `@unchecked Sendable`: `NSXPCListenerDelegate` is a synchronous non-isolated
/// ObjC protocol; actors are not viable here. The only stored property (`engineHost`)
/// is immutable after init — `any EngineProviding` is itself `Sendable` (protocol
/// requirement in OfemKit).
private final class OfemXPCListenerDelegate: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
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
///
/// `@unchecked Sendable`: XPC invokes these methods from an arbitrary thread;
/// `OfemClientControlProtocol` is a synchronous non-isolated `@objc` protocol.
/// The only stored property (`engineHost`) is immutable after init and is itself
/// `Sendable` (declared as `AnyObject & Sendable` in `EngineProviding`).
private final class OfemControlXPCHandler: NSObject, OfemClientControlProtocol, @unchecked Sendable {
    private static let log = Logger(
        subsystem: "dev.debruyn.ofem.fileprovider",
        category: "xpc-handler"
    )

    private let engineHost: any EngineProviding

    init(engineHost: any EngineProviding) {
        self.engineHost = engineHost
        super.init()
    }

    // MARK: - getProtocolVersion

    func getProtocolVersion(reply: @escaping (Int) -> Void) {
        reply(ofemControlProtocolVersion)
    }

    // MARK: - getEngineStatus

    func getEngineStatus(reply: @escaping (XPCEngineStatus?, Error?) -> Void) {
        // xpc-02: reply-once guard via ReplyOnce — fires exactly once on every
        // path, including Task cancellation or connection teardown.
        //
        // XPC @objc reply blocks are @escaping but not @Sendable. Box in
        // @unchecked Sendable so the Task body can capture it safely — the
        // ReplyOnce guard ensures the closure is called at most once.
        struct ReplyBox: @unchecked Sendable { let fn: (XPCEngineStatus?, Error?) -> Void }
        let rb = ReplyBox(fn: reply)
        let replyOnce = ReplyOnce()
        Task { [self] in
            defer { replyOnce.callOnce { rb.fn(nil, NSFileProviderError(.cannotSynchronize)) } }
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
                    pausedWorkspaces: pausedWorkspaces,
                    needsSignIn: engineHost.needsSignIn,
                    materializedPollIntervalS: cfg.sync.materializedPollIntervalS
                )
                replyOnce.callOnce { rb.fn(status, nil) }
            } catch {
                Self.log.error(
                    "getEngineStatus failed: \(error.localizedDescription, privacy: .public)"
                )
                replyOnce.callOnce { rb.fn(nil, error) }
            }
        }
    }

    // MARK: - setConfig

    func setConfig(key: String, value: String, reply: @escaping (Error?) -> Void) {
        // Validate-first: resolve (key, value) synchronously to a plain Sendable
        // value before spinning up any Task. Validation never mutates state
        // captured by the async mutator closure, so the closure stays
        // `@Sendable`-safe.
        //
        // `ValidatedConfig` is a Sendable enum of plain value-typed cases;
        // the async Task captures only the resolved case, not any closures.
        enum ValidatedConfig: Sendable {
            case telemetry(Bool)
            case cacheMaxSizeGB(Int)
            case netMaxUploads(Int)
            case netMaxDownloads(Int)
            case logLevel(String)
            case syncMaterializedPollIntervalS(Int)
        }

        let result: Result<ValidatedConfig, SetConfigError>
        switch key {
        case "telemetry":
            guard value == "on" || value == "off" else {
                result = .failure(.invalidValue(key: key, value: value,
                    reason: "expected \"on\" or \"off\""))
                break
            }
            result = .success(.telemetry(value == "on"))
        case "cache.max_size_gb":
            guard let gb = Int(value) else {
                result = .failure(.invalidValue(key: key, value: value,
                    reason: "expected an integer"))
                break
            }
            // 0 is the "no limit" sentinel; positive values are
            // clamped to [minSizeGB, maxSizeGB].
            let clamped = gb == 0 ? 0 : min(max(gb, CacheConfig.minSizeGB), CacheConfig.maxSizeGB)
            result = .success(.cacheMaxSizeGB(clamped))
        case "net.max_concurrent_uploads_per_account":
            guard let n = Int(value) else {
                result = .failure(.invalidValue(key: key, value: value,
                    reason: "expected an integer"))
                break
            }
            // xpc-07: use named constants from NetConfig.
            // Upper bound is per-protocol (16 uploads); the shared
            // NetConfig.maxConcurrent (64) is the absolute ceiling
            // for any concurrency field — the XPC protocol caps
            // uploads more tightly to avoid swamping the endpoint.
            result = .success(.netMaxUploads(min(max(n, NetConfig.minConcurrent), SetConfigLimits.maxUploadsPerAccount)))
        case "net.max_concurrent_downloads_per_account":
            guard let n = Int(value) else {
                result = .failure(.invalidValue(key: key, value: value,
                    reason: "expected an integer"))
                break
            }
            // xpc-08: use named constants from NetConfig.
            result = .success(.netMaxDownloads(min(max(n, NetConfig.minConcurrent), SetConfigLimits.maxDownloadsPerAccount)))
        case "log.level":
            let allowed = ["debug", "info", "warn", "error"]
            guard allowed.contains(value) else {
                result = .failure(.invalidValue(key: key, value: value,
                    reason: "expected one of \(allowed.joined(separator: ", "))"))
                break
            }
            result = .success(.logLevel(value))
        case "sync.materialized_poll_interval_s":
            guard let n = Int(value) else {
                result = .failure(.invalidValue(key: key, value: value,
                    reason: "expected an integer"))
                break
            }
            let clamped = max(SyncConfig.minMaterializedPollIntervalS,
                              min(SyncConfig.maxMaterializedPollIntervalS, n))
            result = .success(.syncMaterializedPollIntervalS(clamped))
        default:
            result = .failure(.unknownKey(key))
        }

        let validated: ValidatedConfig
        switch result {
        case .failure(let err):
            Self.log.warning(
                "setConfig: key='\(key, privacy: .public)' rejected: \(err.localizedDescription, privacy: .public)"
            )
            // xpc-03: bridge SetConfigError to NSError so the host
            // receives a decodable, classifiable error at the XPC
            // boundary rather than an opaque SwiftErrorDomain blob.
            reply(err.asNSError())
            return
        case .success(let value):
            validated = value
        }

        // xpc-02: reply-once guard via ReplyOnce — fires exactly once on every
        // path, including Task cancellation or connection teardown.
        //
        // XPC @objc reply blocks are @escaping but not @Sendable. Box in
        // @unchecked Sendable so the Task body can capture it safely — the
        // ReplyOnce guard ensures the closure is called at most once.
        struct ReplyBox: @unchecked Sendable { let fn: (Error?) -> Void }
        let rb = ReplyBox(fn: reply)
        let replyOnce = ReplyOnce()
        Task { [self] in
            defer { replyOnce.callOnce { rb.fn(NSFileProviderError(.cannotSynchronize)) } }
            do {
                let configStore = try engineHost.configStore()
                // The mutator closure captures only `validated` — a Sendable
                // enum of plain value-typed cases — so it is `@Sendable`-safe.
                try await configStore.updateAndSave { cfg in
                    switch validated {
                    case .telemetry(let flag):      cfg.telemetry = flag
                    case .cacheMaxSizeGB(let gb):   cfg.cache.maxSizeGB = gb
                    case .netMaxUploads(let n):     cfg.net.maxConcurrentUploadsPerAccount = n
                    case .netMaxDownloads(let n):   cfg.net.maxConcurrentDownloadsPerAccount = n
                    case .logLevel(let lvl):        cfg.log.level = lvl
                    case .syncMaterializedPollIntervalS(let n): cfg.sync.materializedPollIntervalS = n
                    }
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

                replyOnce.callOnce { rb.fn(nil) }
            } catch {
                Self.log.error(
                    "setConfig failed: key='\(key, privacy: .public)' error=\(error.localizedDescription, privacy: .public)"
                )
                replyOnce.callOnce { rb.fn(error) }
            }
        }
    }

    // MARK: - pollMaterialized

    func pollMaterialized(alias: String, reply: @escaping (Bool, Error?) -> Void) {
        // xpc-02: reply-once guard — fires exactly once on every path.
        //
        // XPC @objc reply blocks are @escaping but not @Sendable. Box in
        // @unchecked Sendable so the Task body can capture it safely — the
        // ReplyOnce guard ensures the closure is called at most once.
        struct ReplyBox: @unchecked Sendable { let fn: (Bool, Error?) -> Void }
        let rb = ReplyBox(fn: reply)
        let replyOnce = ReplyOnce()
        Task { [self] in
            defer { replyOnce.callOnce { rb.fn(false, NSFileProviderError(.cannotSynchronize)) } }
            do {
                let engine = try await engineHost.engine()
                // Read the materialized-container set for `alias` from the
                // cache. The FPE is the sole writer; no host-side cache access.
                let keys = try await engine.cache.materializedContainers(alias: alias)
                // Fan out refreshes with a per-alias concurrency cap that
                // mirrors the download-semaphore cap used elsewhere in the engine.
                let changed = await engine.sync.refreshMaterialized(
                    alias: alias,
                    keys: keys,
                    concurrencyCap: 4
                )
                replyOnce.callOnce { rb.fn(changed, nil) }
            } catch {
                Self.log.error(
                    "pollMaterialized failed alias=\(alias, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
                replyOnce.callOnce { rb.fn(false, error) }
            }
        }
    }

    // MARK: - clearCache

    func clearCache(reply: @escaping (Int64, Error?) -> Void) {
        // xpc-02: reply-once guard via ReplyOnce — fires exactly once on every
        // path, including Task cancellation or connection teardown.
        //
        // XPC @objc reply blocks are @escaping but not @Sendable. Box in
        // @unchecked Sendable so the Task body can capture it safely — the
        // ReplyOnce guard ensures the closure is called at most once.
        struct ReplyBox: @unchecked Sendable { let fn: (Int64, Error?) -> Void }
        let rb = ReplyBox(fn: reply)
        let replyOnce = ReplyOnce()
        Task { [self] in
            defer { replyOnce.callOnce { rb.fn(0, NSFileProviderError(.cannotSynchronize)) } }
            do {
                let engine = try await engineHost.engine()
                let (_, freedBytes) = try await engine.cache.wipe()
                Self.log.info("clearCache: \(freedBytes, privacy: .public) bytes freed")
                replyOnce.callOnce { rb.fn(freedBytes, nil) }
            } catch {
                Self.log.error(
                    "clearCache failed: \(error.localizedDescription, privacy: .public)"
                )
                replyOnce.callOnce { rb.fn(0, error) }
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
