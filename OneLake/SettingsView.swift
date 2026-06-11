// SettingsView.swift
// The Settings scene the host app exposes via SwiftUI's Settings { … }
// scene. Layout follows System Settings conventions: LabeledContent rows
// inside Form sections (`.grouped` style), values right-aligned, controls
// sized for inline reading. Every config write goes through MenuStatusModel's
// debounced setters so dragging a Slider or holding a Stepper arrow does
// not flood the FPE with config.set calls.
//
// Hard rule: the user must never need to hand-edit the TOML config file.
// There is no "Open Config File" affordance anywhere in this window or
// in the slimmed-down menu-bar dropdown.

import AppKit
import OfemKit
import SwiftUI

/// The Settings scene's root tab container.
struct SettingsView: View {
    @ObservedObject private var model = MenuStatusModel.shared
    @ObservedObject private var loginItem = LoginItemManager.shared

    var body: some View {
        TabView {
            GeneralSettingsTab(model: model, loginItem: loginItem)
                .tabItem { Label("General", systemImage: "gearshape") }

            CacheSettingsTab(model: model)
                .tabItem { Label("Storage", systemImage: "internaldrive") }

            NetworkSettingsTab(model: model)
                .tabItem { Label("Network", systemImage: "network") }

            AdvancedSettingsTab(model: model)
                .tabItem { Label("Advanced", systemImage: "slider.horizontal.3") }
        }
        // A fixed frame keeps the window the same size between tabs;
        // SwiftUI's default would shrink to fit each tab's content,
        // which makes the chrome feel jumpy.
        .frame(width: 520, height: 340)
        .onAppear {
            model.refresh()
            loginItem.refresh()
        }
    }
}

// MARK: - General

private struct GeneralSettingsTab: View {
    @ObservedObject var model: MenuStatusModel
    @ObservedObject var loginItem: LoginItemManager

    var body: some View {
        Form {
            Section {
                Toggle(isOn: Binding(
                    get: { loginItem.isRegistered },
                    set: { _ in loginItem.toggle() }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Open at Login")
                        Text("Start OneLake automatically when you sign in.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)

                Toggle(isOn: Binding(
                    get: { model.telemetryEnabled },
                    set: { model.setTelemetry(enabled: $0) }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Send Anonymous Telemetry")
                        Text("Tenant IDs only. Usernames, workspace names and file paths are never sent.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)
                .disabled(!model.isRunning)
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
    }
}

// MARK: - Storage

private struct CacheSettingsTab: View {
    @ObservedObject var model: MenuStatusModel
    @State private var showingClearConfirm = false

    /// SwiftUI Slider is Double-backed; we round on write so the visible
    /// number snaps to an integer GB without rendering tick marks under
    /// the track (which `step: 1` would). The model clamps to [1, 100]
    /// and debounces the IPC write at 750 ms.
    private var sliderBinding: Binding<Double> {
        Binding(
            get: { Double(max(1, model.cacheMaxSizeGB)) },
            set: { model.setCacheLimitGB(Int($0.rounded())) }
        )
    }

    var body: some View {
        Form {
            Section {
                LabeledContent {
                    HStack(spacing: 12) {
                        Slider(value: sliderBinding, in: 1...100)
                            .controlSize(.small)
                            .frame(minWidth: 240)
                        Text("\(currentLimitGB) GB")
                            .font(.body.monospacedDigit())
                            .foregroundStyle(.primary)
                            .frame(minWidth: 56, alignment: .trailing)
                    }
                } label: {
                    Text("Storage limit")
                }
                .disabled(!model.isRunning)

                LabeledContent {
                    VStack(alignment: .trailing, spacing: 6) {
                        if model.cacheBytes >= 0 && model.cacheMaxSizeGB > 0 {
                            ProgressView(value: usageFraction)
                                .progressViewStyle(.linear)
                                .tint(usageTint)
                                .frame(width: 240)
                            Text(usageLabel)
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        } else {
                            Text("Not measured yet")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                } label: {
                    Text("In use")
                }
            } footer: {
                Text("OneLake files stream from the cloud on demand. Cached blobs are evicted oldest-first as the cache approaches the limit.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Clear all cached data")
                        Text("Files will re-download from OneLake on next access.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Clear Cache…") {
                        showingClearConfirm = true
                    }
                    .disabled(!model.isRunning)
                }
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .confirmationDialog(
            "Clear all cached data?",
            isPresented: $showingClearConfirm,
            titleVisibility: .visible
        ) {
            Button("Clear Cache", role: .destructive) {
                model.cacheClear()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes all locally cached OneLake blobs. Files will be re-downloaded from OneLake on next access.")
        }
    }

    private var currentLimitGB: Int { max(1, model.cacheMaxSizeGB) }

    /// Used / limit clamped to [0, 1]. A transient overage during eviction
    /// would otherwise render as an overflowing bar.
    private var usageFraction: Double {
        let limitBytes = Double(currentLimitGB) * 1024 * 1024 * 1024
        guard limitBytes > 0 else { return 0 }
        return min(1.0, max(0.0, Double(model.cacheBytes) / limitBytes))
    }

    private var usageTint: Color {
        switch usageFraction {
        case ..<0.75: return .accentColor
        case ..<0.95: return .orange
        default:      return .red
        }
    }

    private var usageLabel: String {
        let f = ByteCountFormatter()
        f.allowedUnits = [.useGB, .useMB, .useKB]
        f.countStyle = .binary
        f.allowsNonnumericFormatting = false
        let used = f.string(fromByteCount: model.cacheBytes)
        return "\(used) of \(currentLimitGB) GB"
    }
}

// MARK: - Network

private struct NetworkSettingsTab: View {
    @ObservedObject var model: MenuStatusModel

    /// True once the FPE status has been fetched and the net values are loaded.
    /// The controls are read-only until then to prevent the hardcoded
    /// display fallbacks from being written back before real values arrive.
    private var netLoaded: Bool {
        model.netMaxUploads > 0 && model.netMaxDownloads > 0
    }

    private var uploadsBinding: Binding<Int> {
        Binding(
            get: { model.netMaxUploads },
            set: { model.setNetMaxUploads($0) }
        )
    }

    private var downloadsBinding: Binding<Int> {
        Binding(
            get: { model.netMaxDownloads },
            set: { model.setNetMaxDownloads($0) }
        )
    }

    var body: some View {
        Form {
            Section {
                if netLoaded {
                    concurrencyRow(
                        title: "Parallel uploads",
                        detail: "Maximum simultaneous outgoing transfers per account.",
                        value: uploadsBinding,
                        range: 1...16
                    )
                    concurrencyRow(
                        title: "Parallel downloads",
                        detail: "Maximum simultaneous incoming transfers per account.",
                        value: downloadsBinding,
                        range: 1...32
                    )
                } else {
                    LabeledContent("Parallel uploads") {
                        Text("Loading…").foregroundStyle(.secondary)
                    }
                    LabeledContent("Parallel downloads") {
                        Text("Loading…").foregroundStyle(.secondary)
                    }
                }
            } footer: {
                Text("Lower these on metered networks. Raise the download count when Finder routinely opens many cloud-only files at once.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
    }

    @ViewBuilder
    private func concurrencyRow(
        title: String,
        detail: String,
        value: Binding<Int>,
        range: ClosedRange<Int>
    ) -> some View {
        LabeledContent {
            HStack(spacing: 8) {
                Text("\(value.wrappedValue)")
                    .font(.body.monospacedDigit())
                    .frame(minWidth: 24, alignment: .trailing)
                Stepper("", value: value, in: range, step: 1)
                    .labelsHidden()
            }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .disabled(!model.isRunning)
    }
}

// MARK: - Advanced

private struct AdvancedSettingsTab: View {
    @ObservedObject var model: MenuStatusModel

    /// True once the FPE status has been fetched and the log level is loaded.
    private var logLevelLoaded: Bool { !model.logLevel.isEmpty }

    private var logLevelBinding: Binding<String> {
        Binding(
            get: { model.logLevel },
            set: { model.setLogLevel($0) }
        )
    }

    var body: some View {
        Form {
            Section {
                if logLevelLoaded {
                    Picker(selection: logLevelBinding) {
                        Text("Debug").tag("debug")
                        Text("Info").tag("info")
                        Text("Warning").tag("warn")
                        Text("Error").tag("error")
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Log level")
                            Text("Higher levels keep logs small; Debug helps when reporting an issue.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .pickerStyle(.menu)
                    .disabled(!model.isRunning)
                } else {
                    LabeledContent("Log level") {
                        Text("Loading…").foregroundStyle(.secondary)
                    }
                }

                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Logs folder")
                        Text("Open the log folder in Finder.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Reveal in Finder") {
                        openLogsFolder()
                    }
                    .disabled(!model.isRunning)
                }
            }

            Section {
                LabeledContent("App version") {
                    Text("v\(BuildInfo.version)")
                        .font(.body.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
    }

    private func openLogsFolder() {
        let logDir = OfemPaths().logDir
        if NSWorkspace.shared.open(logDir) { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(logDir.path(percentEncoded: false), forType: .string)
    }
}
