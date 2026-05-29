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
//
// Persistent model: `pollChanges` uses a long-lived NWConnection
// managed by the caller (ChangeWatcher), because it is a one-producer
// / one-consumer polling loop; each call() is still one connection per
// call.

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

// MARK: - IPCClient

/// Stateless JSON-RPC client over the daemon's Unix socket.
final class IPCClient {
    private static let log = Logger(subsystem: "dev.debruyn.ofem.ipc", category: "client")
    private static let maxFrameSize = 1 << 20 // 1 MiB, matching ipc.MaxFrameSize

    /// Upper bound on a single sync.pollChanges round-trip. The daemon
    /// answers from its in-memory changefeed so real latency is sub-ms;
    /// this is purely a liveness guard so a daemon that dies mid-frame
    /// cannot freeze the poll loop.
    private static let pollTimeout: TimeInterval = 10

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

    // MARK: - Persistent-connection poll call

    /// Open (or reopen) a persistent connection to the daemon socket for use
    /// by the poll loop. Returns a ready NWConnection; caller owns it and must
    /// eventually call `conn.cancel()`.
    func openPersistentConnection() async throws -> NWConnection {
        try await openConnection()
    }

    /// Cancel a persistent connection opened by `openPersistentConnection()`.
    func closePersistentConnection(_ conn: NWConnection) {
        conn.cancel()
    }

    /// Poll the daemon for changes since `anchor` using a persistent
    /// `NWConnection`. The call is bounded by `pollTimeout` seconds so a
    /// daemon that dies mid-frame cannot freeze the caller forever.
    ///
    /// Returns a tuple of events, the new anchor, and a fullResync flag.
    func pollChanges(
        conn: NWConnection,
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
        // Safe: we just encoded a strongly-typed value.
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

        // Bound the write+read so a hung connection cannot freeze the loop.
        let responseData = try await Self.withTimeout(seconds: Self.pollTimeout) { [self] in
            try await self.writeFrameOnConn(conn, requestData)
            return try await self.readFrame(conn)
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
        try await writeFrameOnConn(conn, data)
    }

    /// Write a length-prefixed frame on `conn`. Separated so both the
    /// one-shot `call` and the persistent-conn `pollChanges` path share it.
    private func writeFrameOnConn(_ conn: NWConnection, _ data: Data) async throws {
        var header = Data(count: 4)
        let length = UInt32(data.count)
        header[0] = UInt8((length >> 24) & 0xFF)
        header[1] = UInt8((length >> 16) & 0xFF)
        header[2] = UInt8((length >> 8) & 0xFF)
        header[3] = UInt8(length & 0xFF)
        let frame = header + data
        try await withConnectionCancellation(conn) { (cont: CheckedContinuation<Void, Error>) in
            conn.send(content: frame, completion: .contentProcessed { err in
                if let err = err {
                    cont.resume(throwing: err)
                } else {
                    cont.resume()
                }
            })
        }
    }

    /// Read one length-prefixed frame from `conn`.
    ///
    /// NWConnection's receive may deliver fewer bytes than requested at
    /// EOF/close, so the payload read loops until all `length` bytes are
    /// accumulated or a real error/EOF occurs — treating a short delivery
    /// as a hard error would be fragile near the frame cap.
    private func readFrame(_ conn: NWConnection) async throws -> Data {
        // Read 4-byte header.
        let header = try await receiveExact(conn, count: 4)
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
        return try await receiveExact(conn, count: length)
    }

    /// Accumulate exactly `count` bytes from `conn`, looping over partial
    /// deliveries. NWConnection may satisfy a receive with fewer bytes than
    /// requested when the peer sends the data in multiple TCP segments or
    /// closes the connection mid-frame; looping is the correct fix.
    private func receiveExact(_ conn: NWConnection, count: Int) async throws -> Data {
        var accumulated = Data()
        while accumulated.count < count {
            let want = count - accumulated.count
            let chunk: Data = try await withConnectionCancellation(conn) { cont in
                conn.receive(
                    minimumIncompleteLength: 1,
                    maximumLength: want
                ) { data, _, isComplete, err in
                    if let err = err {
                        cont.resume(throwing: err)
                        return
                    }
                    let bytes = data ?? Data()
                    if bytes.isEmpty && isComplete {
                        // Peer closed the connection before we got all bytes.
                        cont.resume(throwing: IPCError.protocolError(
                            "connection closed after \(accumulated.count) of \(count) bytes"
                        ))
                        return
                    }
                    cont.resume(returning: bytes)
                }
            }
            accumulated.append(chunk)
        }
        return accumulated
    }

    // MARK: - Cancellation bridge

    /// Bridge a continuation-style NWConnection send/receive into async
    /// such that task cancellation actually unblocks it. NWConnection's
    /// completion handlers are NOT cancellation-aware: a stalled peer never
    /// fires them, so a bare `withCheckedThrowingContinuation` would suspend
    /// forever. Cancelling the connection forces the pending callback to fire
    /// with an error, which resumes the continuation.
    private func withConnectionCancellation<T>(
        _ conn: NWConnection,
        _ body: @escaping (CheckedContinuation<T, Error>) -> Void
    ) async throws -> T {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation(body)
        } onCancel: {
            conn.cancel()
        }
    }

    // MARK: - Timeout helper

    /// Run `op` with a wall-clock ceiling. Two children race: `op` and a
    /// sleeper that throws on expiry. `group.next()` rethrows whichever
    /// finishes first and cancels the loser.
    ///
    /// This fires reliably because the frame I/O inside `op` is wrapped in
    /// `withConnectionCancellation`: cancelling the task cancels the
    /// connection, which forces the pending NWConnection receive to complete
    /// with an error so the task unwinds promptly.
    static func withTimeout<T: Sendable>(
        seconds: TimeInterval,
        _ op: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await op() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw IPCError.protocolError("IPC timed out after \(seconds)s")
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else {
                throw IPCError.protocolError("IPC task group produced no result")
            }
            return first
        }
    }
}
