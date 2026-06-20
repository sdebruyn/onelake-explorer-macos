// ContainerSignaller.swift
// Signals a specific sub-container's enumerator via NSFileProviderManager.
//
// ContainerSignaller holds the NSFileProviderDomain for the FPE process and
// exposes a single async method that asks macOS to re-pull the enumerator for
// a given NSFileProviderItemIdentifier.  The call is non-fatal: failures are
// logged and swallowed so a signal failure never bubbles up to the caller.
//
// Actor isolation: ContainerSignaller has no actor isolation and makes no
// assumptions about which executor its methods run on.  Callers may call
// signal(container:) from any context.

@preconcurrency import FileProvider
import Foundation
import os.log

// MARK: - ContainerSignaller

/// Signals a specific sub-container enumerator in a File Provider domain.
///
/// Use `signal(container:)` to ask macOS to call back into `enumerateChanges`
/// for the given item identifier.  Only sub-containers should be signalled;
/// `.rootContainer` is deliberately excluded (signalling it throws
/// `.syncAnchorExpired`, which triggers a full re-enumeration).
///
/// `ContainerSignaller` is `Sendable`: it holds the domain via an
/// `@unchecked Sendable` box, matching the established pattern used in
/// `OfemFPEEnumerator` for `NSFileProviderEnumerationObserver` and
/// `NSFileProviderChangeObserver`.
struct ContainerSignaller: Sendable {
    private static let log = Logger(
        subsystem: "dev.debruyn.ofem.fileprovider",
        category: "container-signaller"
    )

    // NSFileProviderDomain is not Sendable; box it with @unchecked Sendable
    // following the same pattern as OfemFPEEnumerator (lines 211/288).
    private struct DomainBox: @unchecked Sendable {
        let value: NSFileProviderDomain
    }

    private let domainBox: DomainBox

    init(domain: NSFileProviderDomain) {
        self.domainBox = DomainBox(value: domain)
    }

    /// Signals the enumerator for `container` in the domain.
    ///
    /// Builds `NSFileProviderManager(for: domain)` on each call; the manager
    /// is not cached because the domain may be removed between calls.  If the
    /// manager cannot be created (domain removed/unregistered) the call is a
    /// no-op.  Any error from `signalEnumerator(for:)` is logged at `.warning`
    /// and swallowed — Finder's own periodic refresh will catch up.
    func signal(container: NSFileProviderItemIdentifier) async {
        let domain = domainBox.value
        let domainId = domain.identifier.rawValue

        guard let manager = NSFileProviderManager(for: domain) else {
            Self.log.debug(
                "ContainerSignaller: no manager for domain \(domainId, privacy: .public); domain may have been removed"
            )
            return
        }

        do {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                manager.signalEnumerator(for: container) { error in
                    if let error = error {
                        cont.resume(throwing: error)
                    } else {
                        cont.resume()
                    }
                }
            }
            Self.log.debug(
                "ContainerSignaller: signalled \(domainId, privacy: .public)/\(container.rawValue, privacy: .public)"
            )
        } catch {
            // Non-fatal: Finder's own periodic refresh will catch up.
            Self.log.warning(
                "ContainerSignaller: signalEnumerator failed for \(domainId, privacy: .public)/\(container.rawValue, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
        }
    }
}
