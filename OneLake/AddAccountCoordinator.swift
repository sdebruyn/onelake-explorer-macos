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
protocol SignInProvider: Sendable {
    func signIn(
        alias: String,
        tenant: String?,
        clientID: String?,
        window: NSWindow
    ) async throws -> XPCAccountInfo
}

/// Abstracts domain registration so AddAccountCoordinator can be tested
/// without a live NSFileProviderManager.
protocol DomainRegistrar: Sendable {
    func registerDomain(alias: String) async
}

// MARK: - Default production implementations

extension SharedOfemAuth: SignInProvider {}

// `DomainRegistrar: Sendable` is satisfied because `OfemFPEClient` is
// `@MainActor final class` (already `Sendable`). See MenuStatusModel.swift,
// the canonical location for all OfemFPEClient protocol conformances.
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
        case waiting // sign-in in flight
        case success(String) // signed-in username; brief success display
        case readyToDismiss(String) // pause elapsed; view should dismiss
        case failure(String) // human-readable error

        /// True while sign-in is in progress (fields should be disabled).
        var isInProgress: Bool {
            switch self {
            case .waiting, .success, .readyToDismiss: true
            case .idle, .failure: false
            }
        }
    }

    @Published private(set) var phase: Phase = .idle

    // MARK: - Dependencies

    private let signInProvider: SignInProvider
    private let domainRegistrar: DomainRegistrar

    private static let log = Logger(subsystem: ofemSubsystem, category: "add-account-coordinator")

    /// Duration the success state is shown before transitioning to readyToDismiss.
    static let successDisplayDuration: Duration = .milliseconds(1200)

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
    /// Accepts raw field strings from the View and normalises them here so the
    /// View has no orchestration logic. The View supplies the anchor window
    /// (key window at the time Sign In is tapped) rather than the coordinator
    /// reaching into NSApp directly, which keeps the coordinator testable.
    ///
    /// - Parameters:
    ///   - alias:    Raw alias string from the text field (will be trimmed).
    ///   - tenant:   Raw tenant field (trimmed; nil if blank).
    ///   - clientID: Raw client ID field (trimmed; nil if blank).
    ///   - window:   Window that anchors the MSAL ASWebAuthenticationSession sheet.
    func startLogin(
        alias: String,
        tenant: String?,
        clientID: String?,
        window: NSWindow
    ) {
        guard !phase.isInProgress else { return }

        let trimmedAlias = alias.trimmingCharacters(in: .whitespaces)
        guard !trimmedAlias.isEmpty else { return }

        let tenantArg = tenant?.trimmingCharacters(in: .whitespaces)
        let clientIDArg = clientID?.trimmingCharacters(in: .whitespaces)

        isCancelled = false
        phase = .waiting
        loginTask = Task { [weak self] in
            await self?.runLogin(
                alias: trimmedAlias,
                tenant: tenantArg.flatMap { $0.isEmpty ? nil : $0 },
                clientID: clientIDArg.flatMap { $0.isEmpty ? nil : $0 },
                window: window
            )
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

            guard !Task.isCancelled, !isCancelled else { return }

            // Brief success display before auto-dismiss (host-16): the pause and
            // the transition to readyToDismiss live here so the View has no
            // sleep or dismiss orchestration.
            try? await Task.sleep(for: Self.successDisplayDuration)
            guard !Task.isCancelled, !isCancelled else { return }
            phase = .readyToDismiss(info.username)

        } catch is CancellationError {
            Self.log.info("sign-in task cancelled")
            // A CancellationError can arrive from the provider even when
            // cancel() was not called (e.g. the framework cancels the task
            // directly). Explicitly reset to .idle so the UI is never left
            // stuck in .waiting with a disabled Sign In button (host-04).
            if !isCancelled {
                phase = .idle
            }
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
            case .fabricConsentFailed: return "Fabric consent was not obtained. Please try signing in again and complete both browser prompts."
            case let .unknownAlias(a): return "Account '\(a)' not found."
            }
        }
        if let authErr = error as? OfemAuthError {
            switch authErr {
            case .interactionRequired: return "Authentication required — please sign in again."
            case .emptyAlias: return "Alias must not be empty."
            case let .duplicateAlias(a): return "Account '\(a)' already exists."
            case let .unknownAlias(a): return "Account '\(a)' not found."
            case .emptyScopes: return "Internal error: no scopes configured."
            case let .silentTokenFailed(alias): return "Token error for '\(alias)' — please sign in again."
            case let .configRejection(alias): return "Authentication configuration error for '\(alias)' — contact the administrator."
            case let .msalRemoveFailed(alias, _): return "Sign-out error for '\(alias)' — refresh token may not have been cleared."
            }
        }
        return error.localizedDescription
    }
}
