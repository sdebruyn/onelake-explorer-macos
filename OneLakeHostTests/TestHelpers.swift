// TestHelpers.swift
// Shared helpers used across the OneLakeHostTests target.
//
// OneLakeHostTests compiles the OneLake app sources directly (no
// `@testable import` boundary — see project.yml), so this file, like every
// other file here, is just a plain member of the test target's module.

import Foundation
import XCTest

// MARK: - waitUntil

/// Polls `condition` until it returns true or `timeout` elapses, then fails
/// the current test if it never became true.
///
/// Used instead of a fixed sleep so tests aren't tied to (and don't
/// silently stop covering) a specific debounce/interval value — a fixed
/// sleep tied to a production timing constant is flaky under load and
/// becomes vacuous if that value ever changes (T2).
///
/// Calls `XCTFail` on timeout so a regression that stops `condition` from
/// ever becoming true fails the test here, instead of silently returning and
/// leaving the result up to whatever assertion happens to follow. This
/// matters even for call sites whose own trailing assertion re-checks the
/// same fact `condition` describes, and is essential for the (several) call
/// sites in this target whose trailing assertion checks something else
/// (e.g. a value captured before the wait even started) — those sites would
/// otherwise pass vacuously if the awaited state transition never happened,
/// exactly the coverage the `XCTestExpectation`/`fulfillment(timeout:)` this
/// replaces used to provide via its own timeout failure.
///
/// `@MainActor`-isolated (matching every call site, which is always a
/// `@MainActor` test method) so the non-escaping `condition` closure —
/// which reads `@MainActor`-isolated model state — never has to cross an
/// actor boundary. Without this, Swift 6 strict concurrency rejects the
/// closure as a non-`Sendable` value being "sent" into a nonisolated
/// `async` function.
///
/// Previously redeclared per-file (unlike the per-scenario fakes elsewhere
/// in this target, `waitUntil` has no domain coupling, so duplicating it
/// bought nothing); consolidated here so every test file shares one copy.
///
/// - Parameters:
///   - file/line: Default to the call site (matching every `XCTAssert*`
///     signature) so a timeout failure points at the waiting test, not at
///     this helper.
@MainActor
func waitUntil(
    timeout: Duration = .seconds(3),
    interval: Duration = .milliseconds(20),
    file: StaticString = #filePath,
    line: UInt = #line,
    _ condition: () -> Bool
) async {
    let deadline = ContinuousClock.now + timeout
    while !condition(), ContinuousClock.now < deadline {
        try? await Task.sleep(for: interval)
    }
    if !condition() {
        XCTFail("waitUntil timed out after \(timeout) — condition never became true", file: file, line: line)
    }
}
