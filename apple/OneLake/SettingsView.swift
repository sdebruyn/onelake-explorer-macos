// SettingsView.swift
// The Settings scene the host app exposes via SwiftUI's Settings { … }
// scene. It replaces the per-knob menu items the menu-bar dropdown used
// to host (Cache submenu, Telemetry toggle, Open at Login toggle, Open
// Logs / Open Config) with a single window of four tabs:
//
//   • General  — Open at Login, Send Anonymous Telemetry
//   • Cache    — Storage limit slider + usage gauge + Clear Cache
//   • Network  — Parallel uploads / downloads per account
//   • Advanced — Log level + read-only daemon version
//
// Hard rule: the user must never need to hand-edit the TOML config file.
// There is no "Open Config File" affordance anywhere in this window or
// in the slimmed-down menu-bar dropdown. The TOML still exists on disk
// (the daemon owns it) — it is just no longer a user-facing surface.
//
// Writes go through the same MenuStatusModel the menu-bar dropdown uses
// (single source of truth), which itself debounces rapid mutations
// (Slider / Stepper drags) before they cross the IPC seam.

import AppKit
import SwiftUI

/// The Settings scene's root tab container. The host app wires it as the
/// SwiftUI `Settings { SettingsView() }` scene so Cmd+, and the standard
/// "Preferences…" menu item both target it.
struct SettingsView: View {
    /// Single shared model — same instance the menu bar reads, so changes
    /// land in both places immediately without ad-hoc syncing.
    @ObservedObject private var model = MenuStatusModel.shared
    /// Read-only observed singleton; @ObservedObject does not own the
    /// lifetime (the singleton handles that).
    @ObservedObject private var loginItem = LoginItemManager.shared

    var body: some View {
        TabView {
            GeneralSettingsTab(model: model, loginItem: loginItem)
                .tabItem { Label("General", systemImage: "gearshape") }

            CacheSettingsTab(model: model)
                .tabItem { Label("Cache", systemImage: "internaldrive") }

            NetworkSettingsTab(model: model)
                .tabItem { Label("Network", systemImage: "network") }

            AdvancedSettingsTab(model: model)
                .tabItem { Label("Advanced", systemImage: "slider.horizontal.3") }
        }
        // A fixed frame keeps the window size consistent between tabs;
        // SwiftUI's default sizing would shrink the window whenever a
        // tab with less content is shown, which looks janky.
        .frame(width: 460, height: 320)
        .onAppear {
            // The Settings window is reached without the menu-bar dropdown
            // opening first, so it must trigger its own refresh — otherwise
            // the first time the user hits Cmd+, the tabs show stale or
            // zero values from before the auto-refresh timer ran.
            model.refresh()
            loginItem.refresh()
        }
    }
}

// MARK: - General

/// First tab. Hosts the two boolean toggles that used to live in the
/// menu-bar dropdown — Open at Login (SMAppService) and Send Anonymous
/// Telemetry (config.set telemetry).
private struct GeneralSettingsTab: View {
    @ObservedObject var model: MenuStatusModel
    @ObservedObject var loginItem: LoginItemManager

    var body: some View {
        Form {
            // .toggleStyle(.switch) is the macOS-native control here — the
            // platform default (.checkbox in a Form) would render fine but
            // a switch reads as "this changes a setting that takes effect
            // now," which is exactly the contract for both rows.
            Toggle(
                "Open at Login",
                isOn: Binding(
                    get: { loginItem.isRegistered },
                    // The toggle's intent is "make it match the new value";
                    // LoginItemManager exposes a single toggle() that flips
                    // whichever way it currently sits. Calling it on every
                    // change is safe because SwiftUI only fires `set` when
                    // the user actually flipped the switch.
                    set: { _ in loginItem.toggle() }
                )
            )
            .toggleStyle(.switch)

            Toggle(
                "Send Anonymous Telemetry",
                isOn: Binding(
                    get: { model.telemetryEnabled },
                    set: { model.setTelemetry(enabled: $0) }
                )
            )
            .toggleStyle(.switch)
            .disabled(!model.isRunning)
        }
        .formStyle(.grouped)
        .padding()
    }
}

// MARK: - Cache

/// Second tab. Replaces the menubar Cache submenu (Stepper + Clear Cache).
/// The Slider's value is bound to a clamped Int — SwiftUI Slider only
/// publishes the live position, so the model's own debounce takes care of
/// not flooding the daemon during a drag.
private struct CacheSettingsTab: View {
    @ObservedObject var model: MenuStatusModel
    @State private var showingClearConfirm = false

    /// SwiftUI Slider is Double-backed; this projects it onto the model's
    /// integer GB value. Reads round to the nearest integer; writes go
    /// through `setCacheLimitGB`, which clamps to [1, 100] and debounces
    /// the IPC write internally (750 ms — see MenuStatusModel).
    private var sliderBinding: Binding<Double> {
        Binding(
            get: { Double(max(1, model.cacheMaxSizeGB)) },
            set: { model.setCacheLimitGB(Int($0.rounded())) }
        )
    }

    var body: some View {
        Form {
            Section("Storage Limit") {
                VStack(alignment: .leading, spacing: 6) {
                    // Slider + label. The label is a separate Text so the
                    // value reads at full size; embedding it in the Slider's
                    // own label slot would render it small and grey.
                    HStack {
                        Text("1 GB")
                            .foregroundStyle(.secondary)
                            .font(.caption)
                        Slider(value: sliderBinding, in: 1...100, step: 1)
                            .disabled(!model.isRunning)
                        Text("100 GB")
                            .foregroundStyle(.secondary)
                            .font(.caption)
                    }
                    Text(currentLimitLabel)
                        .font(.callout.weight(.medium))
                        .frame(maxWidth: .infinity, alignment: .center)
                }
            }

            Section("Current Usage") {
                // ProgressView gives a familiar disk-usage feel. When the
                // daemon hasn't reported a cache size yet (cacheBytes < 0)
                // the bar is hidden and a placeholder explains why.
                if model.cacheBytes >= 0 && model.cacheMaxSizeGB > 0 {
                    VStack(alignment: .leading, spacing: 4) {
                        ProgressView(value: usageFraction)
                            .progressViewStyle(.linear)
                        Text(usageLabel)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text("Cache size unknown")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                }
            }

            Section {
                HStack {
                    Spacer()
                    Button("Clear Cache…", role: .destructive) {
                        showingClearConfirm = true
                    }
                    .disabled(!model.isRunning)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        // .confirmationDialog is the SwiftUI-idiomatic destructive prompt
        // and integrates with the Settings window without requiring an
        // NSAlert manual activate() dance.
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

    private var currentLimitLabel: String {
        let gb = max(1, model.cacheMaxSizeGB)
        return "Limit: \(gb) GB"
    }

    /// Used-vs-limit fraction in [0, 1]. Clamped so a transient spike
    /// where the cache briefly exceeds the limit (eviction races) does
    /// not render an overflowing bar.
    private var usageFraction: Double {
        let limitBytes = Double(model.cacheMaxSizeGB) * 1024 * 1024 * 1024
        guard limitBytes > 0 else { return 0 }
        return min(1.0, max(0.0, Double(model.cacheBytes) / limitBytes))
    }

    private var usageLabel: String {
        let usedFormatter = ByteCountFormatter()
        usedFormatter.allowedUnits = [.useGB, .useMB]
        usedFormatter.countStyle = .binary
        usedFormatter.allowsNonnumericFormatting = false
        let used = usedFormatter.string(fromByteCount: model.cacheBytes)
        return "\(used) of \(model.cacheMaxSizeGB) GB used"
    }
}

// MARK: - Network

/// Third tab. Two Steppers backing the per-account upload / download
/// concurrency knobs. Both go through MenuStatusModel's debounced setters
/// so holding the arrow does not flood the daemon with config.set calls.
private struct NetworkSettingsTab: View {
    @ObservedObject var model: MenuStatusModel

    /// Same Double-to-Int projection trick as CacheSettingsTab — Stepper's
    /// own integer overload would force us to materialise the snapshot
    /// value into a @State and reconcile it on every refresh, which gets
    /// ugly fast.
    private var uploadsBinding: Binding<Int> {
        Binding(
            get: { model.netMaxUploads > 0 ? model.netMaxUploads : 4 },
            set: { model.setNetMaxUploads($0) }
        )
    }

    private var downloadsBinding: Binding<Int> {
        Binding(
            get: { model.netMaxDownloads > 0 ? model.netMaxDownloads : 8 },
            set: { model.setNetMaxDownloads($0) }
        )
    }

    var body: some View {
        Form {
            Section("Concurrency") {
                Stepper(
                    value: uploadsBinding,
                    in: 1...16,
                    step: 1
                ) {
                    Text("Parallel uploads per account: \(uploadsBinding.wrappedValue)")
                }
                .disabled(!model.isRunning)

                Stepper(
                    value: downloadsBinding,
                    in: 1...32,
                    step: 1
                ) {
                    Text("Parallel downloads per account: \(downloadsBinding.wrappedValue)")
                }
                .disabled(!model.isRunning)
            }

            Section {
                Text("Lower these on metered networks. Raise the download count when Finder routinely opens many cloud-only files at once.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

// MARK: - Advanced

/// Fourth tab. Log level + read-only daemon version + an "Open Logs
/// Folder" affordance (the one piece of the old menu-bar Open-X group
/// that survives, since it's genuinely useful when reporting a bug).
/// The install ID is intentionally NOT shown — config.snapshot scrubs it
/// for telemetry-pseudonymisation reasons and we don't relax that here.
private struct AdvancedSettingsTab: View {
    @ObservedObject var model: MenuStatusModel

    /// One of the four daemon-accepted levels. The Picker writes into the
    /// model only when the user makes a new selection (no rapid bursts),
    /// so no debounce is needed.
    private var logLevelBinding: Binding<String> {
        Binding(
            get: { model.logLevel.isEmpty ? "info" : model.logLevel },
            set: { model.setLogLevel($0) }
        )
    }

    var body: some View {
        Form {
            Section("Logging") {
                Picker("Log level", selection: logLevelBinding) {
                    Text("Debug").tag("debug")
                    Text("Info").tag("info")
                    Text("Warn").tag("warn")
                    Text("Error").tag("error")
                }
                .pickerStyle(.menu)
                .disabled(!model.isRunning)

                Button("Open Logs Folder") {
                    openLogsFolder()
                }
                .disabled(!model.isRunning || model.paths.logDir.isEmpty)
            }

            Section("About") {
                LabeledContent("Daemon version", value: model.daemonVersion.isEmpty ? "—" : model.daemonVersion)
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private func openLogsFolder() {
        let path = model.paths.logDir
        guard !path.isEmpty else { return }
        let url = URL(fileURLWithPath: path, isDirectory: true)
        if NSWorkspace.shared.open(url) { return }
        // The directory may not exist yet (daemon hasn't written logs);
        // fall back to copying the path so the user can navigate to the
        // parent manually — same fallback the old menu-bar item used.
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
    }
}
