// CoreBridge.swift
// Singleton that owns the cgo bridge to the Go core (`libofemcore.a`).
//
// All File Provider Extension entry points eventually funnel through
// this type. It is responsible for:
//
//   * Initialising the Go core exactly once per process (sync.Once-style
//     semantics on the Swift side, mirroring the Go-side guard).
//   * Resolving the App Group container path so the Go core, the host
//     app, and the daemon all read/write the same on-disk state.
//   * Marshalling C strings across the FFI boundary and freeing every
//     buffer the Go core returns to us.
//   * Decoding the JSON envelopes the Go core produces into typed
//     Swift values, surfacing typed errors on failure.
//
// The bridge is intentionally thread-safe by way of a serial dispatch
// queue: the C entry points themselves are safe to call concurrently
// from Go's perspective, but funnelling every call through a single
// queue gives us deterministic ordering and a single place to hang
// future tracing/diagnostics off.

import Foundation
import os.log

// TODO(shared-framework): Account and BridgeError below are duplicated
// in apple/OneLake/CoreBridge.swift (host-app target). Both copies must
// stay in sync. Tracked for consolidation into a shared framework in
// Phase 2. See apple/OneLake/CoreBridge.swift for the authoritative comment.

/// JSON shape returned by `ofem_core_list_accounts`.
struct Account: Decodable, Equatable {
    let alias: String
    let username: String
    let tenantId: String
    let tenantName: String
}

/// Decoded representation of a single item entry returned by the Go
/// core's enumerate / item calls. Mapped onto `OneLakeItem` for
/// presentation to the File Provider framework.
struct BridgeItem: Decodable, Equatable {
    let identifier: String
    let parentIdentifier: String?
    let filename: String
    let isDir: Bool
    let size: Int64?
    let contentType: String?
    let modificationDate: Date?
    let contentVersion: String
    let metadataVersion: String
    let capabilities: [String]?

    /// Custom decoding so we can parse the RFC3339 `modificationDate`
    /// string with millisecond precision without forcing the whole
    /// decoder to a single date strategy.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.identifier = try c.decode(String.self, forKey: .identifier)
        self.parentIdentifier = try c.decodeIfPresent(String.self, forKey: .parentIdentifier)
        self.filename = try c.decode(String.self, forKey: .filename)
        self.isDir = try c.decode(Bool.self, forKey: .isDir)
        self.size = try c.decodeIfPresent(Int64.self, forKey: .size)
        self.contentType = try c.decodeIfPresent(String.self, forKey: .contentType)
        self.contentVersion = try c.decode(String.self, forKey: .contentVersion)
        self.metadataVersion = try c.decode(String.self, forKey: .metadataVersion)
        self.capabilities = try c.decodeIfPresent([String].self, forKey: .capabilities)

        if let raw = try c.decodeIfPresent(String.self, forKey: .modificationDate) {
            self.modificationDate = BridgeItem.parseDate(raw)
        } else {
            self.modificationDate = nil
        }
    }

    private static let rfc3339WithFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let rfc3339Plain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static func parseDate(_ raw: String) -> Date? {
        if let d = rfc3339WithFractional.date(from: raw) {
            return d
        }
        return rfc3339Plain.date(from: raw)
    }

    private enum CodingKeys: String, CodingKey {
        case identifier
        case parentIdentifier
        case filename
        case isDir
        case size
        case contentType
        case modificationDate
        case contentVersion
        case metadataVersion
        case capabilities
    }
}

/// Envelope shape for the JSON the Go core returns. Either a payload
/// (`items` / `item` / `accounts`) or an `error` describing a typed
/// failure. The two are mutually exclusive on the wire; we model them
/// as separate optional fields and let the caller dispatch.
private struct AccountsEnvelope: Decodable {
    let accounts: [Account]?
    let error: BridgeErrorPayload?
}

private struct ItemsEnvelope: Decodable {
    let items: [BridgeItem]?
    let error: BridgeErrorPayload?
}

private struct ItemEnvelope: Decodable {
    let item: BridgeItem?
    let error: BridgeErrorPayload?
}

private struct BridgeErrorPayload: Decodable {
    let code: String
    let message: String
}

/// Typed errors the bridge can surface. Mapped to `NSFileProviderError`
/// at the boundary with `ErrorMapping.swift`.
enum BridgeError: Error, Equatable {
    case noSuchItem(String)
    case notAuthenticated(String)
    case serverUnreachable(String)
    case serverBusy(String)
    case insufficientQuota(String)
    case cannotSynchronize(String)
    /// The Go core handed back a payload we could not parse. The
    /// underlying decoder error is summarised in the message so it
    /// shows up in Console.app logs.
    case decoding(String)
    /// The Go core returned `NULL` from a function that promised to
    /// return a JSON buffer.
    case nullPointer(String)
    /// The Go core has not been initialised yet. Indicates a
    /// programming error — we should always call `bootstrap()` first.
    case notBootstrapped

    fileprivate init(payload: BridgeErrorPayload) {
        switch payload.code {
        case "noSuchItem":
            self = .noSuchItem(payload.message)
        case "notAuthenticated":
            self = .notAuthenticated(payload.message)
        case "serverUnreachable":
            self = .serverUnreachable(payload.message)
        case "serverBusy":
            self = .serverBusy(payload.message)
        case "insufficientQuota":
            self = .insufficientQuota(payload.message)
        case "cannotSynchronize":
            self = .cannotSynchronize(payload.message)
        default:
            self = .cannotSynchronize("\(payload.code): \(payload.message)")
        }
    }
}

/// Process-wide entry point for the Go core. Constructed lazily on
/// first access and never re-created; the Go core itself uses a
/// `sync.Once` guard, so calling `bootstrap()` more than once is
/// cheap but unnecessary.
final class CoreBridge {
    static let shared = CoreBridge()

    private static let log = Logger(
        subsystem: "dev.debruyn.ofem.fileprovider",
        category: "core-bridge"
    )

    /// App Group identifier shared by host app, extension and daemon.
    /// Mirrored in the entitlements files and `Info.plist`.
    static let appGroupIdentifier = "group.dev.debruyn.ofem"

    /// Serial queue for lightweight synchronous bridge calls (listAccounts,
    /// enumerate, item). These are expected to return quickly and must not
    /// be stalled by an in-progress multi-GB download.
    private let queue = DispatchQueue(
        label: "dev.debruyn.ofem.fileprovider.core-bridge",
        qos: .userInitiated
    )

    /// Separate concurrent queue for fetchContents. Downloads can be
    /// long-running; running them on a dedicated queue prevents a slow
    /// download from blocking the serial `queue` and stalling enumerate
    /// calls while the download is in progress.
    private let fetchQueue = DispatchQueue(
        label: "dev.debruyn.ofem.fileprovider.core-bridge.fetch",
        qos: .userInitiated,
        attributes: .concurrent
    )

    /// Guards `didBootstrap`. Cheap because contention is rare —
    /// only the very first call into the bridge actually mutates it.
    private let bootstrapLock = NSLock()
    private var didBootstrap = false

    /// JSON decoder reused across calls. The decoder is stateless once
    /// configured, so a single instance is safe to share.
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        return d
    }()

    private init() {}

    // MARK: - Lifecycle

    /// Idempotently initialise the Go core. Returns silently if the
    /// core has already been bootstrapped in this process. On first
    /// invocation, resolves the App Group container path and hands it
    /// to `ofem_core_init`, which the Go side uses to anchor its
    /// SQLite cache, config TOML, and log file.
    @discardableResult
    func bootstrap() -> Bool {
        bootstrapLock.lock()
        defer { bootstrapLock.unlock() }
        if didBootstrap {
            return true
        }
        guard let containerPath = Self.resolveGroupContainerPath() else {
            CoreBridge.log.error(
                "Failed to resolve App Group container for \(Self.appGroupIdentifier, privacy: .public)"
            )
            return false
        }
        // cgo-exported signatures use `char*` (non-const); Swift's
        // withCString hands us `UnsafePointer<CChar>`. Cast at the call
        // site — the Go side never mutates the buffer.
        let rc = containerPath.withCString { cPath -> Int32 in
            ofem_core_init(UnsafeMutablePointer(mutating: cPath))
        }
        if rc != 0 {
            CoreBridge.log.error(
                "ofem_core_init returned non-zero status \(rc, privacy: .public) for path \(containerPath, privacy: .public)"
            )
            return false
        }
        CoreBridge.log.info(
            "Go core initialised against \(containerPath, privacy: .public)"
        )
        didBootstrap = true
        return true
    }

    /// Resolves the on-disk path of the shared App Group container.
    /// macOS creates the directory on demand the first time a
    /// process in the group asks for it. Falls back to `nil` when
    /// the sandbox refuses (entitlement misconfiguration); callers
    /// log and skip the cgo call in that case so we don't crash.
    static func resolveGroupContainerPath() -> String? {
        guard let url = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier
        ) else {
            return nil
        }
        return url.path
    }

    // MARK: - High-level wrappers

    /// Returns the list of accounts the Go core currently knows about.
    /// The Go core reads this from the shared `config.toml`; we make
    /// no assumption about ordering.
    func listAccounts() throws -> [Account] {
        try ensureBootstrapped()
        let raw = try queue.sync { () throws -> Data in
            guard let cString = ofem_core_list_accounts() else {
                throw BridgeError.nullPointer("ofem_core_list_accounts returned NULL")
            }
            defer { ofem_core_string_free(cString) }
            return Data(String(cString: cString).utf8)
        }
        let envelope: AccountsEnvelope = try decode(raw)
        if let payload = envelope.error {
            throw BridgeError(payload: payload)
        }
        return envelope.accounts ?? []
    }

    /// Enumerate children of the given identifier inside the named
    /// account. Returns the decoded items or throws a typed error.
    func enumerate(alias: String, identifier: String) throws -> [BridgeItem] {
        try ensureBootstrapped()
        let raw = try queue.sync { () throws -> Data in
            guard let cString = alias.withCString({ cAlias in
                identifier.withCString { cIdent in
                    ofem_core_enumerate(
                        UnsafeMutablePointer(mutating: cAlias),
                        UnsafeMutablePointer(mutating: cIdent)
                    )
                }
            }) else {
                throw BridgeError.nullPointer("ofem_core_enumerate returned NULL")
            }
            defer { ofem_core_string_free(cString) }
            return Data(String(cString: cString).utf8)
        }
        let envelope: ItemsEnvelope = try decode(raw)
        if let payload = envelope.error {
            throw BridgeError(payload: payload)
        }
        return envelope.items ?? []
    }

    /// Fetch a single item's metadata.
    func item(alias: String, identifier: String) throws -> BridgeItem {
        try ensureBootstrapped()
        let raw = try queue.sync { () throws -> Data in
            guard let cString = alias.withCString({ cAlias in
                identifier.withCString { cIdent in
                    ofem_core_item(
                        UnsafeMutablePointer(mutating: cAlias),
                        UnsafeMutablePointer(mutating: cIdent)
                    )
                }
            }) else {
                throw BridgeError.nullPointer("ofem_core_item returned NULL")
            }
            defer { ofem_core_string_free(cString) }
            return Data(String(cString: cString).utf8)
        }
        let envelope: ItemEnvelope = try decode(raw)
        if let payload = envelope.error {
            throw BridgeError(payload: payload)
        }
        guard let item = envelope.item else {
            throw BridgeError.decoding("item envelope missing both 'item' and 'error'")
        }
        return item
    }

    /// Download the contents of `identifier` to the destination URL
    /// macOS handed us. Returns the updated `BridgeItem` so the caller
    /// can hand a fresh `NSFileProviderItem` back to the framework.
    ///
    /// Uses a detached `Task` to keep the cgo call off the main actor;
    /// the Go core blocks until the download is complete, which can
    /// be long for big files.
    func fetchContents(alias: String, identifier: String, dest: URL) async throws -> BridgeItem {
        try ensureBootstrapped()
        return try await withCheckedThrowingContinuation { continuation in
            fetchQueue.async {
                let result: Result<BridgeItem, Error> = Result {
                    let path = dest.path
                    guard let cString = alias.withCString({ cAlias in
                        identifier.withCString { cIdent in
                            path.withCString { cDest in
                                ofem_core_fetch_contents(
                                    UnsafeMutablePointer(mutating: cAlias),
                                    UnsafeMutablePointer(mutating: cIdent),
                                    UnsafeMutablePointer(mutating: cDest)
                                )
                            }
                        }
                    }) else {
                        throw BridgeError.nullPointer("ofem_core_fetch_contents returned NULL")
                    }
                    defer { ofem_core_string_free(cString) }
                    let data = Data(String(cString: cString).utf8)
                    let envelope: ItemEnvelope = try self.decode(data)
                    if let payload = envelope.error {
                        throw BridgeError(payload: payload)
                    }
                    guard let item = envelope.item else {
                        throw BridgeError.decoding(
                            "fetch_contents envelope missing both 'item' and 'error'"
                        )
                    }
                    return item
                }
                continuation.resume(with: result)
            }
        }
    }

    // MARK: - Write operations

    /// Upload a new file or create a directory inside a Fabric item.
    ///
    /// - Parameters:
    ///   - alias: Account alias the domain was registered under.
    ///   - parentIdentifier: Bridge identifier of the parent container,
    ///     e.g. `"<wsId>/<itemId>"` or `"<wsId>/<itemId>/<parentPath>"`.
    ///   - filename: Leaf name of the new item.
    ///   - isDir: `true` to create a directory; `false` to upload a file.
    ///   - srcPath: Absolute path of the local source file. Ignored when
    ///     `isDir` is `true`; pass `nil` or empty for directories.
    /// - Returns: The bridge representation of the newly created item.
    func createItem(
        alias: String,
        parentIdentifier: String,
        filename: String,
        isDir: Bool,
        srcPath: String?
    ) throws -> BridgeItem {
        try ensureBootstrapped()
        let src = srcPath ?? ""
        let isDirFlag = isDir ? Int32(1) : Int32(0)
        let raw = try queue.sync { () throws -> Data in
            guard let cString = alias.withCString({ cAlias in
                parentIdentifier.withCString { cParent in
                    filename.withCString { cName in
                        src.withCString { cSrc in
                            ofem_core_create_item(
                                UnsafeMutablePointer(mutating: cAlias),
                                UnsafeMutablePointer(mutating: cParent),
                                UnsafeMutablePointer(mutating: cName),
                                isDirFlag,
                                UnsafeMutablePointer(mutating: cSrc)
                            )
                        }
                    }
                }
            }) else {
                throw BridgeError.nullPointer("ofem_core_create_item returned NULL")
            }
            defer { ofem_core_string_free(cString) }
            return Data(String(cString: cString).utf8)
        }
        let envelope: ItemEnvelope = try decode(raw)
        if let payload = envelope.error {
            throw BridgeError(payload: payload)
        }
        guard let item = envelope.item else {
            throw BridgeError.decoding("create_item envelope missing both 'item' and 'error'")
        }
        return item
    }

    /// Replace the content of an existing file.
    ///
    /// - Parameters:
    ///   - alias: Account alias.
    ///   - identifier: Bridge identifier of the file, e.g. `"<wsId>/<itemId>/<path>"`.
    ///   - srcPath: Absolute path of the local file with new content.
    /// - Returns: The updated bridge representation of the item.
    func modifyItem(
        alias: String,
        identifier: String,
        srcPath: String
    ) throws -> BridgeItem {
        try ensureBootstrapped()
        let raw = try queue.sync { () throws -> Data in
            guard let cString = alias.withCString({ cAlias in
                identifier.withCString { cIdent in
                    srcPath.withCString { cSrc in
                        ofem_core_modify_item(
                            UnsafeMutablePointer(mutating: cAlias),
                            UnsafeMutablePointer(mutating: cIdent),
                            UnsafeMutablePointer(mutating: cSrc)
                        )
                    }
                }
            }) else {
                throw BridgeError.nullPointer("ofem_core_modify_item returned NULL")
            }
            defer { ofem_core_string_free(cString) }
            return Data(String(cString: cString).utf8)
        }
        let envelope: ItemEnvelope = try decode(raw)
        if let payload = envelope.error {
            throw BridgeError(payload: payload)
        }
        guard let item = envelope.item else {
            throw BridgeError.decoding("modify_item envelope missing both 'item' and 'error'")
        }
        return item
    }

    /// Delete a file or directory from OneLake.
    ///
    /// - Parameters:
    ///   - alias: Account alias.
    ///   - identifier: Bridge identifier of the item to delete.
    func deleteItem(alias: String, identifier: String) throws {
        try ensureBootstrapped()
        let raw = try queue.sync { () throws -> Data in
            guard let cString = alias.withCString({ cAlias in
                identifier.withCString { cIdent in
                    ofem_core_delete_item(
                        UnsafeMutablePointer(mutating: cAlias),
                        UnsafeMutablePointer(mutating: cIdent)
                    )
                }
            }) else {
                throw BridgeError.nullPointer("ofem_core_delete_item returned NULL")
            }
            defer { ofem_core_string_free(cString) }
            return Data(String(cString: cString).utf8)
        }
        // The success envelope is "{}"; check whether there's an error key.
        struct DeleteEnvelope: Decodable {
            let error: BridgeErrorPayload?
        }
        let envelope: DeleteEnvelope = try decode(raw)
        if let payload = envelope.error {
            throw BridgeError(payload: payload)
        }
    }

    // MARK: - Internals

    private func ensureBootstrapped() throws {
        if !bootstrap() {
            throw BridgeError.notBootstrapped
        }
    }

    /// Decode the JSON payload returned by the Go core. We do not log
    /// the raw payload — it may contain workspace / file names — but
    /// we do log the decoder's debug description so we have a fighting
    /// chance of diagnosing a schema drift in the field.
    private func decode<T: Decodable>(_ data: Data) throws -> T {
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            CoreBridge.log.error(
                "Failed to decode core payload as \(String(describing: T.self), privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            throw BridgeError.decoding(error.localizedDescription)
        }
    }
}
