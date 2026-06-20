// MaterializedPollTests.swift
// Unit tests for ChangeWatcher.pollOnce — the deterministic testability seam
// for the materialized-container poll loop.
//
// All tests use injected mock collaborators (no NSFileProviderManager, no XPC,
// no network, no SQLite). The static `pollOnce` function is the canonical body
// of one poll-loop iteration; the timer wrapping it is not exercised here.
//
// Scenarios:
//   1. delta → .workingSet signal fired once for the matching domain
//   2. no delta → no signal
//   3. two accounts, both delta → two domains signalled (one each)
//   4. two accounts, one delta → only that domain signalled
//   5. delta reported but domain not found → no signal (graceful skip)

import XCTest
@preconcurrency import FileProvider
import OfemKit

// MARK: - Mock collaborators

/// Records which aliases were polled and returns a configurable delta per alias.
private actor RecordingPoller: MaterializedPoller {
    private(set) var polledAliases: [String] = []

    /// Map alias → should return `true` (delta). Missing entries return `false`.
    private let deltaFor: [String: Bool]

    init(deltaFor: [String: Bool] = [:]) {
        self.deltaFor = deltaFor
    }

    nonisolated func pollMaterialized(alias: String) async -> Bool {
        await _pollMaterialized(alias: alias)
    }

    private func _pollMaterialized(alias: String) -> Bool {
        polledAliases.append(alias)
        return deltaFor[alias] ?? false
    }
}

/// Records which domain identifiers received a .workingSet signal.
private actor RecordingSignaller: WorkingSetSignaller {
    private(set) var signalledDomainIDs: [String] = []

    nonisolated func signal(domain: NSFileProviderDomain) async {
        await _signal(domainIdentifier: domain.identifier.rawValue)
    }

    private func _signal(domainIdentifier: String) {
        signalledDomainIDs.append(domainIdentifier)
    }
}

// MARK: - Helpers

private func makeAccount(alias: String) -> Account {
    Account(
        alias: alias,
        tenantID: "tenant-\(alias)",
        homeAccountID: "home-\(alias)",
        username: "\(alias)@example.com",
        addedAt: "2026-01-01"
    )
}

/// Creates a fake `NSFileProviderDomain` for the given identifier string.
private func makeDomain(identifier: String) -> NSFileProviderDomain {
    NSFileProviderDomain(
        identifier: NSFileProviderDomainIdentifier(rawValue: identifier),
        displayName: identifier
    )
}

/// Canonical domain identifier for alias — mirrors the production formula.
private func domainID(for alias: String) -> String {
    "ofem.\(alias)"
}

// MARK: - Tests

final class MaterializedPollTests: XCTestCase {

    // MARK: 1. Delta → signal fired once

    func testPollOnce_delta_signalsWorkingSetOnce() async throws {
        let alias = "work"
        let accounts = [makeAccount(alias: alias)]
        let domId = domainID(for: alias)
        let domains = [makeDomain(identifier: domId)]

        let poller = RecordingPoller(deltaFor: [alias: true])
        let signaller = RecordingSignaller()

        await ChangeWatcher.pollOnce(
            accounts: accounts,
            domains: domains,
            domainIdentifierFor: domainID(for:),
            poller: poller,
            signaller: signaller
        )

        let polled = await poller.polledAliases
        let signalled = await signaller.signalledDomainIDs

        XCTAssertEqual(polled, [alias], "Expected exactly one poll for alias \(alias)")
        XCTAssertEqual(signalled, [domId], "Expected exactly one .workingSet signal for domain \(domId)")
    }

    // MARK: 2. No delta → no signal

    func testPollOnce_noDelta_noSignal() async throws {
        let alias = "personal"
        let accounts = [makeAccount(alias: alias)]
        let domains = [makeDomain(identifier: domainID(for: alias))]

        let poller = RecordingPoller(deltaFor: [alias: false])
        let signaller = RecordingSignaller()

        await ChangeWatcher.pollOnce(
            accounts: accounts,
            domains: domains,
            domainIdentifierFor: domainID(for:),
            poller: poller,
            signaller: signaller
        )

        let polled = await poller.polledAliases
        let signalled = await signaller.signalledDomainIDs

        XCTAssertEqual(polled, [alias], "Should poll the alias even when no delta")
        XCTAssertTrue(signalled.isEmpty, "No signal expected when no delta")
    }

    // MARK: 3. Two accounts, both delta → two signals

    func testPollOnce_twoAccounts_bothDelta_twoSignals() async throws {
        let a1 = "work", a2 = "client"
        let accounts = [makeAccount(alias: a1), makeAccount(alias: a2)]
        let d1 = domainID(for: a1), d2 = domainID(for: a2)
        let domains = [makeDomain(identifier: d1), makeDomain(identifier: d2)]

        let poller = RecordingPoller(deltaFor: [a1: true, a2: true])
        let signaller = RecordingSignaller()

        await ChangeWatcher.pollOnce(
            accounts: accounts,
            domains: domains,
            domainIdentifierFor: domainID(for:),
            poller: poller,
            signaller: signaller
        )

        let polled = await poller.polledAliases
        let signalled = await signaller.signalledDomainIDs

        XCTAssertEqual(Set(polled), Set([a1, a2]), "Both accounts should be polled")
        XCTAssertEqual(Set(signalled), Set([d1, d2]), "Both domains should receive a signal")
        XCTAssertEqual(signalled.count, 2, "Exactly two signals — one per domain")
    }

    // MARK: 4. Two accounts, one delta → only that domain signalled

    func testPollOnce_twoAccounts_oneDelta_oneSignal() async throws {
        let a1 = "work", a2 = "client"
        let accounts = [makeAccount(alias: a1), makeAccount(alias: a2)]
        let d1 = domainID(for: a1), d2 = domainID(for: a2)
        let domains = [makeDomain(identifier: d1), makeDomain(identifier: d2)]

        // Only a1 has a delta.
        let poller = RecordingPoller(deltaFor: [a1: true, a2: false])
        let signaller = RecordingSignaller()

        await ChangeWatcher.pollOnce(
            accounts: accounts,
            domains: domains,
            domainIdentifierFor: domainID(for:),
            poller: poller,
            signaller: signaller
        )

        let polled = await poller.polledAliases
        let signalled = await signaller.signalledDomainIDs

        XCTAssertEqual(Set(polled), Set([a1, a2]), "Both accounts should be polled")
        XCTAssertEqual(signalled, [d1], "Only the domain with a delta should be signalled")
    }

    // MARK: 5. Delta but domain not found → no signal

    func testPollOnce_deltaButDomainNotFound_noSignal() async throws {
        let alias = "orphan"
        let accounts = [makeAccount(alias: alias)]
        // Domains list is empty — the domain for this alias is not registered.
        let domains: [NSFileProviderDomain] = []

        let poller = RecordingPoller(deltaFor: [alias: true])
        let signaller = RecordingSignaller()

        await ChangeWatcher.pollOnce(
            accounts: accounts,
            domains: domains,
            domainIdentifierFor: domainID(for:),
            poller: poller,
            signaller: signaller
        )

        let polled = await poller.polledAliases
        let signalled = await signaller.signalledDomainIDs

        XCTAssertEqual(polled, [alias], "Should poll even when the domain is absent")
        XCTAssertTrue(signalled.isEmpty, "No signal when the domain is not in the registered domains list")
    }
}
