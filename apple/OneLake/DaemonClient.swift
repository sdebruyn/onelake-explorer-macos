// DaemonClient.swift
// Async JSON-RPC 2.0 client for the ofem daemon's Unix-domain socket.
//
// The daemon speaks JSON-RPC 2.0 over a length-prefixed frame protocol:
// each frame is a 4-byte big-endian uint32 payload length followed by
// the JSON bytes. The socket lives at:
//
//   ~/Library/Group Containers/group.dev.debruyn.ofem/ofem.sock
//
// Network.framework approach for Unix-domain sockets:
//
//   NWConnection supports Unix-domain sockets via NWEndpoint.unix(path:).
//   The correct NWParameters to pass is NWParameters(tls: nil) — no explicit
//   TCP transport. When the endpoint is a Unix path, Network.framework selects
//   a stream transport over the Unix socket automatically; passing .tcp would
//   attempt a TCP connection to the path string, which fails on a Unix socket.
//
//   The stateUpdateHandler fires on every state transition (preparing →
//   ready, ready → failed, etc.). A CheckedContinuation must be resumed
//   exactly once; all handlers use a one-shot guard to ensure this.
//
// Usage is one-instance-per-app-lifetime: create, call `connect()`, then
// poll via `pollChanges(since:)`. On disconnect the caller should discard
// the instance and create a fresh one.

import Foundation
import Network
import os.log

/// Payload shape for one change event returned by the daemon.
struct DaemonChangeEvent: Decodable {
    let domain: String
    let containerId: String
    let occurredAt: Date
}

/// Response shape for sync.pollChanges.
private struct PollChangesResponse: Decodable {
    let events: [DaemonChangeEvent]
    let anchor: Date
    let fullResync: Bool
}

/// JSON-RPC 2.0 response envelope.
private struct RPCResponse: Decodable {
    let result: PollChangesResponse?
    let error: RPCError?

    enum CodingKeys: String, CodingKey {
        case result, error
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Try to decode the result as our known type; if missing, try error.
        result = try? c.decode(PollChangesResponse.self, forKey: .result)
        error = try? c.decode(RPCError.self, forKey: .error)
    }
}

private struct RPCError: Decodable, Error {
    let code: Int
    let message: String
}

enum DaemonClientError: Error {
    case notConnected
    case frameTooLarge(Int)
    case protocolError(String)
}

/// Connection state tracked by DaemonClient.
private enum ConnectionState {
    case disconnected
    case connecting
    case connected
}

/// Lightweight async JSON-RPC 2.0 client over the daemon's Unix socket.
/// Not safe for concurrent calls — ChangeWatcher serialises them via its
/// single polling Task.
final class DaemonClient {
    private static let log = Logger(subsystem: "dev.debruyn.ofem", category: "daemon-client")

    private static let maxFrameSize = 1 << 20  // 1 MiB, matching ipc.MaxFrameSize

    private let socketPath: String
    private var connection: NWConnection?
    private var connectionState: ConnectionState = .disconnected

    /// Returns true when a connection is established and ready.
    var isConnected: Bool { connectionState == .connected }
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    init(socketPath: String) {
        self.socketPath = socketPath
    }

    /// Convenience initialiser that resolves the default socket path from
    /// the App Group container, matching where the daemon puts ofem.sock.
    convenience init() {
        let groupContainer = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: CoreBridge.appGroupIdentifier
        )?.path ?? ""
        self.init(socketPath: groupContainer + "/ofem.sock")
    }

    /// Open (or reopen) the connection to the daemon socket.
    /// Throws if the socket does not exist or is unreachable.
    func connect() async throws {
        // Tear down any previous connection first.
        connection?.cancel()
        connection = nil
        connectionState = .connecting

        let ep = NWEndpoint.unix(path: socketPath)
        // NWParameters(tls: nil) is correct for Unix-domain sockets.
        // Passing .tcp here would attempt a TCP connection to the path string
        // instead of opening the Unix socket. With tls:nil Network.framework
        // uses an unencrypted stream transport, which is correct since the
        // Unix socket is owner-only (0600) and never leaves the machine.
        let params = NWParameters(tls: nil)
        let conn = NWConnection(to: ep, using: params)

        // stateUpdateHandler fires on every transition. Guard against
        // resuming the continuation more than once — doing so would crash
        // with a "continuation resumed more than once" fatal error.
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            var didResume = false
            conn.stateUpdateHandler = { [weak self] state in
                guard !didResume else { return }
                switch state {
                case .ready:
                    didResume = true
                    self?.connectionState = .connected
                    cont.resume()
                case .failed(let err):
                    didResume = true
                    self?.connectionState = .disconnected
                    cont.resume(throwing: err)
                case .waiting(let err):
                    // Waiting means the path is unavailable; surface as error.
                    didResume = true
                    self?.connectionState = .disconnected
                    cont.resume(throwing: err)
                default:
                    break
                }
            }
            conn.start(queue: .global(qos: .utility))
        }

        connection = conn
        Self.log.debug("Connected to daemon at \(self.socketPath, privacy: .public)")
    }

    /// Poll the daemon for changes since `anchor`.
    ///
    /// Returns a tuple of changed (domainId, containerId) pairs and the
    /// new anchor to use on the next call, plus a fullResync flag.
    func pollChanges(since anchor: Date?) async throws -> (
        events: [(domainId: String, containerId: String)],
        anchor: Date,
        fullResync: Bool
    ) {
        guard connectionState == .connected, connection != nil else { throw DaemonClientError.notConnected }

        struct PollParams: Encodable {
            let anchor: Date?
        }
        let params = PollParams(anchor: anchor)
        let paramsData = try encoder.encode(params)
        let paramsJSON = try JSONSerialization.jsonObject(with: paramsData) as! [String: Any]

        let requestID = UUID().uuidString
        let requestDict: [String: Any] = [
            "jsonrpc": "2.0",
            "method": "sync.pollChanges",
            "params": paramsJSON,
            "id": requestID,
        ]
        let requestData = try JSONSerialization.data(withJSONObject: requestDict)
        try await writeFrame(requestData)

        let responseData = try await readFrame()
        let response = try decoder.decode(RPCResponse.self, from: responseData)

        if let err = response.error {
            throw err
        }
        guard let result = response.result else {
            throw DaemonClientError.protocolError("missing result in sync.pollChanges response")
        }

        let pairs = result.events.map { (domainId: $0.domain, containerId: $0.containerId) }
        return (events: pairs, anchor: result.anchor, fullResync: result.fullResync)
    }

    /// Close the connection.
    func disconnect() {
        connection?.cancel()
        connection = nil
        connectionState = .disconnected
    }

    // MARK: - Frame I/O

    private func writeFrame(_ data: Data) async throws {
        guard let conn = connection else { throw DaemonClientError.notConnected }

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

    private func readFrame() async throws -> Data {
        guard let conn = connection else { throw DaemonClientError.notConnected }

        // Read 4-byte header.
        let header: Data = try await withCheckedThrowingContinuation { cont in
            conn.receive(minimumIncompleteLength: 4, maximumLength: 4) { data, _, _, err in
                if let err = err { cont.resume(throwing: err); return }
                cont.resume(returning: data ?? Data())
            }
        }
        guard header.count == 4 else {
            throw DaemonClientError.protocolError("short frame header: \(header.count) bytes")
        }
        let length = Int(header[0]) << 24 | Int(header[1]) << 16 | Int(header[2]) << 8 | Int(header[3])
        guard length <= Self.maxFrameSize else {
            throw DaemonClientError.frameTooLarge(length)
        }

        // Read payload.
        let payload: Data = try await withCheckedThrowingContinuation { cont in
            conn.receive(minimumIncompleteLength: length, maximumLength: length) { data, _, _, err in
                if let err = err { cont.resume(throwing: err); return }
                cont.resume(returning: data ?? Data())
            }
        }
        guard payload.count == length else {
            throw DaemonClientError.protocolError("short frame body: got \(payload.count), want \(length)")
        }
        return payload
    }
}
