// OfemClientControlProtocol.swift
// XPC protocol the host app uses to control the File Provider Extension.
//
// The FPE owns all account state (OfemAuth, OfemConfigStore). The host app
// communicates with it through NSFileProviderManager.service(name:for:) +
// NSXPCConnection.
//
// NSXPCInterface requires @objc types, so every parameter and return
// type must be NSObject-compatible. Complex values are passed as
// XPCEngineStatus (see XPCEngineStatus.swift), conforming to NSSecureCoding.
//
// Protocol surface:
//   - getProtocolVersion(reply:)  — version handshake; call before any other method
//   - getEngineStatus(reply:)     — cache stats + config snapshot
//   - setConfig(key:value:reply:) — write a single config field and notify FPE
//   - clearCache(reply:)          — wipe all cached blobs
//
// Reply-block style (xpc-01 / xpc-02):
//   The protocol uses @objc reply-block signatures rather than Swift async
//   methods because NSXPCInterface requires @objc-compatible method signatures
//   and the XPC runtime uses the reply-block presence to model the two-phase
//   call/reply lifecycle. Converting to `async throws` would require dropping
//   `@objc`, which breaks NSXPCInterface registration.
//
//   IMPORTANT for FPE implementors (xpc-02): every reply block MUST be called
//   exactly once on ALL paths — including Task cancellation. Use a defer-based
//   guard or `withTaskCancellationHandler` to guarantee this:
//
//       func getEngineStatus(reply: @escaping (XPCEngineStatus?, Error?) -> Void) {
//           var replied = false
//           let safeReply: (XPCEngineStatus?, Error?) -> Void = { s, e in
//               guard !replied else { return }
//               replied = true
//               reply(s, e)
//           }
//           Task {
//               defer { safeReply(nil, CancellationError()) }
//               // … actual work; call reply directly for success/failure …
//           }
//       }
//
//   Failing to call reply on cancellation causes the host's continuation to
//   hang until the connection's interruptionHandler fires, which is the only
//   backstop but is not guaranteed to fire promptly.
//
// Error bridging (xpc-03):
//   Errors returned through reply blocks MUST be bridged to NSError via
//   `NSError.ofemXPC(for:)` (see XPCError.swift) before being passed to
//   `reply`. Raw Swift enum errors are not reliably preserved by NSSecureCoding
//   across the XPC boundary; the host receives a generic NSError with a
//   flattened domain/code that loses the original case.

import Foundation

/// Service name the FPE registers under NSFileProviderServiceSource and
/// the host app connects to via NSFileProviderManager.
///
/// Must match exactly on both sides.
@objc public protocol OfemClientControlProtocol {

    // MARK: - Protocol version handshake

    /// Returns the protocol version implemented by the FPE.
    ///
    /// Call this first after obtaining a proxy. If the returned version is
    /// lower than `ofemControlProtocolVersion`, the host and FPE are
    /// mismatched: treat the connection as degraded and show a stale-extension
    /// warning rather than silently misbehaving (xpc-06).
    ///
    /// Declared `@objc optional` so existing FPE builds that pre-date
    /// protocol version 2 do not fail to satisfy the protocol — the host
    /// checks `proxy.responds(to:)` before calling and treats a non-response
    /// as "version 1" (pre-versioning build).
    ///
    /// - Parameter reply: Called with the FPE's protocol version integer.
    @objc optional func getProtocolVersion(reply: @escaping (Int) -> Void)

    // MARK: - Engine status

    /// Returns a rich engine status snapshot: cache usage, config fields,
    /// and other metrics the menu-bar UI needs.
    ///
    /// - Parameter reply: Called with an `XPCEngineStatus` on success, or
    ///   nil + an error on failure.
    func getEngineStatus(reply: @escaping (XPCEngineStatus?, Error?) -> Void)

    // MARK: - Config mutation

    /// Persists a single config field and signals the FPE to reload its
    /// in-memory snapshot.
    ///
    /// Supported keys (matching the TOML schema):
    ///   - "telemetry"                                 ("on" | "off")
    ///   - "cache.max_size_gb"                         (integer string, 1–100)
    ///   - "net.max_concurrent_uploads_per_account"    (integer string, 1–NetConfig.maxConcurrent)
    ///   - "net.max_concurrent_downloads_per_account"  (integer string, 1–NetConfig.maxConcurrent)
    ///   - "log.level"                                 ("debug" | "info" | "warn" | "error")
    ///
    /// Errors returned via `reply` are bridged to `NSError` in
    /// `OfemXPCErrorDomain` (see `XPCError.swift`) so the host can
    /// distinguish validation failures from transport failures.
    ///
    /// - Parameters:
    ///   - key:   Config key in dot notation (see above).
    ///   - value: New value as a string.
    ///   - reply: Called with nil on success, or an `NSError` in `OfemXPCErrorDomain`.
    func setConfig(key: String, value: String, reply: @escaping (Error?) -> Void)

    // MARK: - Cache

    /// Clears all cached blobs.
    ///
    /// - Parameter reply: Called with the byte count remaining after the
    ///   wipe (always 0 on success) or an error.
    func clearCache(reply: @escaping (Int64, Error?) -> Void)
}

// MARK: - Service name + protocol version constants

/// The NSFileProviderServiceName string used to look up the FPE's
/// control service. Shared between FPE (publisher) and host (subscriber).
public let ofemControlServiceName = "dev.debruyn.ofem.control"

/// Current protocol version implemented by this build.
///
/// Increment this integer whenever a breaking change is made to
/// `OfemClientControlProtocol` (new required method, removed method, changed
/// semantics). The FPE reports this value from `getProtocolVersion(reply:)`;
/// the host compares it to detect a stale extension (xpc-06).
///
/// Version history:
///   1 — initial protocol (getEngineStatus, setConfig, clearCache)
///   2 — added getProtocolVersion; XPCError domain; strict decode in payloads
public let ofemControlProtocolVersion: Int = 2
