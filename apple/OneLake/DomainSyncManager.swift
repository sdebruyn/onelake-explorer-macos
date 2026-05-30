// DomainSyncManager.swift
// Reconciles the set of `NSFileProviderDomain`s macOS knows about
// with the set of accounts the Go core has on file.
//
// The host app is the only process allowed to call
// `NSFileProviderManager.add` / `.remove`. The File Provider
// Extension is sandboxed and cannot mutate the domain list itself,
// and the daemon does not link against `FileProvider.framework`.
// So every domain edit funnels through this manager on the host
// app's main actor.
//
// Reconciliation is idempotent:
//
//   - For every account-alias the Go core reports, ensure a domain
//     with identifier `ofem.<alias>` is registered. If one is missing,
//     add it.
//   - For every registered domain that starts with `ofem.` but is
//     no longer in the account list, remove it (preserving the
//     user's downloaded content — they may want it back).
//
// Calling `reconcile()` more than once concurrently is safe: the
// `@MainActor` annotation serialises every entry point.

import FileProvider
import Foundation
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
    /// Mirrored in the File Provider Extension's `OneLakeEnumerator`
    /// (`ofemDomainIdentifierPrefix`); the two targets do not share
    /// source files, so the constant is defined twice on purpose.
    private let identifierPrefix = "ofem."

    private init() {}

    /// Reconcile the macOS domain list with the Go core's account
    /// list. Safe to call repeatedly. Logs at info level for every
    /// add / remove so the operator can audit the activity from
    /// Console.app.
    func reconcile() async throws {
        // Confirm we can locate the daemon socket (no in-process core to
        // boot any more). Cheap and synchronous — no IPC.
        _ = CoreBridge.shared.bootstrap()

        let accounts = try await CoreBridge.shared.listAccounts()
        let existing = try await Self.existingDomains()
        let existingById: [String: NSFileProviderDomain] = Dictionary(
            uniqueKeysWithValues: existing.map { ($0.identifier.rawValue, $0) }
        )

        let desiredIds = Set(accounts.map { "\(self.identifierPrefix)\($0.alias)" })

        // 1) Add domains for accounts that lack one.
        for account in accounts {
            let id = "\(self.identifierPrefix)\(account.alias)"
            if existingById[id] != nil {
                continue
            }
            // macOS's NSFileProviderDomain init takes only identifier +
            // displayName; pathRelativeToDocumentStorage is iOS-only.
            // The system picks the on-disk parent itself: each domain
            // materialises at ~/Library/CloudStorage/OneLake-<alias>/.
            //
            // Sidebar label: with only `account.alias` as displayName,
            // Finder's Locations sidebar collapses single-domain apps to
            // just "OneLake" (no em-dash, no alias). Set the displayName
            // to the full "OneLake — <alias>" string so the sidebar
            // entry is unambiguous from the first account onward, and
            // so multi-account setups disambiguate by alias the same
            // way OneDrive does ("OneDrive — Personal" / "OneDrive —
            // Company"). The em-dash is display-only; the on-disk path
            // stays ASCII (`OneLake-<alias>`).
            let domain = NSFileProviderDomain(
                identifier: NSFileProviderDomainIdentifier(rawValue: id),
                displayName: "OneLake \u{2014} \(account.alias)"
            )
            do {
                try await NSFileProviderManager.add(domain)
                Self.log.info("Added File Provider domain \(id, privacy: .public)")
            } catch {
                // macOS reports an EEXIST-like error if the domain is
                // already known; reconcile() should be idempotent so
                // log and continue rather than aborting.
                Self.log.notice(
                    "NSFileProviderManager.add(\(id, privacy: .public)) failed: \(error.localizedDescription, privacy: .public)"
                )
            }
        }

        // 2) Remove orphan domains — ones we own (have our prefix)
        // but the Go core no longer reports an account for.
        for (id, domain) in existingById {
            if !id.hasPrefix(self.identifierPrefix) {
                continue
            }
            if desiredIds.contains(id) {
                continue
            }
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
