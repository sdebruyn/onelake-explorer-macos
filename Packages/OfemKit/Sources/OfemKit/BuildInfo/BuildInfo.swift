import Foundation

/// Runtime identity for the running OFEM binary.
///
/// `version` is the single canonical CalVer source (engine-05).  It is read
/// from `CFBundleShortVersionString` in `Bundle.main` at runtime, so
/// Xcode-built releases automatically pick up the CalVer string
/// (e.g. `"2026.05.1"`) injected by `xcodebuild MARKETING_VERSION=…` on the
/// release tag.  The `"0.0.0-dev"` fallback is returned in unit-test contexts
/// where `Bundle.main` is the `xctest` runner which carries no version key.
///
/// ## Testability (engine-06)
///
/// The bundle read is isolated in ``version(from:)`` so the parsing + fallback
/// logic can be exercised in unit tests against a synthetic `Bundle`.  The
/// top-level ``version`` property is a convenience that calls
/// ``version(from:)`` with `Bundle.main`.
public enum BuildInfo {
    // MARK: - Version

    /// The CalVer release string (e.g. `"2026.05.1"`).
    ///
    /// Reads `CFBundleShortVersionString` from `Bundle.main`. Falls back to
    /// `"0.0.0-dev"` when the key is absent (xctest, command-line tool builds,
    /// or un-versioned debug builds).
    ///
    /// This is the **single canonical version source** for the entire package
    /// (engine-05).  Do not introduce additional version constants.
    public static let version: String = version(from: .main)

    /// Returns the CalVer string from the given bundle, or `"0.0.0-dev"`.
    ///
    /// Exposed for testing so the parse + fallback path can be exercised
    /// with a synthetic `Bundle` (engine-06).
    ///
    /// - Parameter bundle: The bundle to read `CFBundleShortVersionString` from.
    /// - Returns: The version string, or `"0.0.0-dev"` if the key is absent.
    public static func version(from bundle: Bundle) -> String {
        bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString")
            as? String ?? "0.0.0-dev"
    }

    // MARK: - Build timestamp

    /// The ISO-8601 UTC build timestamp injected by the build system
    /// (e.g. `"2026-06-20T14:03:12Z"`).
    ///
    /// Reads `OFEMBuildTimestamp` from `Bundle.main`, which the
    /// `inject-build-timestamp.sh` build phase writes into the compiled
    /// bundle's Info.plist at build time. Returns `nil` when the key is
    /// absent (xctest runner, command-line builds without the script phase).
    public static let buildTimestamp: String? = buildTimestamp(from: .main)

    /// Returns the build timestamp from the given bundle, or `nil`.
    ///
    /// Exposed for testing so the lookup + fallback path can be exercised
    /// with a synthetic `Bundle`.
    ///
    /// - Parameter bundle: The bundle to read `OFEMBuildTimestamp` from.
    /// - Returns: The ISO-8601 timestamp string, or `nil` if the key is absent.
    public static func buildTimestamp(from bundle: Bundle) -> String? {
        bundle.object(forInfoDictionaryKey: "OFEMBuildTimestamp") as? String
    }

    // MARK: - Telemetry

    /// The Application Insights connection string used for opt-out telemetry.
    ///
    /// This is a committed source constant. App Insights connection strings are
    /// write-only by design and ship inside every browser-side JS app, mobile
    /// binary, and desktop app that uses Application Insights. Committing it
    /// here means that source builds and forks report to the same endpoint as
    /// official Homebrew releases, so the maintainer sees a representative signal.
    ///
    /// Users disable telemetry from the menu bar (Settings › Telemetry) or by
    /// setting `OFEM_TELEMETRY=0`. No opt-in path requires editing this file.
    public static let appInsightsConnectionString =
        "InstrumentationKey=bb7c05e2-4616-4b8d-a18a-e32128034eb4;" +
        "IngestionEndpoint=https://westeurope-5.in.applicationinsights.azure.com/;" +
        "LiveEndpoint=https://westeurope.livediagnostics.monitor.azure.com/;" +
        "ApplicationId=427c95d5-7252-4513-aed3-e1e5c3eece9d"
}
