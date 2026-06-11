import Foundation

/// Runtime identity for the running OFEM binary.
///
/// `version` is read from `CFBundleShortVersionString` in `Bundle.main` at
/// runtime, so Xcode-built releases automatically pick up the CalVer string
/// (e.g. `"2026.05.1"`) injected by `xcodebuild MARKETING_VERSION=…` on the
/// release tag. The `"0.0.0-dev"` fallback is used in unit-test contexts where
/// `Bundle.main` is the `xctest` runner which carries no version key.
public enum BuildInfo {
    // MARK: - Version

    /// The CalVer release string (e.g. `"2026.05.1"`).
    ///
    /// Read from `CFBundleShortVersionString` in `Bundle.main`. Falls back
    /// to `"0.0.0-dev"` when the key is absent (xctest, command-line tool
    /// builds, or un-versioned debug builds).
    public static let version: String = {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
            as? String ?? "0.0.0-dev"
    }()

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
