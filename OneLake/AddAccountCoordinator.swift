// AddAccountCoordinator.swift
// Testable sign-in orchestration for the "Add Account" flow.
//
// Extracted from AddAccountView.startLogin() so the state-machine logic
// (auth → domain registration → error mapping) can be unit-tested with
// mocked dependencies. The View owns an instance and binds to `phase`.
//
// Protocol seams (SignInProvider, DomainRegistrar) let tests inject fakes
// without a live MSAL/FPE stack. Production wiring uses default arguments
// so existing call sites need no changes.

import AppKit
import Foundation
import OfemKit
import os.log

// MARK: - Protocol seams

/// Abstracts the interactive sign-in operation so AddAccountCoordinator can
/// be tested with a mock that doesn't require MSAL or a real NSWindow.
protocol SignInProvider {
    func signIn(
        alias: String,
        tenant: String?,
        clientID: String?,
        window: NSWindow
    ) async throws -> XPCAccountInfo
}

/// Abstracts domain registration so AddAccountCoordinator can be tested
/// without a live NSFileProviderManager.
protocol DomainRegistrar {
    func registerDomain(alias: String) async
}

// MARK: - Default production implementations

extension SharedOfemAuth: SignInProvider {}

extension OfemFPEClient: DomainRegistrar {}

// MARK: - AddAccountCoordinator

/// Drives the sign-in state machine for the "Add Account" flow.
///
/// The View creates and owns an instance; it reads `phase` for rendering
/// and calls `startLogin` / `cancel`. All state mutations are `@MainActor`.
@MainActor
final class AddAccountCoordinator: ObservableObject {

    // MARK: - Phase

    enum Phase: Equatable {
        case idle
        case waiting             // sign-in in flight
        case success(String)     // signed-in username
        case failure(String)     // human-readable error
    }

    @Published private(set) var phase: Phase = .idle

    // MARK: - Dependencies

    private let signInProvider: SignInProvider
    private let domainRegistrar: DomainRegistrar

    private static let log = Logger(subsystem: "dev.debruyn.ofem", category: "add-account-coordinator")

    /// Production initialiser — wires to shared singletons by default.
    /// The `@MainActor` default args are safe here because the class itself
    /// is `@MainActor` so the initialiser always runs on the main actor.
    @MainActor
    init(
        signInProvider: SignInProvider? = nil,
        domainRegistrar: DomainRegistrar? = nil
    ) {
        self.signInProvider = signInProvider ?? SharedOfemAuth.shared
        self.domainRegistrar = domainRegistrar ?? OfemFPEClient.shared
    }

    // MARK: - Running task

    private var loginTask: Task<Void, Never>?

    /// Set synchronously by `cancel()` before the task cancel call. Checked
    /// inside the task at each @MainActor turn so that a result racing a
    /// cancel() cannot overwrite the idle reset with .success or .failure.
    private var isCancelled = false

    // MARK: - Public interface

    /// Drives the sign-in flow.
    ///
    /// - Parameters:
    ///   - alias:      Trimmed, non-empty alias string.
    ///   - tenant:     Optional tenant GUID/domain; nil means "let AAD pick".
    ///   - clientID:   Optional custom Entra App Registration; nil means built-in.
    ///   - window:     Window that anchors the ASWebAuthenticationSession sheet.
    func startLogin(
        alias: String,
        tenant: String?,
        clientID: String?,
        window: NSWindow
    ) {
        guard phase != .waiting else { return }
        isCancelled = false
        phase = .waiting
        loginTask = Task { [weak self] in
            await self?.runLogin(alias: alias, tenant: tenant, clientID: clientID, window: window)
        }
    }

    /// Cancels the in-flight login task and resets to idle.
    ///
    /// Sets `isCancelled` synchronously before cancelling the Task so that
    /// any @MainActor turn already in flight (e.g. the task resumed with a
    /// sign-in result just before this call) sees the flag and skips writing
    /// .success or .failure, preventing the cancelled-but-succeeded race.
    func cancel() {
        isCancelled = true
        loginTask?.cancel()
        loginTask = nil
        phase = .idle
    }

    // MARK: - Private

    private func runLogin(
        alias: String,
        tenant: String?,
        clientID: String?,
        window: NSWindow
    ) async {
        do {
            let info = try await signInProvider.signIn(
                alias: alias,
                tenant: tenant,
                clientID: clientID,
                window: window
            )

            guard !Task.isCancelled, !isCancelled else { return }
            Self.log.info(
                "sign-in succeeded: alias=\(alias, privacy: .public) user=\(info.username, privacy: .private)"
            )
            phase = .success(info.username)

            // Register the File Provider domain so the account appears in the
            // Finder sidebar immediately.
            await domainRegistrar.registerDomain(alias: info.alias)

        } catch is CancellationError {
            Self.log.info("sign-in task cancelled by user")
            // phase was already reset by cancel() or remains .waiting —
            // callers should call cancel() to reset; don't touch phase here.
        } catch {
            guard !Task.isCancelled, !isCancelled else { return }
            Self.log.error("sign-in failed: \(error.localizedDescription, privacy: .public)")
            phase = .failure(AddAccountCoordinator.friendlyError(error))
        }
    }

    // MARK: - Error mapping

    /// Maps an auth error to a short human-readable string.
    static func friendlyError(_ error: Error) -> String {
        if let authErr = error as? SharedOfemAuthError {
            switch authErr {
            case .noViewController: return "Internal error: no window for authentication."
            }
        }
        if let authErr = error as? OfemAuthError {
            switch authErr {
            case .interactionRequired: return "Authentication required — please sign in again."
            case .emptyAlias: return "Alias must not be empty."
            case .duplicateAlias(let a): return "Account '\(a)' already exists."
            case .unknownAlias(let a): return "Account '\(a)' not found."
            case .emptyScopes: return "Internal error: no scopes configured."
            case .silentTokenFailed(_, let e): return "Token error: \(e.localizedDescription)"
            }
        }
        return error.localizedDescription
    }
}
