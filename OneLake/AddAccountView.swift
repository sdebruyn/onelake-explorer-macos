// AddAccountView.swift
// SwiftUI form for the "Add Account" sign-in flow.
//
// The user picks a short alias (becomes OneLake-<alias> on disk and
// "OneLake — <alias>" in the Finder sidebar), optionally pins a tenant
// (GUID or domain; blank = Azure AD picks it from the login prompt), then
// clicks Sign In.
//
// The sign-in orchestration lives in AddAccountCoordinator (testable).
// This view binds to the coordinator's `phase` and delegates all
// async work to it.
//
// Cancellation: tapping Cancel cancels the coordinator's Task.
// MSAL's ASWebAuthenticationSession sheet closes automatically when the Task
// is cancelled (Swift structured concurrency cooperative cancellation).
//
// On success: close the window after a brief pause so the user sees "Signed in".

import AppKit
import OfemKit
import os.log
import SwiftUI

struct AddAccountView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var alias: String = ""
    @State private var tenant: String = ""
    @State private var customClientID: String = ""
    @State private var showAdvanced: Bool = false
    @State private var coordinator = AddAccountCoordinator()

    // The follow-on docs page that describes when and how to bring
    // your own Entra App Registration. Linked from the Advanced
    // section so curious users don't have to dig for it.
    // URL(string:) can return nil for malformed literals; guard with a fallback
    // so a typo doesn't crash at first access of the view type (host-18).
    private static let customAppRegDocsURL: URL = .init(
        string: "https://ofem.debruyn.dev/custom-app-registration/"
    ) ?? URL(string: "https://ofem.debruyn.dev/")!

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
                    .disabled(coordinator.phase.isInProgress)
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
                    .disabled(coordinator.phase.isInProgress)
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
            coordinator.cancel()
        }
        .onChange(of: coordinator.phase) { _, newPhase in
            // Auto-dismiss when the coordinator signals readyToDismiss.
            // The delay and policy live in the coordinator, not here (host-16/host-07).
            if case .readyToDismiss = newPhase {
                dismiss()
            }
        }
    }

    // MARK: - Advanced (Bring Your Own App Registration)

    private var advancedSection: some View {
        DisclosureGroup("Advanced", isExpanded: $showAdvanced) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Client ID (optional)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
                TextField("Use the built-in app registration when blank", text: $customClientID)
                    .textFieldStyle(.roundedBorder)
                    .disabled(coordinator.phase.isInProgress)
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
        switch coordinator.phase {
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

        case let .success(username), let .readyToDismiss(username):
            Label("Signed in as \(username)", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.subheadline)

        case let .failure(message):
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
        switch coordinator.phase {
        case .idle, .failure: return true
        case .waiting, .success, .readyToDismiss: return false
        }
    }

    private func startLogin() {
        // Resolve the window that presents the MSAL auth sheet.
        // The "Add Account" window is the key window while the form is open;
        // fall back to mainWindow if keyWindow is briefly nil.
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow else { return }
        // Field normalisation and nil-vs-value decisions live in the coordinator
        // (host-07); the View only resolves the window and forwards raw values.
        coordinator.startLogin(
            alias: alias,
            tenant: tenant,
            clientID: customClientID,
            window: window
        )
    }

    private func cancelAndDismiss() {
        coordinator.cancel()
        dismiss()
    }
}
