// OfemConstants.swift
// Compile-time constants shared across the host-app target.
//
// Centralises strings that were previously hand-typed in multiple files:
//   - Logger subsystem (was in 11 host files)
//   - Window scene identifiers
//   - Config key names used by MenuStatusModel and the FPE parser

import Foundation

// MARK: - Subsystem

/// Logger subsystem used by every Logger in the host-app target.
let ofemSubsystem = "dev.debruyn.ofem"

// MARK: - Window identifiers

/// Scene id for the "Add Account" window. Must match the `Window(_, id:)` declaration
/// in OneLakeApp and the `openWindow(id:)` call site in MenuBarView.
let ofemAddAccountWindowID = "add-account"

// MARK: - Config keys

/// Config key names for the shared config.toml.
/// Must match the key names the FPE-side OfemConfigStore parses.
enum OfemConfigKey {
    static let cacheMaxSizeGB           = "cache.max_size_gb"
    static let telemetry                = "telemetry"
    static let netMaxUploads            = "net.max_concurrent_uploads_per_account"
    static let netMaxDownloads          = "net.max_concurrent_downloads_per_account"
    static let logLevel                 = "log.level"
}
