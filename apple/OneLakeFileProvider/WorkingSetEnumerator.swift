// WorkingSetEnumerator.swift
// Minimal enumerator for the `.workingSet` container.
//
// The working set is macOS's bag of "recently used / actively
// referenced" items used for cross-folder search, badges, and the
// recents list. The daemon does not yet emit a change feed powering it,
// so we hand back an empty page and a constant zero-byte sync anchor.
// Returning a real (empty) enumerator rather than refusing keeps Finder,
// Spotlight, and the framework's badge machinery happy.

import FileProvider
import Foundation
import os.log

private let workingSetSyncAnchor = NSFileProviderSyncAnchor(Data())

final class WorkingSetEnumerator: NSObject, NSFileProviderEnumerator {
    private static let log = Logger(
        subsystem: "dev.debruyn.ofem.fileprovider",
        category: "working-set"
    )

    let alias: String

    init(domain: NSFileProviderDomain) {
        self.alias = OneLakeEnumerator.alias(from: domain)
        super.init()
    }

    func invalidate() {
        WorkingSetEnumerator.log.debug(
            "Invalidate working set enumerator for \(self.alias, privacy: .public)"
        )
    }

    func enumerateItems(
        for observer: NSFileProviderEnumerationObserver,
        startingAt _: NSFileProviderPage
    ) {
        WorkingSetEnumerator.log.debug(
            "enumerateItems(workingSet) for \(self.alias, privacy: .public) -> empty"
        )
        observer.finishEnumerating(upTo: nil)
    }

    func enumerateChanges(
        for observer: NSFileProviderChangeObserver,
        from _: NSFileProviderSyncAnchor
    ) {
        WorkingSetEnumerator.log.debug(
            "enumerateChanges(workingSet) for \(self.alias, privacy: .public) -> no changes"
        )
        observer.finishEnumeratingChanges(upTo: workingSetSyncAnchor, moreComing: false)
    }

    func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        completionHandler(workingSetSyncAnchor)
    }
}
