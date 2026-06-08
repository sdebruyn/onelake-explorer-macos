// OfemClientControlProtocol.swift
// XPC protocol the host app uses to manage accounts inside the
// File Provider Extension.
//
// The FPE owns all account state (OfemAuth, OfemConfigStore) after the
// architecture flip in Fase 7.2. The host app communicates with it
// through NSFileProviderManager.service(name:for:) + NSXPCConnection.
//
// NSXPCInterface requires @objc types, so every parameter and return
// type must be NSObject-compatible. Complex values are passed as
// XPCAccountInfo (see XPCAccountInfo.swift) or XPCEngineStatus
// (see XPCEngineStatus.swift), both conforming to NSSecureCoding.
//
// Fase 7.3b-1 additions:
//   - getEngineStatus(reply:)   — cache stats + config snapshot
//   - setConfig(key:value:reply:) — write a single config field + notify FPE
//   - clearCache(reply:)        — wipe all cached blobs
// These replace the old Unix-socket CoreBridge calls
// (bridge.status(), bridge.configSnapshot(), bridge.configSet(),
// bridge.cacheClear()) so CoreBridge is no longer called by any consumer
// after this phase.

import Foundation

/// Service name the FPE registers under NSFileProviderServiceSource and
/// the host app connects to via NSFileProviderManager.
///
/// Must match exactly on both sides.
@objc public protocol OfemClientControlProtocol {

    // MARK: - Account management

    /// Adds a new account via the interactive browser sign-in flow.
    ///
    /// The FPE's OfemAuth drives MSAL interactively; the host app is
    /// responsible for opening the returned `authURL` in the system
    /// browser via NSWorkspace.open(_:). After the browser flow
    /// completes, the FPE persists the tokens and calls back via
    /// `reply` with the new account info (or an error).
    ///
    /// - Parameters:
    ///   - alias: Short user-chosen account name (e.g. "work").
    ///   - tenant: Optional Entra tenant GUID or domain. Pass nil or ""
    ///     to use Azure AD home-tenant routing.
    ///   - clientID: Optional custom Entra App Registration GUID.
    ///     Pass nil or "" to use the built-in OFEM registration.
    ///   - reply: Called on completion with the new account or an error.
    func addAccount(
        alias: String,
        tenant: String,
        clientID: String,
        reply: @escaping (XPCAccountInfo?, Error?) -> Void
    )

    /// Removes the account identified by `alias` from the FPE's config.
    ///
    /// - Parameters:
    ///   - alias: The account alias to remove.
    ///   - reply: Called on completion with nil on success, or an error.
    func removeAccount(alias: String, reply: @escaping (Error?) -> Void)

    /// Returns all accounts known to the FPE.
    ///
    /// - Parameter reply: Called with the account list or an error.
    func listAccounts(reply: @escaping ([XPCAccountInfo], Error?) -> Void)

    /// Sets the default account alias in the FPE's config.
    ///
    /// - Parameters:
    ///   - alias: The alias to make the default.
    ///   - reply: Called on completion with nil on success, or an error.
    func setDefaultAccount(alias: String, reply: @escaping (Error?) -> Void)

    // MARK: - Status

    /// Returns a lightweight status snapshot from the FPE engine.
    ///
    /// - Parameter reply: Called with an optional status dictionary or
    ///   an error. The dictionary contains:
    ///   - "accounts": [[String: String]] (alias, username, tenantId, tenantName)
    ///   - "defaultAccount": String
    func status(reply: @escaping ([String: Any]?, Error?) -> Void)

    // MARK: - Engine status (Fase 7.3b-1)

    /// Returns a rich engine status snapshot: cache usage, config fields,
    /// and other metrics the menu-bar UI needs.
    ///
    /// Replaces `CoreBridge.status()` + `CoreBridge.configSnapshot()`.
    ///
    /// - Parameter reply: Called with an `XPCEngineStatus` on success, or
    ///   nil + an error on failure.
    func getEngineStatus(reply: @escaping (XPCEngineStatus?, Error?) -> Void)

    // MARK: - Config mutation (Fase 7.3b-1)

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
    /// Replaces `CoreBridge.configSet(key:value:)`.
    ///
    /// - Parameters:
    ///   - key:   Config key in dot notation (see above).
    ///   - value: New value as a string.
    ///   - reply: Called with nil on success, or an error.
    func setConfig(key: String, value: String, reply: @escaping (Error?) -> Void)

    // MARK: - Cache (Fase 7.3b-1)

    /// Clears all cached blobs.
    ///
    /// Replaces `CoreBridge.cacheClear()`.
    ///
    /// - Parameter reply: Called with the byte count remaining after the
    ///   wipe (always 0 on success) or an error.
    func clearCache(reply: @escaping (Int64, Error?) -> Void)
}

// MARK: - Service name constant

/// The NSFileProviderServiceName string used to look up the FPE's
/// control service. Shared between FPE (publisher) and host (subscriber).
public let ofemControlServiceName = "dev.debruyn.ofem.control"
