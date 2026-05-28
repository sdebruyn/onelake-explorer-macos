// IPCClient.swift
// General async JSON-RPC 2.0 client for the ofem daemon's Unix-domain
// socket, shared by the host app and the File Provider Extension.
//
// The daemon frames each message as a 4-byte big-endian uint32 length
// followed by the JSON bytes. The socket lives at:
//
//   ~/Library/Group Containers/group.dev.debruyn.ofem/ofem.sock
//
// Connection model: stateless, one connection per call. A File Provider
// Extension and the host app issue calls from many threads; a fresh
// NWConnection per call sidesteps all shared-connection lifecycle bugs.
// A Unix-domain socket connect is cheap (microseconds) relative to the
// network I/O to OneLake the daemon then performs, so this is the right
// trade for correctness. The daemon must be running; when it is not,
// connect fails and the caller surfaces serverUnreachable.

import Foundation
import Network
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

/// Stateless JSON-RPC client over the daemon's Unix socket.
final class IPCClient {
    private static let log = Logger(subsystem: "dev.debruyn.ofem.ipc", category: "client")
    private static let maxFrameSize = 1 << 20 // 1 MiB, matching ipc.MaxFrameSize

    private let socketPath: String

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

        let conn = try await openConnection()
        defer { conn.cancel() }

        try await writeFrame(conn, requestData)
        let responseData = try await readFrame(conn)

        guard let obj = try JSONSerialization.jsonObject(with: responseData) as? [String: Any] else {
            throw IPCError.protocolError("response is not a JSON object")
        }
        if let errObj = obj["error"] as? [String: Any] {
            let code = (errObj["code"] as? Int) ?? -1
            let message = (errObj["message"] as? String) ?? "unknown error"
            throw IPCError.rpc(code: code, message: message)
        }
        // result may be any JSON value; re-serialize it so the caller can
        // decode it with a typed Decodable.
        let result = obj["result"] ?? [String: Any]()
        return try JSONSerialization.data(withJSONObject: result)
    }

    // MARK: - Connection

    private func openConnection() async throws -> NWConnection {
        let ep = NWEndpoint.unix(path: socketPath)
        let conn = NWConnection(to: ep, using: NWParameters(tls: nil))
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            var didResume = false
            conn.stateUpdateHandler = { state in
                guard !didResume else { return }
                switch state {
                case .ready:
                    didResume = true
                    cont.resume()
                case .failed(let err):
                    didResume = true
                    cont.resume(throwing: IPCError.unreachable(err.localizedDescription))
                case .waiting(let err):
                    didResume = true
                    cont.resume(throwing: IPCError.unreachable(err.localizedDescription))
                default:
                    break
                }
            }
            conn.start(queue: .global(qos: .userInitiated))
        }
        return conn
    }

    // MARK: - Frame I/O

    private func writeFrame(_ conn: NWConnection, _ data: Data) async throws {
        var header = Data(count: 4)
        let length = UInt32(data.count)
        header[0] = UInt8((length >> 24) & 0xFF)
        header[1] = UInt8((length >> 16) & 0xFF)
        header[2] = UInt8((length >> 8) & 0xFF)
        header[3] = UInt8(length & 0xFF)
        let frame = header + data
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            conn.send(content: frame, completion: .contentProcessed { err in
                if let err = err {
                    cont.resume(throwing: err)
                } else {
                    cont.resume()
                }
            })
        }
    }

    private func readFrame(_ conn: NWConnection) async throws -> Data {
        let header: Data = try await withCheckedThrowingContinuation { cont in
            conn.receive(minimumIncompleteLength: 4, maximumLength: 4) { data, _, _, err in
                if let err = err { cont.resume(throwing: err); return }
                cont.resume(returning: data ?? Data())
            }
        }
        guard header.count == 4 else {
            throw IPCError.protocolError("short frame header: \(header.count) bytes")
        }
        let length = Int(header[0]) << 24 | Int(header[1]) << 16 | Int(header[2]) << 8 | Int(header[3])
        guard length >= 0, length <= Self.maxFrameSize else {
            throw IPCError.frameTooLarge(length)
        }
        if length == 0 {
            return Data()
        }
        let payload: Data = try await withCheckedThrowingContinuation { cont in
            conn.receive(minimumIncompleteLength: length, maximumLength: length) { data, _, _, err in
                if let err = err { cont.resume(throwing: err); return }
                cont.resume(returning: data ?? Data())
            }
        }
        guard payload.count == length else {
            throw IPCError.protocolError("short frame body: got \(payload.count), want \(length)")
        }
        return payload
    }
}
