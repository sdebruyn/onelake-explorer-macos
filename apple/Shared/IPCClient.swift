// IPCClient.swift
// General async JSON-RPC 2.0 client for the ofem daemon's Unix-domain
// socket, shared by the host app and the File Provider Extension.
//
// The daemon frames each message as a 4-byte big-endian uint32 length
// followed by the JSON bytes. The socket lives at:
//
//   ~/Library/Group Containers/group.dev.debruyn.ofem/ofem.sock
//
// Transport: plain POSIX socket (see IPCTransport.swift). The previous
// implementation used NWConnection (Network.framework) and bled state-
// machine + continuation bugs into every caller; replacing it with a
// straight `socket()` + blocking `read`/`write` on a background queue
// eliminated that whole class of problems.
//
// Connection model: stateless, one connection per call. A File Provider
// Extension and the host app issue calls from many threads; a fresh
// connection per call sidesteps shared-connection lifecycle bugs. A
// Unix-domain connect is microseconds relative to the OneLake I/O the
// daemon then performs, so this is the right trade for correctness.
//
// Persistent model: `pollChanges` uses a long-lived connection managed
// by the caller (ChangeWatcher), because it is a one-producer / one-
// consumer polling loop.

import Foundation
import os
import os.log

/// App Group identifier shared by host app, extension, and daemon.
let ofemAppGroupIdentifier = "group.dev.debruyn.ofem"

/// Errors raised by the transport itself (as opposed to a domain error,
/// which the daemon returns inside the JSON-RPC result envelope).
enum IPCError: Error {
    /// The daemon socket could not be reached (daemon not running, or the
    /// App Group container could not be resolved).
    case unreachable(String)
    case frameTooLarge(Int)
    case protocolError(String)
    /// A JSON-RPC protocol-level error object (bad params, unknown method).
    case rpc(code: Int, message: String)
}

// MARK: - Payload shapes for sync.pollChanges

/// One change event returned by the daemon's sync.pollChanges method.
struct PollChangeEvent: Decodable {
    let domain: String
    let containerId: String
    let occurredAt: Date
}

private struct PollChangesResponse: Decodable {
    let events: [PollChangeEvent]
    let anchor: Date
    let fullResync: Bool
}

private struct PollRPCResponse: Decodable {
    let result: PollChangesResponse?
    let error: PollRPCError?

    enum CodingKeys: String, CodingKey { case result, error }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        result = try? c.decode(PollChangesResponse.self, forKey: .result)
        error = try? c.decode(PollRPCError.self, forKey: .error)
    }
}

private struct PollRPCError: Decodable, Error {
    let code: Int
    let message: String
}

// MARK: - Persistent connection handle

/// Opaque handle around a long-lived `IPCSocket` used by callers that
/// keep a connection open across many round-trips (the change-feed
/// poll loop). The class is final and the only thing callers can do
/// with it is hand it back to `IPCClient.pollChanges` or
/// `IPCClient.closePersistentConnection`.
final class IPCPersistentConnection {
    let socket: IPCSocket
    init(socket: IPCSocket) {
        self.socket = socket
    }
}

// MARK: - IPCClient

/// Stateless JSON-RPC client over the daemon's Unix socket.
final class IPCClient {
    private static let log = Logger(subsystem: "dev.debruyn.ofem.ipc", category: "client")

    /// Upper bound on a single sync.pollChanges round-trip. The daemon
    /// answers from its in-memory changefeed so real latency is sub-ms;
    /// this is purely a liveness guard so a daemon that dies mid-frame
    /// cannot freeze the poll loop.
    private static let pollTimeout: TimeInterval = 10
    /// Bounds the one-shot `call` path (connect + write + read) so a
    /// connection that hangs cannot freeze the menu's status fetch
    /// forever. Surfaces as a thrown timeout the model can log and
    /// retry on next refresh.
    private static let callTimeout: TimeInterval = 5

    private let socketPath: String

    private let pollDecoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
    private let pollEncoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    init(socketPath: String) {
        self.socketPath = socketPath
    }

    /// Resolves the default socket path inside the App Group container,
    /// where the daemon places ofem.sock. Returns nil when the sandbox
    /// refuses to resolve the container (entitlement misconfiguration).
    static func defaultSocketPath() -> String? {
        guard let url = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: ofemAppGroupIdentifier
        ) else {
            return nil
        }
        return url.appendingPathComponent("ofem.sock").path
    }

    // MARK: - One-shot RPC call

    /// Sends a JSON-RPC request for `method` with `params` and returns the
    /// raw bytes of the response's `result` value. Throws [IPCError] on a
    /// transport failure or a JSON-RPC error object.
    func call(method: String, params: [String: Any]) async throws -> Data {
        let requestID = UUID().uuidString
        let request: [String: Any] = [
            "jsonrpc": "2.0",
            "method": method,
            "params": params,
            "id": requestID,
        ]
        let requestData = try JSONSerialization.data(withJSONObject: request)
        let path = socketPath
        let timeout = Self.callTimeout

        // Hand the socket reference to the cancellation handler via a
        // box so onCancel can close whatever socket the worker has so
        // far attached.
        let box = SocketBox()
        let responseData: Data
        do {
            responseData = try await ipcRunBlocking(onCancel: { box.closeAndRelease() }) {
                let sock = try Self.connectMappingErrors(path: path, timeout: timeout)
                box.attach(sock)
                defer { box.closeAndRelease() }
                do {
                    try sock.writeFrame(requestData)
                    return try sock.readFrame()
                } catch let e as IPCSocket.SocketError {
                    throw Self.mapSocketError(e)
                }
            }
        } catch is CancellationError {
            throw IPCError.protocolError("IPC call cancelled")
        }

        guard let obj = try JSONSerialization.jsonObject(with: responseData) as? [String: Any] else {
            throw IPCError.protocolError("response is not a JSON object")
        }
        if let errObj = obj["error"] as? [String: Any] {
            let code = (errObj["code"] as? Int) ?? -1
            let message = (errObj["message"] as? String) ?? "unknown error"
            throw IPCError.rpc(code: code, message: message)
        }
        let result = obj["result"] ?? [String: Any]()
        return try JSONSerialization.data(withJSONObject: result)
    }

    // MARK: - Persistent-connection poll call

    /// Open (or reopen) a persistent connection to the daemon socket for
    /// use by the poll loop. Caller owns it and must eventually call
    /// `closePersistentConnection`. The pollTimeout is applied as the
    /// socket-level SO_RCVTIMEO/SO_SNDTIMEO so a dead daemon surfaces as
    /// a read error within bounded time.
    func openPersistentConnection() async throws -> IPCPersistentConnection {
        let path = socketPath
        let timeout = Self.pollTimeout
        let sock = try await ipcRunBlocking {
            try Self.connectMappingErrors(path: path, timeout: timeout)
        }
        return IPCPersistentConnection(socket: sock)
    }

    /// Cancel a persistent connection opened by `openPersistentConnection`.
    func closePersistentConnection(_ conn: IPCPersistentConnection) {
        conn.socket.shutdownAndClose()
    }

    /// Poll the daemon for changes since `anchor` using a persistent
    /// connection. SO_RCVTIMEO on the socket bounds the read; if the
    /// daemon dies mid-frame the next read fails with EAGAIN and the
    /// caller surfaces a protocolError.
    func pollChanges(
        conn: IPCPersistentConnection,
        since anchor: Date?
    ) async throws -> (
        events: [(domainId: String, containerId: String)],
        anchor: Date,
        fullResync: Bool
    ) {
        struct PollParams: Encodable {
            let anchor: Date?
        }
        let paramsData = try pollEncoder.encode(PollParams(anchor: anchor))
        guard let paramsJSON = try JSONSerialization.jsonObject(with: paramsData) as? [String: Any] else {
            throw IPCError.protocolError("failed to build pollChanges params")
        }
        let requestDict: [String: Any] = [
            "jsonrpc": "2.0",
            "method": "sync.pollChanges",
            "params": paramsJSON,
            "id": UUID().uuidString,
        ]
        let requestData = try JSONSerialization.data(withJSONObject: requestDict)
        let socket = conn.socket

        let responseData: Data = try await ipcRunBlocking(onCancel: { socket.shutdownAndClose() }) {
            do {
                try socket.writeFrame(requestData)
                return try socket.readFrame()
            } catch let e as IPCSocket.SocketError {
                throw Self.mapSocketError(e)
            }
        }

        let response = try pollDecoder.decode(PollRPCResponse.self, from: responseData)
        if let err = response.error {
            throw IPCError.rpc(code: err.code, message: err.message)
        }
        guard let result = response.result else {
            throw IPCError.protocolError("missing result in sync.pollChanges response")
        }
        let pairs = result.events.map { (domainId: $0.domain, containerId: $0.containerId) }
        return (events: pairs, anchor: result.anchor, fullResync: result.fullResync)
    }

    // MARK: - Helpers

    /// Mutable, sendable holder for the socket that a blocking worker
    /// might be using. Used to bridge a cancellation that fires on
    /// another queue into a socket-close on the worker's queue.
    private final class SocketBox: @unchecked Sendable {
        private let lock = OSAllocatedUnfairLock<IPCSocket?>(initialState: nil)
        func attach(_ s: IPCSocket) {
            lock.withLock { $0 = s }
        }
        func closeAndRelease() {
            let s = lock.withLock { (slot: inout IPCSocket?) -> IPCSocket? in
                let v = slot
                slot = nil
                return v
            }
            s?.shutdownAndClose()
        }
    }

    private static func connectMappingErrors(path: String, timeout: TimeInterval) throws -> IPCSocket {
        do {
            return try IPCSocket.connect(path: path, timeout: timeout)
        } catch let e as IPCSocket.SocketError {
            throw mapSocketError(e)
        }
    }

    private static func mapSocketError(_ e: IPCSocket.SocketError) -> IPCError {
        switch e {
        case .socketCreate(let code):
            return .unreachable("socket() failed: errno \(code)")
        case .connect(let code):
            return .unreachable("connect() failed: errno \(code)")
        case .pathTooLong(let n):
            return .protocolError("socket path too long (\(n) bytes)")
        case .write(let code):
            return .protocolError("write failed: errno \(code)")
        case .read(let code):
            return .protocolError("read failed: errno \(code)")
        case .eof(let n):
            return .protocolError("connection closed after \(n) bytes")
        case .timeout:
            // Mirrors the prior NWConnection withTimeout message so existing
            // logs and error matchers continue to work.
            return .protocolError("IPC timed out after \(Self.callTimeout)s")
        case .frameTooLarge(let n):
            return .frameTooLarge(n)
        case .closed:
            return .protocolError("connection closed")
        }
    }
}
