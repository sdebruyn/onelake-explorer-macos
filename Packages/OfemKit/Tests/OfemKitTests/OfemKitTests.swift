import Testing
@testable import OfemKit

// engine-05: OfemKit.version was a dead stub conflicting with BuildInfo.version.
// The single canonical version is now BuildInfo.version (see BuildInfoTests for
// full coverage).  This file is kept as a minimal package-level smoke test.
@Test func packageModuleIsImportable() {
    // Verify the module itself can be imported and the canonical version source
    // is non-empty.
    #expect(!BuildInfo.version.isEmpty)
}
