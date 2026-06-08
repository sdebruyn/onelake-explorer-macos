import CryptoKit
import Foundation

/// Privacy-safe field filtering for OFEM telemetry.
///
/// This is a direct Swift port of `internal/telemetry/redact.go`. The
/// functions here are the **structural** privacy boundary: every property
/// value that flows to the App Insights sink passes through `scrubProperty`
/// (and error codes through `safeErrorCode`) inside `AppInsightsEnvelope`,
/// so a careless or future call site that stuffs a workspace name, file path,
/// or UPN into an event field cannot leak it — the value collapses to
/// `"redacted"` before it leaves the device.
///
/// ### Allowed character set
///
/// `[A-Za-z0-9_.:-]` — deliberately excludes:
/// - `/` and `\` (path separators)
/// - `@` (UPN tell-tale)
/// - whitespace
/// - non-ASCII bytes
///
/// This admits every legitimate OFEM value:
/// - Tenant GUIDs (hex + `-`)
/// - Alias hashes (hex)
/// - Snake_case event names
/// - `"true"` / `"false"`
/// - CalVer strings (`"2026.05.1"`)
/// - Constant error codes (`"AADSTS50079"`)
public enum TelemetryRedaction {
    // MARK: - Constants

    /// Maximum length of a safe error code (mirrors `safeErrorCodeMaxLen`).
    public static let safeErrorCodeMaxLen = 32

    /// Maximum length of any telemetry property value.
    public static let maxPropertyLen = 128

    // MARK: - Public API

    /// Returns the first 8 hex characters of `SHA256(alias)`.
    ///
    /// Mirrors `HashAlias` in `internal/telemetry/redact.go`. The empty
    /// string maps to the empty string so callers can pass through a missing
    /// alias without branching.
    public static func hashAlias(_ alias: String) -> String {
        guard !alias.isEmpty else { return "" }
        let digest = SHA256.hash(data: Data(alias.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return String(hex.prefix(8))
    }

    /// Returns `errorCode` unchanged when it is short and drawn only from
    /// the safe charset; collapses everything else to `"redacted"`.
    ///
    /// Mirrors `SafeErrorCode` in `internal/telemetry/redact.go`.
    public static func safeErrorCode(_ errorCode: String) -> String {
        guard !errorCode.isEmpty else { return "" }
        guard errorCode.utf8.count <= safeErrorCodeMaxLen else { return "redacted" }
        return isSafePropertyValue(errorCode) ? errorCode : "redacted"
    }

    /// Returns `value` unchanged when it passes the charset and length
    /// check; collapses to `"redacted"` otherwise.
    ///
    /// Mirrors `scrubProperty` in `internal/telemetry/redact.go`.
    public static func scrubProperty(_ value: String) -> String {
        guard !value.isEmpty else { return "" }
        guard value.utf8.count <= maxPropertyLen else { return "redacted" }
        return isSafePropertyValue(value) ? value : "redacted"
    }

    // MARK: - Private

    /// Returns `true` when every byte of `value` is in `[A-Za-z0-9_.:-]`.
    private static func isSafePropertyValue(_ value: String) -> Bool {
        value.utf8.allSatisfy { isSafeByte($0) }
    }

    /// Reports whether `c` is in the telemetry value charset.
    private static func isSafeByte(_ c: UInt8) -> Bool {
        switch c {
        case UInt8(ascii: "A")...UInt8(ascii: "Z"): return true
        case UInt8(ascii: "a")...UInt8(ascii: "z"): return true
        case UInt8(ascii: "0")...UInt8(ascii: "9"): return true
        case UInt8(ascii: "_"), UInt8(ascii: "."),
             UInt8(ascii: ":"), UInt8(ascii: "-"): return true
        default: return false
        }
    }
}
