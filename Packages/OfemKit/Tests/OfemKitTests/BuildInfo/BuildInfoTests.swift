import Testing
@testable import OfemKit

@Suite("BuildInfo")
struct BuildInfoTests {
    @Test("version is non-empty and does not contain whitespace")
    func versionNonEmpty() {
        let v = BuildInfo.version
        #expect(!v.isEmpty)
        #expect(!v.contains(" "), "version must not contain spaces: \(v)")
    }

    @Test("version in test context is the dev fallback or a valid CalVer string")
    func versionFallback() {
        // In xctest the bundle is the test runner; CFBundleShortVersionString
        // is absent, so we expect exactly the "0.0.0-dev" fallback.
        // In a fully-versioned Xcode build the value must match CalVer:
        // YYYY.MM.PATCH with each component being digits only.
        let v = BuildInfo.version
        let isDevFallback = v == "0.0.0-dev"
        // CalVer: three dot-separated numeric components (YYYY.MM.PATCH).
        let calVerRegex = /^\d{4}\.\d+\.\d+$/
        let looksLikeCalVer = v.wholeMatch(of: calVerRegex) != nil
        #expect(
            isDevFallback || looksLikeCalVer,
            "version '\(v)' is neither '0.0.0-dev' nor a YYYY.MM.PATCH CalVer string"
        )
    }

    @Test("appInsightsConnectionString starts with InstrumentationKey")
    func connectionStringStartsWithInstrumentationKey() {
        #expect(
            BuildInfo.appInsightsConnectionString.hasPrefix("InstrumentationKey="),
            "connection string must start with InstrumentationKey="
        )
    }

    @Test("appInsightsConnectionString contains IngestionEndpoint")
    func connectionStringContainsIngestionEndpoint() {
        #expect(
            BuildInfo.appInsightsConnectionString.contains("IngestionEndpoint="),
            "connection string must include IngestionEndpoint="
        )
    }
}
