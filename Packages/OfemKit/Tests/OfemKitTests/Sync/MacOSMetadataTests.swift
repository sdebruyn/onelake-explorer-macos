import Foundation
@testable import OfemKit
import Testing

// MARK: - MacOSMetadata tests

/// Tests for ``isMacOSMetadata`` — macOS-specific extended-attribute spill
/// files that must be silently skipped on upload.
struct MacOSMetadataTests {
    // MARK: - Files that should be skipped

    @Test func dsStoreIsMetadata() {
        #expect(isMacOSMetadata(".DS_Store"))
    }

    @Test func dotUnderscoreIsMetadata() {
        #expect(isMacOSMetadata("._report.csv"))
    }

    @Test func dotUnderscoreInSubdirIsMetadata() {
        #expect(isMacOSMetadata("Files/._report.csv"))
    }

    @Test func spotlightDirIsMetadata() {
        #expect(isMacOSMetadata(".Spotlight-V100"))
    }

    @Test func trashesIsMetadata() {
        #expect(isMacOSMetadata(".Trashes"))
    }

    @Test func fsEventsIsMetadata() {
        #expect(isMacOSMetadata(".fseventsd"))
    }

    @Test func ofemUploadStagingFileIsMetadata() {
        // finding F11: OneLakeClient's upload-staging file must be hidden the
        // same way `._*` AppleDouble junk is, whether caught mid-flight by a
        // concurrent listing or orphaned by a hard kill before the rename.
        #expect(isMacOSMetadata("\(ofemUploadStagingPrefix)\(UUID().uuidString)-report.csv"))
    }

    @Test func ofemUploadStagingFileInSubdirIsMetadata() {
        #expect(isMacOSMetadata("Files/\(ofemUploadStagingPrefix)\(UUID().uuidString)-report.csv"))
    }

    // MARK: - Files that should NOT be skipped

    @Test func normalFileIsNotMetadata() {
        #expect(!isMacOSMetadata("report.csv"))
    }

    @Test func hiddenFileIsNotMetadata() {
        #expect(!isMacOSMetadata(".gitignore"))
    }

    @Test func dotFileWithoutUnderscoreIsNotMetadata() {
        #expect(!isMacOSMetadata(".env"))
    }
}
