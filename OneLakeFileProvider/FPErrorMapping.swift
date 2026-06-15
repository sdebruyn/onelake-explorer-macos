// FPErrorMapping.swift
// Shared FPError.Code → NSFileProviderError conversion.
//
// One canonical mapping ensures that a code change (e.g. deciding .serverBusy
// should surface differently) is applied consistently at every FPE call site.

import FileProvider
import OfemKit

/// Maps a stable ``FPError/Code`` to the corresponding `NSFileProviderError`.
///
/// All FPE call sites (``FileProviderExtension``, ``OfemFPEEnumerator``) must
/// use this function exclusively — never inline the switch.
func nsFileProviderError(for code: FPError.Code) -> Error {
    switch code {
    case .noSuchItem:        return NSFileProviderError(.noSuchItem)
    case .notAuthenticated:  return NSFileProviderError(.notAuthenticated)
    case .serverBusy:        return NSFileProviderError(.serverUnreachable)
    case .serverUnreachable: return NSFileProviderError(.serverUnreachable)
    case .cannotSynchronize: return NSFileProviderError(.cannotSynchronize)
    }
}
