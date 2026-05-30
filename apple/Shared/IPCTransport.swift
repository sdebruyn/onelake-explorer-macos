// IPCTransport.swift
// Plain POSIX/Darwin Unix-domain socket transport for the ofem daemon.
//
// Replaces the NWConnection-based implementation that lived in
// IPCClient.swift. Network.framework's multi-state connection machine
// (`.preparing`/`.ready`/`.waiting`) and its non-cancellation-aware
// completion handlers were a continual source of subtle bugs on a
// transport that is, fundamentally, blocking read/write on a local
// stream socket.
//
// Design:
//   - `IPCSocket` owns one file descriptor. All I/O is synchronous and
//     blocking. Per-socket timeouts are enforced with SO_RCVTIMEO and
//     SO_SNDTIMEO so a hung daemon surfaces as a read error in bounded
//     time even when the socket has no pending data.
//   - All blocking work runs on a background dispatch queue so the
//     async/await boundary never blocks a cooperative thread.
//   - EINTR on read/write is retried — macOS can deliver signals on any
//     blocking syscall and the only correct response is to try again.

import Darwin
import Foundation

/// Owns a single AF_UNIX/SOCK_STREAM fd and exposes synchronous,
/// blocking length-prefixed frame I/O. Thread-affinity is the caller's
/// responsibility: serialise calls through a single dispatch queue.
final class IPCSocket {
    enum SocketError: Error {
        case socketCreate(Int32)
        case connect(Int32)
        case pathTooLong(Int)
        case write(Int32)
        case read(Int32)
        case eof(Int)
        case timeout
        case frameTooLarge(Int)
        case closed
    }

    static let maxFrameSize = 1 << 20

    private var fd: Int32
    private var closed = false

    private init(fd: Int32) {
        self.fd = fd
    }

    /// Connect to a Unix-domain socket at `path` with `timeout` applied
    /// to subsequent reads and writes. The connect itself is unbounded;
    /// the kernel rejects a missing/refused unix socket essentially
    /// instantly so a separate connect timer would only add latency.
    static func connect(path: String, timeout: TimeInterval) throws -> IPCSocket {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        if fd < 0 {
            throw SocketError.socketCreate(errno)
        }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let maxLen = MemoryLayout.size(ofValue: addr.sun_path)
        let pathBytes = Array(path.utf8)
        if pathBytes.count >= maxLen {
            close(fd)
            throw SocketError.pathTooLong(pathBytes.count)
        }
        withUnsafeMutablePointer(to: &addr.sun_path) { tuplePtr in
            tuplePtr.withMemoryRebound(to: CChar.self, capacity: maxLen) { dst in
                for i in 0..<pathBytes.count {
                    dst[i] = CChar(bitPattern: pathBytes[i])
                }
                dst[pathBytes.count] = 0
            }
        }
        let addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
        let rc = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.connect(fd, sa, addrLen)
            }
        }
        if rc != 0 {
            let err = errno
            close(fd)
            throw SocketError.connect(err)
        }
        let sock = IPCSocket(fd: fd)
        try sock.disableSIGPIPE()
        try sock.setTimeouts(timeout)
        return sock
    }

    /// Disable SIGPIPE on write-to-closed-peer. The default behaviour on
    /// Darwin is to terminate the process; for an IPC client we want the
    /// write to fail with EPIPE so the caller can surface it as a
    /// recoverable error.
    private func disableSIGPIPE() throws {
        var on: Int32 = 1
        let sz = socklen_t(MemoryLayout<Int32>.size)
        if setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, sz) != 0 {
            throw SocketError.write(errno)
        }
    }

    /// Apply `seconds` as both SO_RCVTIMEO and SO_SNDTIMEO. Whichever
    /// blocking I/O hits the limit fails with EAGAIN, which surfaces as
    /// `SocketError.timeout` instead of stalling forever.
    func setTimeouts(_ seconds: TimeInterval) throws {
        guard !closed else { throw SocketError.closed }
        let sec = Int(seconds)
        let usec = Int32((seconds - Double(sec)) * 1_000_000)
        var tv = timeval(tv_sec: sec, tv_usec: usec)
        let sz = socklen_t(MemoryLayout<timeval>.size)
        if setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sz) != 0 {
            throw SocketError.read(errno)
        }
        if setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sz) != 0 {
            throw SocketError.write(errno)
        }
    }

    /// Idempotent close of the underlying fd. Subsequent I/O throws
    /// `.closed`. Safe to call from any queue, including from the
    /// cancellation handler of a task that is currently blocked in a
    /// read on a different queue: closing the fd wakes the read with
    /// EBADF, so the caller unwinds.
    func shutdownAndClose() {
        if closed { return }
        closed = true
        let oldFD = fd
        fd = -1
        // shutdown() first so a blocked read on another thread returns
        // immediately, then close to release the fd.
        _ = Darwin.shutdown(oldFD, SHUT_RDWR)
        _ = Darwin.close(oldFD)
    }

    deinit {
        shutdownAndClose()
    }

    /// Write all of `data`, looping over partial writes. EINTR is
    /// retried transparently.
    func writeAll(_ data: Data) throws {
        guard !closed else { throw SocketError.closed }
        try data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
            guard let base = buf.baseAddress else { return }
            var sent = 0
            while sent < data.count {
                let remaining = data.count - sent
                let n = Darwin.write(fd, base.advanced(by: sent), remaining)
                if n < 0 {
                    let err = errno
                    if err == EINTR { continue }
                    if err == EAGAIN || err == EWOULDBLOCK {
                        throw SocketError.timeout
                    }
                    throw SocketError.write(err)
                }
                if n == 0 {
                    throw SocketError.eof(sent)
                }
                sent += n
            }
        }
    }

    /// Read exactly `count` bytes, looping over partial reads. EOF
    /// before `count` is a hard error — every frame the daemon writes
    /// is sized up front. EINTR is retried transparently.
    func readExact(count: Int) throws -> Data {
        guard !closed else { throw SocketError.closed }
        if count == 0 { return Data() }
        var buf = Data(count: count)
        var read = 0
        try buf.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            while read < count {
                let want = count - read
                let n = Darwin.read(fd, base.advanced(by: read), want)
                if n < 0 {
                    let err = errno
                    if err == EINTR { continue }
                    if err == EAGAIN || err == EWOULDBLOCK {
                        throw SocketError.timeout
                    }
                    throw SocketError.read(err)
                }
                if n == 0 {
                    throw SocketError.eof(read)
                }
                read += n
            }
        }
        return buf
    }

    /// Write a 4-byte big-endian length prefix followed by `payload`.
    /// Matches the Go server's `ipc.WriteFrame`.
    func writeFrame(_ payload: Data) throws {
        if payload.count > IPCSocket.maxFrameSize {
            throw SocketError.frameTooLarge(payload.count)
        }
        var header = Data(count: 4)
        let length = UInt32(payload.count)
        header[0] = UInt8((length >> 24) & 0xFF)
        header[1] = UInt8((length >> 16) & 0xFF)
        header[2] = UInt8((length >> 8) & 0xFF)
        header[3] = UInt8(length & 0xFF)
        try writeAll(header)
        if !payload.isEmpty {
            try writeAll(payload)
        }
    }

    /// Read one length-prefixed frame. Enforces `maxFrameSize` against
    /// the declared length before allocating the payload buffer.
    func readFrame() throws -> Data {
        let header = try readExact(count: 4)
        let length = (Int(header[0]) << 24) | (Int(header[1]) << 16) | (Int(header[2]) << 8) | Int(header[3])
        if length < 0 || length > IPCSocket.maxFrameSize {
            throw SocketError.frameTooLarge(length)
        }
        if length == 0 {
            return Data()
        }
        return try readExact(count: length)
    }
}

/// Shared serial-by-default work queue for IPC blocking I/O. Concurrent
/// attribute lets multiple parallel async calls each grab their own
/// thread for blocking syscalls — they are isolated by socket, not by
/// queue, since each call owns its fresh `IPCSocket`.
enum IPCQueues {
    static let io = DispatchQueue(
        label: "dev.debruyn.ofem.ipc.io",
        qos: .userInitiated,
        attributes: .concurrent
    )
}

/// Run a synchronous, blocking closure on the IPC I/O queue and bridge
/// its outcome to async. Cancellation runs `onCancel` synchronously on
/// whatever queue the task was cancelled from — typically this calls
/// `shutdownAndClose()` on the socket the work is blocked on, which
/// makes the next syscall fail and the closure unwind.
func ipcRunBlocking<T: Sendable>(
    onCancel: @Sendable @escaping () -> Void = {},
    _ body: @escaping @Sendable () throws -> T
) async throws -> T {
    try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<T, Error>) in
            IPCQueues.io.async {
                do {
                    cont.resume(returning: try body())
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    } onCancel: {
        onCancel()
    }
}
