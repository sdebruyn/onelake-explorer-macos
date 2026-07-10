// OfemClientControlService.swift
// NSFileProviderServiceSource implementation for the FPE.
//
// The FPE exposes one NSFileProviderService named
// "dev.debruyn.ofem.control". The host app connects to this service
// via NSFileProviderManager.service(name:for:) and obtains an
// NSXPCConnection that it uses to call OfemClientControlProtocol
// methods (getProtocolVersion, getEngineStatus, setConfig, clearCache,
// pollMaterialized, reloadEngine).
//
// Account management (add / remove) is handled in the host process via
// SharedOfemAuth and DomainSyncManager and does not cross the XPC boundary.
//
// XPC methods exposed:
//   - getProtocolVersion(reply:)  — version handshake; called on every new connection
//   - getEngineStatus(reply:)     — cache stats + config snapshot
//   - getBadgeStatus(reply:)      — slim needsSignIn + pausedWorkspaces, no cache scan (#397)
//   - setConfig(key:value:reply:) — write one config field, persist and trigger engine reload
//   - clearCache(reply:)          — wipe all cached blobs; reply carries freed byte count
//   - reloadEngine(alias:reply:)  — reload the engine for alias (e.g. after re-authentication)
//
// NSXPCInterface setup: the secure-coding class wiring for getEngineStatus's
// reply lives in the single `OfemControlInterface.make()` factory in
// Shared/ (xpc-09) — both this file's `exportedInterface` and the host's
// `remoteObjectInterface` call the same factory.

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

/// Boxes an XPC reply closure as `Sendable` (M11).
///
/// `@objc` XPC protocol reply blocks are `@escaping` but never `@Sendable`, so
/// they cannot be captured directly by a `Task` body. `Reply` is inferred at
/// each call site as the verb's own reply closure type (e.g.
/// `(Bool, Error?) -> Void`); this box carries it across the region-isolation
/// boundary unchanged. `ReplyOnce` — not this box — is what actually enforces
/// single-invocation; the box only satisfies the compiler.
private struct ReplyBox<Reply>: @unchecked Sendable {
    let fn: Reply
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
    // periphery:ignore - NSXPCListener.delegate is weak; this var is the strong retain anchor
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

    init(engineHost: any EngineProviding) {
        self.engineHost = engineHost
        super.init()
    }

    func listener(
        _: NSXPCListener,
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
        newConnection.exportedInterface = OfemControlInterface.make()
        let handler = OfemControlXPCHandler(engineHost: engineHost)
        newConnection.exportedObject = handler
        // M11: cancel every Task the handler has in flight once this
        // connection tears down — invalidationHandler is the guaranteed
        // final teardown signal (unlike interruptionHandler, which can
        // precede a reconnect). Mirrors OfemFPEEnumerator's invalidate().
        newConnection.invalidationHandler = { [weak handler] in
            handler?.cancelActiveTasks()
        }
        newConnection.resume()
        return true
    }
}

// MARK: - XPC Handler (the "exported object" on the FPE side)

/// Implements OfemClientControlProtocol — called by the host app via XPC.
///
/// `@unchecked Sendable`: XPC invokes these methods from an arbitrary thread;
/// `OfemClientControlProtocol` is a synchronous non-isolated `@objc` protocol.
/// The only stored property (`engineHost`) is immutable after init and is itself
/// `Sendable` (declared as `AnyObject & Sendable` in `EngineProviding`).
///
/// Internal rather than `private` (the file-scoping used by the other helper
/// types in this file) so `OfemClientControlServiceTests.swift` can construct
/// it directly against a `MockEngineHost` and exercise the protocol methods
/// without an actual XPC connection.
final class OfemControlXPCHandler: NSObject, OfemClientControlProtocol, @unchecked Sendable {
    private static let log = Logger(
        subsystem: "dev.debruyn.ofem.fileprovider",
        category: "xpc-handler"
    )

    private let engineHost: any EngineProviding

    // MARK: - Handler Task tracking (M11)

    /// Guards `activeTasks`, `finishedBeforeRegistration`, and
    /// `isInvalidated`. XPC invokes every handler verb from an arbitrary
    /// queue, and `cancelActiveTasks()` can run concurrently with an
    /// in-flight verb call spawning a new Task, so all access goes through
    /// this lock — mirrors `OfemFPEEnumerator`'s `taskLock` discipline.
    private let tasksLock = NSLock()
    /// Every Task spawned by `runReplying`, keyed by a per-call `UUID` so
    /// concurrent calls — to the same verb or different ones — are tracked
    /// independently. Each entry is removed by its own Task's `defer` on
    /// completion (via `untrack(_:)`); `cancelActiveTasks()` drains
    /// whatever remains on teardown.
    private nonisolated(unsafe) var activeTasks: [UUID: Task<Void, Never>] = [:]
    /// IDs of Tasks whose `defer` called `untrack(_:)` *before*
    /// `runReplying` got back around to registering them in `activeTasks` —
    /// the fast-finish race described on `runReplying`. `runReplying`
    /// consumes (removes) its own ID from here instead of storing a handle
    /// for a Task that has already finished; there would be nothing left
    /// for `cancelActiveTasks()` to usefully cancel.
    ///
    /// Only ever populated pre-invalidation (`untrack(_:)` skips the insert
    /// once `isInvalidated` is true — see its doc comment) and drained by
    /// either `runReplying`'s registration step or, for the narrow window
    /// where invalidation lands between that check and registration,
    /// `runReplying`'s own `isInvalidated` branch. Never left to grow
    /// unboundedly.
    private nonisolated(unsafe) var finishedBeforeRegistration: Set<UUID> = []
    /// Set by `cancelActiveTasks()` under `tasksLock`. `runReplying` checks
    /// this under the same lock acquisition it uses to store a new Task's
    /// handle, so a Task whose creation races with `cancelActiveTasks()` is
    /// cancelled immediately instead of being stored and left unmanaged.
    private nonisolated(unsafe) var isInvalidated = false

    init(engineHost: any EngineProviding) {
        self.engineHost = engineHost
        super.init()
    }

    /// Removes a completed Task's handle from `activeTasks`. Called from
    /// the Task's own `defer` in `runReplying`.
    ///
    /// A miss (the handle isn't in `activeTasks`) has two possible causes,
    /// and they need different handling:
    /// - the genuine fast-finish race: `runReplying` hasn't reached its own
    ///   `tasksLock.withLock` registration step yet. Record the ID in
    ///   `finishedBeforeRegistration` so that pending registration step
    ///   knows not to store a handle for a Task that has already finished.
    /// - post-invalidation: `cancelActiveTasks()` already ran — either it
    ///   drained this ID out of `activeTasks` via `removeAll()`, or
    ///   registration hasn't happened yet and will see `isInvalidated` and
    ///   skip storing entirely. Either way nothing will ever consume an
    ///   entry inserted here, so inserting one would leak it permanently.
    ///   `isInvalidated` only ever transitions false → true, so checking it
    ///   here reliably distinguishes the two cases.
    private func untrack(_ id: UUID) {
        tasksLock.withLock {
            guard activeTasks.removeValue(forKey: id) == nil else { return }
            guard !isInvalidated else { return }
            finishedBeforeRegistration.insert(id)
        }
    }

    /// Cancels every outstanding handler Task's cooperative-cancellation
    /// flag and drops its tracking entry. Wired to the owning
    /// `NSXPCConnection`'s `invalidationHandler` in
    /// `OfemXPCListenerDelegate`, so no Task's *bookkeeping* survives its
    /// connection's teardown.
    ///
    /// `task.cancel()` only sets `Task.isCancelled`; it does not interrupt
    /// work already in flight. Whether a given verb's `operation` actually
    /// stops early depends on that verb: read-only verbs (`getEngineStatus`,
    /// `getBadgeStatus`) check `Task.isCancelled` and bail out;
    /// state-mutating verbs (`setConfig`, `reloadEngine`, `clearCache`) run
    /// to completion by design — see each verb's own comment. Either way
    /// the eventual reply is safe: `replyOnce` still fires exactly once,
    /// and a reply delivered to an already-invalidated `NSXPCConnection` is
    /// a no-op (the host's `withProxy` continuation was already resumed by
    /// the connection's own error handler).
    func cancelActiveTasks() {
        tasksLock.withLock {
            isInvalidated = true
            for task in activeTasks.values {
                task.cancel()
            }
            activeTasks.removeAll()
        }
    }

    // MARK: - Reply-scaffold helper (M11)

    /// Runs `operation` on a newly created, tracked `Task`, guaranteeing the
    /// XPC reply block fires at most once.
    ///
    /// This helper never calls `reply` itself — it only boxes it (`ReplyBox`)
    /// so `onTeardown` and `operation` can carry it across the
    /// region-isolation boundary. Both routes call it only through the
    /// shared `ReplyOnce`, so whichever fires first — `operation`'s own
    /// success/failure reply, or the `onTeardown` fallback running in
    /// `defer` (Task cancelled, or `operation` returned without replying) —
    /// wins, and the other is a silent no-op. A genuine double reply is
    /// therefore structurally impossible, not merely unlikely.
    ///
    /// The Task is created *outside* `tasksLock`, then registered under a
    /// separate `tasksLock.withLock` — matching `OfemFPEEnumerator`'s
    /// create-then-lock ordering, rather than creating the Task from inside
    /// the locked block (which would let its own `defer`-triggered
    /// `untrack(_:)` call re-enter `tasksLock` while this method might
    /// still be holding it — safe only because `Task {}` never runs its
    /// body inline, which is a fragile invariant to lean on rather than a
    /// structural guarantee).
    ///
    /// This ordering reopens a race the enumerator doesn't have to deal
    /// with — it never removes its own single-slot handle, so it can't
    /// race its own removal — but `activeTasks` here supports many
    /// concurrent in-flight verb calls via a dictionary, which does need
    /// self-removal. Two races are closed:
    /// - a Task created concurrently with `cancelActiveTasks()` is
    ///   cancelled immediately instead of stored (`isInvalidated` check,
    ///   same as the enumerator);
    /// - a Task fast enough to run to completion and call `untrack(_:)`
    ///   before this method reaches its own registration step would
    ///   otherwise leave a permanently-orphaned entry once this method
    ///   *did* go on to store it. `untrack(_:)` records that case in
    ///   `finishedBeforeRegistration`; this method consumes that record
    ///   instead of storing a handle for a Task that's already done.
    private func runReplying<Reply>(
        reply: Reply,
        onTeardown: @escaping @Sendable (Reply) -> Void,
        operation: @escaping @Sendable (Reply, ReplyOnce) async -> Void
    ) {
        let rb = ReplyBox(fn: reply)
        let replyOnce = ReplyOnce()
        let taskID = UUID()
        let task = Task { [self] in
            defer {
                replyOnce.callOnce { onTeardown(rb.fn) }
                untrack(taskID)
            }
            await operation(rb.fn, replyOnce)
        }
        tasksLock.withLock {
            if isInvalidated {
                task.cancel()
                // Belt-and-suspenders: closes the narrow window where this
                // Task finished and untrack(_:) inserted into
                // finishedBeforeRegistration *before* isInvalidated flipped
                // true, but cancelActiveTasks() then ran before this
                // registration step did. untrack(_:) itself won't have
                // leaked a fresh entry here (it now skips inserting once
                // isInvalidated is true), so this only ever mops up that
                // one pre-existing race window — never grows the set.
                finishedBeforeRegistration.remove(taskID)
            } else if finishedBeforeRegistration.remove(taskID) != nil {
                // Already ran to completion before we got here — nothing
                // left to track or cancel.
            } else {
                activeTasks[taskID] = task
            }
        }
    }

    // MARK: - XPCPausedWorkspace mapping (M11)

    /// Maps a cache row to the XPC wire type. Shared by `getEngineStatus`
    /// and `getBadgeStatus`, the only two verbs that report paused
    /// workspaces.
    private static func mapPausedWorkspace(_ row: WorkspaceStatusRecord) -> XPCPausedWorkspace {
        XPCPausedWorkspace(
            accountAlias: row.accountAlias,
            workspaceID: row.workspaceID,
            reason: row.reason,
            detectedAtSec: row.detectedAtNs > 0
                ? Double(row.detectedAtNs) / 1_000_000_000
                : 0
        )
    }

    // MARK: - getProtocolVersion

    func getProtocolVersion(reply: @escaping (Int) -> Void) {
        reply(ofemControlProtocolVersion)
    }

    // MARK: - getEngineStatus

    func getEngineStatus(reply: @escaping (XPCEngineStatus?, Error?) -> Void) {
        // xpc-02 / M11: reply-once guard via runReplying — fires exactly
        // once on every path, including Task cancellation or connection
        // teardown. Read-only, so cancellation is genuinely safe: the
        // Task.isCancelled check below actually skips the remaining work
        // (unlike the mutating verbs — see clearCache's comment).
        runReplying(
            reply: reply,
            onTeardown: { fn in fn(nil, NSFileProviderError(.cannotSynchronize)) },
            operation: { fn, replyOnce in
                guard !Task.isCancelled else { return }
                do {
                    // Read config snapshot via the shared configStore — does NOT
                    // require the engine to be built yet (cheaper for first call).
                    let configStore = try self.engineHost.configStore()
                    let cfg = configStore.snapshot()

                    // Measure cached blob bytes only if the engine is already up;
                    // if the engine has never been started we return -1 (not measured).
                    let cacheBytes: Int64
                    var pausedWorkspaces: [XPCPausedWorkspace] = []

                    if let engine = self.engineHost.existingEngine() {
                        guard !Task.isCancelled else { return }
                        cacheBytes = (try? await engine.cache.blobBytes()) ?? -1

                        // Query the workspace_status table for paused entries.
                        // Best-effort — a failure leaves the list empty rather than
                        // causing the whole status call to fail.
                        if let rows = try? await engine.cache.listPausedWorkspaces() {
                            pausedWorkspaces = rows.map(Self.mapPausedWorkspace)
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
                        needsSignIn: self.engineHost.needsSignIn,
                        materializedPollIntervalS: cfg.sync.materializedPollIntervalS,
                        selfHealIntervalM: cfg.sync.selfHealIntervalM
                    )
                    replyOnce.callOnce { fn(status, nil) }
                } catch {
                    Self.log.error(
                        "getEngineStatus failed: \(error.localizedDescription, privacy: .public)"
                    )
                    replyOnce.callOnce { fn(nil, error) }
                }
            }
        )
    }

    // MARK: - getBadgeStatus

    func getBadgeStatus(reply: @escaping (XPCBadgeStatus?, Error?) -> Void) {
        // xpc-02 / M11: reply-once guard via runReplying — fires exactly
        // once on every path, including Task cancellation or connection
        // teardown. Read-only, so cancellation is genuinely safe: the
        // Task.isCancelled check below actually skips the remaining work
        // (unlike the mutating verbs — see clearCache's comment).
        runReplying(
            reply: reply,
            onTeardown: { fn in fn(nil, NSFileProviderError(.cannotSynchronize)) },
            operation: { fn, replyOnce in
                guard !Task.isCancelled else { return }
                // Engine-optional, mirroring getEngineStatus's existingEngine() branch,
                // so the badge still reports needsSignIn before the engine has ever
                // been built. Deliberately skips blobBytes() and the config snapshot
                // entirely — that's the whole point of this slim verb (#397).
                var pausedWorkspaces: [XPCPausedWorkspace] = []
                if let engine = self.engineHost.existingEngine(),
                   let rows = try? await engine.cache.listPausedWorkspaces()
                {
                    pausedWorkspaces = rows.map(Self.mapPausedWorkspace)
                }
                let status = XPCBadgeStatus(needsSignIn: self.engineHost.needsSignIn, pausedWorkspaces: pausedWorkspaces)
                replyOnce.callOnce { fn(status, nil) }
            }
        )
    }

    // MARK: - setConfig helpers

    /// Parses `value` as `Int`, returning `SetConfigError.invalidValue` on failure.
    /// Shared by the integer-typed config keys to avoid repeating the guard+error in each case.
    private static func intRequired(key: String, value: String) -> Result<Int, SetConfigError> {
        guard let n = Int(value) else {
            return .failure(.invalidValue(key: key, value: value, reason: "expected an integer"))
        }
        return .success(n)
    }

    /// Validates a raw (key, value) XPC pair and resolves it to a typed `ValidatedConfig`.
    ///
    /// Pure and synchronous — called by `setConfig` before any Task is spawned so the async
    /// mutator closure captures only a `Sendable` value, never a closure. The switch covers
    /// every `OfemConfigKey` case without a `default:` arm so a new key added to `OfemConfigKey`
    /// that lacks a matching arm here fails the build rather than silently falling through
    /// to `.unknownKey` at runtime (xpc-10).
    private static func validateConfig(key: String, value: String) -> Result<ValidatedConfig, SetConfigError> {
        guard let configKey = OfemConfigKey(rawValue: key) else {
            return .failure(.unknownKey(key))
        }
        switch configKey {
        case .telemetry:
            guard ["on", "off"].contains(value) else {
                return .failure(.invalidValue(key: key, value: value,
                                              reason: "expected \"on\" or \"off\""))
            }
            return .success(.telemetry(value == "on"))
        case .cacheMaxSizeGB:
            // 0 = "no limit" sentinel; positives clamped to [minSizeGB, maxSizeGB] (M9).
            return Self.intRequired(key: key, value: value)
                .map { .cacheMaxSizeGB(CacheConfig.clampSizeGB($0)) }
        case .netMaxUploads:
            // xpc-07: per-protocol cap (16 uploads) tighter than maxConcurrent (64); same clamp as M9.
            return Self.intRequired(key: key, value: value)
                .map { .netMaxUploads(SetConfigLimits.clampUploads($0)) }
        case .netMaxDownloads:
            // xpc-08: see clampUploads above.
            return Self.intRequired(key: key, value: value)
                .map { .netMaxDownloads(SetConfigLimits.clampDownloads($0)) }
        case .logLevel:
            let allowed = ["debug", "info", "warn", "error"]
            guard allowed.contains(value) else {
                return .failure(.invalidValue(key: key, value: value,
                                              reason: "expected one of \(allowed.joined(separator: ", "))"))
            }
            return .success(.logLevel(value))
        case .syncMaterializedPollIntervalS:
            return Self.intRequired(key: key, value: value).map {
                let clamped = max(SyncConfig.minMaterializedPollIntervalS,
                                  min(SyncConfig.maxMaterializedPollIntervalS, $0))
                return .syncMaterializedPollIntervalS(clamped)
            }
        case .syncSelfHealIntervalM:
            // 0 is the "disabled" sentinel and is preserved as-is.
            return Self.intRequired(key: key, value: value)
                .map { .syncSelfHealIntervalM(clampedSelfHealIntervalM($0)) }
        }
    }

    // MARK: - setConfig

    func setConfig(key: String, value: String, reply: @escaping (Error?) -> Void) {
        // Validate-first: resolve (key, value) to a plain Sendable value before
        // spinning up any Task. `ValidatedConfig` is a Sendable enum; the async
        // Task captures only the resolved case, not any closures.
        let result = Self.validateConfig(key: key, value: value)

        let validated: ValidatedConfig
        switch result {
        case let .failure(err):
            Self.log.warning(
                "setConfig: key='\(key, privacy: .public)' rejected: \(err.localizedDescription, privacy: .public)"
            )
            // xpc-03: bridge SetConfigError to NSError so the host
            // receives a decodable, classifiable error at the XPC
            // boundary rather than an opaque SwiftErrorDomain blob.
            reply(err.asNSError())
            return
        case let .success(v):
            validated = v
        }

        // xpc-02 / M11: reply-once guard via runReplying — fires exactly once.
        // Does NOT check Task.isCancelled (write + reload must complete atomically).
        runReplying(
            reply: reply,
            onTeardown: { fn in fn(NSFileProviderError(.cannotSynchronize)) },
            operation: { fn, replyOnce in
                do {
                    let configStore = try self.engineHost.configStore()
                    // `validated` is Sendable (value-typed enum) — `@Sendable`-safe capture.
                    try await configStore.updateAndSave { cfg in
                        switch validated {
                        case let .telemetry(flag): cfg.telemetry = flag
                        case let .cacheMaxSizeGB(gb): cfg.cache.maxSizeGB = gb
                        case let .netMaxUploads(n): cfg.net.maxConcurrentUploadsPerAccount = n
                        case let .netMaxDownloads(n): cfg.net.maxConcurrentDownloadsPerAccount = n
                        case let .logLevel(lvl): cfg.log.level = lvl
                        case let .syncMaterializedPollIntervalS(n): cfg.sync.materializedPollIntervalS = n
                        case let .syncSelfHealIntervalM(n): cfg.sync.selfHealIntervalM = n
                        }
                    }
                    Self.log.info(
                        "setConfig: key='\(key, privacy: .public)' value='\(value, privacy: .public)' applied"
                    )
                    // Reload the engine so the new config values take effect without waiting
                    // for the FPE process to terminate. OfemEngine reads the config snapshot
                    // once at init; reload shuts down the current engine and lets the next
                    // use rebuild lazily.
                    await self.engineHost.reloadEngine()
                    replyOnce.callOnce { fn(nil) }
                } catch {
                    Self.log.error(
                        "setConfig failed: key='\(key, privacy: .public)' error=\(error.localizedDescription, privacy: .public)"
                    )
                    replyOnce.callOnce { fn(error) }
                }
            }
        )
    }

    // MARK: - pollMaterialized

    func pollMaterialized(alias: String, reply: @escaping (Bool, Error?) -> Void) {
        // xpc-02 / M11: reply-once guard via runReplying — fires exactly
        // once on every path. Only a pre-flight Task.isCancelled check:
        // skips *starting* refreshMaterialized if already cancelled, but
        // does not attempt to interrupt it mid-pass once started —
        // refreshMaterialized's own per-key error handling already treats
        // cancellation as a non-fatal per-key error and runs the pass to
        // completion regardless (see its doc comment in SyncEngine.swift),
        // so an isCancelled check partway through would not change its
        // behaviour.
        runReplying(
            reply: reply,
            onTeardown: { fn in fn(false, NSFileProviderError(.cannotSynchronize)) },
            operation: { fn, replyOnce in
                guard !Task.isCancelled else { return }
                do {
                    let engine = try await self.engineHost.engine()
                    // Read the materialized-container set for `alias` from the
                    // cache. The FPE is the sole writer; no host-side cache access.
                    let keys = try await engine.cache.materializedContainers(alias: alias)
                    // Read the configured self-heal interval from the shared config store.
                    // Falls back to the engine's built-in default when the store is unavailable.
                    let selfHealIntervalM: Int = if let configStore = try? self.engineHost.configStore() {
                        configStore.snapshot().sync.selfHealIntervalM
                    } else {
                        SyncEngine.defaultSelfHealIntervalMinutes
                    }
                    // Fan out refreshes with a per-alias concurrency cap that
                    // mirrors the download-semaphore cap used elsewhere in the engine.
                    let changed = await engine.sync.refreshMaterialized(
                        alias: alias,
                        keys: keys,
                        concurrencyCap: 4,
                        selfHealIntervalMinutes: selfHealIntervalM
                    )
                    replyOnce.callOnce { fn(changed, nil) }
                } catch {
                    Self.log.error(
                        "pollMaterialized failed alias=\(alias, privacy: .public): \(error.localizedDescription, privacy: .public)"
                    )
                    replyOnce.callOnce { fn(false, error) }
                }
            }
        )
    }

    // MARK: - reloadEngine

    func reloadEngine(alias: String, reply: @escaping (Error?) -> Void) {
        // xpc-02 / M11: reply-once guard via runReplying — fires exactly
        // once on every path. Deliberately does NOT check Task.isCancelled:
        // reloadEngine() shuts the current engine down and rebuilds lazily
        // on next use — interrupting that halfway would leave the engine in
        // an inconsistent shutdown state. cancelActiveTasks() still clears
        // this Task's tracking entry on teardown; see its doc comment.
        runReplying(
            reply: reply,
            onTeardown: { fn in fn(NSFileProviderError(.cannotSynchronize)) },
            operation: { fn, replyOnce in
                // engineHost.reloadEngine() shuts down the current engine and
                // clears _needsSignIn; the next use rebuilds it lazily (xpc-11).
                await self.engineHost.reloadEngine()
                Self.log.info("reloadEngine: alias=\(alias, privacy: .public) reloaded")
                replyOnce.callOnce { fn(nil) }
            }
        )
    }

    // MARK: - clearCache

    func clearCache(reply: @escaping (Int64, Error?) -> Void) {
        // xpc-02 / M11: reply-once guard via runReplying — fires exactly
        // once on every path, including Task cancellation or connection
        // teardown. Deliberately does NOT check Task.isCancelled: this
        // wipes the on-disk blob cache, and interrupting a wipe halfway
        // could leave it in a partially-cleared state — worse than letting
        // it finish and delivering (or safely discarding) a late reply.
        // cancelActiveTasks() still clears this Task's tracking entry on
        // teardown; it just doesn't stop the wipe in flight.
        runReplying(
            reply: reply,
            onTeardown: { fn in fn(0, NSFileProviderError(.cannotSynchronize)) },
            operation: { fn, replyOnce in
                do {
                    let engine = try await self.engineHost.engine()
                    let (_, freedBytes) = try await engine.cache.wipe()
                    Self.log.info("clearCache: \(freedBytes, privacy: .public) bytes freed")
                    replyOnce.callOnce { fn(freedBytes, nil) }
                } catch {
                    Self.log.error(
                        "clearCache failed: \(error.localizedDescription, privacy: .public)"
                    )
                    replyOnce.callOnce { fn(0, error) }
                }
            }
        )
    }
}

// MARK: - ValidatedConfig

/// Typed result of per-key XPC config validation. `Sendable` because all cases hold
/// value types; `setConfig` captures one of these in the async Task body.
private enum ValidatedConfig {
    case telemetry(Bool)
    case cacheMaxSizeGB(Int)
    case netMaxUploads(Int)
    case netMaxDownloads(Int)
    case logLevel(String)
    case syncMaterializedPollIntervalS(Int)
    case syncSelfHealIntervalM(Int)
}

/// Clamps a raw self-heal interval: 0 (the "disabled" sentinel) is preserved as-is;
/// non-zero values are clamped to [minSelfHealIntervalM, maxSelfHealIntervalM].
private func clampedSelfHealIntervalM(_ n: Int) -> Int {
    n == 0 ? 0 : max(SyncConfig.minSelfHealIntervalM, min(SyncConfig.maxSelfHealIntervalM, n))
}

// MARK: - SetConfig errors

/// Errors returned when the host app sends a setConfig call with an unknown
/// key or a value that fails validation.
enum SetConfigError: Error, LocalizedError {
    case unknownKey(String)
    case invalidValue(key: String, value: String, reason: String)

    var errorDescription: String? {
        switch self {
        case let .unknownKey(k):
            "setConfig: unknown key '\(k)'"
        case let .invalidValue(k, v, r):
            "setConfig: invalid value '\(v)' for key '\(k)': \(r)"
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
        case let .unknownKey(k):
            code = 1
            userInfo["key"] = k
        case let .invalidValue(k, v, r):
            code = 2
            userInfo["key"] = k
            userInfo["value"] = v
            userInfo["reason"] = r
        }
        userInfo[NSLocalizedDescriptionKey] = errorDescription ?? localizedDescription
        return NSError(domain: "dev.debruyn.ofem.setConfig", code: code, userInfo: userInfo)
    }
}
