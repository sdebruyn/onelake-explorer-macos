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
import SwiftUI

// MARK: - Singleton controller

@MainActor
final class AboutWindowController: NSObject {
    static let shared = AboutWindowController()

    private var window: NSWindow?

    private override init() { super.init() }

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
        self.window = win
    }
}

// MARK: - About content view

private struct AboutView: View {
    private let version: String
    private let build: String
    private let copyright: String

    init() {
        let info = Bundle.main.infoDictionary ?? [:]
        let v = info["CFBundleShortVersionString"] as? String ?? ""
        let b = info["CFBundleVersion"] as? String ?? ""
        version = v
        build = b

        // Derive the copyright year from the CalVer version prefix ("YYYY.MM.PATCH").
        // Fall back to the current calendar year if the version is not in CalVer form.
        let year: String
        if let yearComponent = v.split(separator: ".").first, yearComponent.count == 4,
           Int(yearComponent) != nil {
            year = String(yearComponent)
        } else {
            year = String(Calendar.current.component(.year, from: Date()))
        }
        copyright = "Copyright © \(year) Debruyn Consultancy BV. MIT licensed."
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
