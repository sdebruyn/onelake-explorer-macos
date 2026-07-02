// FileProviderExtensionTests.swift
// Tests for FileProviderExtension callback logic.
//
// Uses MockEngineHost to exercise completion-handler wiring, error mapping,
// and cancellation behaviour without a live fileproviderd or OfemEngine.

@preconcurrency import FileProvider
import Foundation
import XCTest

final class FileProviderExtensionTests: XCTestCase {
    // MARK: - item(for:) — engine unavailable maps to cannotSynchronize

    func testItemForEngineUnavailableMapsToCannotSynchronize() async throws {
        let host = MockEngineHost(alias: "test")
        host.engineResult = .failure(NSFileProviderError(.cannotSynchronize))

        let ext = makeExtension(host: host)
        let result = await withCheckedContinuation { cont in
            _ = ext.item(for: .rootContainer, request: makeRequest()) { _, err in
                cont.resume(returning: err)
            }
        }

        let nsErr = try XCTUnwrap(result as NSError?)
        XCTAssertEqual(nsErr.domain, NSFileProviderErrorDomain)
        XCTAssertEqual(nsErr.code, NSFileProviderError.cannotSynchronize.rawValue)
    }

    // MARK: - item(for:) — bad identifier maps to noSuchItem

    func testItemForBadIdentifierMapsToNoSuchItem() async throws {
        let host = MockEngineHost(alias: "test")
        let ext = makeExtension(host: host)

        // "bad//identifier" has an empty segment and will fail ItemIdentifierParser.
        let bad = NSFileProviderItemIdentifier("bad//identifier")
        let result = await withCheckedContinuation { cont in
            _ = ext.item(for: bad, request: makeRequest()) { _, err in
                cont.resume(returning: err)
            }
        }

        let nsErr = try XCTUnwrap(result as NSError?)
        XCTAssertEqual(nsErr.domain, NSFileProviderErrorDomain)
        XCTAssertEqual(nsErr.code, NSFileProviderError.noSuchItem.rawValue)
    }

    // MARK: - item(for:) — workingSet returns noSuchItem

    func testItemForWorkingSetReturnsNoSuchItem() async throws {
        let host = MockEngineHost(alias: "test")
        let ext = makeExtension(host: host)

        let result = await withCheckedContinuation { cont in
            _ = ext.item(for: .workingSet, request: makeRequest()) { _, err in
                cont.resume(returning: err)
            }
        }

        let nsErr = try XCTUnwrap(result as NSError?)
        XCTAssertEqual(nsErr.domain, NSFileProviderErrorDomain)
        XCTAssertEqual(nsErr.code, NSFileProviderError.noSuchItem.rawValue)
    }

    // MARK: - createItem — bad parentIdentifier maps to noSuchItem

    func testCreateItemBadParentIdentifier() async throws {
        let host = MockEngineHost(alias: "test")
        let ext = makeExtension(host: host)
        let template = MockFPItem(parentID: "bad//parent", filename: "test.txt")

        let result = await withCheckedContinuation { cont in
            _ = ext.createItem(
                basedOn: template,
                fields: [],
                contents: nil,
                options: [],
                request: makeRequest()
            ) { _, _, _, err in
                cont.resume(returning: err)
            }
        }

        let nsErr = try XCTUnwrap(result as NSError?)
        XCTAssertEqual(nsErr.domain, NSFileProviderErrorDomain)
        XCTAssertEqual(nsErr.code, NSFileProviderError.noSuchItem.rawValue)
    }

    // MARK: - modifyItem — rename with invalid identifier maps to noSuchItem (fpe-09)

    func testModifyItemRenameInvalidIdentifierMapsToNoSuchItem() async {
        // An item whose identifier is a framework-internal constant
        // (not a valid OFEM path identifier) triggers the parsing guard,
        // which maps to noSuchItem — not a pending field.
        let host = MockEngineHost(alias: "test")
        let ext = makeExtension(host: host)
        let template = MockFPItem(parentID: NSFileProviderItemIdentifier.rootContainer.rawValue, filename: "renamed.txt")

        var capturedError: (any Error)?
        _ = await withCheckedContinuation { cont in
            _ = ext.modifyItem(
                template,
                baseVersion: NSFileProviderItemVersion(contentVersion: Data(), metadataVersion: Data()),
                changedFields: .filename,
                contents: nil,
                request: makeRequest()
            ) { _, _, _, err in
                capturedError = err
                cont.resume(returning: ())
            }
        }

        let nsErr = capturedError as NSError?
        XCTAssertNotNil(nsErr, "expected an error for an unparseable item identifier")
        XCTAssertEqual(nsErr?.domain, NSFileProviderErrorDomain)
        XCTAssertEqual(nsErr?.code, NSFileProviderError.noSuchItem.rawValue,
                       "unparseable identifier should map to noSuchItem")
    }

    // MARK: - modifyItem — reparent leaves .parentItemIdentifier pending

    func testModifyItemReparentLeavesPending() async {
        let host = MockEngineHost(alias: "test")
        let ext = makeExtension(host: host)
        let template = MockFPItem(parentID: NSFileProviderItemIdentifier.rootContainer.rawValue, filename: "file.txt")

        var pendingFields: NSFileProviderItemFields = []
        _ = await withCheckedContinuation { cont in
            _ = ext.modifyItem(
                template,
                baseVersion: NSFileProviderItemVersion(contentVersion: Data(), metadataVersion: Data()),
                changedFields: .parentItemIdentifier,
                contents: nil,
                request: makeRequest()
            ) { _, fields, _, _ in
                pendingFields = fields
                cont.resume(returning: ())
            }
        }

        XCTAssertTrue(pendingFields.contains(.parentItemIdentifier),
                      ".parentItemIdentifier must remain pending when reparent is not supported")
    }

    // MARK: - deleteItem — bad identifier maps to noSuchItem

    func testDeleteItemBadIdentifierMapsToNoSuchItem() async throws {
        let host = MockEngineHost(alias: "test")
        let ext = makeExtension(host: host)
        let bad = NSFileProviderItemIdentifier("bad//id")

        let result = await withCheckedContinuation { cont in
            _ = ext.deleteItem(
                identifier: bad,
                baseVersion: NSFileProviderItemVersion(contentVersion: Data(), metadataVersion: Data()),
                options: [],
                request: makeRequest()
            ) { err in
                cont.resume(returning: err)
            }
        }

        let nsErr = try XCTUnwrap(result as NSError?)
        XCTAssertEqual(nsErr.domain, NSFileProviderErrorDomain)
        XCTAssertEqual(nsErr.code, NSFileProviderError.noSuchItem.rawValue)
    }

    // MARK: - supportedServiceSources — only rootContainer gets the service

    func testSupportedServiceSourcesRootContainer() async throws {
        let host = MockEngineHost(alias: "test")
        let ext = makeExtension(host: host)

        // [any NSFileProviderServiceSource] is @_nonSendable in the SDK.
        // Box it so it can cross the continuation boundary; unbox immediately.
        struct SourcesBox: @unchecked Sendable {
            let value: [any NSFileProviderServiceSource]
        }
        let box: SourcesBox = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<SourcesBox, any Error>) in
            _ = ext.supportedServiceSources(for: .rootContainer) { sources, err in
                if let err { cont.resume(throwing: err) }
                else { cont.resume(returning: SourcesBox(value: sources ?? [])) }
            }
        }
        let sources = box.value

        XCTAssertFalse(sources.isEmpty, "rootContainer should expose the control service")
    }

    func testSupportedServiceSourcesNonRootIsEmpty() async throws {
        let host = MockEngineHost(alias: "test")
        let ext = makeExtension(host: host)
        let wsID = NSFileProviderItemIdentifier("00000000-0000-0000-0000-000000000001")

        // [any NSFileProviderServiceSource] is @_nonSendable in the SDK.
        // Box it so it can cross the continuation boundary; unbox immediately.
        struct SourcesBox: @unchecked Sendable {
            let value: [any NSFileProviderServiceSource]
        }
        let box: SourcesBox = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<SourcesBox, any Error>) in
            _ = ext.supportedServiceSources(for: wsID) { sources, err in
                if let err { cont.resume(throwing: err) }
                else { cont.resume(returning: SourcesBox(value: sources ?? [])) }
            }
        }
        let sources = box.value

        XCTAssertTrue(sources.isEmpty, "non-rootContainer should expose no services")
    }

    // MARK: - enumerator(for:) — trash gets a real empty enumerator, not the working-set one

    /// OneLake has no trash: `.trashContainer` must route to `OfemTrashEnumerator`,
    /// never to `OfemWorkingSetEnumerator`. Before this was fixed, both sentinels
    /// shared the working-set enumerator, so trash enumeration would trigger a
    /// throttled `listWorkspaces` refresh and report alias-wide cache deltas
    /// under the trash container — behaviour that has nothing to do with trash.
    func testEnumeratorForTrashIsNotWorkingSetAndNeverTouchesEngine() throws {
        let host = MockEngineHost(alias: "test")
        let ext = makeExtension(host: host)

        let enumerator = try ext.enumerator(for: .trashContainer, request: makeRequest())

        // Downcast to the concrete type: it both proves trash gets a real
        // OfemTrashEnumerator (not OfemWorkingSetEnumerator — a different
        // final class, so the two are mutually exclusive) and lets the calls
        // below dispatch statically instead of through the optional-chained
        // NSFileProviderEnumerator protocol requirements.
        let trashEnumerator = try XCTUnwrap(
            enumerator as? OfemTrashEnumerator,
            "trash must get a real empty enumerator, not the working-set one"
        )

        let itemsObserver = SpyEnumerationObserver()
        trashEnumerator.enumerateItems(for: itemsObserver, startingAt: NSFileProviderPage.initialPageSortedByName as NSFileProviderPage)
        XCTAssertTrue(itemsObserver.didEnumerateCalled)
        XCTAssertTrue(itemsObserver.enumeratedItems.isEmpty)
        XCTAssertTrue(itemsObserver.finishEnumeratingCalled)

        let changesObserver = SpyChangeObserver()
        trashEnumerator.enumerateChanges(for: changesObserver, from: encodeSyncAnchor(0))
        XCTAssertTrue(changesObserver.finished)
        XCTAssertFalse(changesObserver.finishedWithError)

        XCTAssertEqual(host.engineCallCount, 0, "trash enumeration must never build/touch the engine")
    }

    /// Regression guard: `.workingSet` must keep vending the real
    /// `OfemWorkingSetEnumerator` (only trash was mis-routed).
    func testEnumeratorForWorkingSetReturnsWorkingSetEnumerator() throws {
        let host = MockEngineHost(alias: "test")
        let ext = makeExtension(host: host)

        let enumerator = try ext.enumerator(for: .workingSet, request: makeRequest())

        XCTAssertTrue(enumerator is OfemWorkingSetEnumerator)
    }

    // MARK: - Helpers

    private func makeExtension(host: MockEngineHost) -> FileProviderExtension {
        let domain = NSFileProviderDomain(
            identifier: NSFileProviderDomainIdentifier("ofem.\(host.alias)"),
            displayName: host.alias
        )
        return FileProviderExtension(domain: domain, engineHost: host)
    }

    private func makeRequest() -> NSFileProviderRequest {
        NSFileProviderRequest()
    }
}

// MARK: - MockFPItem

/// Minimal NSFileProviderItem for tests that need a template object.
private final class MockFPItem: NSObject, NSFileProviderItem {
    let itemIdentifier: NSFileProviderItemIdentifier
    let parentItemIdentifier: NSFileProviderItemIdentifier
    let filename: String
    let contentType: UTType
    let capabilities: NSFileProviderItemCapabilities
    let documentSize: NSNumber?
    let contentModificationDate: Date?
    let itemVersion: NSFileProviderItemVersion

    init(
        id: String = "NSFileProviderRootContainerItemIdentifier",
        parentID: String,
        filename: String
    ) {
        self.itemIdentifier = NSFileProviderItemIdentifier(id)
        self.parentItemIdentifier = NSFileProviderItemIdentifier(parentID)
        self.filename = filename
        self.contentType = .plainText
        self.capabilities = [.allowsReading, .allowsWriting]
        self.documentSize = nil
        self.contentModificationDate = nil
        self.itemVersion = NSFileProviderItemVersion(contentVersion: Data("v1".utf8), metadataVersion: Data("mv1".utf8))
        super.init()
    }
}

// Need to import UTType explicitly for MockFPItem
import UniformTypeIdentifiers
