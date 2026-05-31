// AddAccountView.swift
// SwiftUI form for the "Add Account" sign-in flow.
//
// The user picks a short alias (becomes OneLake-<alias> on disk and
// "OneLake — <alias>" in the Finder sidebar), optionally pins a tenant
// (GUID or domain; blank = Azure AD picks it from the login prompt), then
// clicks Sign In. We call CoreBridge.login(), which sends auth.login to the
// daemon. The daemon opens the system browser and blocks until the OAuth
// redirect arrives — the call is intentionally long-running (see
// CoreBridge.login() for the timeout rationale). A spinner + status label
// give feedback while we wait.
//
// Cancellation: tapping Cancel dismisses the UI. The Swift Task is
// cancelled, which closes the IPC connection. The daemon-side MSAL flow
// keeps running until its own session timeout fires (typically ~5 min) but
// no credentials are persisted for an incomplete login — safe to ignore.
//
// On success: close the window, refresh MenuStatusModel, reconcile domains.

import AppKit
import SwiftUI
import os.log

struct AddAccountView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var alias: String = ""
    @State private var tenant: String = ""
    @State private var customClientID: String = ""
    @State private var showAdvanced: Bool = false
    @State private var phase: LoginPhase = .idle
    @State private var loginTask: Task<Void, Never>?

    // The follow-on docs page that describes when and how to bring
    // your own Entra App Registration. Linked from the Advanced
    // section so curious users don't have to dig for it.
    private static let customAppRegDocsURL = URL(
        string: "https://ofem.debruyn.dev/custom-app-registration/"
    )!

    private static let log = Logger(subsystem: "dev.debruyn.ofem", category: "add-account")

    // MARK: - Phase

    private enum LoginPhase: Equatable {
        case idle
        case waiting             // auth.login IPC in flight
        case success(String)     // signed-in username
        case failure(String)     // human-readable error
    }

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add OneLake Account")
                .font(.headline)

            // Alias field — required; becomes the on-disk and Finder label.
            VStack(alignment: .leading, spacing: 4) {
                Text("Alias")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                TextField("e.g. work", text: $alias)
                    .textFieldStyle(.roundedBorder)
                    .disabled(phase == .waiting)
                // fixedSize(vertical) lets the caption wrap to a second
                // line when the alias is long enough to push the
                // composed preview past the field width, instead of
                // clipping with an ellipsis.
                Text("Short name for this account. Appears in Finder as \"OneLake \u{2014} \(alias.isEmpty ? "<alias>" : alias)\".")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Tenant field — optional; leave blank to let Azure pick at login.
            VStack(alignment: .leading, spacing: 4) {
                Text("Tenant (optional)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                TextField("GUID or domain", text: $tenant)
                    .textFieldStyle(.roundedBorder)
                    .disabled(phase == .waiting)
                Text("Optional. Leave blank and Microsoft will pick the right tenant at sign-in. Pin a specific tenant only if you belong to multiple and want to skip the picker.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Advanced — Bring Your Own App Registration. Hidden by
            // default; only users whose tenant admin has not approved
            // the built-in OFEM app registration need to set this.
            advancedSection

            Divider()

            // Status area.
            statusArea

            Divider()

            // Action buttons.
            HStack {
                Button("Cancel") {
                    cancelAndDismiss()
                }
                .keyboardShortcut(.escape, modifiers: [])

                Spacer()

                Button("Sign In") {
                    startLogin()
                }
                .keyboardShortcut(.return, modifiers: [])
                .disabled(!canSignIn)
            }
        }
        .padding(20)
        .frame(width: 380)
        // Dismiss if the window is closed via the red traffic-light button.
        .onDisappear {
            loginTask?.cancel()
        }
    }

    // MARK: - Advanced (Bring Your Own App Registration)

    @ViewBuilder
    private var advancedSection: some View {
        DisclosureGroup("Advanced", isExpanded: $showAdvanced) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Client ID (optional)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
                TextField("Use the built-in app registration when blank", text: $customClientID)
                    .textFieldStyle(.roundedBorder)
                    .disabled(phase == .waiting)
                // Help text — kept short here, with a link to the full
                // docs page that explains when this is needed and how
                // to configure the Entra registration.
                Text("Sign in with your own Microsoft Entra App Registration instead of the built-in OFEM one. Only needed when your tenant admin has not approved the OFEM app for organisation-wide use.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
                Link("How to set up a custom App Registration",
                     destination: Self.customAppRegDocsURL)
                    .font(.caption)
                    .padding(.top, 2)
            }
        }
    }

    // MARK: - Status area

    @ViewBuilder
    private var statusArea: some View {
        switch phase {
        case .idle:
            EmptyView()

        case .waiting:
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Waiting for browser sign-in…")
                    .foregroundStyle(.secondary)
                    .font(.subheadline)
            }

        case .success(let username):
            Label("Signed in as \(username)", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.subheadline)

        case .failure(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .font(.subheadline)
                // Allow long error text to wrap.
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Helpers

    private var canSignIn: Bool {
        guard !alias.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        switch phase {
        case .idle, .failure: return true
        case .waiting, .success: return false
        }
    }

    private func startLogin() {
        let trimmedAlias = alias.trimmingCharacters(in: .whitespaces)
        guard !trimmedAlias.isEmpty else {
            phase = .failure("Alias must not be empty.")
            return
        }
        phase = .waiting
        loginTask = Task { @MainActor in
            do {
                let tenantArg = tenant.trimmingCharacters(in: .whitespaces)
                let clientIDArg = customClientID.trimmingCharacters(in: .whitespaces)
                let info = try await CoreBridge.shared.login(
                    alias: trimmedAlias,
                    tenant: tenantArg.isEmpty ? nil : tenantArg,
                    clientID: clientIDArg.isEmpty ? nil : clientIDArg
                )
                // Task may have been cancelled while the browser was open;
                // guard against updating state after cancellation.
                guard !Task.isCancelled else { return }
                Self.log.info("auth.login succeeded: alias=\(trimmedAlias, privacy: .public) user=\(info.username, privacy: .private)")
                phase = .success(info.username)
                // Reconcile so the new domain appears in Finder immediately.
                try? await DomainSyncManager.shared.reconcile()
                // Refresh the menu-bar status model on the next open.
                // We don't have a reference to MenuStatusModel here; the model
                // will pick up the new account on its next onAppear refresh.
                // Close the window after a brief pause so the user sees "Signed in".
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                dismiss()
            } catch is CancellationError {
                // User tapped Cancel — phase was already reset in cancelAndDismiss().
                Self.log.info("auth.login task cancelled by user")
            } catch {
                guard !Task.isCancelled else { return }
                Self.log.error("auth.login failed: \(error.localizedDescription, privacy: .public)")
                let message = friendlyError(error)
                phase = .failure(message)
            }
        }
    }

    private func cancelAndDismiss() {
        loginTask?.cancel()
        loginTask = nil
        phase = .idle
        dismiss()
    }

    /// Map a BridgeError or IPCError to a short human-readable string.
    private func friendlyError(_ error: Error) -> String {
        if let be = error as? BridgeError {
            switch be {
            case .notAuthenticated(let m): return "Authentication failed: \(m)"
            case .serverUnreachable(let m): return "Daemon unreachable: \(m)"
            case .serverBusy(let m): return "Daemon busy: \(m)"
            case .notBootstrapped: return "Daemon not running — start it first."
            case .decoding(let m): return "Unexpected response: \(m)"
            case .cannotSynchronize(let m): return "Sign-in failed: \(m)"
            case .noSuchItem(let m): return "Sign-in failed: \(m)"
            case .nullPointer(let m): return "Internal error: \(m)"
            }
        }
        return error.localizedDescription
    }
}
