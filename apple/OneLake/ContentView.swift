// ContentView.swift
// Minimal landing view for the OneLake host app.

import SwiftUI
import AppKit
import os.log

/// Single-screen landing view shown when the user opens OneLake from
/// `/Applications`. Confirms the bundle wiring (by surfacing the
/// loaded bundle identifier) and gives the user a one-click shortcut
/// to the Finder mount point that the File Provider Extension will
/// own once the sync engine is wired up.
struct ContentView: View {
    private static let log = Logger(subsystem: "dev.debruyn.ofem", category: "ui")

    /// The bundle identifier the running process was loaded under.
    /// Displayed in the UI as a smoke test for the
    /// `PRODUCT_BUNDLE_IDENTIFIER` build setting.
    private var bundleIdentifier: String {
        Bundle.main.bundleIdentifier ?? "<unknown>"
    }

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "cloud.fill")
                .resizable()
                .scaledToFit()
                .frame(width: 64, height: 64)
                .foregroundStyle(.tint)
                .accessibilityHidden(true)

            Text("OneLake")
                .font(.largeTitle.bold())

            Text("Sign in to your OneLake accounts from the menu bar.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Text(bundleIdentifier)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.tertiary)

            Button {
                openFinderMount()
            } label: {
                Label("Open Finder", systemImage: "folder")
            }
            .buttonStyle(.borderedProminent)
            .padding(.top, 8)
        }
        .padding(40)
        .frame(minWidth: 420, minHeight: 320)
    }

    /// Reveals (or creates) the `~/OneLake` parent in Finder. The
    /// File Provider domains will be nested under this path once the
    /// extension is wired up; for now opening the path simply shows
    /// the user where their mounts will appear.
    private func openFinderMount() {
        let expanded = NSString(string: "~/OneLake").expandingTildeInPath
        let url = URL(fileURLWithPath: expanded)
        ContentView.log.info("Opening Finder mount at \(url.path, privacy: .public)")
        NSWorkspace.shared.open(url)
    }
}

#Preview {
    ContentView()
}
