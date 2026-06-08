// OneLakeEnumerator.swift
// Polymorphic enumerator that translates File Provider enumeration
// requests onto the Go core's flat identifier model.
//
// Each File Provider domain corresponds to exactly one account-alias,
// and the alias is encoded in the domain identifier (`ofem.<alias>`).
// We pull it apart here once per enumerator instance so every call
// into the bridge can pass the alias and bridge-format identifier
// in a single hop.

import FileProvider
import Foundation
import os.log

/// Domain identifier prefix the host app stamps onto every domain it
/// registers. Defined here (and mirrored in `DomainSyncManager`) so a
/// rename only has to happen in two places.
let ofemDomainIdentifierPrefix = "ofem."

/// Single-anchor sync token. Real anchors are not yet tracked, so
/// `currentSyncAnchor` hands back a fixed zero-byte value and
/// `enumerateChanges` never computes a diff.
///
/// Crucially, `enumerateChanges` does NOT answer "no changes": that
/// would tell macOS its cached listing is authoritative, so macOS
/// would keep the first enumeration of every container forever and
/// never call `enumerateItems` again — a folder seen empty once would
/// stay empty even after its contents appeared server-side. Instead we
/// answer `.syncAnchorExpired`, which makes macOS discard its cache and
/// re-run `enumerateItems`. The Go core's own metadata-cache TTL keeps
/// that cheap, so this is the right read-only behaviour for now.
///
/// TODO: replace with MAX(SyncedAt) from the cache so the daemon's
/// change-detection path can emit real diffs and avoid full
/// re-enumerations on every Finder refresh.
private let staticSyncAnchor = NSFileProviderSyncAnchor(Data())

final class OneLakeEnumerator: NSObject, NSFileProviderEnumerator {
    private static let log = Logger(
        subsystem: "dev.debruyn.ofem.fileprovider",
        category: "enumerator"
    )

    /// Container we are enumerating. Held so we can hand it back to
    /// the framework verbatim in log lines and trace output.
    let containerItemIdentifier: NSFileProviderItemIdentifier

    /// Logical scope parsed from the container identifier.
    let scope: EnumScope

    /// Account-alias for the domain this enumerator belongs to.
    let alias: String

    /// In-flight enumeration task, retained so `invalidate()` (the
    /// framework's cancellation signal for enumerators — there is no
    /// per-call `NSProgress` here) can cancel the awaiting bridge call.
    private var inFlightTask: Task<Void, Never>?

    init(
        containerItemIdentifier: NSFileProviderItemIdentifier,
        scope: EnumScope,
        domain: NSFileProviderDomain
    ) {
        self.containerItemIdentifier = containerItemIdentifier
        self.scope = scope
        self.alias = Self.alias(from: domain)
        super.init()
    }

    /// Extract the alias from `ofem.<alias>`. Falls back to the raw
    /// identifier if the prefix is missing — the bridge will then
    /// reject the call cleanly and log a meaningful error.
    static func alias(from domain: NSFileProviderDomain) -> String {
        let raw = domain.identifier.rawValue
        if raw.hasPrefix(ofemDomainIdentifierPrefix) {
            return String(raw.dropFirst(ofemDomainIdentifierPrefix.count))
        }
        return raw
    }

    func invalidate() {
        OneLakeEnumerator.log.debug(
            "Invalidate enumerator for \(self.containerItemIdentifier.rawValue, privacy: .public)"
        )
        inFlightTask?.cancel()
        inFlightTask = nil
    }

    // MARK: - Enumeration

    func enumerateItems(
        for observer: NSFileProviderEnumerationObserver,
        startingAt page: NSFileProviderPage
    ) {
        // The trash container has no bridge counterpart;
        // serve an empty page so Finder doesn't show stale state.
        if case .trashContainer = scope {
            observer.finishEnumerating(upTo: nil)
            return
        }

        let bridgeId = BridgeItemIdentifierParser.bridgeIdentifier(for: scope)
        let aliasCopy = self.alias

        // Decode the cursor from the page's raw UTF-8 bytes.
        // The well-known initial pages (.initialPageSortedByName /
        // .initialPageSortedByDate) carry a single NUL byte or a
        // fixed Apple-internal marker; treat any non-UTF8-decodable
        // or empty value as "first page" (no cursor).
        let cursor: String
        if page == NSFileProviderPage.initialPageSortedByName as NSFileProviderPage
            || page == NSFileProviderPage.initialPageSortedByDate as NSFileProviderPage
        {
            cursor = ""
        } else {
            cursor = String(bytes: page.rawValue, encoding: .utf8) ?? ""
        }

        inFlightTask?.cancel()
        inFlightTask = Task {
            do {
                let result = try await CoreBridge.shared.enumerate(
                    alias: aliasCopy,
                    identifier: bridgeId,
                    cursor: cursor
                )
                let provided = result.items.map { OneLakeItem(from: $0) }
                OneLakeEnumerator.log.debug(
                    "enumerateItems \(aliasCopy, privacy: .public)/\(bridgeId, privacy: .public) cursor='\(cursor, privacy: .private)' -> \(provided.count, privacy: .public) items nextCursor='\(result.nextCursor, privacy: .private)'"
                )
                observer.didEnumerate(provided)
                // Signal the next page when the daemon provides a cursor,
                // or nil to indicate this is the last (or only) page.
                if result.nextCursor.isEmpty {
                    observer.finishEnumerating(upTo: nil)
                } else {
                    let nextPage = NSFileProviderPage(Data(result.nextCursor.utf8))
                    observer.finishEnumerating(upTo: nextPage)
                }
            } catch is CancellationError {
                OneLakeEnumerator.log.debug(
                    "enumerateItems cancelled for \(aliasCopy, privacy: .public)/\(bridgeId, privacy: .public)"
                )
                observer.finishEnumeratingWithError(NSFileProviderError(.cannotSynchronize))
            } catch let error as BridgeError {
                OneLakeEnumerator.log.error(
                    "enumerateItems failed for \(aliasCopy, privacy: .public)/\(bridgeId, privacy: .public): \(String(describing: error), privacy: .public)"
                )
                observer.finishEnumeratingWithError(error.nsFileProviderError)
            } catch {
                OneLakeEnumerator.log.error(
                    "enumerateItems failed for \(aliasCopy, privacy: .public)/\(bridgeId, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
                observer.finishEnumeratingWithError(error)
            }
        }
    }

    func enumerateChanges(
        for observer: NSFileProviderChangeObserver,
        from _: NSFileProviderSyncAnchor
    ) {
        // No incremental change support yet. Rather than claim "no changes"
        // (which would freeze macOS on its cached listing forever), expire the
        // anchor so macOS drops its cache and re-runs `enumerateItems`. The Go
        // core's metadata-cache TTL absorbs the cost, so refreshes stay cheap
        // on the read-only browsing path.
        OneLakeEnumerator.log.debug(
            "enumerateChanges \(self.alias, privacy: .public)/\(self.containerItemIdentifier.rawValue, privacy: .public) -> syncAnchorExpired (force re-enumerate)"
        )
        observer.finishEnumeratingWithError(NSFileProviderError(.syncAnchorExpired))
    }

    func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        completionHandler(staticSyncAnchor)
    }
}
