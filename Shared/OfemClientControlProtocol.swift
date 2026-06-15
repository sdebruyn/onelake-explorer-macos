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
    ///   - "net.max_concurrent_uploads_per_account"    (integer string, 1–16)
    ///   - "net.max_concurrent_downloads_per_account"  (integer string, 1–32)
    ///   - "log.level"                                 ("debug" | "info" | "warn" | "error")
    ///
    /// - Parameters:
    ///   - key:   Config key in dot notation (see above).
    ///   - value: New value as a string.
    ///   - reply: Called with nil on success, or an error.
    func setConfig(key: String, value: String, reply: @escaping (Error?) -> Void)

    // MARK: - Cache

    /// Clears all cached blobs.
    ///
    /// - Parameter reply: Called with the byte count remaining after the
    ///   wipe (always 0 on success) or an error.
    func clearCache(reply: @escaping (Int64, Error?) -> Void)
}

// MARK: - Service name constant

/// The NSFileProviderServiceName string used to look up the FPE's
/// control service. Shared between FPE (publisher) and host (subscriber).
public let ofemControlServiceName = "dev.debruyn.ofem.control"

// MARK: - Protocol version

/// The protocol version this build implements.
///
/// Version history:
///   1 — original protocol (getEngineStatus, setConfig, clearCache)
///   2 — added getProtocolVersion; strict decode in XPC payloads
///
/// The FPE reports its version via `getProtocolVersion(reply:)`.
/// The host compares to this constant and degrades gracefully on mismatch.
public let ofemControlProtocolVersion: Int = 2
