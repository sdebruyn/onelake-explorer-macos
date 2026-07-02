// OfemConfigKey.swift
// Canonical vocabulary of setConfig(key:value:) dotted keys, shared by the
// host (MenuStatusModel's debounced setters) and the FPE
// (OfemClientControlService's setConfig switch).
//
// This vocabulary used to be defined three times — a host-side enum, an
// FPE-side switch over string literals, and prose in the protocol doc
// comment — with nothing tying them together. A key added on one side but
// not the others is silently rejected as "unknown key" at runtime (xpc-10).
// Switching on these cases (rather than raw string literals) on both sides
// turns that drift into a compile error.

import Foundation

/// Config key names for the shared config.toml, as sent over
/// `setConfig(key:value:reply:)`. Must match the key names the FPE-side
/// `OfemConfigStore` parses.
public enum OfemConfigKey {
    public static let cacheMaxSizeGB = "cache.max_size_gb"
    public static let telemetry = "telemetry"
    public static let netMaxUploads = "net.max_concurrent_uploads_per_account"
    public static let netMaxDownloads = "net.max_concurrent_downloads_per_account"
    public static let logLevel = "log.level"
    public static let syncMaterializedPollIntervalS = "sync.materialized_poll_interval_s"
    public static let syncSelfHealIntervalM = "sync.self_heal_interval_m"
}
