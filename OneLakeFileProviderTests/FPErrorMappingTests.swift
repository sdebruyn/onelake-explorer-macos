// FPErrorMappingTests.swift
// Tests for FPError.classify and nsFileProviderError(for:).
//
// Each FPError case must map to a specific NSFileProviderError domain/code.
// A change to the mapping table that silently alters retry semantics would be
// caught here before it reaches the framework.

import FileProvider
import Foundation
import OfemKit
import XCTest

final class FPErrorMappingTests: XCTestCase {

    // MARK: - nsFileProviderError(for:)

    func testNoSuchItemCode() {
        let err = nsFileProviderError(for: .noSuchItem) as NSError
        XCTAssertEqual(err.domain, NSFileProviderErrorDomain)
        XCTAssertEqual(err.code, NSFileProviderError.noSuchItem.rawValue)
    }

    func testNotAuthenticatedCode() {
        let err = nsFileProviderError(for: .notAuthenticated) as NSError
        XCTAssertEqual(err.domain, NSFileProviderErrorDomain)
        XCTAssertEqual(err.code, NSFileProviderError.notAuthenticated.rawValue)
    }

    func testServerBusyCode() {
        let err = nsFileProviderError(for: .serverBusy) as NSError
        XCTAssertEqual(err.domain, NSFileProviderErrorDomain)
        XCTAssertEqual(err.code, NSFileProviderError.serverUnreachable.rawValue)
    }

    func testServerUnreachableCode() {
        let err = nsFileProviderError(for: .serverUnreachable) as NSError
        XCTAssertEqual(err.domain, NSFileProviderErrorDomain)
        XCTAssertEqual(err.code, NSFileProviderError.serverUnreachable.rawValue)
    }

    func testCannotSynchronizeCode() {
        let err = nsFileProviderError(for: .cannotSynchronize) as NSError
        XCTAssertEqual(err.domain, NSFileProviderErrorDomain)
        XCTAssertEqual(err.code, NSFileProviderError.cannotSynchronize.rawValue)
    }

    // MARK: - FPError.classify for domain errors

    func testClassifyNoSuchItem() {
        XCTAssertEqual(FPError.classify(FPError.noSuchItem("x")), .noSuchItem)
    }

    func testClassifyInvalidIdentifier() {
        XCTAssertEqual(FPError.classify(FPError.invalidIdentifier("bad")), .noSuchItem)
    }

    func testClassifyWrongItemKind() {
        XCTAssertEqual(FPError.classify(FPError.wrongItemKind("dir used as file")), .noSuchItem)
    }

    func testClassifyInvalidRecord() {
        XCTAssertEqual(FPError.classify(FPError.invalidRecord("decode fail")), .cannotSynchronize)
    }

    // MARK: - CancellationError maps to userCancelled (fpe-03)

    func testCancellationIsUserCancelled() async throws {
        // Cancellation must surface as CocoaError(.userCancelled) at the FPE
        // boundary, NOT as an NSFileProviderError. Verify via the production
        // enumerator path: cancel a Task that is mid-flight in engine(), and
        // assert the observer receives finishEnumeratingWithError with the
        // correct domain/code.
        let host = MockEngineHost(alias: "cancel-test")
        // engine() will never return (hangs); Task cancellation must fire the
        // userCancelled reply via the catch block in enumerateItems.
        host.engineResult = .failure(CancellationError())

        let id = NSFileProviderItemIdentifier(ItemIdentifier.rootContainerString)
        let enumerator = OfemFPEEnumerator(
            containerItemIdentifier: id,
            identifier: .root,
            alias: "cancel-test",
            engineHost: host
        )

        let observer = CancellationSpyObserver()
        enumerator.enumerateItems(
            for: observer,
            startingAt: NSFileProviderPage.initialPageSortedByName as NSFileProviderPage
        )

        // Wait up to 1 second for the async Task to complete.
        for _ in 0..<50 {
            if observer.receivedError != nil { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }

        let err = try XCTUnwrap(observer.receivedError as NSError?)
        // The production catch block calls observer.finishEnumeratingWithError(CocoaError(.userCancelled)).
        XCTAssertEqual(err.domain, CocoaError.errorDomain,
                       "CancellationError must surface as CocoaError domain, not NSFileProviderErrorDomain")
        XCTAssertEqual(err.code, CocoaError.userCancelled.rawValue)
        // Confirm it is NOT mapped through nsFileProviderError (which would give cannotSynchronize).
        XCTAssertNotEqual(err.domain, NSFileProviderErrorDomain)
    }
}

// MARK: - Spy observer for cancellation test

private final class CancellationSpyObserver: NSObject, NSFileProviderEnumerationObserver {
    private(set) var receivedError: Error?

    func didEnumerate(_: [NSFileProviderItem]) {}
    func finishEnumerating(upTo _: NSFileProviderPage?) {}
    func finishEnumeratingWithError(_ error: Error) {
        receivedError = error
    }
}

