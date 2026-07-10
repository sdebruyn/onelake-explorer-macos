// TestHelpers.swift
// Shared helpers used across the OneLakeHostTests target.
//
// OneLakeHostTests compiles the OneLake app sources directly (no
// `@testable import` boundary — see project.yml), so this file, like every
// other file here, is just a plain member of the test target's module.

import Foundation

// MARK: - waitUntil

/// Polls `condition` until it returns true or `timeout` elapses.
///
/// Used instead of a fixed sleep so tests aren't tied to (and don't
/// silently stop covering) a specific debounce/interval value — a fixed
/// sleep tied to a production timing constant is flaky under load and
/// becomes vacuous if that value ever changes (T2).
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
@MainActor
func waitUntil(
    timeout: Duration = .seconds(3),
    interval: Duration = .milliseconds(20),
    _ condition: () -> Bool
) async {
    let deadline = ContinuousClock.now + timeout
    while !condition(), ContinuousClock.now < deadline {
        try? await Task.sleep(for: interval)
    }
}
