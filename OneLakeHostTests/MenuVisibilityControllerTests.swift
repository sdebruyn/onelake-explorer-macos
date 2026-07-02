// MenuVisibilityControllerTests.swift
// Unit tests for MenuVisibilityController's depth-counter logic (E3,
// review round 2 SHOULD #5): begin/end pairing, submenu nesting, and the
// underflow clamp for an unpaired didEndTracking notification.
//
// MenuVisibilityController is initialised with a fake HighFrequencySurface
// rather than the real MenuStatusModel.shared, so these tests exercise
// trackingBegan()/trackingEnded() directly without touching production
// dependencies (Keychain-backed auth, XPC to the FPE) — the tests below
// never actually observe a real NSMenu tracking notification, since that
// requires a live AppKit menu.

import XCTest

// MARK: - Fake

@MainActor
private final class SpySurface: HighFrequencySurface {
    private(set) var becameVisibleCount = 0
    private(set) var becameHiddenCount = 0

    func surfaceBecameVisible() {
        becameVisibleCount += 1
    }

    func surfaceBecameHidden() {
        becameHiddenCount += 1
    }
}

// MARK: - Tests

@MainActor
final class MenuVisibilityControllerTests: XCTestCase, @unchecked Sendable {
    func testTrackingBegan_singleOpen_notifiesSurfaceVisible() {
        let surface = SpySurface()
        let controller = MenuVisibilityController(surface: surface)

        controller.trackingBegan()

        XCTAssertEqual(surface.becameVisibleCount, 1)
        XCTAssertEqual(controller.trackingDepth, 1)
    }

    func testTrackingEnded_singleClose_notifiesSurfaceHidden() {
        let surface = SpySurface()
        let controller = MenuVisibilityController(surface: surface)

        controller.trackingBegan()
        controller.trackingEnded()

        XCTAssertEqual(surface.becameVisibleCount, 1)
        XCTAssertEqual(surface.becameHiddenCount, 1)
        XCTAssertEqual(controller.trackingDepth, 0)
    }

    func testSubmenuNesting_doesNotStopSessionPrematurely() {
        // AppKit posts didBeginTracking/didEndTracking for submenus too
        // (e.g. opening an account's submenu inside the dropdown). Only
        // the outermost begin/end pair should toggle the surface.
        let surface = SpySurface()
        let controller = MenuVisibilityController(surface: surface)

        controller.trackingBegan() // root dropdown opens
        XCTAssertEqual(surface.becameVisibleCount, 1)

        controller.trackingBegan() // submenu opens
        XCTAssertEqual(surface.becameVisibleCount, 1, "A submenu opening must not restart the session")
        XCTAssertEqual(controller.trackingDepth, 2)

        controller.trackingEnded() // submenu closes back to its parent
        XCTAssertEqual(surface.becameHiddenCount, 0, "The session must survive a submenu closing while the root is still open")
        XCTAssertEqual(controller.trackingDepth, 1)

        controller.trackingEnded() // root dropdown closes
        XCTAssertEqual(surface.becameHiddenCount, 1)
        XCTAssertEqual(controller.trackingDepth, 0)
    }

    func testTrackingEnded_unpaired_doesNotUnderflowOrNotify() {
        // AppKit can fail to pair a didEndTracking with a prior
        // didBeginTracking (observed around Spaces switches, Mission
        // Control, or screen lock). This must not drive the depth
        // negative, which would otherwise require an extra begin before
        // the depth could ever reach 0 (and notify hidden) again.
        let surface = SpySurface()
        let controller = MenuVisibilityController(surface: surface)

        controller.trackingEnded() // unpaired — no prior begin

        XCTAssertEqual(controller.trackingDepth, 0)
        XCTAssertEqual(surface.becameHiddenCount, 0, "An unpaired end must not spuriously notify hidden")

        // A normal open/close afterwards must still behave correctly.
        controller.trackingBegan()
        XCTAssertEqual(surface.becameVisibleCount, 1)
        XCTAssertEqual(controller.trackingDepth, 1)

        controller.trackingEnded()
        XCTAssertEqual(surface.becameHiddenCount, 1)
        XCTAssertEqual(controller.trackingDepth, 0)
    }
}
