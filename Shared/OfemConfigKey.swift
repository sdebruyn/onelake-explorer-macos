// OfemConfigKey.swift
// Canonical vocabulary of setConfig(key:value:) dotted keys, shared by the
// host (MenuStatusModel's debounced setters) and the FPE
// (OfemClientControlService's setConfig switch).
//
// This vocabulary used to be defined three times — a host-side enum of
// String constants, an FPE-side switch over string literals, and prose in
// the protocol doc comment — with nothing tying them together. A key added
// on one side but not the others was silently rejected as "unknown key" at
// runtime (xpc-10).
//
// `OfemConfigKey` is a `String`-backed enum (not a namespace of `let`
// constants) specifically so the FPE's setConfig switch can be genuinely
// exhaustive: switching over `OfemConfigKey` with no `default:` arm means
// the compiler rejects the build if a case is ever added here without a
// matching arm added there. (Raw string values still cross the XPC wire —
// `key: String` in the protocol is unchanged — `OfemConfigKey(rawValue:)`
// decodes it back to a case on the FPE side.)
public enum OfemConfigKey: String {
    case cacheMaxSizeGB = "cache.max_size_gb"
    case telemetry
    case netMaxUploads = "net.max_concurrent_uploads_per_account"
    case netMaxDownloads = "net.max_concurrent_downloads_per_account"
    case logLevel = "log.level"
    case syncMaterializedPollIntervalS = "sync.materialized_poll_interval_s"
    case syncSelfHealIntervalM = "sync.self_heal_interval_m"
}
