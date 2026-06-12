// DomainSyncManager.swift
// Reconciles the set of `NSFileProviderDomain`s macOS knows about
// with the set of accounts stored in the shared config.
//
// The host app is the only process allowed to call
// `NSFileProviderManager.add` / `.remove`. The File Provider
// Extension is sandboxed and cannot mutate the domain list itself.
// So every domain edit funnels through this manager on the host
// app's main actor.
//
// Reconciliation is idempotent:
//
// - For every account-alias in config.toml, ensure a domain
// with identifier `ofem.<alias>` is registered. If one is missing,
// add it.
// - For every registered domain that starts with `ofem.` but is
// no longer in the account list, remove it (preserving the
// user's downloaded content — they may want it back).
//
// Calling `reconcile()` more than once concurrently is safe: the
// `@MainActor` annotation serialises every entry point.
//
// reconcile() reads the account list from SharedOfemAuth (config.toml).
// addDomain(alias:) and removeDomain(alias:) are surgical alternatives
// for callers that already know exactly which domain to add or remove.

import FileProvider
import Foundation
import OfemKit
import os.log

/// Hosts the (very small) account-to-domain reconciliation policy.
/// Lives on the main actor because both `NSFileProviderManager.add`
/// and `.remove` are documented as main-thread-only.
@MainActor
final class DomainSyncManager {
    static let shared = DomainSyncManager()

    private static let log = Logger(
        subsystem: "dev.debruyn.ofem",
        category: "domain-sync"
    )

    /// Identifier prefix every OFEM-owned domain carries. Anything
    /// without this prefix is left alone — even if it lives in our
    /// process — to avoid clobbering domains another tool registered.
    ///
    /// Mirrored in `FileProviderExtension.extractAlias` (`ofemDomainIdentifierPrefix`);
    /// the two targets do not share source files, so the constant is defined
    /// twice on purpose.
    let identifierPrefix = "ofem."

    init() {}

    // MARK: - Targeted domain operations

    /// Returns the domain identifier string for `alias`.
    func domainIdentifier(for alias: String) -> String {
        "\(identifierPrefix)\(alias)"
    }

    /// Returns an NSFileProviderDomain for `alias`.
    private func makeDomain(alias: String) -> NSFileProviderDomain {
        NSFileProviderDomain(
            identifier: NSFileProviderDomainIdentifier(rawValue: domainIdentifier(for: alias)),
            displayName: alias
        )
    }

    /// Registers a single File Provider domain for `alias`.
    ///
    /// Call this immediately after a successful interactive sign-in so
    /// the new account appears in the Finder sidebar without waiting for
    /// the next full `reconcile()` pass.
    ///
    /// Idempotent: if the domain is already registered the underlying
    /// `NSFileProviderManager.add` call returns an "already exists" error
    /// that is logged and swallowed.
    ///
    /// - Parameter alias: The account alias (e.g. "work").
    func addDomain(alias: String) async {
        let id = domainIdentifier(for: alias)
        do {
            try await NSFileProviderManager.add(makeDomain(alias: alias))
            Self.log.info("Added File Provider domain \(id, privacy: .public)")
        } catch {
            // "Already exists" is expected on idempotent calls; treat
            // all failures as non-fatal so callers don't need to handle them.
            Self.log.notice(
                "NSFileProviderManager.add(\(id, privacy: .public)) failed: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    /// Removes the File Provider domain for `alias`, preserving locally
    /// downloaded user data.
    ///
    /// Call this after a successful account removal so the domain
    /// disappears from the Finder sidebar without waiting for the next
    /// full `reconcile()` pass.
    ///
    /// - Parameter alias: The account alias (e.g. "work").
    func removeDomain(alias: String) async {
        let id = domainIdentifier(for: alias)
        let existing: [NSFileProviderDomain]
        do {
            existing = try await Self.existingDomains()
        } catch {
            Self.log.error(
                "removeDomain: getDomainsWithCompletionHandler failed: \(error.localizedDescription, privacy: .public)"
            )
            return
        }
        guard let domain = existing.first(where: { $0.identifier.rawValue == id }) else {
            Self.log.info("removeDomain: domain \(id, privacy: .public) not registered, skipping")
            return
        }
        do {
            try await NSFileProviderManager.remove(domain, mode: .preserveDownloadedUserData)
            Self.log.info("Removed File Provider domain \(id, privacy: .public)")
        } catch {
            Self.log.notice(
                "NSFileProviderManager.remove(\(id, privacy: .public)) failed: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    // MARK: - Full reconcile

    /// Reconcile the macOS domain list with the account list from
    /// config.toml (via SharedOfemAuth).
    ///
    /// Safe to call repeatedly. Logs at info level for every add / remove
    /// so the operator can audit the activity from Console.app.
    /// Expressed in terms of addDomain/removeDomain so error-handling and
    /// domain-identifier composition are defined in exactly one place.
    func reconcile() async throws {
        let accounts = await SharedOfemAuth.shared.auth.listAccounts()
        let existing = try await Self.existingDomains()
        let existingById: [String: NSFileProviderDomain] = Dictionary(
            uniqueKeysWithValues: existing.map { ($0.identifier.rawValue, $0) }
        )

        let desiredIds = Set(accounts.map { domainIdentifier(for: $0.alias) })

        // 1) Add domains for accounts that lack one.
        for account in accounts {
            let id = domainIdentifier(for: account.alias)
            if existingById[id] != nil { continue }
            await addDomain(alias: account.alias)
        }

        // 2) Remove orphan domains — ones we own (have our prefix)
        // but the config no longer has an account for.
        for (id, domain) in existingById {
            if !id.hasPrefix(self.identifierPrefix) { continue }
            if desiredIds.contains(id) { continue }
            // Call the underlying API directly: removeDomain(alias:) would
            // re-fetch the domain list unnecessarily since we already have it.
            do {
                try await NSFileProviderManager.remove(
                    domain,
                    mode: .preserveDownloadedUserData
                )
                Self.log.info("Removed orphan domain \(id, privacy: .public)")
            } catch {
                Self.log.notice(
                    "NSFileProviderManager.remove(\(id, privacy: .public)) failed: \(error.localizedDescription, privacy: .public)"
                )
            }
        }
    }

    // MARK: - Helpers

    /// Snapshot the currently-registered domains. Bridges the
    /// completion-handler API into `async` so the rest of the
    /// reconciliation reads top-to-bottom.
    ///
    /// We funnel through `withCheckedThrowingContinuation` rather
    /// than relying on Swift's auto-bridged `getDomains()`
    /// overload because the latter has shifted shape across macOS
    /// SDK revisions (sometimes `() async throws -> [Domain]`,
    /// sometimes `() async -> [Domain]`). The explicit bridge
    /// keeps the call site predictable.
    private static func existingDomains() async throws -> [NSFileProviderDomain] {
        try await withCheckedThrowingContinuation { continuation in
            NSFileProviderManager.getDomainsWithCompletionHandler { domains, error in
                if let error = error {
                    continuation.resume(throwing: error)
                    return
                }
                continuation.resume(returning: domains)
            }
        }
    }
}
