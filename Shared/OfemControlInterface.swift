// OfemControlInterface.swift
// Single factory for the NSXPCInterface used on both sides of the
// host↔FPE control channel.
//
// xpc-09: the secure-coding class wiring for getEngineStatus's reply was
// duplicated in OfemFPEClient.swift (host) and OfemClientControlService.swift
// (FPE). NSXPCInterface's secure-coding policy fails silently — a class
// listed on one side but not the other decodes the value to nil at runtime
// rather than throwing or crashing. This factory is the single place that
// wiring is defined, so both sides always ship the same interface.

import Foundation

/// Builds the `NSXPCInterface` for `OfemClientControlProtocol`, including all
/// secure-coding class registrations. Both `OfemFPEClient` (host, sets
/// `remoteObjectInterface`) and the FPE's XPC listener delegate (sets
/// `exportedInterface`) must use the exact same interface, so this factory
/// is the single call site both sides use.
public enum OfemControlInterface {
    /// Returns a freshly configured `NSXPCInterface` for
    /// `OfemClientControlProtocol`. Call once per connection/listener.
    public static func make() -> NSXPCInterface {
        let iface = NSXPCInterface(with: OfemClientControlProtocol.self)

        // getEngineStatus reply: (XPCEngineStatus?, Error?)
        // XPCEngineStatus carries an NSArray of XPCPausedWorkspace; all three
        // types must be listed so XPC's secure-coding policy allows them to
        // cross the boundary.
        //
        // `setClasses(_:for:argumentIndex:ofReply:)` requires `Set<AnyHashable>`.
        // NSObject subclasses bridge to AnyHashable through ObjC, so the
        // NSSet(array:) bridge is the idiomatic Swift way to construct this set.
        // The force-cast is safe: ObjC class objects always bridge to AnyHashable.
        iface.setClasses(
            // swiftlint:disable:next force_cast
            NSSet(array: [XPCEngineStatus.self, NSArray.self, XPCPausedWorkspace.self]) as! Set<AnyHashable>,
            for: #selector(OfemClientControlProtocol.getEngineStatus(reply:)),
            argumentIndex: 0,
            ofReply: true
        )

        // getBadgeStatus reply: (XPCBadgeStatus?, Error?)
        // Same NSArray/XPCPausedWorkspace wiring as getEngineStatus above, plus
        // XPCBadgeStatus itself — the slim badge-status type (#397).
        iface.setClasses(
            // swiftlint:disable:next force_cast
            NSSet(array: [XPCBadgeStatus.self, NSArray.self, XPCPausedWorkspace.self]) as! Set<AnyHashable>,
            for: #selector(OfemClientControlProtocol.getBadgeStatus(reply:)),
            argumentIndex: 0,
            ofReply: true
        )
        return iface
    }
}
