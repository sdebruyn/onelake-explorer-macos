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
//   - getProtocolVersion(reply:)      — version handshake; call before any other method
//   - getEngineStatus(reply:)         — cache stats + config snapshot
//   - setConfig(key:value:reply:)     — write a single config field and notify FPE
//   - clearCache(reply:)              — wipe all cached blobs
//   - pollMaterialized(alias:reply:)  — refresh materialized containers for alias, return whether any changed

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
    /// The host app and FPE always ship together in the same `.app` bundle,
    /// so a version mismatch indicates a corrupted installation and is surfaced
    /// as a user-visible error rather than a silent degraded mode.
    ///
    /// - Parameter reply: Called with the FPE's protocol version integer.
    func getProtocolVersion(reply: @escaping (Int) -> Void)

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
    ///   - "sync.materialized_poll_interval_s"         (integer string, 30–600)
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

    // MARK: - Materialized poll

    /// Refreshes all materialized containers for `alias` via the sync engine.
    ///
    /// The FPE reads the `materialized_containers` table for `alias`, calls
    /// `SyncEngine.refreshMaterialized`, and replies `true` when at least one
    /// container produced a non-zero diff (i.e. the SQLite cache was updated
    /// and `.workingSet` should be signalled to let the system call
    /// `enumerateChanges`).  Replies `false` when no containers changed or no
    /// containers are materialized.
    ///
    /// The FPE is the sole writer of the cache; this method therefore keeps
    /// the single-writer invariant intact — the host only reads the Bool result.
    ///
    /// - Parameters:
    ///   - alias: Account alias identifying which engine to poll.
    ///   - reply: Called with `true` (delta) or `false` (no delta) on success,
    ///     or `false` + an `Error` when the engine is unavailable.
    func pollMaterialized(alias: String, reply: @escaping (Bool, Error?) -> Void)
}

// MARK: - Service name constant

/// The NSFileProviderServiceName string used to look up the FPE's
/// control service. Shared between FPE (publisher) and host (subscriber).
public let ofemControlServiceName = "dev.debruyn.ofem.control"

// MARK: - Protocol version

/// The protocol version this build implements.
///
/// The FPE reports its version via `getProtocolVersion(reply:)`.
/// The host compares this value to the FPE's report on every new connection;
/// a mismatch is surfaced as a user-visible error.
public let ofemControlProtocolVersion: Int = 3
