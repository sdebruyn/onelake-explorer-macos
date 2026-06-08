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
// XPCAccountInfo (see XPCAccountInfo.swift), which conforms to
// NSSecureCoding.
//
// Backwards compatibility: the existing Unix-socket IPC remains active
// during this phase (Fase 7.2). The host app's new OfemFPEClient
// connects over XPC when the FPE service is available. Fase 7.3 will
// remove the Unix-socket path.

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

    // MARK: - Auth URL relay

    /// Phase-2 relay for the interactive login flow.
    ///
    /// After `addAccount` responds with an `authURL`, the host app
    /// opens it in the browser and then calls this method with the
    /// `sessionID` to unblock the FPE's MSAL wait loop. The FPE
    /// completes token acquisition internally; the result was already
    /// delivered via the `addAccount` reply block.
    ///
    /// Note: in the current OfemKit implementation MSAL drives the
    /// full OAuth round-trip in-process (host app), so this relay
    /// method is reserved for a future two-phase split if the
    /// interactive flow ever moves inside the FPE process. The host
    /// app performs the MSAL interactive call itself in Fase 7.2.
    func notifyAuthComplete(sessionID: String, reply: @escaping (Error?) -> Void)

    // MARK: - Status

    /// Returns a lightweight status snapshot from the FPE engine.
    ///
    /// - Parameter reply: Called with an optional status dictionary or
    ///   an error. The dictionary contains:
    ///   - "accounts": [[String: String]] (alias, username, tenantId, tenantName)
    ///   - "defaultAccount": String
    func status(reply: @escaping ([String: Any]?, Error?) -> Void)
}

// MARK: - Service name constant

/// The NSFileProviderServiceName string used to look up the FPE's
/// control service. Shared between FPE (publisher) and host (subscriber).
public let ofemControlServiceName = "dev.debruyn.ofem.control"
