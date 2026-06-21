import Foundation

/// Shared redaction boundary for on-disk log lines and telemetry envelopes.
///
/// Both the `OfemLogger` JSON file sink and the telemetry envelope path route
/// every free-form string through this module before it leaves the process.
///
/// ### Log message contract
///
/// Log **messages** are developer-authored static or format strings that must
/// never contain dynamic or PII-bearing data.  `OfemLogger` writes the `msg`
/// field verbatim to the on-disk JSON file — no hashing or scrubbing is
/// applied to it.  All dynamic or PII-bearing data (paths, UPNs, workspace
/// names, aliases) must be passed as **metadata values**, which are scrubbed
/// via `scrubLogValue(_:)` before the JSON sink writes them.  On the
/// `os.Logger` side, dynamic interpolations use `.private` so they are
/// redacted in the system log on non-development builds.
///
/// ### Log metadata redaction
///
/// Metadata key–value pairs attached to log calls are routed through
/// `scrubLogValue(_:)` before the JSON file sink writes them **in release
/// builds only**.  In DEBUG builds the file sink writes values verbatim so
/// developers can inspect real paths, UPNs, and workspace names locally.
/// Values that pass the safe-charset test are written verbatim in both
/// configurations; values that fail (paths, UPNs, workspace names) are
/// collapsed to `"redacted"` in release builds.
public enum Privacy {
    // MARK: - Constants

    /// Maximum byte length for a metadata value to be considered for
    /// pass-through (longer values are always redacted).
    public static let maxMetaValueLen = 256

    // MARK: - Log metadata

    /// Returns `value` when it consists entirely of characters in the safe
    /// charset `[A-Za-z0-9_.:-]` and is within the length cap; otherwise
    /// returns `"redacted"`.
    ///
    /// Use for key/value pairs in `OfemLogger.info(_:metadata:)` etc.  The
    /// log *message* itself should always be a static string constant supplied
    /// by the call site — dynamic content belongs in metadata.
    public static func scrubLogValue(_ value: String) -> String {
        guard !value.isEmpty else { return "" }
        guard value.utf8.count <= maxMetaValueLen else { return "redacted" }
        return isSafe(value) ? value : "redacted"
    }

    // MARK: - GUID validation

    /// Returns `true` when `s` matches the UUID/GUID format
    /// `xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx` (8-4-4-4-12 hex digits,
    /// where each digit is `0-9`, `a-f`, or `A-F`).
    ///
    /// Used to validate tenant IDs before they are written to telemetry
    /// envelopes.
    public static func isGUID(_ s: String) -> Bool {
        guard s.utf8.count == 36 else { return false }
        let pattern: [UInt8] = [
            8, UInt8(ascii: "-"), 4, UInt8(ascii: "-"), 4,
            UInt8(ascii: "-"), 4, UInt8(ascii: "-"), 12,
        ]
        var idx = s.startIndex
        // Walk the expected pattern: groups of hex digits separated by '-'.
        var groupIdx = 0
        while groupIdx < pattern.count {
            let p = pattern[groupIdx]
            groupIdx += 1
            if p == UInt8(ascii: "-") {
                guard idx < s.endIndex, s[idx] == "-" else { return false }
                idx = s.index(after: idx)
            } else {
                let count = Int(p)
                for _ in 0 ..< count {
                    guard idx < s.endIndex, s[idx].isHexDigit else { return false }
                    idx = s.index(after: idx)
                }
            }
        }
        return idx == s.endIndex
    }

    // MARK: - Private

    /// Returns `true` when every byte of `value` is in `[A-Za-z0-9_.:-]`.
    private static func isSafe(_ value: String) -> Bool {
        value.utf8.allSatisfy { isSafeByte($0) }
    }

    private static func isSafeByte(_ c: UInt8) -> Bool {
        switch c {
        case UInt8(ascii: "A") ... UInt8(ascii: "Z"): true
        case UInt8(ascii: "a") ... UInt8(ascii: "z"): true
        case UInt8(ascii: "0") ... UInt8(ascii: "9"): true
        case UInt8(ascii: "_"), UInt8(ascii: "."),
             UInt8(ascii: ":"), UInt8(ascii: "-"): true
        default: false
        }
    }
}
