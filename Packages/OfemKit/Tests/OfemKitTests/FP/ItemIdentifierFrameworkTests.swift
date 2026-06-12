import FileProvider
import Testing
@testable import OfemKit

// MARK: - ItemIdentifier framework-conformance tests
//
// These tests pin OfemKit's sentinel raw values to the Apple
// NSFileProviderItemIdentifier constants. A mismatch here means the FPE
// parser will classify root-container / trash / working-set identifiers
// as garbage workspace GUIDs, breaking all enumeration.

struct ItemIdentifierFrameworkTests {

    // MARK: - Sentinel contract pins

    @Test func rootContainerStringMatchesAppleConstant() {
        // Pin to the literal string the Apple framework has published since the
        // FileProvider API was introduced. If the framework ever renames the
        // constant, or our assignment drifts to a different source, this test
        // will catch it before the FPE parser silently mis-classifies root.
        #expect(
            ItemIdentifier.rootContainerString
                == "NSFileProviderRootContainerItemIdentifier"
        )
    }

    @Test func trashContainerStringMatchesAppleConstant() {
        #expect(
            ItemIdentifier.trashContainerString
                == "NSFileProviderTrashContainerItemIdentifier"
        )
    }

    @Test func workingSetStringMatchesAppleConstant() {
        #expect(
            ItemIdentifier.workingSetString
                == "NSFileProviderWorkingSetContainerItemIdentifier"
        )
    }

    // MARK: - Parser recognises Apple raw values

    @Test func parserAcceptsRootContainerRawValue() throws {
        let id = try ItemIdentifierParser.parse(
            NSFileProviderItemIdentifier.rootContainer.rawValue
        )
        #expect(id == .root)
    }

    @Test func parserAcceptsTrashContainerRawValue() throws {
        let id = try ItemIdentifierParser.parse(
            NSFileProviderItemIdentifier.trashContainer.rawValue
        )
        #expect(id == .trash)
    }

    @Test func parserAcceptsWorkingSetRawValue() throws {
        let id = try ItemIdentifierParser.parse(
            NSFileProviderItemIdentifier.workingSet.rawValue
        )
        #expect(id == .workingSet)
    }
}
