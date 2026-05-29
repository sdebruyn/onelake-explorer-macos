// CoreBridge.swift
// The host app's and File Provider Extension's gateway to the Go core.
//
// The Go engine and cache are owned by the long-running daemon; this type
// is a thin async client that talks to it over the unix-socket IPC (see
// IPCClient). It replaces the old cgo bridge that compiled a second engine
// into each Swift target — see SIMPLIFICATION.md.
//
// Files cross the process boundary through the shared App Group container:
// a fetch asks the daemon to write into the container and then moves the
// bytes to the URL macOS handed us; a create/modify copies the staged
// source into the container so the daemon can read it. Both sides have the
// App Group entitlement, so these reads/writes are permitted; the engine
// stays the daemon's alone.

import Foundation
import os.log

/// JSON shape returned by the "account.list" IPC method (extra keys such
/// as addedAt / defaultAccount are ignored). Every field except `alias`
/// decodes defensively to "" when absent, because the daemon's
/// AccountSummary marks them `omitempty` — an account with no tenant name
/// drops the key entirely, which a non-optional `String` would reject.
struct Account: Decodable, Equatable {
    let alias: String
    let username: String
    let tenantId: String
    let tenantName: String

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        alias = try c.decode(String.self, forKey: .alias)
        username = (try c.decodeIfPresent(String.self, forKey: .username)) ?? ""
        tenantId = (try c.decodeIfPresent(String.self, forKey: .tenantId)) ?? ""
        tenantName = (try c.decodeIfPresent(String.self, forKey: .tenantName)) ?? ""
    }

    private enum CodingKeys: String, CodingKey {
        case alias, username, tenantId, tenantName
    }
}

/// Decoded representation of a single item entry. Mapped onto OneLakeItem
/// for the File Provider framework.
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
        rfc3339WithFractional.date(from: raw) ?? rfc3339Plain.date(from: raw)
    }

    private enum CodingKeys: String, CodingKey {
        case identifier, parentIdentifier, filename, isDir, size
        case contentType, modificationDate, contentVersion, metadataVersion, capabilities
    }
}

private struct AccountsEnvelope: Decodable {
    let accounts: [Account]?
    let error: BridgeErrorPayload?
}

private struct ItemsEnvelope: Decodable {
    let items: [BridgeItem]?
    let nextCursor: String?
    let error: BridgeErrorPayload?
}

private struct ItemEnvelope: Decodable {
    let item: BridgeItem?
    let error: BridgeErrorPayload?
}

private struct ErrorOnlyEnvelope: Decodable {
    let error: BridgeErrorPayload?
}

private struct BridgeErrorPayload: Decodable {
    let code: String
    let message: String
}

/// Typed errors the bridge can surface. Mapped to NSFileProviderError at
/// the boundary by ErrorMapping.swift.
enum BridgeError: Error, Equatable {
    case noSuchItem(String)
    case notAuthenticated(String)
    case serverUnreachable(String)
    case serverBusy(String)
    case insufficientQuota(String)
    case cannotSynchronize(String)
    case decoding(String)
    case nullPointer(String)
    case notBootstrapped

    fileprivate init(payload: BridgeErrorPayload) {
        switch payload.code {
        case "noSuchItem": self = .noSuchItem(payload.message)
        case "notAuthenticated": self = .notAuthenticated(payload.message)
        case "serverUnreachable": self = .serverUnreachable(payload.message)
        case "serverBusy": self = .serverBusy(payload.message)
        case "insufficientQuota": self = .insufficientQuota(payload.message)
        case "cannotSynchronize": self = .cannotSynchronize(payload.message)
        default: self = .cannotSynchronize("\(payload.code): \(payload.message)")
        }
    }

    /// Maps a transport-level IPC failure to a bridge error. A daemon we
    /// cannot reach is the read-only browser's serverUnreachable; anything
    /// else (protocol / rpc) is a non-specific cannotSynchronize.
    fileprivate init(ipc: IPCError) {
        switch ipc {
        case .unreachable(let m): self = .serverUnreachable("daemon unreachable: \(m)")
        case .frameTooLarge(let n): self = .cannotSynchronize("ipc frame too large: \(n)")
        case .protocolError(let m): self = .cannotSynchronize("ipc protocol error: \(m)")
        case .rpc(_, let m): self = .cannotSynchronize("ipc error: \(m)")
        }
    }
}

/// Process-wide gateway to the daemon. Constructed lazily; holds no engine
/// state of its own.
final class CoreBridge {
    static let shared = CoreBridge()

    private static let log = Logger(subsystem: "dev.debruyn.ofem.ipc", category: "core-bridge")

    /// App Group identifier shared by host app, extension, and daemon.
    static let appGroupIdentifier = ofemAppGroupIdentifier

    private let client: IPCClient?
    private let decoder = JSONDecoder()

    private init() {
        if let path = IPCClient.defaultSocketPath() {
            client = IPCClient(socketPath: path)
        } else {
            client = nil
        }
    }

    // MARK: - Lifecycle

    /// Confirms we can locate the daemon socket. There is no Go core to
    /// initialise in-process any more; the daemon owns it. Returns false
    /// only when the App Group container cannot be resolved (entitlement
    /// misconfiguration), in which case every call would fail anyway.
    @discardableResult
    func bootstrap() -> Bool {
        client != nil
    }

    static func resolveGroupContainerPath() -> String? {
        FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier
        )?.path
    }

    // MARK: - Reads

    func listAccounts() async throws -> [Account] {
        let env: AccountsEnvelope = try await callAsync("account.list", [:])
        if let payload = env.error { throw BridgeError(payload: payload) }
        return env.accounts ?? []
    }

    /// Enumerate the children of `identifier` for `alias`. Returns items and
    /// an optional cursor for the next page (empty string means last page).
    func enumerate(alias: String, identifier: String, cursor: String = "") async throws -> (items: [BridgeItem], nextCursor: String) {
        var params: [String: Any] = ["alias": alias, "identifier": identifier]
        if !cursor.isEmpty {
            params["cursor"] = cursor
        }
        let env: ItemsEnvelope = try await callAsync("fp.enumerate", params)
        if let payload = env.error { throw BridgeError(payload: payload) }
        return (items: env.items ?? [], nextCursor: env.nextCursor ?? "")
    }

    func item(alias: String, identifier: String) async throws -> BridgeItem {
        let env: ItemEnvelope = try await callAsync("fp.item", ["alias": alias, "identifier": identifier])
        if let payload = env.error { throw BridgeError(payload: payload) }
        guard let item = env.item else {
            throw BridgeError.decoding("fp.item envelope missing both 'item' and 'error'")
        }
        return item
    }

    /// Download `identifier` and move the bytes to `dest`. The daemon
    /// (which owns the engine and blob store) writes into the App Group
    /// container; we move from there to the macOS-supplied `dest` and hand
    /// the container temp back to be cleaned up.
    func fetchContents(alias: String, identifier: String, dest: URL) async throws -> BridgeItem {
        guard let client = client else { throw BridgeError.notBootstrapped }
        let staged = try Self.appGroupTempURL()
        defer { try? FileManager.default.removeItem(at: staged) }

        let resultData: Data
        do {
            resultData = try await client.call(method: "fp.fetchContents", params: [
                "alias": alias, "identifier": identifier, "destPath": staged.path,
            ])
        } catch let e as IPCError {
            throw BridgeError(ipc: e)
        }
        let env: ItemEnvelope = try decode(resultData)
        if let payload = env.error { throw BridgeError(payload: payload) }
        guard let item = env.item else {
            throw BridgeError.decoding("fp.fetchContents envelope missing both 'item' and 'error'")
        }
        // Move (not copy) the daemon-written bytes to the URL macOS gave
        // us, so a large download is not written to disk twice.
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: staged, to: dest)
        return item
    }

    // MARK: - Writes

    func createItem(alias: String, parentIdentifier: String, filename: String, isDir: Bool, srcPath: String?) async throws -> BridgeItem {
        var daemonSrc = ""
        var stagedCopy: URL?
        defer { if let s = stagedCopy { try? FileManager.default.removeItem(at: s) } }
        if !isDir, let srcPath = srcPath, !srcPath.isEmpty {
            let staged = try Self.appGroupTempURL()
            try FileManager.default.copyItem(at: URL(fileURLWithPath: srcPath), to: staged)
            stagedCopy = staged
            daemonSrc = staged.path
        }
        let env: ItemEnvelope = try await callAsync("fp.createItem", [
            "alias": alias, "parentIdentifier": parentIdentifier,
            "filename": filename, "isDir": isDir, "srcPath": daemonSrc,
        ])
        if let payload = env.error { throw BridgeError(payload: payload) }
        guard let item = env.item else {
            throw BridgeError.decoding("fp.createItem envelope missing both 'item' and 'error'")
        }
        return item
    }

    func modifyItem(alias: String, identifier: String, srcPath: String) async throws -> BridgeItem {
        let staged = try Self.appGroupTempURL()
        defer { try? FileManager.default.removeItem(at: staged) }
        try FileManager.default.copyItem(at: URL(fileURLWithPath: srcPath), to: staged)
        let env: ItemEnvelope = try await callAsync("fp.modifyItem", [
            "alias": alias, "identifier": identifier, "srcPath": staged.path,
        ])
        if let payload = env.error { throw BridgeError(payload: payload) }
        guard let item = env.item else {
            throw BridgeError.decoding("fp.modifyItem envelope missing both 'item' and 'error'")
        }
        return item
    }

    func deleteItem(alias: String, identifier: String) async throws {
        let env: ErrorOnlyEnvelope = try await callAsync("fp.deleteItem", ["alias": alias, "identifier": identifier])
        if let payload = env.error { throw BridgeError(payload: payload) }
    }

    // MARK: - Internals

    private func callAsync<T: Decodable>(_ method: String, _ params: [String: Any]) async throws -> T {
        guard let client = client else { throw BridgeError.notBootstrapped }
        let data: Data
        do {
            data = try await client.call(method: method, params: params)
        } catch let e as IPCError {
            throw BridgeError(ipc: e)
        }
        return try decode(data)
    }

    private func decode<T: Decodable>(_ data: Data) throws -> T {
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            CoreBridge.log.error(
                "Failed to decode daemon payload as \(String(describing: T.self), privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            throw BridgeError.decoding(error.localizedDescription)
        }
    }

    /// A unique path inside the App Group container for staging file bytes
    /// across the process boundary. The directory is created on demand.
    static func appGroupTempURL() throws -> URL {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier
        ) else {
            throw BridgeError.notBootstrapped
        }
        let dir = container.appendingPathComponent("fp-transfer", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(UUID().uuidString)
    }
}
