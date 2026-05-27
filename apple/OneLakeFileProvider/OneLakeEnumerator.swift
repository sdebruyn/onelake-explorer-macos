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

/// Single-anchor sync token. Phase 1 always returns a zero-byte
/// anchor and an empty change set — macOS therefore treats every
/// enumeration as authoritative without ever asking us for diffs.
/// This keeps the Phase 1 surface tiny; real sync anchors land when
/// the daemon's change-detection ships.
///
/// The zero-byte value means macOS will call `enumerateChanges` with
/// this anchor and we will always respond "no changes, moreComing=false",
/// causing a full re-enumeration on every refresh. That is correct and
/// intentional for Phase 1.
///
/// TODO(phase-2): replace with MAX(SyncedAt) from the cache so the
/// daemon's change-detection path can emit real diffs and avoid full
/// re-enumerations on every Finder refresh.
private let phaseOneSyncAnchor = NSFileProviderSyncAnchor(Data())

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
    }

    // MARK: - Enumeration

    func enumerateItems(
        for observer: NSFileProviderEnumerationObserver,
        startingAt _: NSFileProviderPage
    ) {
        // The trash container has no bridge counterpart in Phase 1;
        // serve an empty page so Finder doesn't show stale state.
        if case .trashContainer = scope {
            observer.finishEnumerating(upTo: nil)
            return
        }
        let bridgeId = ItemIdentifierParser.bridgeIdentifier(for: scope)
        do {
            let items = try CoreBridge.shared.enumerate(alias: alias, identifier: bridgeId)
            let provided = items.map { OneLakeItem(from: $0) }
            OneLakeEnumerator.log.debug(
                "enumerateItems \(self.alias, privacy: .public)/\(bridgeId, privacy: .public) -> \(provided.count, privacy: .public) items"
            )
            observer.didEnumerate(provided)
            observer.finishEnumerating(upTo: nil)
        } catch let error as BridgeError {
            OneLakeEnumerator.log.error(
                "enumerateItems failed for \(self.alias, privacy: .public)/\(bridgeId, privacy: .public): \(String(describing: error), privacy: .public)"
            )
            observer.finishEnumeratingWithError(error.nsFileProviderError)
        } catch {
            OneLakeEnumerator.log.error(
                "enumerateItems failed for \(self.alias, privacy: .public)/\(bridgeId, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            observer.finishEnumeratingWithError(error)
        }
    }

    func enumerateChanges(
        for observer: NSFileProviderChangeObserver,
        from _: NSFileProviderSyncAnchor
    ) {
        // Phase 1: no incremental change support. macOS will fall back
        // to full re-enumeration whenever it needs fresh state, which
        // is fine for the read-only browsing path.
        OneLakeEnumerator.log.debug(
            "enumerateChanges \(self.alias, privacy: .public)/\(self.containerItemIdentifier.rawValue, privacy: .public) -> no changes"
        )
        observer.finishEnumeratingChanges(upTo: phaseOneSyncAnchor, moreComing: false)
    }

    func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        completionHandler(phaseOneSyncAnchor)
    }
}
