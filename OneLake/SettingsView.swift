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
            loginItem.refresh()
            // The engine-status poll is now gated on visibility (E3): the
            // low-frequency background loop that used to keep this window's
            // cache/network/interval values current on its own is coarse
            // (~75s), so refresh immediately on appear rather than showing
            // a stale snapshot, and register this window as a high-frequency
            // surface for as long as it stays open.
            model.refresh()
            model.surfaceBecameVisible()
        }
        .onDisappear {
            model.surfaceBecameHidden()
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
                .disabled(!model.hasAccounts)
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

    /// True once the FPE has returned a non-zero cacheMaxSizeGB.
    /// The slider is hidden until then so the `max(1, …)` placeholder
    /// value cannot be written back before real values arrive.
    private var cacheLoaded: Bool {
        model.cacheMaxSizeGB > 0
    }

    /// SwiftUI Slider is Double-backed; we round on write so the visible
    /// number snaps to an integer GB without rendering tick marks under
    /// the track (which `step: 1` would). The model clamps to [1, 100]
    /// and debounces the IPC write at 750 ms.
    ///
    /// The binding reads the model directly — no `max(1, …)` fallback —
    /// so this is only active when `cacheLoaded` is true (cacheMaxSizeGB > 0).
    private var sliderBinding: Binding<Double> {
        Binding(
            get: { Double(model.cacheMaxSizeGB) },
            set: { model.setCacheLimitGB(Int($0.rounded())) }
        )
    }

    var body: some View {
        Form {
            Section {
                LabeledContent {
                    if cacheLoaded {
                        HStack(spacing: 12) {
                            Slider(value: sliderBinding, in: 1 ... 100)
                                .controlSize(.small)
                                .frame(minWidth: 240)
                            Text("\(model.cacheMaxSizeGB) GB")
                                .font(.body.monospacedDigit())
                                .foregroundStyle(.primary)
                                .frame(minWidth: 56, alignment: .trailing)
                        }
                    } else {
                        Text("Loading…").foregroundStyle(.secondary)
                    }
                } label: {
                    Text("Storage limit")
                }
                .disabled(!model.hasAccounts)

                LabeledContent {
                    VStack(alignment: .trailing, spacing: 6) {
                        if model.cacheBytes >= 0, model.cacheMaxSizeGB > 0 {
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
                    .disabled(!model.hasAccounts)
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

    /// Used / limit clamped to [0, 1]. A transient overage during eviction
    /// would otherwise render as an overflowing bar.
    private var usageFraction: Double {
        // Use cacheMaxBytes (the byte-level value kept in sync by the model)
        // instead of re-deriving from cacheMaxSizeGB to avoid the GiB literal.
        let limitBytes = Double(model.cacheMaxBytes)
        guard limitBytes > 0 else { return 0 }
        return min(1.0, max(0.0, Double(model.cacheBytes) / limitBytes))
    }

    private var usageTint: Color {
        switch usageFraction {
        case ..<0.75: .accentColor
        case ..<0.95: .orange
        default: .red
        }
    }

    private var usageLabel: String {
        // Use the same binary formatter configuration as MenuStatusModel.formattedCache
        // so the two surfaces display consistent representations of the same number.
        let used = ByteCountFormatter.string(fromByteCount: model.cacheBytes, countStyle: .binary)
        return "\(used) of \(model.cacheMaxSizeGB) GB"
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
                        range: 1 ... 16
                    )
                    concurrencyRow(
                        title: "Parallel downloads",
                        detail: "Maximum simultaneous incoming transfers per account.",
                        value: downloadsBinding,
                        range: 1 ... 32
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
        .disabled(!model.hasAccounts)
    }
}

// MARK: - Advanced

private struct AdvancedSettingsTab: View {
    @ObservedObject var model: MenuStatusModel

    /// True once the FPE status has been fetched and the log level is loaded.
    private var logLevelLoaded: Bool {
        !model.logLevel.isEmpty
    }

    private var logLevelBinding: Binding<String> {
        Binding(
            get: { model.logLevel },
            set: { model.setLogLevel($0) }
        )
    }

    /// True once the FPE status has been fetched and the poll interval is loaded.
    private var pollIntervalLoaded: Bool {
        model.materializedPollIntervalS > 0
    }

    private var pollIntervalBinding: Binding<Int> {
        // `pollIntervalLoaded` guards the Stepper; this binding is only
        // evaluated when materializedPollIntervalS > 0.
        Binding(
            get: { model.materializedPollIntervalS },
            set: { model.setMaterializedPollInterval($0) }
        )
    }

    /// True once the FPE status has been fetched and the self-heal interval is loaded.
    /// Uses the dedicated `engineStatusReceived` flag so this does not implicitly
    /// depend on an unrelated sibling field (e.g. `materializedPollIntervalS`):
    /// `selfHealIntervalM` can legitimately be 0 (disabled) even after the FPE
    /// has replied, so a non-zero proxy would be incorrect.
    private var selfHealLoaded: Bool {
        model.engineStatusReceived
    }

    /// Whether self-heal is currently enabled (non-zero interval).
    private var selfHealEnabled: Bool {
        model.selfHealIntervalM > 0
    }

    private var selfHealIntervalBinding: Binding<Int> {
        Binding(
            get: { model.selfHealIntervalM > 0 ? model.selfHealIntervalM : SyncConfig.defaultSelfHealIntervalM },
            set: { model.setSelfHealInterval($0) }
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
                    .disabled(!model.hasAccounts)
                } else {
                    LabeledContent("Log level") {
                        Text("Loading…").foregroundStyle(.secondary)
                    }
                }

                if pollIntervalLoaded {
                    LabeledContent {
                        HStack(spacing: 8) {
                            Text("\(model.materializedPollIntervalS) s")
                                .font(.body.monospacedDigit())
                            Stepper("", value: pollIntervalBinding,
                                    in: SyncConfig.minMaterializedPollIntervalS ... SyncConfig.maxMaterializedPollIntervalS,
                                    step: 15)
                                .labelsHidden()
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Content refresh interval")
                            // swiftlint:disable:next line_length
                            Text("How often open folders are polled for new files (\(SyncConfig.minMaterializedPollIntervalS)–\(SyncConfig.maxMaterializedPollIntervalS) s).")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .disabled(!model.hasAccounts)
                } else {
                    LabeledContent("Content refresh interval") {
                        Text("Loading…").foregroundStyle(.secondary)
                    }
                }

                if selfHealLoaded {
                    LabeledContent {
                        HStack(spacing: 8) {
                            Toggle("", isOn: Binding(
                                get: { selfHealEnabled },
                                set: { enabled in
                                    model.setSelfHealInterval(
                                        enabled ? SyncConfig.defaultSelfHealIntervalM : 0
                                    )
                                }
                            ))
                            .labelsHidden()
                            .toggleStyle(.switch)
                            if selfHealEnabled {
                                Stepper("", value: selfHealIntervalBinding,
                                        in: SyncConfig.minSelfHealIntervalM ... SyncConfig.maxSelfHealIntervalM,
                                        step: 5)
                                    .labelsHidden()
                                Text("\(model.selfHealIntervalM) min")
                                    .font(.body.monospacedDigit())
                                    .frame(minWidth: 56, alignment: .trailing)
                            }
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Self-heal full refresh")
                            // swiftlint:disable:next line_length
                            Text("Periodically force a full re-list of open folders as insurance against missed changes (\(SyncConfig.minSelfHealIntervalM)–\(SyncConfig.maxSelfHealIntervalM) min).")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .disabled(!model.hasAccounts)
                } else {
                    LabeledContent("Self-heal full refresh") {
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
                    .disabled(!model.hasAccounts)
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
        let paths = OfemPaths()
        let logDir = paths.logDir
        // Create the log directory (and siblings) if it doesn't exist yet so
        // the reveal always succeeds even before the engine has written its first
        // log entry.
        try? paths.ensureDirectories()
        // activateFileViewerSelecting is the reliable way to open and select a
        // specific directory in Finder; open() returns false when the directory
        // was absent at call time, which is the root cause of the silent no-op.
        NSWorkspace.shared.activateFileViewerSelecting([logDir])
    }
}
