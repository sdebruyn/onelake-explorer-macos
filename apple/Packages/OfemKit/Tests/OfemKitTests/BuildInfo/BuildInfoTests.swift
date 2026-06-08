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

    @Test("version in test context falls back to dev string or real version")
    func versionFallback() {
        // In xctest the bundle is the test runner; it either has no
        // CFBundleShortVersionString (→ fallback) or has a real one.
        // Either way it must not be empty.
        let v = BuildInfo.version
        let isDevFallback = v == "0.0.0-dev"
        let looksLikeCalVer = v.split(separator: ".").count >= 2
        #expect(isDevFallback || looksLikeCalVer,
                "version \(v) is neither the dev fallback nor CalVer")
    }

    @Test("appInsightsConnectionString contains InstrumentationKey")
    func connectionStringContainsInstrumentationKey() {
        #expect(
            BuildInfo.appInsightsConnectionString.contains("InstrumentationKey="),
            "connection string must begin with InstrumentationKey="
        )
    }

    @Test("appInsightsConnectionString contains IngestionEndpoint")
    func connectionStringContainsIngestionEndpoint() {
        #expect(
            BuildInfo.appInsightsConnectionString.contains("IngestionEndpoint="),
            "connection string must include IngestionEndpoint="
        )
    }

    @Test("commit and date are strings (may be empty in test builds)")
    func commitAndDateAreStrings() {
        // These are empty in source/test builds — just verify the type compiles.
        let _ = BuildInfo.commit as String
        let _ = BuildInfo.date as String
    }
}
