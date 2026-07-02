// OfemDomainIdentifier.swift
// Alias ↔ File Provider domain identifier composition.
//
// Every OFEM-owned NSFileProviderDomain identifier is "ofem.<alias>". The
// host composes it when registering domains (DomainSyncManager); the FPE
// decomposes it back to the alias on startup (FileProviderExtension). Both
// sides previously carried their own private copy of the "ofem." prefix —
// a change to one without the other would silently break the alias
// round-trip (xpc-09). This file is the single source both targets call into.

import Foundation

/// Prefix every OFEM-owned File Provider domain identifier carries.
public let ofemDomainIdentifierPrefix = "ofem."

/// Composes the domain identifier string for `alias` (e.g. `"work"` → `"ofem.work"`).
public func ofemDomainIdentifier(forAlias alias: String) -> String {
    "\(ofemDomainIdentifierPrefix)\(alias)"
}

/// Recovers the user-chosen account alias from a raw domain identifier
/// string (e.g. `"ofem.work"` → `"work"`). Returns the raw string unchanged
/// if it does not carry the OFEM prefix.
public func ofemAlias(fromDomainIdentifier raw: String) -> String {
    guard raw.hasPrefix(ofemDomainIdentifierPrefix) else { return raw }
    return String(raw.dropFirst(ofemDomainIdentifierPrefix.count))
}
