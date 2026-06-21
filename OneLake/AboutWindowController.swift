// AboutWindowController.swift
// Minimal custom About window that reads version from Bundle.main explicitly.
//
// Motivation: NSApplication.orderFrontStandardAboutPanel reads NSHumanReadableCopyright
// from the in-memory Info.plist. The release build sets that key to
// "Copyright © $(CURRENT_YEAR) Debruyn Consultancy BV. MIT licensed." but
// $(CURRENT_YEAR) is not a standard Xcode build variable — it is never defined —
// so the installed bundle carries an empty year placeholder. The standard panel
// therefore shows "Copyright ©  Debruyn Consultancy BV. MIT licensed." (double space,
// year missing). This window corrects that by computing the year from the CalVer
// version string ("YYYY.MM.PATCH") and building the copyright line in Swift.
//
// Style: matches the sober, native macOS look of SettingsView — no custom chrome,
// fixed size, Cmd-W / close button to dismiss.

import AppKit
import OfemKit
import SwiftUI

// MARK: - Copyright derivation (testable free function)

/// Derives the copyright year from a CalVer version string.
///
/// The version string is expected to be "YYYY.MM.PATCH"; the year component is
/// the first dot-separated token. If the token is a valid 4-digit integer the
/// function returns it as the year; otherwise it falls back to the current
/// calendar year.
///
/// This logic is extracted from `AboutView.init` so it can be unit-tested
/// without a live Bundle.main (host-10). The exact parsing this guards against
/// — the `$(CURRENT_YEAR)` placeholder that produces an empty year — is
/// precisely the kind of regression that benefits from an isolated test.
func copyrightYear(from version: String) -> String {
    if let yearComponent = version.split(separator: ".").first,
       yearComponent.count == 4,
       Int(yearComponent) != nil
    {
        return String(yearComponent)
    }
    return String(Calendar.current.component(.year, from: Date()))
}

/// Builds the full copyright line for `version`.
func copyrightString(version: String) -> String {
    "Copyright © \(copyrightYear(from: version)) Debruyn Consultancy BV. MIT licensed."
}

// MARK: - Singleton controller

@MainActor
final class AboutWindowController: NSObject {
    static let shared = AboutWindowController()

    private var window: NSWindow?

    override private init() {
        super.init()
    }

    func show() {
        if let existing = window, existing.isVisible {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let hostingView = NSHostingView(rootView: AboutView())
        let size = CGSize(width: 300, height: 220)
        hostingView.frame = NSRect(origin: .zero, size: size)

        let win = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        win.title = "About OFEM"
        win.isReleasedWhenClosed = false
        win.contentView = hostingView
        // Cmd-W closes the panel: NSPanel routes key events through the
        // responder chain when canBecomeKey is true (default for NSPanel).
        win.center()
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window = win
    }
}

// MARK: - About content view

private struct AboutView: View {
    private let version: String
    private let build: String
    private let copyright: String
    private let buildTimestamp: String?

    init() {
        let info = Bundle.main.infoDictionary ?? [:]
        let v = info["CFBundleShortVersionString"] as? String ?? ""
        let b = info["CFBundleVersion"] as? String ?? ""
        version = v
        build = b
        // Delegate year/copyright derivation to the testable free function.
        copyright = copyrightString(version: v)
        // Build timestamp is only shown in DEBUG builds; always nil in release.
        #if DEBUG
            buildTimestamp = BuildInfo.buildTimestamp
        #else
            buildTimestamp = nil
        #endif
    }

    var body: some View {
        VStack(spacing: 0) {
            // App icon
            if let icon = NSApp.applicationIconImage {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 64, height: 64)
                    .padding(.top, 24)
                    .padding(.bottom, 8)
            }

            // App name
            Text("OneLake Explorer for macOS")
                .font(.headline)
                .multilineTextAlignment(.center)

            // Version line — show build number only when it differs from version
            Group {
                if !version.isEmpty {
                    if build.isEmpty || build == version {
                        Text("Version \(version)")
                    } else {
                        Text("Version \(version) (\(build))")
                    }
                }
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .padding(.top, 2)

            // Build timestamp — DEBUG builds only, so dev can confirm which
            // binary is running without checking logs.
            if let ts = buildTimestamp {
                Text("Built \(ts)")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.top, 1)
            }

            Spacer()

            // Copyright
            Text(copyright)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)
                .padding(.bottom, 20)
        }
        .frame(width: 300, height: 220)
    }
}
