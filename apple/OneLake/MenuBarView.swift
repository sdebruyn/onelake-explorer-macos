// MenuBarView.swift
// SwiftUI content for the menu-bar-extra dropdown (Phase 0).
//
// Phase 0 scope: status header + per-account submenus with Open in Finder,
// About and Quit. No add/sign-out/set-default actions — those come in later PRs.

import AppKit
import SwiftUI
import os.log

struct MenuBarView: View {
    @StateObject private var model = MenuStatusModel()

    private static let log = Logger(subsystem: "dev.debruyn.ofem", category: "menubar-view")

    var body: some View {
        // Trigger a fetch every time the menu opens.
        Group {
            statusHeader
            Divider()
            accountRows
            Divider()
            aboutItem
            Divider()
            quitItem
        }
        .onAppear {
            model.refresh()
        }
    }

    // MARK: - Header

    @ViewBuilder
    private var statusHeader: some View {
        Text(model.headerLabel)
            .foregroundStyle(.secondary)
            // Disabled so clicking the header closes the menu without action.
            .disabled(true)
    }

    // MARK: - Account rows

    @ViewBuilder
    private var accountRows: some View {
        if model.accounts.isEmpty {
            Text(model.isRunning
                 ? "No accounts — add one from a later build"
                 : "Daemon not running")
                .foregroundStyle(.secondary)
                .disabled(true)
        } else {
            ForEach(model.accounts) { account in
                Menu {
                    AccountSubmenu(account: account)
                } label: {
                    HStack {
                        // em-dash as separator between alias and default-mark,
                        // matching the Finder sidebar style.
                        Text(account.alias)
                        if account.alias == model.defaultAccount {
                            Spacer()
                            Text("✓")
                        }
                    }
                }
            }
        }
    }

    // MARK: - About

    @ViewBuilder
    private var aboutItem: some View {
        Button("About OFEM\(model.daemonVersion.isEmpty ? "" : " v\(model.daemonVersion)")…") {
            NSApplication.shared.orderFrontStandardAboutPanel(nil)
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
    }

    // MARK: - Quit

    @ViewBuilder
    private var quitItem: some View {
        Button("Quit OneLake") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q", modifiers: .command)
    }
}

// MARK: - Per-account submenu (Phase 0: Open in Finder only)

private struct AccountSubmenu: View {
    let account: AccountInfo
    private static let log = Logger(subsystem: "dev.debruyn.ofem", category: "menubar-view")

    var body: some View {
        Button("Open in Finder") {
            openInFinder()
        }
    }

    private func openInFinder() {
        // Mount path convention: ~/Library/CloudStorage/OneLake-<alias>/
        // See CLAUDE.md and docs/file-provider-domain-nesting.md.
        let expandedBase = NSString(
            string: "~/Library/CloudStorage/OneLake-\(account.alias)"
        ).expandingTildeInPath
        let url = URL(fileURLWithPath: expandedBase, isDirectory: true)

        // Create on demand — the directory may not exist yet if the File
        // Provider Extension has not registered the domain yet.
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        } catch {
            Self.log.warning(
                "createDirectory for \(url.path, privacy: .public) failed: \(error.localizedDescription, privacy: .public)"
            )
        }

        Self.log.info("Opening Finder at \(url.path, privacy: .public)")
        if !NSWorkspace.shared.open(url) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }
}
