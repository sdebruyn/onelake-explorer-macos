// CoreBridge.swift (host app)
// Slim Go-core bridge for the host application target.
//
// The File Provider Extension has its own, richer copy of this file
// under `apple/OneLakeFileProvider/`. The host app only needs to be
// able to:
//
//   * Bootstrap the Go core against the shared App Group container
//     (so the first launch of `OneLake.app` creates the cache /
//     config skeleton on disk before the extension is asked to mount
//     any domain).
//   * Read the account list, to drive `DomainSyncManager.reconcile()`.
//
// Both copies are intentionally namespaced under the same type name
// (`CoreBridge`) and share the same App Group identifier so the two
// targets behave identically when they need to. Keeping the host-app
// copy small avoids dragging extension-only types (BridgeItem,
// EnumScope, ...) into the host app's binary.

import Foundation
import os.log

/// Account record returned by the Go core. Matches the
/// extension-side definition byte-for-byte; we don't share the
/// declaration because the two targets do not share sources.
struct Account: Decodable, Equatable {
    let alias: String
    let username: String
    let tenantId: String
    let tenantName: String
}

/// Subset of `BridgeError` the host app needs. The full vocabulary
/// lives in the File Provider Extension's `CoreBridge.swift`; we
/// re-implement just the cases we actually surface here.
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

    init(payload: BridgeErrorPayload) {
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

struct BridgeErrorPayload: Decodable {
    let code: String
    let message: String
}

private struct AccountsEnvelope: Decodable {
    let accounts: [Account]?
    let error: BridgeErrorPayload?
}

/// Host-app singleton facade over the cgo bridge. Mirrors the
/// shape of the extension-side `CoreBridge` for the calls the host
/// app actually makes.
final class CoreBridge {
    static let shared = CoreBridge()

    private static let log = Logger(
        subsystem: "dev.debruyn.ofem",
        category: "core-bridge"
    )

    static let appGroupIdentifier = "group.dev.debruyn.ofem"

    private let queue = DispatchQueue(
        label: "dev.debruyn.ofem.host.core-bridge",
        qos: .userInitiated
    )

    private let bootstrapLock = NSLock()
    private var didBootstrap = false

    private let decoder = JSONDecoder()

    private init() {}

    /// Idempotently initialise the Go core against the App Group
    /// container path. Returns `true` once the core is ready.
    @discardableResult
    func bootstrap() -> Bool {
        bootstrapLock.lock()
        defer { bootstrapLock.unlock() }
        if didBootstrap {
            return true
        }
        guard let path = Self.resolveGroupContainerPath() else {
            CoreBridge.log.error(
                "Failed to resolve App Group container for \(Self.appGroupIdentifier, privacy: .public)"
            )
            return false
        }
        // cgo-exported signatures use `char*` (non-const); Swift's
        // withCString hands us `UnsafePointer<CChar>`. Cast at the call
        // site — the Go side never mutates the buffer.
        let rc = path.withCString { ofem_core_init(UnsafeMutablePointer(mutating: $0)) }
        if rc != 0 {
            CoreBridge.log.error(
                "ofem_core_init returned \(rc, privacy: .public) for \(path, privacy: .public)"
            )
            return false
        }
        CoreBridge.log.info("Go core initialised against \(path, privacy: .public)")
        didBootstrap = true
        return true
    }

    static func resolveGroupContainerPath() -> String? {
        FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier
        )?.path
    }

    /// Return the accounts the Go core currently knows about.
    func listAccounts() throws -> [Account] {
        guard bootstrap() else {
            throw BridgeError.notBootstrapped
        }
        let data = try queue.sync { () throws -> Data in
            guard let cString = ofem_core_list_accounts() else {
                throw BridgeError.nullPointer("ofem_core_list_accounts returned NULL")
            }
            defer { ofem_core_string_free(cString) }
            return Data(String(cString: cString).utf8)
        }
        do {
            let envelope = try decoder.decode(AccountsEnvelope.self, from: data)
            if let payload = envelope.error {
                throw BridgeError(payload: payload)
            }
            return envelope.accounts ?? []
        } catch let error as BridgeError {
            throw error
        } catch {
            CoreBridge.log.error(
                "Failed to decode accounts payload: \(error.localizedDescription, privacy: .public)"
            )
            throw BridgeError.decoding(error.localizedDescription)
        }
    }
}
