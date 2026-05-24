// RootEnumerator.swift
// Empty NSFileProviderEnumerator so the extension loads cleanly and
// Finder sees an empty root for any registered OneLake domain. Real
// enumeration (workspaces, items, paths) lands once the cgo bridge
// to the Go core is in place — see docs/file-provider.md.

import FileProvider
import os.log

/// Stub enumerator that returns an empty page for any container it
/// is asked about. Sufficient to let macOS register the domain and
/// not crash when the user clicks the (empty) OneLake sidebar entry.
final class RootEnumerator: NSObject, NSFileProviderEnumerator {
    private static let log = Logger(
        subsystem: "dev.debruyn.ofem.fileprovider",
        category: "enumerator"
    )

    /// The container the enumerator was created for. Held so the
    /// real implementation can route by identifier (root container,
    /// workspace, item, sub-path).
    let containerItemIdentifier: NSFileProviderItemIdentifier

    init(containerItemIdentifier: NSFileProviderItemIdentifier) {
        self.containerItemIdentifier = containerItemIdentifier
        super.init()
    }

    func invalidate() {
        RootEnumerator.log.debug(
            "Invalidate enumerator for \(self.containerItemIdentifier.rawValue, privacy: .public)"
        )
    }

    func enumerateItems(
        for observer: NSFileProviderEnumerationObserver,
        startingAt _: NSFileProviderPage
    ) {
        RootEnumerator.log.debug(
            "enumerateItems for \(self.containerItemIdentifier.rawValue, privacy: .public) — empty page"
        )
        observer.didEnumerate([])
        observer.finishEnumerating(upTo: nil)
    }

    func enumerateChanges(
        for observer: NSFileProviderChangeObserver,
        from _: NSFileProviderSyncAnchor
    ) {
        RootEnumerator.log.debug(
            "enumerateChanges for \(self.containerItemIdentifier.rawValue, privacy: .public) — no changes"
        )
        let anchor = NSFileProviderSyncAnchor(Data())
        observer.finishEnumeratingChanges(upTo: anchor, moreComing: false)
    }

    func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        completionHandler(NSFileProviderSyncAnchor(Data()))
    }
}
