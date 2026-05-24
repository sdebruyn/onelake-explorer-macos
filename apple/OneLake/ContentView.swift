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

    /// The Go core build version, fetched on view construction by
    /// calling `ofem_core_version()` through the cgo bridge. We copy
    /// the returned C string into a Swift `String` and immediately
    /// hand the buffer back to Go via `ofem_core_string_free` so
    /// nothing leaks across the FFI boundary.
    private let coreVersion: String = Self.loadCoreVersion()

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

            Text("core \(coreVersion)")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.tertiary)
                .accessibilityLabel("OneLake core version \(coreVersion)")

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

    /// Opens `~/Library/CloudStorage/` in Finder — the macOS-managed
    /// parent that every File Provider Extension lands under. Once the
    /// extension is wired up, each OneLake account materialises here as
    /// its own `OneLake-<alias>` folder (shown in the Finder sidebar as
    /// `OneLake — <alias>`). For now opening this path simply shows
    /// the user where their mounts will appear. We create the directory
    /// on demand because it only exists after the user (or some app)
    /// has registered at least one CloudStorage provider — on a fresh
    /// macOS install with no File Provider Extensions ever activated
    /// it is not guaranteed to be there.
    private func openFinderMount() {
        let expanded = NSString(string: "~/Library/CloudStorage").expandingTildeInPath
        let url = URL(fileURLWithPath: expanded)
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        } catch {
            ContentView.log.error("createDirectory failed for \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
        ContentView.log.info("Opening Finder at \(url.path, privacy: .public)")
        let opened = NSWorkspace.shared.open(url)
        ContentView.log.info("NSWorkspace.shared.open returned \(opened, privacy: .public)")
        if !opened {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    /// Calls into the Go core via the cgo bridge to read the linked
    /// `libofemcore.a` build version. Returns `"<unknown>"` if the
    /// bridge somehow hands back a NULL pointer (it shouldn't).
    private static func loadCoreVersion() -> String {
        guard let cString = ofem_core_version() else {
            log.error("ofem_core_version returned NULL")
            return "<unknown>"
        }
        defer { ofem_core_string_free(cString) }
        return String(cString: cString)
    }
}

#Preview {
    ContentView()
}
