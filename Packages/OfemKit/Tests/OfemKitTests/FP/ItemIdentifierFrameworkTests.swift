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
        #expect(
            ItemIdentifier.rootContainerString
                == NSFileProviderItemIdentifier.rootContainer.rawValue,
            "ItemIdentifier.rootContainerString must equal NSFileProviderItemIdentifier.rootContainer.rawValue"
        )
    }

    @Test func trashContainerStringMatchesAppleConstant() {
        #expect(
            ItemIdentifier.trashContainerString
                == NSFileProviderItemIdentifier.trashContainer.rawValue,
            "ItemIdentifier.trashContainerString must equal NSFileProviderItemIdentifier.trashContainer.rawValue"
        )
    }

    @Test func workingSetStringMatchesAppleConstant() {
        #expect(
            ItemIdentifier.workingSetString
                == NSFileProviderItemIdentifier.workingSet.rawValue,
            "ItemIdentifier.workingSetString must equal NSFileProviderItemIdentifier.workingSet.rawValue"
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
