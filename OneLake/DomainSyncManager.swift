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
// `@MainActor` annotation serialises every entry point, and the
// `reconcileInFlight` guard prevents two reconcile passes from
// interleaving at async suspension points.
//
// reconcile() reads the account list from SharedOfemAuth (config.toml).
// addDomain(alias:) and removeDomain(alias:) are surgical alternatives
// for callers that already know exactly which domain to add or remove.

@preconcurrency import FileProvider
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
        subsystem: ofemSubsystem,
        category: "domain-sync"
    )

    /// Identifier prefix every OFEM-owned domain carries. Anything
    /// without this prefix is left alone — even if it lives in our
    /// process — to avoid clobbering domains another tool registered.
    ///
    /// The canonical value lives in `OfemConstants.ofemDomainIdentifierPrefix`.
    var identifierPrefix: String {
        ofemDomainIdentifierPrefix
    }

    init() {}

    // MARK: - Targeted domain operations

    /// Returns the domain identifier string for `alias`.
    func domainIdentifier(for alias: String) -> String {
        "\(identifierPrefix)\(alias)"
    }

    /// Returns an NSFileProviderDomain for `alias`.
    ///
    /// The `displayName` is set to the bare alias (not `"OneLake — <alias>"`):
    /// macOS composes the Finder sidebar label from `CFBundleDisplayName`
    /// ("OneLake") and the domain's `displayName` with an em-dash separator,
    /// producing "OneLake — <alias>" automatically. Passing just the alias is
    /// the correct and intentional input to that composition. Do not include the
    /// em-dash here — it is a display artefact, not part of the stored identifier.
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
            existing = try await ofemGetAllDomains()
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

    /// In-flight guard: prevents two concurrent reconcile() calls from
    /// interleaving at async suspension points and performing duplicate
    /// add/remove operations (host-20).
    private var reconcileInFlight = false

    /// Reconcile the macOS domain list with the account list from
    /// config.toml (via SharedOfemAuth).
    ///
    /// Safe to call repeatedly; concurrent calls while a pass is already
    /// in flight are dropped (not queued) since the in-flight pass will
    /// complete with the current account list anyway. Logs at info level
    /// for every add / remove so the operator can audit the activity from
    /// Console.app. Expressed in terms of addDomain/removeDomain so
    /// error-handling and domain-identifier composition are defined in
    /// exactly one place.
    func reconcile() async throws {
        guard !reconcileInFlight else {
            Self.log.debug("reconcile: skipped (pass already in flight)")
            return
        }
        reconcileInFlight = true
        defer { reconcileInFlight = false }

        let accounts = await SharedOfemAuth.shared.auth.listAccounts()
        let existing = try await ofemGetAllDomains()
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
}
